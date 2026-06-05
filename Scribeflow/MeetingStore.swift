import Foundation
import Observation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

private let storeLog = Logger(subsystem: "ai.scribeflow.app", category: "MeetingStore")

private actor MeetingPersistenceWriter {
    /// Encodes and atomically writes the library. Throws on encode/write
    /// failure so the caller can surface data loss instead of swallowing it.
    func saveMeetings(_ meetings: [Meeting], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meetings)
        try data.write(to: url, options: .atomic)
    }

    /// Copies the live file to a known-good backup — but only after verifying it
    /// still decodes. This snapshot is the recovery source if the main file is
    /// later truncated or corrupted. Called once per launch from a file we just
    /// loaded successfully, so it never propagates same-session bad state.
    func snapshotKnownGood(from source: URL, to backup: URL) {
        guard let data = try? Data(contentsOf: source), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard (try? decoder.decode([Meeting].self, from: data)) != nil else { return }
        try? data.write(to: backup, options: .atomic)
    }
}

@MainActor
@Observable
final class MeetingStore {
    var meetings: [Meeting] {
        didSet {
            revision &+= 1
            save()
            rebuildIndex()
            _recentMeetings = nil
            _pinnedMeetings = nil
            _openLoopsCache = nil
            _smartCollectionsCache = nil
        }
    }

    private(set) var revision = 0

    /// `true` when the most recent persistence attempt failed. Observed by the
    /// UI so data-loss is surfaced rather than silently swallowed.
    private(set) var lastSaveFailed = false

    /// Set at launch when the main library file was unreadable AND no backup
    /// could be recovered. The corrupt file is quarantined, not destroyed.
    private(set) var loadFailed = false

    /// Set at launch when the main file was unreadable but a backup restored
    /// the library. Surfaced so the user knows recovery happened.
    private(set) var recoveredFromBackup = false

    /// Bump when `Meeting`'s on-disk shape changes in a non-additive way.
    /// Backups carry this so a newer file isn't silently mis-read by an older
    /// build.
    static let currentSchemaVersion = 1

    @ObservationIgnored private var _recentMeetings: [Meeting]? = nil
    @ObservationIgnored private var _pinnedMeetings: [Meeting]? = nil
    @ObservationIgnored private var _openLoopsCache: [OpenLoop]? = nil
    @ObservationIgnored private var _smartCollectionsCache: [SmartCollectionCard]? = nil

    /// Dictionary index for O(1) `meeting(withID:)` lookup. Previously a
    /// linear `first(where:)` scan — measurable lag on libraries >100.
    @ObservationIgnored private var indexByID: [Meeting.ID: Int] = [:]

    /// A single welcoming example meeting for first launch. Notes are written
    /// to show the Smart Notes extraction at its best — a decision, owned
    /// actions (You / named), a due date, a risk — so the app feels alive and
    /// the core value is obvious on screen one.
    private static func firstRunExample() -> Meeting {
        Meeting(
            title: "Example · Acme kickoff",
            workspace: "Welcome",
            when: .now.addingTimeInterval(-1800),
            durationMinutes: 24,
            attendees: ["Maya", "Sam"],
            status: .ready,
            stage: "Captured and ready to review",
            objective: "See how Scribeflow turns rough notes into a clean, shareable recap.",
            rawNotes: """
            - We decided to start with the mobile rollout first
            - I'll send the security overview by Friday
            - Maya will confirm the integration scope
            - Risk: legal still needs to review the data terms
            - Budget approved at $25k for phase one
            - Tip: tap Enhance notes below, then Share recap
            """,
            transcript: [],
            summaries: [],
            prompts: [],
            destinations: [],
            selectedTemplate: .discovery,
            selectedPromptID: nil,
            isPinned: false
        )
    }

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        indexByID.reserveCapacity(meetings.count)
        for (i, m) in meetings.enumerated() {
            indexByID[m.id] = i
        }
    }

    @ObservationIgnored
    private let saveURL: URL

    /// Known-good snapshot, refreshed once per launch from a file that decoded.
    @ObservationIgnored
    private let backupURL: URL

    @ObservationIgnored
    private let persistenceWriter = MeetingPersistenceWriter()

    @ObservationIgnored
    private var saveTask: Task<Void, Never>?

    @ObservationIgnored
    private var regenTask: Task<Void, Never>?

    /// True only while loading seed data, so authored seed commitments are kept
    /// instead of being overwritten by note-derived generation.
    @ObservationIgnored
    private var isSeedLoad = false

    init() {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = baseDirectory.appendingPathComponent("Scribeflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? RecordingFileStore.ensureDirectory()
        let mainURL = folder.appendingPathComponent("meetings.json")
        saveURL = mainURL
        backupURL = folder.appendingPathComponent("meetings.backup.json")
        // Clean up legacy wellness.json from older builds (fitness feature was removed).
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("wellness.json"))
        let shouldResetData = ProcessInfo.processInfo.arguments.contains("-SCRIBEFLOW_RESET_DATA")
        let shouldUseSeedData = ProcessInfo.processInfo.arguments.contains("-SCRIBEFLOW_USE_SEED_DATA")

        let fileManager = FileManager.default
        let hasSavedData = fileManager.fileExists(atPath: mainURL.path)
            || fileManager.fileExists(atPath: backupURL.path)

        if shouldResetData {
            meetings = []
        } else if hasSavedData {
            // Real data wins over seed. Recovers from the backup and quarantines
            // (never deletes) a corrupt main file rather than wiping the library.
            let outcome = Self.loadMeetings(mainURL: mainURL, backupURL: backupURL)
            meetings = outcome.meetings.map(Self.normalizedMeeting)
            loadFailed = outcome.loadFailed
            recoveredFromBackup = outcome.recoveredFromBackup
        } else if shouldUseSeedData {
            meetings = Meeting.seed.map { meeting in
                var mutableMeeting = Self.normalizedMeeting(meeting)
                mutableMeeting.selectedPromptID = meeting.prompts.first?.id
                return mutableMeeting
            }
        } else if !UserDefaults.standard.bool(forKey: "scribeflow.didSeedFirstRunExample") {
            // Genuine first launch — land in one labeled example so the app
            // isn't a blank slate. Happens exactly once; deleting it is final.
            UserDefaults.standard.set(true, forKey: "scribeflow.didSeedFirstRunExample")
            meetings = [Self.normalizedMeeting(Self.firstRunExample())]
        } else {
            meetings = []
        }

        isSeedLoad = shouldUseSeedData
        for index in meetings.indices {
            refreshSummariesIfNeeded(at: index, applySupersededCommitments: false)
        }
        isSeedLoad = false
        applySupersededCommitments()

        // `didSet` doesn't fire for assignments inside `init`, so build the
        // lookup index up front instead of waiting for the first mutation.
        rebuildIndex()

        // Snapshot a known-good backup off the file we just loaded, so a future
        // corrupt write has a recovery source. Skipped when we already recovered
        // (the backup is the source) or when there's nothing persisted yet.
        if !loadFailed, !recoveredFromBackup, !meetings.isEmpty {
            let source = saveURL
            let backup = backupURL
            let writer = persistenceWriter
            Task(priority: .utility) { await writer.snapshotKnownGood(from: source, to: backup) }
        }
    }

    deinit {
        saveTask?.cancel()
    }

    // MARK: - Load + recovery

    struct LoadOutcome: Equatable {
        var meetings: [Meeting]
        var loadFailed: Bool
        var recoveredFromBackup: Bool
    }

    static func decodeMeetings(_ data: Data) -> [Meeting]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Meeting].self, from: data)
    }

    /// Loads the library with a recovery ladder: main → backup → quarantine.
    /// A corrupt main file is moved aside (preserved for manual rescue), never
    /// deleted, so an empty save can't permanently destroy it.
    static func loadMeetings(mainURL: URL, backupURL: URL) -> LoadOutcome {
        let fileManager = FileManager.default

        if let data = try? Data(contentsOf: mainURL), !data.isEmpty {
            if let meetings = decodeMeetings(data) {
                return LoadOutcome(meetings: meetings, loadFailed: false, recoveredFromBackup: false)
            }
            // Main is present but unreadable. Try the backup, then quarantine main.
            if let backupData = try? Data(contentsOf: backupURL), let meetings = decodeMeetings(backupData) {
                quarantine(mainURL, fileManager: fileManager)
                return LoadOutcome(meetings: meetings, loadFailed: false, recoveredFromBackup: true)
            }
            quarantine(mainURL, fileManager: fileManager)
            return LoadOutcome(meetings: [], loadFailed: true, recoveredFromBackup: false)
        }

        // No usable main file — fall back to the backup if one survived.
        if let backupData = try? Data(contentsOf: backupURL),
           let meetings = decodeMeetings(backupData), !meetings.isEmpty {
            return LoadOutcome(meetings: meetings, loadFailed: false, recoveredFromBackup: true)
        }
        return LoadOutcome(meetings: [], loadFailed: false, recoveredFromBackup: false)
    }

    /// Moves an unreadable file aside with a timestamp so the bytes survive for
    /// manual recovery instead of being overwritten by the next save.
    static func quarantine(_ url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let dest = url.deletingLastPathComponent().appendingPathComponent("meetings.corrupt-\(stamp).json")
        do {
            try fileManager.moveItem(at: url, to: dest)
            storeLog.error("Quarantined unreadable library to \(dest.lastPathComponent, privacy: .public)")
        } catch {
            storeLog.error("Failed to quarantine unreadable library: \(error.localizedDescription, privacy: .public)")
        }
    }

    var pinnedMeetings: [Meeting] {
        _ = meetings // register observation dependency
        if let cached = _pinnedMeetings { return cached }
        let computed = meetings.filter(\.isPinned).sorted(by: Meeting.sortDescending)
        _pinnedMeetings = computed
        return computed
    }

    var recentMeetings: [Meeting] {
        _ = meetings // register observation dependency
        if let cached = _recentMeetings { return cached }
        let computed = meetings.sorted(by: Meeting.sortDescending)
        _recentMeetings = computed
        return computed
    }

    var totalMeetingsCount: Int {
        meetings.count
    }

    var liveMeetingsCount: Int {
        meetings.filter { $0.status == .live }.count
    }

    var followUpCount: Int {
        meetings.filter { $0.status != .shared }.count
    }

    var sharedMeetingsCount: Int {
        meetings.filter { $0.status == .shared }.count
    }

    var phoneCallMeetingsCount: Int {
        meetings.filter(\.isCallMeeting).count
    }

    var workspacesCount: Int {
        Set(meetings.map(\.workspace)).count
    }

    var todayBrief: String {
        let recent = Array(recentMeetings.prefix(3))
        guard !recent.isEmpty else {
            return "Start with a quick note or live capture and Scribeflow will shape the rest."
        }

        let themes = topWorkspaceThemes(limit: 2)
        let firstTitle = recent[0].title

        if themes.isEmpty {
            return "Your latest thread is \(firstTitle). Scribeflow is ready to turn rough notes into a cleaner brief."
        }

        return "Your recent meetings keep circling around \(themes.joined(separator: " and ")). Start from \(firstTitle) or ask across the full workspace."
    }

    var workspaceSignals: [WorkspaceSignal] {
        let recent = Array(recentMeetings.prefix(8))
        guard !recent.isEmpty else {
            return [
                WorkspaceSignal(
                    title: "Ready to capture",
                    detail: "No saved meetings yet. The first few notes will shape your workspace pulse here.",
                    systemImage: "sparkles"
                )
            ]
        }

        var signals: [WorkspaceSignal] = []

        if let latest = recent.first {
            signals.append(
                WorkspaceSignal(
                    title: "Latest momentum",
                    detail: "\(latest.title) is your freshest note and can anchor the next follow-up.",
                    systemImage: "clock.arrow.circlepath"
                )
            )
        }

        let themes = topWorkspaceThemes(limit: 3)
        if !themes.isEmpty {
            signals.append(
                WorkspaceSignal(
                    title: "Recurring themes",
                    detail: themes.joined(separator: ", ").capitalized,
                    systemImage: "chart.line.text.clipboard"
                )
            )
        }

        if phoneCallMeetingsCount > 0 {
            signals.append(
                WorkspaceSignal(
                    title: "Call capture",
                    detail: "\(phoneCallMeetingsCount) call note\(phoneCallMeetingsCount == 1 ? "" : "s") saved and ready to refine.",
                    systemImage: "phone.connection.fill"
                )
            )
        }

        if followUpCount > 0 {
            signals.append(
                WorkspaceSignal(
                    title: "Open follow-through",
                    detail: "\(followUpCount) meeting\(followUpCount == 1 ? "" : "s") still need a next move or share-out.",
                    systemImage: "checklist.checked"
                )
            )
        }

        return Array(signals.prefix(3))
    }

    var totalOpenLoopsCount: Int {
        openLoops(limit: 50).count
    }

    var captureStreakDays: Int {
        let calendar = Calendar.current
        let meetingDays = Set(meetings.map { calendar.startOfDay(for: $0.when) })
        guard !meetingDays.isEmpty else { return 0 }
        var streak = 0
        var cursor = calendar.startOfDay(for: .now)
        if !meetingDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  meetingDays.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        while meetingDays.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    var weeklyMeetingCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        return meetings.filter { $0.when >= cutoff }.count
    }

    var weeklyMinutesCaptured: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        return meetings.filter { $0.when >= cutoff }.reduce(0) { $0 + $1.durationMinutes }
    }


    func evidenceItems(for meeting: Meeting, filter: EvidenceFilter = .all) -> [EvidenceItem] {
        switch filter {
        case .all:
            return meeting.evidenceItems
        case .verifiedOnly:
            return meeting.evidenceItems.filter { $0.level == .verified }
        case .hideInferred:
            return meeting.evidenceItems.filter { $0.level != .inferred }
        }
    }

    func signals(for meeting: Meeting) -> MeetingSignals {
        // The on-device model's brief wins when present — it comprehends context
        // and fixes typos, where the heuristic only matches keywords.
        if let brief = meeting.aiBrief, !brief.isEmpty {
            return MeetingSignals(
                decisions: brief.decisions,
                actions: brief.actions.map(aiActionSentence),
                risks: brief.risks,
                questions: brief.openQuestions
            )
        }
        // Decisions and actions come from the same distilling/classifying engine
        // that powers commitments, so the Overview surfaces meaningful items
        // ("Maya — send the deck (by Friday)") instead of any raw line that
        // happens to contain a cue word like "review" or "share".
        let decisions = MeetingIntelligenceEngine.decisions(for: meeting, limit: 4)
        let actions = MeetingIntelligenceEngine.structuredActions(for: meeting, limit: 5)
            .map(MeetingIntelligenceEngine.commitmentSentence)

        // Risks stay as surfaced mentions — they're concerns to notice, not
        // commitments. Exclude lines that are actually action items so a task
        // like "book the security walkthrough" doesn't double as a risk.
        let risks = extractedSignalLines(
            from: meeting,
            keywords: ["risk", "concern", "issue", "blocker", "security", "timeline", "budget", "delay", "problem"],
            fallbackPrefixes: ["risk", "concern", "issue"],
            limit: 4,
            exclude: MeetingIntelligenceEngine.isActionableLine
        )

        // Open questions — the unresolved items every meeting template surfaces.
        let questions = MeetingIntelligenceEngine.openQuestions(for: meeting, limit: 4)

        return MeetingSignals(decisions: decisions, actions: actions, risks: risks, questions: questions)
    }

    func openLoops(limit: Int = 6) -> [OpenLoop] {
        _ = meetings // register observation dependency
        if _openLoopsCache == nil {
            _openLoopsCache = recentMeetings
                .filter { $0.status != .shared }
                .flatMap { meeting -> [OpenLoop] in
                    let actionLoops = meeting.commitments
                        .filter { $0.status == .open || $0.status == .atRisk }
                        .prefix(2)
                        .map {
                            OpenLoop(
                                meetingID: meeting.id,
                                meetingTitle: meeting.title,
                                workspace: meeting.workspace,
                                kind: .action,
                                text: $0.formattedLine
                            )
                        }
                    let riskLoops = signals(for: meeting).risks.prefix(1).map {
                        OpenLoop(
                            meetingID: meeting.id,
                            meetingTitle: meeting.title,
                            workspace: meeting.workspace,
                            kind: .risk,
                            text: $0
                        )
                    }
                    return actionLoops + riskLoops
                }
        }
        return Array((_openLoopsCache!).prefix(limit))
    }

    func workspacePrepBrief() -> PrepBrief {
        let recent = Array(recentMeetings.prefix(4))
        guard let latest = recent.first else {
            return PrepBrief(
                headline: "Start a meeting or quick note and Scribeflow will build prep context here.",
                bullets: [],
                questions: []
            )
        }

        let themes = topWorkspaceThemes(limit: 3).map(\.capitalized)
        let latestSignals = signals(for: latest)

        var bullets: [String] = []
        if let firstDecision = latestSignals.decisions.first {
            bullets.append(firstDecision)
        }
        if let firstAction = latestSignals.actions.first {
            bullets.append(firstAction)
        }
        if bullets.isEmpty {
            bullets = recent.prefix(2).map {
                firstMeaningfulLine(in: $0.rawNotes) ?? $0.summary(for: $0.selectedTemplate).title
            }
        }

        var questions: [String] = []
        if let firstRisk = latestSignals.risks.first {
            questions.append("Resolve: \(firstRisk)")
        }
        if latestSignals.actions.count > 1 {
            questions.append("Confirm owner: \(latestSignals.actions[1])")
        } else if let recentAction = recent.dropFirst().compactMap({ signals(for: $0).actions.first }).first {
            questions.append("Carry forward: \(recentAction)")
        }

        let headline: String
        if themes.isEmpty {
            headline = "Prep from \(latest.title) and carry its next move into the next conversation."
        } else {
            headline = "Prep for the next conversation around \(themes.joined(separator: ", "))."
        }

        return PrepBrief(
            headline: headline,
            bullets: Array(bullets.prefix(3)),
            questions: Array(questions.prefix(2))
        )
    }

    func prepBrief(for meeting: Meeting) -> PrepBrief {
        let workspacePeers = recentMeetings.filter {
            $0.workspace == meeting.workspace && $0.id != meeting.id
        }
        let currentSignals = signals(for: meeting)

        var bullets: [String] = []
        if let decision = currentSignals.decisions.first {
            bullets.append(decision)
        }
        if let action = currentSignals.actions.first {
            bullets.append(action)
        }
        if let peer = workspacePeers.first {
            bullets.append(firstMeaningfulLine(in: peer.rawNotes) ?? peer.summary(for: peer.selectedTemplate).title)
        }

        var questions: [String] = []
        if let risk = currentSignals.risks.first {
            questions.append("Clarify: \(risk)")
        }
        if let nextAction = currentSignals.actions.dropFirst().first {
            questions.append("Lock next step: \(nextAction)")
        } else if let peerAction = workspacePeers.compactMap({ signals(for: $0).actions.first }).first {
            questions.append("Reconnect to prior thread: \(peerAction)")
        }

        return PrepBrief(
            headline: "Use this note as the launch point for your next \(meeting.workspace.lowercased()) conversation.",
            bullets: Array(bullets.prefix(3)),
            questions: Array(questions.prefix(2))
        )
    }

    func meeting(withID id: Meeting.ID) -> Meeting? {
        if let idx = indexByID[id], meetings.indices.contains(idx) {
            return meetings[idx]
        }
        if let match = meetings.first(where: { $0.id == id }) {
            storeLog.warning("Index miss for meeting \(id.uuidString, privacy: .public) — rebuilding")
            rebuildIndex()
            return match
        }
        return nil
    }

    func updateNotes(for id: Meeting.ID, notes: String) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].rawNotes = notes
        // Typing stays smooth: the raw text + autosave land immediately, but the
        // heavy summary/evidence/commitment regeneration is debounced so it runs
        // once the user pauses — not on every keystroke.
        scheduleRegeneration(for: id)
    }

    private func scheduleRegeneration(for id: Meeting.ID) {
        regenTask?.cancel()
        regenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            guard let index = self.meetings.firstIndex(where: { $0.id == id }) else { return }
            self.refreshSummariesIfNeeded(at: index)
        }
    }

    func updateTitle(_ title: String, for id: Meeting.ID) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].title = cleaned
        refreshSummariesIfNeeded(at: index)
    }

    func updateMeetingMode(_ mode: MeetingMode, for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].meetingMode = mode
    }

    func updateConsentState(_ state: ConsentState, for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].consentState = state
    }

    func updateRetentionPolicy(_ policy: RetentionPolicy, for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].retentionPolicy = policy
    }

    func setTranscriptVisibility(_ isVisible: Bool, for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].transcriptVisibilityEnabled = isVisible
    }

    func purgeTranscript(for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].transcript = []
        meetings[index].retentionPolicy = .notesOnly
        meetings[index].transcriptVisibilityEnabled = false
        meetings[index].stage = "Transcript purged after review"
        refreshSummariesIfNeeded(at: index)
    }

    func deleteEvidenceItem(for meetingID: Meeting.ID, evidenceID: EvidenceItem.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        let oldCount = meetings[index].evidenceItems.count
        meetings[index].evidenceItems.removeAll { $0.id == evidenceID }
        if meetings[index].evidenceItems.count != oldCount {
            meetings[index].rawNotes = meetings[index].evidenceItems.map(\.text).joined(separator: "\n")
            refreshSummariesIfNeeded(at: index)
        }
    }

    func updateCommitmentStatus(_ status: CommitmentStatus, commitmentID: Commitment.ID, for meetingID: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        guard let commitmentIndex = meetings[index].commitments.firstIndex(where: { $0.id == commitmentID }) else { return }
        meetings[index].commitments[commitmentIndex].status = status
    }

    func selectTemplate(_ template: NoteTemplate, for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].selectedTemplate = template
    }

    func selectPrompt(_ promptID: AIResponse.ID, for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].selectedPromptID = promptID
    }

    func markShared(for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].status = .shared
        meetings[index].stage = "Shared from iPhone"
    }

    func togglePinned(for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].isPinned.toggle()
    }

    // MARK: - Context Mode (Tier 2)

    func updateContextMode(_ mode: MeetingContextMode, for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].contextMode = mode
    }

    // MARK: - Meeting Score (Tier 2)

    func scoreAndSave(for id: Meeting.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        let meeting = meetings[index]
        // Only score a meeting that has something to score. The scorer baselines
        // every dimension at 50, so a thin or empty note would otherwise show a
        // meaningless mid-range number. No substance → no score (UI shows "—").
        let hasSubstance = !meeting.commitments.isEmpty
            || meeting.transcript.count > 3
            || meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).count >= 140
        meetings[index].score = hasSubstance ? MeetingScorer.score(for: meeting) : nil
    }

    // MARK: - Action Inbox (Tier 1)

    var pendingActionChecks: [ActionCheck] {
        ActionTracker.pendingChecks(from: meetings)
    }

    func resolveCommitment(commitmentID: Commitment.ID, in meetingID: Meeting.ID, as status: CommitmentStatus) {
        updateCommitmentStatus(status, commitmentID: commitmentID, for: meetingID)
    }

    /// Convenience for the Home action-items inbox: mark the first open or
    /// at-risk commitment in a meeting as fulfilled. Returns true if a
    /// commitment was resolved.
    @discardableResult
    func resolveFirstOpenCommitment(in meetingID: Meeting.ID) -> Bool {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return false }
        guard let commitment = meeting.commitments.first(where: { $0.status == .open || $0.status == .atRisk }) else {
            return false
        }
        updateCommitmentStatus(.fulfilled, commitmentID: commitment.id, for: meetingID)
        return true
    }

    // MARK: - People Intelligence (Tier 2)

    func personIntelligence(for name: String) -> PersonIntelligence {
        PeopleEngine.intelligence(for: name, in: meetings)
    }

    // MARK: - Product Intelligence

    func intelligenceReport(for meeting: Meeting) -> MeetingIntelligenceReport {
        MeetingIntelligenceEngine.report(for: meeting)
    }

    func speakerSegments(for meetingID: Meeting.ID) -> [SpeakerSegment] {
        guard let meeting = meeting(withID: meetingID) else { return [] }
        return MeetingIntelligenceEngine.report(for: meeting).speakerSegments
    }

    func renameSpeaker(_ currentName: String, to newName: String, for meetingID: Meeting.ID) {
        let cleanedCurrent = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedCurrent.isEmpty,
              !cleanedNew.isEmpty,
              cleanedCurrent.caseInsensitiveCompare(cleanedNew) != .orderedSame,
              let index = meetings.firstIndex(where: { $0.id == meetingID })
        else { return }

        for lineIndex in meetings[index].transcript.indices
        where meetings[index].transcript[lineIndex].speaker.caseInsensitiveCompare(cleanedCurrent) == .orderedSame {
            meetings[index].transcript[lineIndex].speaker = cleanedNew
        }

        meetings[index].attendees = meetings[index].attendees.map {
            $0.caseInsensitiveCompare(cleanedCurrent) == .orderedSame ? cleanedNew : $0
        }
        if !meetings[index].attendees.contains(where: { $0.caseInsensitiveCompare(cleanedNew) == .orderedSame }) {
            meetings[index].attendees.append(cleanedNew)
        }
        meetings[index].attendees = Array(Set(meetings[index].attendees)).sorted()
        meetings[index].stage = "Speaker labels reviewed"
        refreshSummariesIfNeeded(at: index)
    }

    // MARK: - Storage, Backup, and Privacy Controls

    func storageSnapshot() -> StorageSnapshot {
        let recordings = meetings.flatMap { meeting in
            meeting.audioRecordings.map { recording in
                StorageRecordingItem(
                    meetingID: meeting.id,
                    recordingID: recording.id,
                    meetingTitle: meeting.title,
                    recordingTitle: recording.title,
                    fileName: recording.fileName,
                    createdAt: recording.createdAt,
                    durationSeconds: recording.durationSeconds,
                    sizeBytes: RecordingFileStore.fileSize(at: RecordingFileStore.url(for: recording.fileName))
                )
            }
        }

        let audioBytes = recordings.reduce(0) { $0 + $1.sizeBytes }
        let databaseBytes = fileSize(at: saveURL)

        return StorageSnapshot(
            notesCount: meetings.count,
            recordingsCount: recordings.count,
            audioBytes: audioBytes,
            databaseBytes: databaseBytes,
            recordings: recordings
        )
    }

    enum BackupError: LocalizedError {
        case unreadable
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file isn't a Scribeflow backup, or it's damaged."
            case .newerVersion(let version):
                return "This backup (v\(version)) was made by a newer version of Scribeflow. Update the app, then restore."
            }
        }
    }

    func makeBackupData(includeAudio: Bool) throws -> Data {
        let audioFiles: [ScribeflowBackupAudioFile]
        if includeAudio {
            let fileNames = Set(meetings.flatMap { $0.audioRecordings.map(\.fileName) })
            audioFiles = fileNames.compactMap { fileName in
                let url = RecordingFileStore.url(for: fileName)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return ScribeflowBackupAudioFile(fileName: fileName, data: data)
            }
        } else {
            audioFiles = []
        }

        let package = ScribeflowBackupPackage(
            schemaVersion: Self.currentSchemaVersion,
            exportedAt: .now,
            meetings: meetings,
            audioFiles: audioFiles
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(package)
    }

    func restoreBackupData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package: ScribeflowBackupPackage
        do {
            package = try decoder.decode(ScribeflowBackupPackage.self, from: data)
        } catch {
            throw BackupError.unreadable
        }
        // Refuse a backup written by a future schema rather than silently
        // mis-reading it.
        guard package.schemaVersion <= Self.currentSchemaVersion else {
            throw BackupError.newerVersion(package.schemaVersion)
        }

        // Best-effort safety snapshot of the CURRENT library before the
        // destructive restore, so the user can recover their pre-restore state
        // if anything below fails.
        if let currentData = try? encodedMeetings() {
            try? currentData.write(to: backupURL, options: .atomic)
        }

        try RecordingFileStore.ensureDirectory()
        RecordingFileStore.deleteAllFiles()
        for audioFile in package.audioFiles {
            let url = RecordingFileStore.url(for: audioFile.fileName)
            try audioFile.data.write(to: url, options: [.atomic])
            RecordingFileStore.protectFile(at: url)
        }

        meetings = package.meetings.map(Self.normalizedMeeting)

        for index in meetings.indices {
            refreshSummariesIfNeeded(at: index)
        }
    }

    private func encodedMeetings() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(meetings)
    }

    func deleteAllUserData() {
        RecordingFileStore.deleteAllFiles()
        meetings = []
    }

    @discardableResult
    func cleanupRecordings(_ action: StorageCleanupAction) -> Int {
        switch action {
        case .largeRecordings(let minimumBytes):
            return deleteRecordings { recording in
                RecordingFileStore.fileSize(at: RecordingFileStore.url(for: recording.fileName)) >= minimumBytes
            }
        case .olderRecordings(let days):
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
            return deleteRecordings { recording in
                recording.createdAt < cutoff
            }
        case .allRecordings:
            return deleteRecordings { _ in true }
        }
    }

    var allPeople: [String] {
        PeopleEngine.allPeople(from: meetings)
    }

    // MARK: - Share Note (Tier 1)

    func richShareText(for id: Meeting.ID) -> String {
        guard let meeting = meeting(withID: id) else { return "" }
        let summary = meeting.summary(for: meeting.selectedTemplate)
        var lines: [String] = []
        lines.append("📋 \(meeting.title)")
        lines.append("\(meeting.when.formatted(date: .complete, time: .shortened))")
        lines.append("")
        lines.append(summary.title)
        for section in summary.sections {
            lines.append("")
            lines.append("• \(section.title)")
            lines.append(contentsOf: section.bullets.map { "  · \($0)" })
        }
        let openActions = meeting.commitments.filter { $0.status == .open }
        if !openActions.isEmpty {
            lines.append("")
            lines.append("Action Items:")
            lines.append(contentsOf: openActions.prefix(5).map { "  ☐ \($0.statement) [\($0.owner)]" })
        }
        lines.append("")
        lines.append("—")
        lines.append("Sent from Scribeflow")
        return lines.joined(separator: "\n")
    }

    func deleteMeeting(_ id: Meeting.ID) {
        if let meeting = meeting(withID: id) {
            for recording in meeting.audioRecordings {
                RecordingFileStore.deleteFile(named: recording.fileName)
            }
        }
        meetings.removeAll { $0.id == id }
    }

    /// Removes the meeting from the visible array but defers deletion of audio
    /// files to `finalizeDelete(_:)`. Returns the snapshot + original index so
    /// the caller can offer Undo and put it back in place.
    func softDeleteMeeting(_ id: Meeting.ID) -> (Meeting, Int)? {
        guard let idx = meetings.firstIndex(where: { $0.id == id }) else { return nil }
        let snapshot = meetings[idx]
        meetings.remove(at: idx)
        return (snapshot, idx)
    }

    /// Re-inserts a soft-deleted meeting at its prior index (clamped if the
    /// array shifted in the meantime).
    func restoreMeeting(_ meeting: Meeting, at index: Int) {
        let clamped = min(max(index, 0), meetings.count)
        meetings.insert(meeting, at: clamped)
    }

    /// Permanently removes the on-disk audio files for a soft-deleted meeting.
    /// Called after the Undo window elapses.
    func finalizeDelete(_ meeting: Meeting) {
        for recording in meeting.audioRecordings {
            RecordingFileStore.deleteFile(named: recording.fileName)
        }
    }

    func duplicateMeeting(_ id: Meeting.ID) -> Meeting.ID? {
        guard let meeting = meeting(withID: id) else { return nil }
        var duplicate = meeting
        duplicate.id = UUID()
        duplicate.when = .now
        duplicate.status = .ready
        duplicate.stage = "Duplicated for follow-up"
        duplicate.isPinned = false
        duplicate.audioRecordings = []
        duplicate.summaries = generatedSummaries(for: duplicate)
        duplicate.selectedPromptID = duplicate.prompts.first?.id
        meetings.insert(duplicate, at: 0)
        return duplicate.id
    }

    func exportText(for id: Meeting.ID, format: MeetingExportFormat) -> String? {
        guard let meeting = meeting(withID: id) else { return nil }
        return safeSharePreview(
            for: meeting,
            format: format,
            includeInferred: format != .clientRecap,
            includePrivateNotes: format == .internalBrief,
            includeTranscript: false
        )
    }

    func safeSharePreview(
        for meetingID: Meeting.ID,
        format: MeetingExportFormat,
        includeInferred: Bool,
        includePrivateNotes: Bool,
        includeTranscript: Bool
    ) -> String? {
        guard let meeting = meeting(withID: meetingID) else { return nil }
        return safeSharePreview(
            for: meeting,
            format: format,
            includeInferred: includeInferred,
            includePrivateNotes: includePrivateNotes,
            includeTranscript: includeTranscript
        )
    }

    func shareReviewFlags(
        for meetingID: Meeting.ID,
        includeInferred: Bool,
        includePrivateNotes: Bool,
        includeTranscript: Bool
    ) -> [String] {
        guard let meeting = meeting(withID: meetingID) else { return [] }
        var flags = meeting.sensitiveFlags.map { "Contains \($0.title.lowercased())" }

        if includeInferred, meeting.evidenceItems.contains(where: { $0.level == .inferred }) {
            flags.append("Includes inferred bullets")
        }
        if includePrivateNotes, meeting.meetingMode == .privateNotes {
            flags.append("Includes private-note context")
        }
        if includeTranscript, meeting.transcript.isEmpty == false {
            flags.append("Includes transcript snippets")
        }
        if meeting.consentState == .privateCapture && meeting.meetingMode != .privateNotes {
            flags.append("Disclosure state may not match sharing mode")
        }

        return flags
    }

    func markdownExport(for id: Meeting.ID) -> String? {
        exportText(for: id, format: .internalBrief)
    }

    func answerMeetingPrompt(for id: Meeting.ID, prompt: String) async -> String {
        guard let meeting = meeting(withID: id) else {
            return "Meeting not found."
        }
        guard !Task.isCancelled else { return "" }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch AppleIntelligenceNoteTransformer.availability() {
            case .available:
                do {
                    return try await AppleIntelligenceMeetingAssistant.answer(
                        meeting: meeting,
                        prompt: prompt
                    )
                } catch {
                    break
                }
            default:
                break
            }
        }
        #endif

        return fallbackPromptAnswer(for: meeting, prompt: prompt)
    }

    func answerAcrossMeetings(
        prompt: String,
        includeTranscripts: Bool,
        workspaceFilter: String? = nil,
        modelSelection: ChatModelSelection = .auto
    ) async -> String {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedPrompt.isEmpty else {
            return "Ask about decisions, follow-ups, blockers, or what changed across your recent meetings."
        }

        let scopedPool = recentMeetings.filter { meeting in
            guard let workspaceFilter, !workspaceFilter.isEmpty else { return true }
            return meeting.workspace.caseInsensitiveCompare(workspaceFilter) == .orderedSame
        }
        let scopedMeetings = Array(scopedPool.prefix(includeTranscripts ? 25 : 40))

        guard !scopedMeetings.isEmpty else {
            if let workspaceFilter, !workspaceFilter.isEmpty {
                return "There aren’t any saved meetings in \(workspaceFilter) yet."
            }
            return "There aren’t any saved meetings yet, so there’s nothing to search across."
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch AppleIntelligenceNoteTransformer.availability() {
            case .available:
                do {
                    return try await AppleIntelligenceWorkspaceAssistant.answer(
                        meetings: scopedMeetings,
                        prompt: normalizedPrompt,
                        includeTranscripts: includeTranscripts,
                        modelSelection: modelSelection
                    )
                } catch {
                    break
                }
            default:
                break
            }
        }
        #endif

        return fallbackWorkspaceAnswer(
            for: scopedMeetings,
            prompt: normalizedPrompt,
            includeTranscripts: includeTranscripts,
            modelSelection: modelSelection
        )
    }

    func workspaceFolders() -> [WorkspaceFolder] {
        let grouped = Dictionary(grouping: recentMeetings, by: \.workspace)
        return grouped.compactMap { workspace, meetings in
            guard let latest = meetings.max(by: { $0.when < $1.when }) else { return nil }
            return WorkspaceFolder(
                name: workspace,
                description: latest.objective,
                meetingCount: meetings.count,
                latestMeetingDate: latest.when
            )
        }
        .sorted { lhs, rhs in
            if lhs.latestMeetingDate == rhs.latestMeetingDate {
                return lhs.name < rhs.name
            }
            return lhs.latestMeetingDate > rhs.latestMeetingDate
        }
    }

    func smartCollections() -> [SmartCollectionCard] {
        _ = meetings // register observation dependency
        if let cached = _smartCollectionsCache { return cached }
        let computed = SmartCollectionKind.allCases.map { kind in
            SmartCollectionCard(kind: kind, count: meetings(matching: kind).count)
        }
        _smartCollectionsCache = computed
        return computed
    }

    func meetings(matching collection: SmartCollectionKind) -> [Meeting] {
        switch collection {
        case .all:
            return recentMeetings
        case .followUp:
            return recentMeetings.filter { $0.status != .shared }
        case .calls:
            return recentMeetings.filter(\.isCallMeeting)
        case .pinned:
            return recentMeetings.filter(\.isPinned)
        case .shared:
            return recentMeetings.filter { $0.status == .shared }
        }
    }

    func tags(for meeting: Meeting) -> [String] {
        Array(Set(extractedWorkspaceTags(from: meeting))).sorted().prefix(4).map { $0.capitalized }
    }

    func meetings(in folder: WorkspaceFolder) -> [Meeting] {
        recentMeetings
            .filter { $0.workspace.caseInsensitiveCompare(folder.name) == .orderedSame }
            .sorted(by: Meeting.sortDescending)
    }

    func deleteTranscriptLine(for meetingID: Meeting.ID, lineID: TranscriptLine.ID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        let oldCount = meetings[index].transcript.count
        meetings[index].transcript.removeAll { $0.id == lineID }

        guard meetings[index].transcript.count != oldCount else { return }

        meetings[index].stage = "Transcript edited for privacy"
        refreshSummariesIfNeeded(at: index)
    }

    func addMeeting(
        title: String,
        workspace: String,
        attendees: [String],
        objective: String,
        notes: String,
        moments: [String] = [],
        transcript: [TranscriptLine] = [],
        status: MeetingStatus = .ready,
        stage: String = "Captured from iPhone notes",
        durationMinutes: Int = 25,
        meetingMode: MeetingMode = .privateNotes,
        consentState: ConsentState = .privateCapture,
        retentionPolicy: RetentionPolicy = .keepUntilDeleted,
        audioRecordings: [AudioRecordingAttachment] = []
    ) -> Meeting.ID {
        let normalizedAttendees = attendees.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var meeting = Meeting(
            title: title,
            workspace: workspace,
            when: .now,
            durationMinutes: durationMinutes,
            attendees: normalizedAttendees.isEmpty ? ["You"] : normalizedAttendees,
            status: status,
            stage: stage,
            objective: objective,
            rawNotes: notes.isEmpty ? "- Add your key takeaways here" : notes,
            transcript: transcript,
            summaries: [],
            prompts: Self.defaultPrompts(),
            destinations: ["Email", "Slack", "Notion"],
            selectedTemplate: .discovery,
            selectedPromptID: nil,
            isPinned: false,
            consentState: consentState,
            meetingMode: meetingMode,
            retentionPolicy: retentionPolicy,
            transcriptVisibilityEnabled: transcript.isEmpty == false,
            audioRecordings: audioRecordings
        )
        meeting.summaries = generatedSummaries(for: meeting)
        meeting.evidenceItems = generatedEvidenceItems(for: meeting)
        meeting.commitments = generatedCommitments(for: meeting)
        meeting.sensitiveFlags = detectedSensitiveFlags(for: meeting)
        meeting.selectedPromptID = meeting.prompts.first?.id
        meetings.insert(meeting, at: 0)
        applySupersededCommitments()
        // Upgrade to a model-processed brief in the background when available;
        // the heuristic above is shown instantly in the meantime.
        let newID = meeting.id
        Task { await processWithAI(for: newID) }
        return meeting.id
    }

    func livePolishedPreview(
        title: String,
        objective: String,
        notes: String,
        transcriptParagraphs: [String]
    ) -> [String] {
        let cleanedTranscript = transcriptParagraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedNotes.isEmpty || !cleanedTranscript.isEmpty else {
            return []
        }

        let seedNotes: String
        if cleanedNotes.isEmpty {
            seedNotes = cleanedTranscript
                .prefix(3)
                .map { "- \($0)" }
                .joined(separator: "\n")
        } else {
            seedNotes = cleanedNotes
        }

        let polished = enhancedLiveNotes(notes: seedNotes, transcriptParagraphs: cleanedTranscript)
        return polished
            .components(separatedBy: .newlines)
            .map {
                $0
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "- ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    func addMeetingWithTransformation(
        title: String,
        workspace: String,
        attendees: [String],
        objective: String,
        notes: String,
        moments: [String] = [],
        transcript: [TranscriptLine] = [],
        status: MeetingStatus = .ready,
        stage: String = "Captured from iPhone notes",
        durationMinutes: Int = 25,
        meetingMode: MeetingMode = .privateNotes,
        consentState: ConsentState = .privateCapture,
        retentionPolicy: RetentionPolicy = .keepUntilDeleted,
        audioRecordings: [AudioRecordingAttachment] = []
    ) async -> Meeting.ID {
        let meetingID = addMeeting(
            title: title,
            workspace: workspace,
            attendees: attendees,
            objective: objective,
            notes: notes,
            moments: moments,
            transcript: transcript,
            status: status,
            stage: stage,
            durationMinutes: durationMinutes,
            meetingMode: meetingMode,
            consentState: consentState,
            retentionPolicy: retentionPolicy,
            audioRecordings: audioRecordings
        )

        _ = await rewriteMeetingNotes(for: meetingID)
        appendMoments(to: meetingID, moments: moments)
        return meetingID
    }

    func addLiveMeeting(
        title: String,
        workspace: String,
        attendees: [String],
        objective: String,
        notes: String,
        moments: [String] = [],
        transcriptParagraphs: [String],
        meetingMode: MeetingMode = .privateNotes,
        consentState: ConsentState = .privateCapture,
        retentionPolicy: RetentionPolicy = .keepUntilDeleted
    ) async -> Meeting.ID {
        let enhancedNotes = enhancedLiveNotes(notes: notes, transcriptParagraphs: transcriptParagraphs)
        let transcriptLines = transcriptParagraphs.map {
            TranscriptLine(speaker: "Meeting", role: "Live capture", text: $0)
        }

        let meetingID = addMeeting(
            title: title,
            workspace: workspace,
            attendees: attendees,
            objective: objective,
            notes: enhancedNotes,
            moments: moments,
            transcript: transcriptLines,
            status: .ready,
            stage: "Captured live on iPhone",
            meetingMode: meetingMode,
            consentState: consentState,
            retentionPolicy: retentionPolicy
        )

        _ = await rewriteMeetingNotes(for: meetingID)
        appendMoments(to: meetingID, moments: moments)
        return meetingID
    }

    func addVoiceRecording(
        title: String,
        workspace: String,
        notes: String,
        recording: AudioRecordingAttachment
    ) async -> Meeting.ID {
        let transcriptLines = transcriptLines(from: recording.transcript, speaker: "Voice note", role: recording.source.title)
        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackNotes = recording.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawNotes = cleanedNotes.isEmpty
            ? (fallbackNotes.isEmpty ? "- Voice note recorded. Add notes after review." : fallbackNotes)
            : cleanedNotes

        let meetingID = addMeeting(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Voice note" : title,
            workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Voice Notes" : workspace,
            attendees: ["You"],
            objective: "Capture a voice note with audio, transcript, and linked notes.",
            notes: rawNotes,
            transcript: transcriptLines,
            status: .ready,
            stage: "Recorded voice note",
            durationMinutes: recording.durationMinutes,
            meetingMode: .privateNotes,
            consentState: .privateCapture,
            retentionPolicy: recording.hasTranscript ? .transcript7Days : .keepUntilDeleted,
            audioRecordings: [recording]
        )

        _ = await rewriteMeetingNotes(for: meetingID)
        return meetingID
    }

    func attachVoiceRecording(
        _ recording: AudioRecordingAttachment,
        to meetingID: Meeting.ID,
        appendTranscriptToNotes: Bool
    ) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        if !meetings[index].audioRecordings.contains(where: { $0.id == recording.id }) {
            meetings[index].audioRecordings.append(recording)
        }

        let newTranscript = transcriptLines(
            from: recording.transcript,
            speaker: "Voice note",
            role: recording.source.title
        )
        if !newTranscript.isEmpty {
            let existingFingerprints = Set(meetings[index].transcript.map { normalizedFingerprint($0.text) })
            let filtered = newTranscript.filter { !existingFingerprints.contains(normalizedFingerprint($0.text)) }
            meetings[index].transcript.append(contentsOf: filtered)
            meetings[index].transcriptVisibilityEnabled = true
        }

        if appendTranscriptToNotes {
            let noteParts = [
                recording.linkedNote.trimmingCharacters(in: .whitespacesAndNewlines),
                recording.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            let addendum = noteParts.first(where: { !$0.isEmpty }) ?? ""
            if !addendum.isEmpty {
                if meetings[index].rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    meetings[index].rawNotes = addendum
                } else {
                    meetings[index].rawNotes += "\n\nVoice note: \(addendum)"
                }
            }
        }

        let totalRecordingSeconds = meetings[index].audioRecordings.reduce(0) { $0 + $1.durationSeconds }
        meetings[index].durationMinutes = max(meetings[index].durationMinutes, Int(ceil(Double(totalRecordingSeconds) / 60.0)))
        meetings[index].stage = "Voice recording attached"
        meetings[index].sensitiveFlags = detectedSensitiveFlags(for: meetings[index])
        refreshSummariesIfNeeded(at: index)
    }

    func updateRecordingTitle(_ title: String, recordingID: AudioRecordingAttachment.ID, in meetingID: Meeting.ID) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let meetingIndex = meetings.firstIndex(where: { $0.id == meetingID }),
              let recordingIndex = meetings[meetingIndex].audioRecordings.firstIndex(where: { $0.id == recordingID })
        else { return }

        meetings[meetingIndex].audioRecordings[recordingIndex].title = cleaned
    }

    func deleteRecording(_ recordingID: AudioRecordingAttachment.ID, from meetingID: Meeting.ID) {
        guard let meetingIndex = meetings.firstIndex(where: { $0.id == meetingID }),
              let recording = meetings[meetingIndex].audioRecordings.first(where: { $0.id == recordingID })
        else { return }

        meetings[meetingIndex].audioRecordings.removeAll { $0.id == recordingID }
        RecordingFileStore.deleteFile(named: recording.fileName)
        meetings[meetingIndex].stage = meetings[meetingIndex].audioRecordings.isEmpty
            ? "Audio removed after review"
            : "Voice recording removed"
        refreshSummariesIfNeeded(at: meetingIndex)
    }

    private func deleteRecordings(where shouldDelete: (AudioRecordingAttachment) -> Bool) -> Int {
        var updatedMeetings = meetings
        var deletedCount = 0

        for index in updatedMeetings.indices {
            let removed = updatedMeetings[index].audioRecordings.filter(shouldDelete)
            guard !removed.isEmpty else { continue }

            for recording in removed {
                RecordingFileStore.deleteFile(named: recording.fileName)
            }

            let removedIDs = Set(removed.map(\.id))
            updatedMeetings[index].audioRecordings.removeAll { removedIDs.contains($0.id) }
            updatedMeetings[index].stage = updatedMeetings[index].audioRecordings.isEmpty
                ? "Audio files cleaned up"
                : "Some audio files cleaned up"
            deletedCount += removed.count
        }

        guard deletedCount > 0 else { return 0 }

        meetings = updatedMeetings
        for index in meetings.indices {
            refreshSummariesIfNeeded(at: index)
        }
        return deletedCount
    }

    func audioURL(for recording: AudioRecordingAttachment) -> URL {
        RecordingFileStore.url(for: recording.fileName)
    }

    func rewriteMeetingNotes(for id: Meeting.ID, style: NoteRewriteStyle = .concise) async -> String {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else {
            return "Meeting not found."
        }

        let meeting = meetings[index]
        let preservedMoments = extractedBookmarkMoments(from: meeting.rawNotes)
        let outcome = await polishNotes(
            title: meeting.title,
            objective: meeting.objective,
            notes: meeting.rawNotes,
            transcriptParagraphs: meeting.transcript.map(\.text),
            style: style
        )

        switch outcome {
        case let .appleIntelligence(rewrittenNotes, message):
            meetings[index].rawNotes = mergedNotesWithMoments(rewrittenNotes, moments: preservedMoments)
            meetings[index].stage = "Apple Intelligence polished notes"
            refreshSummariesIfNeeded(at: index)
            return message
        case let .heuristic(rewrittenNotes, message):
            if !rewrittenNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                meetings[index].rawNotes = mergedNotesWithMoments(rewrittenNotes, moments: preservedMoments)
                refreshSummariesIfNeeded(at: index)
            }
            if meetings[index].transcript.isEmpty == false {
                meetings[index].stage = "Auto-polished from transcript"
            }
            return message
        case let .unavailable(message):
            return message
        }
    }

    /// Process a meeting's notes with the on-device language model into a clean,
    /// typo-corrected, structured brief, and store it. The brief's read sites
    /// (signals, commitments, summaries) prefer it; if the model is unavailable
    /// or fails, nothing changes and the heuristic engine stays in charge.
    /// Meetings the model is currently processing — drives the "Processing…"
    /// indicator in the UI.
    private(set) var aiProcessingIDs: Set<Meeting.ID> = []

    func isProcessingAI(_ id: Meeting.ID) -> Bool { aiProcessingIDs.contains(id) }

    func processWithAI(for id: Meeting.ID) async {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = AppleIntelligenceBriefExtractor.availability() else { return }
            guard let meeting = meeting(withID: id) else { return }
            aiProcessingIDs.insert(id)
            defer { aiProcessingIDs.remove(id) }
            do {
                let brief = try await AppleIntelligenceBriefExtractor.extract(
                    title: meeting.title,
                    notes: meeting.rawNotes,
                    transcriptParagraphs: meeting.transcript.map(\.text)
                )
                guard !brief.isEmpty,
                      let index = meetings.firstIndex(where: { $0.id == id }) else { return }
                meetings[index].aiBrief = brief
                refreshSummariesIfNeeded(at: index)
                meetings[index].score = MeetingScorer.score(for: meetings[index])
            } catch {
                // Heuristic stays in charge.
            }
        }
        #endif
    }

    /// "Maya — send the deck (by Friday)" from an AI action item.
    func aiActionSentence(_ a: AIActionItem) -> String {
        let core = a.task.hasSuffix(".") ? String(a.task.dropLast()) : a.task
        let due = a.due.isEmpty ? "" : " (by \(a.due))"
        if !a.owner.isEmpty, a.owner != "Owner not named" {
            let lowered = core.prefix(1).lowercased() + core.dropFirst()
            return "\(a.owner) — \(lowered)\(due)"
        }
        return "\(core)\(due)"
    }

    private func save() {
        let snapshot = meetings
        let url = saveURL
        let writer = persistenceWriter
        saveTask?.cancel()
        saveTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try await writer.saveMeetings(snapshot, to: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastSaveFailed = false
                }
            } catch {
                storeLog.error("Failed to persist meetings: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastSaveFailed = true
                }
            }
        }
    }

    private func refreshSummariesIfNeeded(at index: Int, applySupersededCommitments shouldApplySupersededCommitments: Bool = true) {
        meetings[index].summaries = generatedSummaries(for: meetings[index])
        meetings[index].evidenceItems = generatedEvidenceItems(for: meetings[index])
        // Keep explicitly authored seed commitments; otherwise derive from notes.
        if !(isSeedLoad && !meetings[index].commitments.isEmpty) {
            meetings[index].commitments = generatedCommitments(for: meetings[index])
        }
        meetings[index].sensitiveFlags = detectedSensitiveFlags(for: meetings[index])
        if shouldApplySupersededCommitments {
            applySupersededCommitments()
        }
    }

    private func generatedSummaries(for meeting: Meeting) -> [TemplateSummary] {
        let noteLines = meeting.rawNotes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•\t")) }
            .filter { !$0.isEmpty }

        // Prefer the model's structured brief; otherwise fall back to the
        // heuristic. Only ever label something a "decision" or "next step" if it
        // really is one — never mislabel note lines or prefill a placeholder.
        let decisions: [String]
        let nextSteps: [String]
        let keyPoints: [String]
        if let brief = meeting.aiBrief, !brief.isEmpty {
            decisions = brief.decisions
            nextSteps = brief.actions.map(aiActionSentence)
            keyPoints = brief.keyPoints
        } else {
            decisions = MeetingIntelligenceEngine.decisions(for: meeting, limit: 3)
            nextSteps = MeetingIntelligenceEngine.structuredActions(for: meeting, limit: 4)
                .map(MeetingIntelligenceEngine.commitmentSentence)
            keyPoints = MeetingIntelligenceEngine.keyPoints(for: meeting, limit: 5)
        }

        func sections(_ decisionsTitle: String, _ stepsTitle: String, _ pointsTitle: String) -> [SummarySection] {
            var out: [SummarySection] = []
            if !decisions.isEmpty { out.append(SummarySection(title: decisionsTitle, bullets: decisions)) }
            if !nextSteps.isEmpty { out.append(SummarySection(title: stepsTitle, bullets: nextSteps)) }
            if !keyPoints.isEmpty { out.append(SummarySection(title: pointsTitle, bullets: keyPoints)) }
            // Last resort only for content-free input (symbols/numbers): echo the
            // note rather than invent structure.
            if out.isEmpty, !noteLines.isEmpty {
                out.append(SummarySection(title: "Notes", bullets: Array(noteLines.prefix(5))))
            }
            return out
        }

        let title = meeting.objective.isEmpty
            ? "Summary of \(meeting.title)."
            : "This meeting is centered on \(meeting.objective.lowercased())."

        return [
            TemplateSummary(template: .discovery, summary: MeetingSummary(
                eyebrow: "Auto draft", title: title,
                sections: sections("Decisions", "Next steps", "Key points"))),
            TemplateSummary(template: .exec, summary: MeetingSummary(
                eyebrow: "Exec view", title: "Quick readout for \(meeting.workspace).",
                sections: sections("What was decided", "Owns the follow-through", "Context"))),
            TemplateSummary(template: .manager, summary: MeetingSummary(
                eyebrow: "Coach angle", title: "Turn this capture into coaching and accountability.",
                sections: sections("Decisions to reinforce", "Hold owners to", "Observed"))),
        ]
    }

    private func enhancedLiveNotes(notes: String, transcriptParagraphs: [String]) -> String {
        let manualLines = notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let transcriptCandidates = transcriptParagraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 24 }

        var merged: [String] = []
        var seen: Set<String> = []
        var usedTranscriptFingerprints: Set<String> = []

        for line in manualLines {
            let context = bestTranscriptContext(for: line, in: transcriptCandidates)
            let enhanced = formatEnhancedMeetingLine(from: line, context: context)
            let fingerprint = normalizedFingerprint(enhanced)

            guard !fingerprint.isEmpty, !seen.contains(fingerprint) else { continue }
            seen.insert(fingerprint)
            merged.append("- \(enhanced)")

            if let context {
                usedTranscriptFingerprints.insert(normalizedFingerprint(context))
            }
        }

        let rankedCandidates = rankTranscriptHighlights(transcriptCandidates)

        for line in rankedCandidates {
            let transcriptFingerprint = normalizedFingerprint(line)

            guard !usedTranscriptFingerprints.contains(transcriptFingerprint) else { continue }

            let enhanced = formatEnhancedMeetingLine(from: line, context: nil)
            let fingerprint = normalizedFingerprint(enhanced)

            guard !fingerprint.isEmpty, !seen.contains(fingerprint) else { continue }
            seen.insert(fingerprint)
            merged.append("- \(enhanced)")
        }

        if merged.isEmpty {
            return """
            - Meeting captured live on iPhone and saved without enough transcript detail to enhance yet.
            - Add a little more context next time and Scribeflow will turn the conversation into stronger notes automatically.
            """
        }

        return merged.prefix(6).joined(separator: "\n")
    }

    private func rankTranscriptHighlights(_ paragraphs: [String]) -> [String] {
        let weightedTerms = SignalWeights.terms

        return paragraphs
            .map { paragraph -> (String, Int) in
                let lower = paragraph.lowercased()
                var score = max(1, paragraph.count / 60)

                for (term, weight) in weightedTerms where lower.contains(term) {
                    score += weight
                }

                if paragraph.rangeOfCharacter(from: .decimalDigits) != nil {
                    score += 1
                }

                return (paragraph, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.count < rhs.0.count
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
    }

    private func bestTranscriptContext(for line: String, in paragraphs: [String]) -> String? {
        let noteTokens = significantTokens(in: line)

        guard !noteTokens.isEmpty else { return nil }

        return paragraphs
            .compactMap { paragraph -> (String, Int)? in
                let paragraphTokens = significantTokens(in: paragraph)
                let overlap = noteTokens.intersection(paragraphTokens).count

                guard overlap > 0 else { return nil }

                let score = overlap * 4 + min(paragraph.count / 50, 3)
                return (paragraph, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.count < rhs.0.count
                }
                return lhs.1 > rhs.1
            }
            .first?.0
    }

    private func formatEnhancedMeetingLine(from line: String, context: String?) -> String {
        let cleaned = polishedFragment(from: line)
        let lower = cleaned.lowercased()
        let base = sentenceBody(cleaned)

        guard !base.isEmpty else { return "" }

        let leadIn: String?

        if lower.contains("decision") || lower.contains("decide") {
            leadIn = "A clear decision emerged"
        } else if lower.contains("next") || lower.contains("follow up") || lower.contains("owner") || lower.contains("action") {
            leadIn = "The meeting landed on a concrete next step"
        } else if lower.contains("need") || lower.contains("needs") || lower.contains("must") || lower.contains("requirement") {
            leadIn = "The group emphasized an important requirement"
        } else if lower.contains("security") || lower.contains("risk") || lower.contains("issue") || lower.contains("problem") {
            leadIn = "A meaningful risk came through"
        } else if lower.contains("budget") || lower.contains("price") {
            leadIn = "Budget pressure showed up in the discussion"
        } else if lower.contains("timeline") || lower.contains("quarter") || lower.contains("launch") {
            leadIn = "Timing came through as an important factor"
        } else {
            leadIn = nil
        }

        var sentence = leadIn.map { "\($0): \(base)" } ?? capitalizedSentence(base)

        if let context,
           let contextClause = contextualClause(from: context, comparedTo: cleaned)
        {
            sentence += ", and the transcript clarified that \(contextClause)"
        }

        return sentence.hasSuffix(".") ? sentence : "\(sentence)."
    }

    private func contextualClause(from context: String, comparedTo line: String) -> String? {
        let cleanedContext = sentenceBody(polishedFragment(from: context))
        let contextFingerprint = normalizedFingerprint(cleanedContext)
        let lineFingerprint = normalizedFingerprint(line)

        guard !cleanedContext.isEmpty, contextFingerprint != lineFingerprint else { return nil }

        let contextTokens = significantTokens(in: cleanedContext)
        let lineTokens = significantTokens(in: line)
        let uniqueContextTokens = contextTokens.subtracting(lineTokens)

        guard uniqueContextTokens.count >= 2 || cleanedContext.count > line.count + 16 else { return nil }

        return lowercasedSentence(cleanedContext)
    }

    private func polishedFragment(from line: String) -> String {
        line
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "•", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sentenceBody(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return "" }

        let components = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)

        if components.count == 2,
           components[0].count < 14
        {
            return String(components[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }

        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func significantTokens(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "about", "after", "again", "also", "around", "been", "being", "but", "from", "have",
            "into", "just", "more", "that", "than", "their", "them", "then", "they", "this",
            "what", "when", "with", "will", "would", "could", "should", "there", "here", "were",
            "your", "ours", "ourselves", "meeting", "notes"
        ]

        return Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }

    private func capitalizedSentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func lowercasedSentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private func normalizedFingerprint(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func firstMeaningfulLine(in notes: String) -> String? {
        notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private func mergedNotesWithMoments(_ notes: String, moments: [String]) -> String {
        guard !moments.isEmpty else { return notes }

        let momentLines = moments.map { "- Bookmark: \($0)" }.joined(separator: "\n")
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedNotes.isEmpty else { return momentLines }
        return trimmedNotes + "\n" + momentLines
    }

    private func extractedBookmarkMoments(from notes: String) -> [String] {
        notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.lowercased().contains("bookmark:") }
            .map {
                $0
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "Bookmark:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private func appendMoments(to id: Meeting.ID, moments: [String]) {
        guard !moments.isEmpty else { return }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }

        let existingNotes = meetings[index].rawNotes
        meetings[index].rawNotes = mergedNotesWithMoments(existingNotes, moments: moments)
        refreshSummariesIfNeeded(at: index)
    }

    private func generatedEvidenceItems(for meeting: Meeting) -> [EvidenceItem] {
        let noteLines = meeting.rawNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return noteLines.map { line in
            let snippets = supportingSnippets(for: line, in: meeting.transcript.map(\.text))
            let lower = line.lowercased()
            let level: EvidenceLevel

            if lower.contains("bookmark:") || lower.contains("personal note") {
                level = .personalNote
            } else if !snippets.isEmpty {
                level = .verified
            } else {
                level = .inferred
            }

            return EvidenceItem(
                text: polishedSignalLine(line),
                level: level,
                supportingSnippets: snippets
            )
        }
        .filter { !$0.text.isEmpty }
    }

    private func generatedCommitments(for meeting: Meeting) -> [Commitment] {
        // Prefer the model's action items when it has processed this meeting.
        if let brief = meeting.aiBrief, !brief.actions.isEmpty {
            return brief.actions.map { a in
                let lower = a.task.lowercased()
                let status: CommitmentStatus = (lower.contains("risk") || lower.contains("block")
                    || lower.contains("stuck") || lower.contains("at risk")) ? .atRisk : .open
                return Commitment(
                    statement: a.task,
                    owner: a.owner.isEmpty ? "Owner not named" : a.owner,
                    sourceSpeaker: "AI",
                    dueHint: a.due.isEmpty ? nil : a.due,
                    status: status,
                    priority: a.priority.isEmpty ? nil : a.priority,
                    rationale: a.why.isEmpty ? nil : a.why
                )
            }
        }
        // Single source of truth: the same text-aware extractor that powers the
        // intelligence report, so persisted commitments match what the user
        // reads — real owners (You / Team / named), due hints, and de-noised
        // action lines instead of any line containing "will" or "by".
        return MeetingIntelligenceEngine.structuredActions(for: meeting, limit: 6).map { action in
            let lower = action.text.lowercased()
            let status: CommitmentStatus = (lower.contains("risk")
                || lower.contains("block")
                || lower.contains("stuck")
                || lower.contains("overdue")
                || lower.contains("at risk")) ? .atRisk : .open
            return Commitment(
                statement: action.text,
                owner: action.owner,
                sourceSpeaker: action.sourceSpeaker,
                dueHint: action.dueHint,
                status: status
            )
        }
    }

    private func transcriptLines(from transcript: String, speaker: String, role: String) -> [TranscriptLine] {
        SpeakerTranscriptParser.lines(from: transcript, defaultSpeaker: speaker, defaultRole: role)
    }

    private func detectedSensitiveFlags(for meeting: Meeting) -> [SensitiveFlag] {
        let corpus = "\(meeting.title) \(meeting.objective) \(meeting.rawNotes) \(meeting.transcript.map(\.text).joined(separator: " "))".lowercased()
        var flags: [SensitiveFlag] = []

        if meeting.attendees.isEmpty == false || corpus.contains("maya") || corpus.contains("priya") {
            flags.append(.names)
        }
        if corpus.contains("price") || corpus.contains("pricing") || corpus.contains("budget") || corpus.contains("$") {
            flags.append(.pricing)
        }
        if corpus.contains("roadmap") || corpus.contains("launch") || corpus.contains("q2") || corpus.contains("q3") {
            flags.append(.roadmap)
        }
        if corpus.contains("security") || corpus.contains("legal") || corpus.contains("retention") || corpus.contains("permission") {
            flags.append(.security)
        }
        if corpus.contains("internal") || corpus.contains("private") || corpus.contains("not share") || corpus.contains("do not share") {
            flags.append(.internalOnly)
        }

        return Array(Set(flags)).sorted { $0.rawValue < $1.rawValue }
    }

    private func applySupersededCommitments() {
        var latestByFingerprint: [String: (meetingID: Meeting.ID, commitmentID: Commitment.ID)] = [:]

        for meeting in recentMeetings.reversed() {
            for commitment in meeting.commitments {
                let fingerprint = normalizedFingerprint(commitment.statement)
                guard !fingerprint.isEmpty else { continue }
                latestByFingerprint[fingerprint] = (meeting.id, commitment.id)
            }
        }

        for meetingIndex in meetings.indices {
            for commitmentIndex in meetings[meetingIndex].commitments.indices {
                let commitment = meetings[meetingIndex].commitments[commitmentIndex]
                let fingerprint = normalizedFingerprint(commitment.statement)
                guard let latest = latestByFingerprint[fingerprint] else { continue }
                guard latest.meetingID != meetings[meetingIndex].id else { continue }
                if meetings[meetingIndex].commitments[commitmentIndex].status == .open {
                    meetings[meetingIndex].commitments[commitmentIndex].status = .superseded
                }
            }
        }
    }

    private func safeSharePreview(
        for meeting: Meeting,
        format: MeetingExportFormat,
        includeInferred: Bool,
        includePrivateNotes: Bool,
        includeTranscript: Bool
    ) -> String {
        let visibleEvidence = meeting.evidenceItems.filter {
            includeInferred || $0.level != .inferred
        }

        let noteLines = visibleEvidence.map(\.text).filter { !$0.isEmpty }
        let notesBlock = noteLines.isEmpty
            ? "- No safe bullets available yet."
            : noteLines.prefix(format == .execUpdate ? 4 : 6).map { "- \($0)" }.joined(separator: "\n")

        let commitmentsBlock = meeting.commitments
            .filter { $0.status != .superseded || format != .clientRecap }
            .prefix(4)
            .map { "- \($0.formattedLine)" }
            .joined(separator: "\n")

        let transcriptBlock = includeTranscript
            ? meeting.transcript.prefix(3).map { "- \($0.speaker): \($0.text)" }.joined(separator: "\n")
            : ""

        let privateNoteFooter = includePrivateNotes
            ? "\nInternal flags: \(meeting.sensitiveFlags.map(\.title).joined(separator: ", "))"
            : ""

        switch format {
        case .internalBrief:
            return """
            \(meeting.title)

            Objective: \(meeting.objective)
            Consent: \(meeting.consentState.title)

            What happened:
            \(notesBlock)

            Commitments:
            \(commitmentsBlock.isEmpty ? "- No commitments captured." : commitmentsBlock)\(privateNoteFooter)
            \(transcriptBlock.isEmpty ? "" : "\nTranscript context:\n\(transcriptBlock)")
            """
        case .clientRecap:
            return """
            Subject: \(meeting.title) recap

            Hi team,

            Thanks again for the conversation. Here’s the clean recap:

            \(notesBlock)

            Next steps:
            \(commitmentsBlock.isEmpty ? "- We’ll confirm the next step in writing." : commitmentsBlock)

            Best,
            """
        case .execUpdate:
            return """
            \(meeting.title) — exec update

            \(meeting.summary(for: .exec).title)

            Decisions and signals:
            \(notesBlock)

            Follow-through:
            \(commitmentsBlock.isEmpty ? "- No executive follow-through captured yet." : commitmentsBlock)
            """
        case .markdown:
            let dateLine = ISO8601DateFormatter().string(from: meeting.when)
            let attendeesLine = meeting.attendees.isEmpty ? "" : "**Attendees:** \(meeting.attendees.joined(separator: ", "))\n"
            let transcriptSection = includeTranscript && !meeting.transcript.isEmpty
                ? "\n## Transcript\n\n" + meeting.transcript.map { "**\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
                : ""
            return """
            # \(meeting.title)

            \(attendeesLine)**Date:** \(dateLine)
            **Objective:** \(meeting.objective)

            ## Notes

            \(notesBlock)

            ## Action items

            \(commitmentsBlock.isEmpty ? "- No action items captured." : commitmentsBlock)\(transcriptSection)
            """
        }
    }

    private func supportingSnippets(for line: String, in transcriptParagraphs: [String]) -> [String] {
        let tokens = significantTokens(in: line)
        guard !tokens.isEmpty else { return [] }

        return transcriptParagraphs.filter { paragraph in
            let overlap = tokens.intersection(significantTokens(in: paragraph)).count
            return overlap >= 2 || paragraph.lowercased().contains(sentenceBody(line).lowercased())
        }
        .prefix(2)
        .map { $0 }
    }

    private func extractedSignalLines(
        from meeting: Meeting,
        keywords: [String],
        fallbackPrefixes: [String],
        limit: Int,
        exclude: (String) -> Bool = { _ in false }
    ) -> [String] {
        let noteLines = meeting.rawNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let transcriptLines = meeting.transcript.map(\.text)
        let corpus = noteLines + transcriptLines

        var ranked: [String] = []
        var seen: Set<String> = []

        for line in corpus {
            let lower = line.lowercased()
            let matchesKeyword = keywords.contains(where: lower.contains)
            let matchesPrefix = fallbackPrefixes.contains { lower.hasPrefix($0) || lower.contains("- \($0)") }

            guard matchesKeyword || matchesPrefix else { continue }
            guard !exclude(line) else { continue }

            let polished = polishedSignalLine(line)
            let fingerprint = normalizedFingerprint(polished)
            guard !polished.isEmpty, !seen.contains(fingerprint) else { continue }
            seen.insert(fingerprint)
            ranked.append(polished)
        }

        if ranked.isEmpty {
            for line in noteLines.prefix(limit) {
                let polished = polishedSignalLine(line)
                let fingerprint = normalizedFingerprint(polished)
                guard !polished.isEmpty, !seen.contains(fingerprint) else { continue }
                seen.insert(fingerprint)
                ranked.append(polished)
            }
        }

        return Array(ranked.prefix(limit))
    }

    private func polishedSignalLine(_ line: String) -> String {
        let cleaned = polishedFragment(from: line)
            .replacingOccurrences(of: "Bookmark:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "" }

        let sentence = capitalizedSentence(sentenceBody(cleaned))
        guard !sentence.isEmpty else { return "" }
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }

    private func extractedWorkspaceTags(from meeting: Meeting) -> [String] {
        let corpus = "\(meeting.objective) \(meeting.rawNotes) \(meeting.transcript.map(\.text).joined(separator: " "))".lowercased()
        let tags = [
            "pricing", "security", "launch", "timeline", "mobile", "integration", "rollout",
            "budget", "hiring", "design", "privacy", "follow-up", "risk", "support", "adoption"
        ]

        return tags.filter { corpus.contains($0) }
    }

    private func topWorkspaceThemes(limit: Int) -> [String] {
        let tags = recentMeetings.prefix(10).flatMap(extractedWorkspaceTags(from:))
        let ranked = Dictionary(grouping: tags, by: { $0 })
            .mapValues(\.count)
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)

        return ranked.map { $0.key }
    }


    private static func normalizedMeeting(_ meeting: Meeting) -> Meeting {
        var normalized = meeting

        let existingPromptTitles = Set(normalized.prompts.map { $0.prompt.lowercased() })
        for prompt in defaultPrompts() where !existingPromptTitles.contains(prompt.prompt.lowercased()) {
            normalized.prompts.append(prompt)
        }

        if normalized.selectedPromptID == nil {
            normalized.selectedPromptID = normalized.prompts.first?.id
        }

        let staleLiveThreshold = Date.now.addingTimeInterval(-14_400)

        if normalized.status == .live, normalized.when < staleLiveThreshold {
            normalized.status = .ready

            if normalized.stage.lowercased().contains("capturing") {
                normalized.stage = "Captured and ready to review"
            }
        }

        normalized.transcriptVisibilityEnabled = normalized.transcriptVisibilityEnabled && !normalized.transcript.isEmpty

        return normalized
    }

    private static func defaultPrompts() -> [AIResponse] {
        [
            AIResponse(prompt: "Write follow-up", answer: "Draft a crisp follow-up that confirms the main outcome, decisions, and next step."),
            AIResponse(prompt: "List action items", answer: "Turn the notes into clear owners, actions, and follow-up deadlines."),
            AIResponse(prompt: "Slack update", answer: "Summarize the meeting for a team Slack update in a concise, confident tone."),
            AIResponse(prompt: "Risks and blockers", answer: "Call out the biggest risks, open questions, and blockers from this meeting."),
            AIResponse(prompt: "Decision memo", answer: "Condense the meeting into the core decision, why it matters, and what happens next."),
            AIResponse(prompt: "Customer themes", answer: "Extract recurring needs, pain points, and product signals from the conversation."),
            AIResponse(prompt: "Catch-up summary", answer: "Write a short catch-up for someone who joined the meeting late."),
        ]
    }

    private func fallbackPromptAnswer(for meeting: Meeting, prompt: String) -> String {
        let noteLines = meeting.rawNotes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let keyLines = Array(noteLines.prefix(4))
        let nextLines = Array(noteLines.dropFirst(4).prefix(3))
        let lowerPrompt = prompt.lowercased()

        if lowerPrompt.contains("follow-up") {
            let highlights = keyLines.isEmpty ? ["Thanks again for the time today."] : keyLines
            return """
            Thanks again for the conversation today.

            Here’s the short recap:
            \(highlights.map { "- \($0)" }.joined(separator: "\n"))

            Next step:
            \(nextLines.first ?? "- Confirm the owner and timing for the next follow-up.")
            """
        }

        if lowerPrompt.contains("action") {
            let actions = MeetingIntelligenceEngine.structuredActions(for: meeting, limit: 6)
            return actions.isEmpty
                ? "- Capture at least one owner and next step in the notes to generate action items."
                : actions.enumerated().map { index, action in
                    "\(index + 1). \(MeetingIntelligenceEngine.commitmentSentence(action))"
                }.joined(separator: "\n")
        }

        if lowerPrompt.contains("slack") {
            let lines = keyLines.isEmpty ? ["Meeting captured and notes are ready."] : keyLines
            return "Quick update: \(lines.joined(separator: " "))"
        }

        if lowerPrompt.contains("risk") || lowerPrompt.contains("blocker") {
            let riskLines = signals(for: meeting).risks

            if riskLines.isEmpty {
                return "- No explicit blocker was captured, but the biggest open question is whether the team has a clear owner and next step."
            }

            return riskLines.map { "- \($0)" }.joined(separator: "\n")
        }

        if lowerPrompt.contains("decision") {
            let decisions = MeetingIntelligenceEngine.decisions(for: meeting, limit: 4)

            if decisions.isEmpty {
                return "- No explicit decision was captured yet, so the best next step is to clarify what was actually agreed."
            }

            return decisions.map { "- \($0)" }.joined(separator: "\n")
        }

        if lowerPrompt.contains("theme") {
            let tags = extractedWorkspaceTags(from: meeting)
            return tags.isEmpty
                ? "- No strong recurring themes were detected yet."
                : tags.map { "- \($0.capitalized)" }.joined(separator: "\n")
        }

        if lowerPrompt.contains("catch-up") {
            let recap = (keyLines + nextLines).prefix(3)
            return recap.isEmpty
                ? "- The meeting is captured, but there isn’t enough detail yet for a useful catch-up."
                : recap.map { "- \($0)" }.joined(separator: "\n")
        }

        return meeting.selectedPrompt.answer
    }

    private func fallbackWorkspaceAnswer(
        for meetings: [Meeting],
        prompt: String,
        includeTranscripts: Bool,
        modelSelection: ChatModelSelection
    ) -> String {
        let lowerPrompt = prompt.lowercased()
        let isDeepMode = modelSelection == .deep || (modelSelection == .auto && meetings.count > 8)

        if lowerPrompt.contains("prep") || lowerPrompt.contains("today") {
            return meetings.prefix(3).map { meeting in
                let note = firstMeaningfulLine(in: meeting.rawNotes) ?? meeting.summary(for: meeting.selectedTemplate).title
                return "- \(meeting.title): \(note) [source: note]"
            }.joined(separator: "\n")
        }

        if lowerPrompt.contains("decision") || lowerPrompt.contains("decided") || lowerPrompt.contains("agree") {
            // Distilled outcomes, attributed to the meeting — not raw lines that
            // happen to contain "decided".
            let matches = meetings.flatMap { meeting in
                MeetingIntelligenceEngine.decisions(for: meeting, limit: 2).map {
                    "- \($0) — \(meeting.title)"
                }
            }

            return matches.isEmpty
                ? "No clear decisions stood out yet across the recent meetings."
                : Array(matches.prefix(isDeepMode ? 8 : 6)).joined(separator: "\n")
        }

        if lowerPrompt.contains("action") || lowerPrompt.contains("follow")
            || lowerPrompt.contains("owe") || lowerPrompt.contains("task")
            || lowerPrompt.contains("owner") || lowerPrompt.contains("to-do") || lowerPrompt.contains("todo") {
            // "Owner — task (by due)", distilled, instead of any line mentioning
            // "send" or "review".
            let matches = meetings.flatMap { meeting in
                MeetingIntelligenceEngine.structuredActions(for: meeting, limit: 2).map {
                    "- \(MeetingIntelligenceEngine.commitmentSentence($0)) — \(meeting.title)"
                }
            }

            return matches.isEmpty
                ? "No strong follow-up items were detected yet across the recent meetings."
                : Array(matches.prefix(isDeepMode ? 8 : 6)).joined(separator: "\n")
        }

        if lowerPrompt.contains("risk") || lowerPrompt.contains("blocker") || lowerPrompt.contains("concern") {
            let matches = meetings.flatMap { meeting in
                signals(for: meeting).risks.prefix(2).map { "- \($0) — \(meeting.title)" }
            }

            return matches.isEmpty
                ? "Nothing is flagged as a risk or blocker across the recent meetings."
                : Array(matches.prefix(isDeepMode ? 8 : 6)).joined(separator: "\n")
        }

        if lowerPrompt.contains("theme") || lowerPrompt.contains("pattern") || lowerPrompt.contains("trend") {
            let tags = meetings.flatMap(extractedWorkspaceTags(from:))
            let ranked = Dictionary(grouping: tags, by: { $0 }).mapValues(\.count)
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value {
                        return lhs.key < rhs.key
                    }
                    return lhs.value > rhs.value
                }
                .prefix(5)

            if ranked.isEmpty {
                return "The recent meetings don’t have enough repeated signals yet to surface themes."
            }

            return ranked.map { key, value in
                "- \(key.capitalized) showed up in \(value) meeting\(value == 1 ? "" : "s")."
            }.joined(separator: "\n")
        }

        let recap = meetings.prefix(4).map { meeting in
            let note = firstMeaningfulLine(in: meeting.rawNotes)
                ?? meeting.summary(for: meeting.selectedTemplate).title
            return "- \(meeting.title): \(note) [source: note]"
        }.joined(separator: "\n")

        return """
        Here’s the quickest read across your recent meetings:

        \(recap)
        """
    }

    private func polishNotes(
        title: String,
        objective: String,
        notes: String,
        transcriptParagraphs: [String],
        style: NoteRewriteStyle
    ) async -> NotePolishOutcome {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch AppleIntelligenceNoteTransformer.availability() {
            case .available:
                do {
                    let rewritten = try await AppleIntelligenceNoteTransformer.transformNotes(
                        title: title,
                        objective: objective,
                        notes: notes,
                        transcriptParagraphs: transcriptParagraphs,
                        style: style
                    )

                    if !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .appleIntelligence(rewritten, "Polished with Apple Intelligence in \(style.title.lowercased()) style.")
                    }
                } catch {
                    break
                }
            case .unavailable(.deviceNotEligible):
                break
            case .unavailable(.appleIntelligenceNotEnabled):
                break
            case .unavailable(.modelNotReady):
                break
            @unknown default:
                break
            }
        }
        #endif

        if !transcriptParagraphs.isEmpty {
            let rewritten = enhancedLiveNotes(notes: notes, transcriptParagraphs: transcriptParagraphs)
            return .heuristic(rewritten, "Saved with transcript-based note enhancement in \(style.title.lowercased()) style.")
        }

        return .unavailable("Apple Intelligence isn’t available on this device yet, so the original note was kept.")
    }
}

private enum NotePolishOutcome {
    case appleIntelligence(String, String)
    case heuristic(String, String)
    case unavailable(String)
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum AppleIntelligenceNoteTransformer {
    static func availability() -> SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static func transformNotes(
        title: String,
        objective: String,
        notes: String,
        transcriptParagraphs: [String],
        style: NoteRewriteStyle
    ) async throws -> String {
        let styleInstruction: String
        switch style {
        case .concise:
            styleInstruction = "Keep the bullets crisp and compact."
        case .detailed:
            styleInstruction = "Add a little more situational detail while staying clean and readable."
        case .executive:
            styleInstruction = "Write for an executive reader, emphasizing business impact, decisions, and risks."
        case .actionFocused:
            styleInstruction = "Emphasize owners, commitments, next steps, and follow-through."
        }

        let session = LanguageModelSession(instructions: """
        You are an expert meeting notes writer.
        Rewrite rough meeting notes into polished, professional notes that sound like a smart human wrote them during a meeting.
        Return only 4 to 6 concise bullet points.
        Each bullet must be one sentence, specific, and useful.
        Prioritize decisions, important requirements, concerns, risks, owners, and next steps.
        Use the person's rough notes as the anchor and use transcript context to fill in detail.
        \(styleInstruction)
        Do not add headings.
        Do not invent facts that aren't supported by the notes or transcript.
        """)

        let transcriptContext = transcriptParagraphs
            .suffix(10)
            .joined(separator: "\n")

        let prompt = """
        Meeting title: \(title)
        Objective: \(objective)

        Rough notes:
        \(notes.isEmpty ? "No rough notes were captured." : notes)

        Transcript context:
        \(transcriptContext.isEmpty ? "No transcript context was captured." : transcriptContext)

        Rewrite this into polished meeting notes now.
        Return only bullet points.
        """

        let response = try await session.respond(to: prompt)
        return normalizeBullets(response.content)
    }

    private static func normalizeBullets(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "- ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let normalized = lines.map { line in
            let sentence = line.hasSuffix(".") ? line : "\(line)."
            return "- \(sentence)"
        }

        return normalized.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedActionItem {
    @Guide(description: "The task as a short imperative phrase, e.g. 'Send the deck'. Fix any spelling.")
    var task: String
    @Guide(description: "Who owns it: a person's name, 'You', or 'Team'. Empty string if unclear.")
    var owner: String
    @Guide(description: "Due date if stated, e.g. 'Friday' or 'next week'. Empty string if none.")
    var due: String
    @Guide(description: "Priority based on urgency and impact stated in the notes: 'high', 'medium', or 'low'. Do not inflate.")
    var priority: String
    @Guide(description: "One short clause on why this matters / the consequence, only if the notes support it. Empty otherwise.")
    var why: String
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedEnhancedNote {
    @Guide(description: "The user's original note point, kept VERBATIM — do not reword, summarize, or fix it.")
    var anchor: String
    @Guide(description: "One concise sentence expanding that point with context from the notes or transcript. Empty string if there is nothing to add.")
    var detail: String
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedBrief {
    @Guide(description: "A one or two sentence professional summary of the meeting.")
    var summary: String
    @Guide(description: "Decisions that were actually made. Empty if none were made.")
    var decisions: [String]
    @Guide(description: "Action items / commitments, each with an owner and due date when stated.")
    var actions: [GeneratedActionItem]
    @Guide(description: "Unresolved questions that still need an answer. Empty if none.")
    var openQuestions: [String]
    @Guide(description: "Other substantive discussion points that are not decisions or actions.")
    var keyPoints: [String]
    @Guide(description: "Risks, blockers, or concerns raised. Empty if none.")
    var risks: [String]
    @Guide(description: "For each point the user wrote, the original text as the anchor plus added context. Keep the user's structure and order.")
    var enhancedNotes: [GeneratedEnhancedNote]
}

/// Turns rough, possibly misspelled notes into a clean, professional structured
/// brief using the on-device model — real comprehension, not keyword matching.
@available(iOS 26.0, *)
private enum AppleIntelligenceBriefExtractor {
    static func availability() -> SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static func extract(title: String, notes: String, transcriptParagraphs: [String]) async throws -> AIBriefData {
        let session = LanguageModelSession(instructions: """
        You are an expert meeting analyst inside a professional note-taking app.
        Read rough, informal, possibly misspelled notes and turn them into a clean,
        well-organized brief. Correct spelling and grammar in everything you output.
        Extract ONLY what the notes (and transcript, if provided) actually support —
        never invent decisions, actions, owners, dates, risks, or facts. If a
        category has nothing, return an empty list for it. Write tasks as short
        imperative phrases. Keep the summary to one or two sentences.

        For enhancedNotes, treat the user's own bullet points as the skeleton:
        keep each one VERBATIM as the anchor (in their order), and add a short
        'detail' that fleshes it out using the transcript or surrounding notes.
        Never reword the anchor. Leave detail empty when there is nothing to add.
        """)

        let transcriptContext = transcriptParagraphs.suffix(12).joined(separator: "\n")
        let prompt = """
        Meeting title: \(title.isEmpty ? "(untitled)" : title)

        Notes (may contain typos and shorthand):
        \(notes.isEmpty ? "(none)" : notes)

        Transcript context:
        \(transcriptContext.isEmpty ? "(none)" : transcriptContext)

        Produce the structured brief now.
        """

        let response = try await session.respond(to: prompt, generating: GeneratedBrief.self)
        let g = response.content
        let clean: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return AIBriefData(
            summary: clean(g.summary),
            decisions: g.decisions.map(clean).filter { !$0.isEmpty },
            actions: g.actions
                .map { AIActionItem(task: clean($0.task), owner: clean($0.owner), due: clean($0.due),
                                    priority: clean($0.priority).lowercased(), why: clean($0.why)) }
                .filter { !$0.task.isEmpty },
            openQuestions: g.openQuestions.map(clean).filter { !$0.isEmpty },
            keyPoints: g.keyPoints.map(clean).filter { !$0.isEmpty },
            risks: g.risks.map(clean).filter { !$0.isEmpty },
            enhancedNotes: g.enhancedNotes
                .map { EnhancedNoteData(anchor: clean($0.anchor), detail: clean($0.detail)) }
                .filter { !$0.anchor.isEmpty }
        )
    }
}

@available(iOS 26.0, *)
private enum AppleIntelligenceMeetingAssistant {
    static func answer(meeting: Meeting, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
        You are a precise meeting assistant inside a professional note-taking app.
        Answer using only the meeting title, objective, notes, and transcript context provided.
        Be concise, useful, and polished.
        Prefer bullets or short paragraphs depending on the user's request.
        Do not invent facts that are not supported by the meeting context.
        """)

        let transcriptContext = meeting.transcript
            .map(\.text)
            .suffix(8)
            .joined(separator: "\n")

        let request = """
        Meeting title: \(meeting.title)
        Objective: \(meeting.objective)
        Workspace: \(meeting.workspace)

        Notes:
        \(meeting.rawNotes)

        Transcript context:
        \(transcriptContext.isEmpty ? "No transcript context was captured." : transcriptContext)

        Task:
        \(prompt)
        """

        let response = try await session.respond(to: request)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@available(iOS 26.0, *)
private enum AppleIntelligenceWorkspaceAssistant {
    static func answer(
        meetings: [Meeting],
        prompt: String,
        includeTranscripts: Bool,
        modelSelection: ChatModelSelection
    ) async throws -> String {
        let styleInstruction: String
        switch modelSelection {
        case .auto:
            styleInstruction = "Default to concise answers, but expand only when the task requires cross-meeting analysis."
        case .fast:
            styleInstruction = "Keep the answer short and execution-focused."
        case .deep:
            styleInstruction = "Provide deeper cross-meeting analysis and tradeoffs while staying concise."
        }

        let session = LanguageModelSession(instructions: """
        You are a precise workspace meeting assistant inside a professional note-taking app.
        Answer using only the meetings provided.
        Be concise, structured, and practical.
        Surface patterns, decisions, action items, blockers, and useful prep notes when relevant.
        Include source references at the end of each bullet, like [source: Meeting title, transcript 3] or [source: Meeting title, note].
        \(styleInstruction)
        Do not invent facts that are not grounded in the meeting content.
        """)

        let limitedMeetings = Array(meetings.prefix(includeTranscripts ? 25 : 40))
        let context = limitedMeetings.map { meeting in
            let notes = meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            let transcript = includeTranscripts
                ? meeting.transcript.map(\.text).suffix(4).joined(separator: "\n")
                : "Transcripts not included for this query."

            return """
            Title: \(meeting.title)
            Workspace: \(meeting.workspace)
            When: \(meeting.when.formatted(date: .abbreviated, time: .shortened))
            Objective: \(meeting.objective)
            Notes:
            \(notes.isEmpty ? "No saved notes." : notes)
            Transcript excerpts:
            \(transcript.isEmpty ? "No transcript excerpts." : transcript)
            """
        }.joined(separator: "\n\n---\n\n")

        let request = """
        Scope: \(includeTranscripts ? "Recent meetings with transcript excerpts (up to 25 meetings)." : "Recent meetings using notes and summaries (up to 40 meetings).")

        Meetings:
        \(context)

        Task:
        \(prompt)
        """

        let response = try await session.respond(to: request)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

