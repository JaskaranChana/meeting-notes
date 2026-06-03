import ActivityKit
import AVFoundation
import Foundation
import MediaPlayer
import Observation
import Speech
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Live Activity

/// Attributes for the meeting-recording Live Activity. The widget extension
/// (when present) provides the `ActivityConfiguration` view that consumes
/// these values. The main app only starts / updates / ends activities.
///
/// **Setup note:** Live Activity UI requires a Widget Extension target with
/// an `ActivityConfiguration<MeetingRecordingAttributes>` view. Add via
/// File ▸ New ▸ Target ▸ Widget Extension, include both this app target's
/// shared types, and check "Include Live Activity" when prompted.
struct MeetingRecordingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Wall-clock time when recording started; the widget formats elapsed
        /// from this rather than receiving a tick so it stays accurate while
        /// the app is backgrounded.
        var startedAt: Date
        /// 0…1 normalized recent input level for the waveform indicator.
        var inputLevel: Double
        /// True when the user has paused capture — widget switches icon.
        var isPaused: Bool
    }

    /// Title shown in the Live Activity / Dynamic Island. Captured at start
    /// so changes to the meeting title during recording don't ripple through
    /// the activity payload.
    var title: String
}

/// Thin wrapper around `Activity<MeetingRecordingAttributes>`. Silently no-ops
/// on devices where Live Activities are unsupported or disabled. Holds a
/// single active activity at a time.
@MainActor
final class MeetingRecordingLiveActivity {
    static let shared = MeetingRecordingLiveActivity()

    private var current: Activity<MeetingRecordingAttributes>?

    /// Begin a new activity. Returns silently if Live Activities are disabled
    /// in user settings or no widget extension is installed.
    func start(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end() // ensure only one at a time
        let attrs = MeetingRecordingAttributes(title: title.isEmpty ? "Recording" : title)
        let state = MeetingRecordingAttributes.ContentState(
            startedAt: .now,
            inputLevel: 0,
            isPaused: false
        )
        do {
            current = try Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            current = nil
        }
    }

    /// Push a fresh content update — input level + paused state.
    func update(inputLevel: Double, isPaused: Bool) {
        guard let current else { return }
        Task {
            let startedAt = current.content.state.startedAt
            await current.update(
                ActivityContent(
                    state: .init(startedAt: startedAt, inputLevel: inputLevel, isPaused: isPaused),
                    staleDate: nil
                )
            )
        }
    }

    /// End the activity immediately. Safe to call when no activity is active.
    func end() {
        guard let current else { return }
        let final = current
        Task {
            await final.end(nil, dismissalPolicy: .immediate)
        }
        self.current = nil
    }
}

enum CapturePermissionState: Equatable {
    case unknown
    case ready
    case denied
    case unsupported
}

enum CaptureSuggestionKind: Equatable {
    case core
    case optional
}

struct CaptureSuggestion: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: CaptureSuggestionKind
}

struct CaptureBookmark: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@MainActor
@Observable
final class LiveMeetingCoordinator {
    var title = "Live meeting"
    var workspace = "Personal workspace"
    var objective = "Capture the key points while I stay present in the meeting."
    var attendees = ""
    var manualNotes = ""
    var selectedTemplate: NoteTemplate = .discovery
    var transcriptText = ""
    var transcriptParagraphs: [String] = []
    var meetingMode: MeetingMode = .privateNotes
    var consentState: ConsentState = .privateCapture
    var retentionPolicy: RetentionPolicy = .keepUntilDeleted
    var transcriptPanelVisible = false
    var hasConfirmedTrustSetup = false
    var suggestions: [CaptureSuggestion] = []
    var bookmarks: [CaptureBookmark] = []
    var catchUpSummary: String?
    var isGeneratingCatchUp = false
    var permissionState: CapturePermissionState = .unknown
    var isRecording = false
    var isPaused = false
    var errorMessage: String?
    var elapsedSeconds = 0
    var inputLevel: Double = 0  // 0...1, RMS-normalized, updated from audio tap
    /// Throttle anchor for waveform updates. Audio tap fires ~50Hz; we
    /// republish at most every 80ms.
    private var lastLevelPublishAt: Date = .distantPast

    @ObservationIgnored
    private let audioEngine = AVAudioEngine()

    @ObservationIgnored
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    @ObservationIgnored
    private var recognitionTask: SFSpeechRecognitionTask?

    @ObservationIgnored
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    @ObservationIgnored
    private var timer: Timer?

    @ObservationIgnored
    private var acceptedFingerprints: Set<String> = []

    @ObservationIgnored
    private var dismissedFingerprints: Set<String> = []

    @ObservationIgnored
    private var pendingTranscriptUpdateTask: Task<Void, Never>?

    /// Audio-thread-readable mirror of `isPaused`. Plain flag so the mic tap
    /// (which runs off the main actor) can check it without hopping actors.
    @ObservationIgnored
    nonisolated(unsafe) private var audioPaused = false

    var elapsedLabel: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var canSave: Bool {
        !manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !transcriptParagraphs.isEmpty
    }

    func prepare() async {
        guard permissionState == .unknown else { return }
        await requestPermissions()
    }

    func requestPermissions() async {
        guard speechRecognizer != nil else {
            permissionState = .unsupported
            errorMessage = "Speech recognition is unavailable on this device."
            return
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        let microphoneAllowed = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard speechStatus == .authorized, microphoneAllowed else {
            permissionState = .denied
            errorMessage = "Please allow microphone and speech recognition access in Settings to use live capture."
            return
        }

        permissionState = .ready
        errorMessage = nil
    }

    func startCapture() async {
        if permissionState != .ready {
            await requestPermissions()
        }

        guard permissionState == .ready else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognition is temporarily unavailable. Try again in a quieter environment or a few moments later."
            return
        }

        stopCapture()
        transcriptText = ""
        transcriptParagraphs = []
        suggestions = []
        bookmarks = []
        catchUpSummary = nil
        elapsedSeconds = 0
        errorMessage = nil
        isPaused = false
        audioPaused = false
        acceptedFingerprints.removeAll()
        dismissedFingerprints.removeAll()

        do {
            try configureAudioSession()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Prefer on-device recognition so audio never leaves the device when
            // supported — matching the app's privacy promise. Falls back to
            // server recognition only where on-device isn't available.
            request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
            request.taskHint = .dictation

            if #available(iOS 16.0, *) {
                request.addsPunctuation = true
            }

            recognitionRequest = request
            let inputNode = audioEngine.inputNode

            // Enable voice processing for echo cancellation and noise reduction.
            if inputNode.isVoiceProcessingEnabled == false {
                try inputNode.setVoiceProcessingEnabled(true)
            }

            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                errorMessage = "Audio input is unavailable. Check microphone access or try reconnecting audio."
                return
            }
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, request] buffer, _ in
                guard let self else { return }
                // While soft-paused, drop audio so the transcript and level
                // freeze — without tearing down the engine (instant resume).
                guard !self.audioPaused else { return }
                // Append to the captured request (thread-safe), avoiding a
                // cross-actor read of the main-isolated `recognitionRequest`.
                request.append(buffer)
                self.computeAndPublishLevel(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                let formattedString = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let errorMessage = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let formattedString {
                        self.handleTranscriptUpdate(formattedString, isFinal: isFinal)
                    }
                    if let errorMessage {
                        self.errorMessage = errorMessage
                        self.stopCapture()
                    }
                }
            }

            isRecording = true
            startTimer()
            updateNowPlaying(isLive: true)
            MeetingRecordingLiveActivity.shared.start(title: title)
        } catch {
            errorMessage = "Unable to start live capture: \(error.localizedDescription)"
            stopCapture()
        }
    }

    /// Soft-pause: freeze the transcript, level, and timer without tearing the
    /// engine down, so resume is instant and seamless.
    func pauseCapture() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        audioPaused = true
        inputLevel = 0
        updateNowPlaying(isLive: false)
        MeetingRecordingLiveActivity.shared.update(inputLevel: 0, isPaused: true)
    }

    func resumeCapture() {
        guard isRecording, isPaused else { return }
        isPaused = false
        audioPaused = false
        updateNowPlaying(isLive: true)
    }

    func stopCapture() {
        isRecording = false
        isPaused = false
        audioPaused = false
        clearNowPlaying()
        MeetingRecordingLiveActivity.shared.end()
        timer?.invalidate()
        timer = nil
        pendingTranscriptUpdateTask?.cancel()
        pendingTranscriptUpdateTask = nil

        // Correct teardown order:
        // 1. Signal no more audio to the recognizer
        // 2. Remove tap BEFORE stopping engine (prevents mid-buffer crash)
        // 3. Stop engine
        // 4. Cancel recognition task
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        AudioSessionManager.shared.stopObserving()
        AudioSessionManager.shared.deactivate()
    }

    func acceptSuggestion(_ suggestion: CaptureSuggestion) {
        let bullet = suggestion.text.hasPrefix("- ") ? suggestion.text : "- \(suggestion.text)"
        let fingerprint = fingerprint(for: suggestion.text)

        if !noteFingerprints(from: manualNotes).contains(fingerprint) {
            if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualNotes = bullet
            } else {
                manualNotes += "\n\(bullet)"
            }
        }

        acceptedFingerprints.insert(fingerprint)
        suggestions.removeAll { $0.id == suggestion.id }
        refreshSuggestions()
    }

    func dismissSuggestion(_ suggestion: CaptureSuggestion) {
        dismissedFingerprints.insert(fingerprint(for: suggestion.text))
        suggestions.removeAll { $0.id == suggestion.id }
        refreshSuggestions()
    }

    func applyMeetingMode(_ mode: MeetingMode) {
        meetingMode = mode
        hasConfirmedTrustSetup = true

        switch mode {
        case .privateNotes:
            consentState = .privateCapture
            retentionPolicy = .notesOnly
            transcriptPanelVisible = false
        case .internalShared:
            consentState = .disclosedInternal
            retentionPolicy = .transcript7Days
        case .clientSafeRecap:
            consentState = .disclosedExternal
            retentionPolicy = .transcript24Hours
            transcriptPanelVisible = false
        }
    }

    func saveMeeting(into store: MeetingStore) async -> Meeting.ID {
        let normalizedAttendees = attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let id = await store.addLiveMeeting(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Live meeting" : title,
            workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Personal workspace" : workspace,
            attendees: normalizedAttendees,
            objective: objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Capture the key decisions and momentum clearly." : objective,
            notes: manualNotes,
            moments: bookmarks.map(\.text),
            transcriptParagraphs: transcriptParagraphs,
            meetingMode: meetingMode,
            consentState: consentState,
            retentionPolicy: retentionPolicy
        )
        store.selectTemplate(selectedTemplate, for: id)
        return id
    }

    func bookmarkCurrentMoment() {
        let source = suggestions.first?.text
            ?? transcriptParagraphs.last
            ?? manualNotes
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { !$0.isEmpty })

        guard let source else { return }

        let normalized = cleanSentence(source)
        let bookmarkText = normalized
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "Bookmark:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !bookmarkText.isEmpty else { return }

        let fingerprint = self.fingerprint(for: bookmarkText)
        let existingFingerprints = Set(bookmarks.map { self.fingerprint(for: $0.text) })
        guard !existingFingerprints.contains(fingerprint) else { return }

        bookmarks.insert(CaptureBookmark(text: bookmarkText), at: 0)
    }

    func removeBookmark(_ bookmark: CaptureBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
    }

    func generateCatchUp() async {
        let notes = manualNotes

        guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !transcriptParagraphs.isEmpty || !bookmarks.isEmpty else {
            catchUpSummary = "Start capturing a little more meeting context first, then Scribeflow can give you a clean catch-up."
            return
        }

        isGeneratingCatchUp = true
        defer { isGeneratingCatchUp = false }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch AppleIntelligenceLiveAssistant.availability() {
            case .available:
                do {
                    catchUpSummary = try await AppleIntelligenceLiveAssistant.catchUp(
                        title: title,
                        objective: objective,
                        notes: notes,
                        transcriptParagraphs: transcriptParagraphs
                    )
                    return
                } catch {
                    break
                }
            default:
                break
            }
        }
        #endif

        catchUpSummary = fallbackCatchUp(notes: notes, transcriptParagraphs: transcriptParagraphs)
    }

    private func handleTranscriptUpdate(_ text: String, isFinal: Bool) {
        pendingTranscriptUpdateTask?.cancel()

        if isFinal {
            applyTranscriptUpdate(text)
            return
        }

        let candidate = text
        pendingTranscriptUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.applyTranscriptUpdate(candidate)
        }
    }

    private func applyTranscriptUpdate(_ text: String) {
        guard text != transcriptText else { return }
        transcriptText = text
        transcriptParagraphs = text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { cleanSentence($0) }
            .filter { !$0.isEmpty }
        refreshSuggestions()
        autoSuggestTitleIfNeeded()
    }

    /// When the user hasn't typed a title yet and we have meaningful
    /// transcript content, derive a 4-6 word working title from the first
    /// paragraph. Stays out of the way once user has typed anything.
    private func autoSuggestTitleIfNeeded() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = trimmed.isEmpty
            || trimmed == "Live meeting"
            || trimmed == "Meeting"
            || trimmed == "Untitled note"
        guard isPlaceholder else { return }
        guard let firstParagraph = transcriptParagraphs.first,
              firstParagraph.split(separator: " ").count >= 4 else { return }
        let suggested = suggestedMeetingTitle(
            objective: objective,
            notes: firstParagraph,
            fallback: "Meeting"
        )
        guard !suggested.isEmpty, suggested != trimmed else { return }
        title = suggested
    }

    private func fallbackCatchUp(notes: String, transcriptParagraphs: [String]) -> String {
        let noteLines = notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)

        let transcriptLines = transcriptParagraphs.suffix(2)
        var bullets: [String] = []

        if let first = noteLines.first {
            bullets.append("- Current focus: \(cleanSentence(first)).")
        }

        if noteLines.count > 1 {
            bullets.append("- Important signal: \(cleanSentence(String(noteLines.dropFirst().first ?? ""))).")
        } else if let lastTranscript = transcriptLines.last {
            bullets.append("- Recent discussion: \(cleanSentence(lastTranscript)).")
        }

        if let lastTranscript = transcriptLines.first {
            bullets.append("- Next to verify: \(cleanSentence(lastTranscript)).")
        }

        return bullets.isEmpty
            ? "Scribeflow is listening, but there isn’t enough detail yet for a useful catch-up."
            : bullets.joined(separator: "\n")
    }

    private func refreshSuggestions() {
        let candidateTexts = rankedCandidateBullets(from: transcriptParagraphs)
        let noteFingerprints = noteFingerprints(from: manualNotes)
        var uniqueBullets: [String] = []
        var seenFingerprints: Set<String> = []

        for candidate in candidateTexts {
            let candidateFingerprint = fingerprint(for: candidate)

            guard !candidateFingerprint.isEmpty else { continue }
            guard !acceptedFingerprints.contains(candidateFingerprint) else { continue }
            guard !dismissedFingerprints.contains(candidateFingerprint) else { continue }
            guard !noteFingerprints.contains(candidateFingerprint) else { continue }
            guard !seenFingerprints.contains(candidateFingerprint) else { continue }

            seenFingerprints.insert(candidateFingerprint)
            uniqueBullets.append(candidate)
        }

        var refreshed: [CaptureSuggestion] = []

        if uniqueBullets.count >= 3 {
            refreshed.append(contentsOf: uniqueBullets.prefix(2).map { CaptureSuggestion(text: $0, kind: .core) })
            refreshed.append(CaptureSuggestion(text: uniqueBullets[2], kind: .optional))
        } else {
            refreshed.append(contentsOf: uniqueBullets.prefix(2).map { CaptureSuggestion(text: $0, kind: .core) })
        }

        suggestions = refreshed
    }

    private func rankedCandidateBullets(from paragraphs: [String]) -> [String] {
        let weightedTerms = SignalWeights.terms

        let recentParagraphs = Array(paragraphs.suffix(12))

        let scored = recentParagraphs.compactMap { paragraph -> (text: String, score: Int)? in
            guard paragraph.count > 28 else { return nil }

            let lower = paragraph.lowercased()
            var score = 1

            for (term, weight) in weightedTerms where lower.contains(term) {
                score += weight
            }

            if paragraph.rangeOfCharacter(from: .decimalDigits) != nil {
                score += 1
            }

            return (noteBullet(from: paragraph), score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.text.count < rhs.text.count
                }
                return lhs.score > rhs.score
            }
            .map(\.text)
    }

    private func noteBullet(from sentence: String) -> String {
        let cleaned = cleanSentence(sentence)
        let lower = cleaned.lowercased()

        if lower.contains("next") || lower.contains("follow up") || lower.contains("owner") {
            return "Next step: \(cleaned)"
        }

        if lower.contains("need") || lower.contains("needs") || lower.contains("must") {
            return "Need: \(cleaned)"
        }

        if lower.contains("budget") || lower.contains("price") {
            return "Budget signal: \(cleaned)"
        }

        if lower.contains("timeline") || lower.contains("quarter") || lower.contains("launch") {
            return "Timing: \(cleaned)"
        }

        if lower.contains("risk") || lower.contains("issue") || lower.contains("problem") || lower.contains("security") {
            return "Risk: \(cleaned)"
        }

        return cleaned
    }

    private func cleanSentence(_ sentence: String) -> String {
        sentence
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func noteFingerprints(from notes: String) -> Set<String> {
        Set(
            notes
                .split(whereSeparator: \.isNewline)
                .map { fingerprint(for: String($0)) }
                .filter { !$0.isEmpty }
        )
    }

    private func fingerprint(for text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "need: ", with: "")
            .replacingOccurrences(of: "next step: ", with: "")
            .replacingOccurrences(of: "budget signal: ", with: "")
            .replacingOccurrences(of: "timing: ", with: "")
            .replacingOccurrences(of: "risk: ", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isPaused else { return }
                self.elapsedSeconds += 1
                // Refresh elapsed time on Lock Screen / Control Center every 5s
                if self.elapsedSeconds % 5 == 0 {
                    self.updateNowPlaying(isLive: true)
                    MeetingRecordingLiveActivity.shared.update(
                        inputLevel: self.inputLevel,
                        isPaused: false
                    )
                }
            }
        }
    }

    /// Push current recording state into the system Now Playing center so
    /// the Lock Screen + Control Center show "Scribeflow — Recording …"
    /// with elapsed time. The user can glance without unlocking. This does
    /// not surface playback transport controls because we aren't a media
    /// player; we're using NPIC purely as a status surface tied to the
    /// background-audio session.
    private func updateNowPlaying(isLive: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Live capture"
            : title
        info[MPMediaItemPropertyArtist] = "Scribeflow"
        info[MPMediaItemPropertyPlaybackDuration] = TimeInterval(elapsedSeconds + 1)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = TimeInterval(elapsedSeconds)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isLive ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        center.nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func configureAudioSession() throws {
        let mgr = AudioSessionManager.shared
        mgr.startObserving()

        // Resume capture automatically after an interruption (e.g. Siri, alarm).
        mgr.onInterruptionEnded = { [weak self] in
            guard let self, self.isRecording else { return }
            try? await self.restartEngineAfterInterruption()
        }

        // Pause then resume when headphones are unplugged mid-meeting.
        mgr.onRouteChanged = { [weak self] reason in
            guard let self else { return }
            if reason == .oldDeviceUnavailable {
                // Headphones/AirPods disconnected — engine output changed.
                // Remove tap and reinstall on the new route.
                Task { @MainActor [weak self] in
                    self?.handleRouteDisconnect()
                }
            }
        }

        try mgr.configureForLiveMeeting()
    }

    private func restartEngineAfterInterruption() async throws {
        // Session was reactivated by AudioSessionManager after interruption.
        // Restart the engine — the tap and recognition request are still live.
        guard audioEngine.isRunning == false else { return }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private nonisolated func computeAndPublishLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        let channel = data[0]
        for i in 0..<frames {
            let s = channel[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))
        let normalized = min(max(Double(rms) * 12, 0), 1)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Throttle to ~12Hz. Audio tap fires at ~50Hz which over-renders
            // the waveform meter, costing GPU + battery while recording.
            let now = Date.now
            if now.timeIntervalSince(self.lastLevelPublishAt) >= 0.08 {
                self.lastLevelPublishAt = now
                self.inputLevel = normalized
            }
        }
    }

    private func handleRouteDisconnect() {
        guard audioEngine.isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
            self?.computeAndPublishLevel(buf)
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum AppleIntelligenceLiveAssistant {
    static func availability() -> SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static func catchUp(
        title: String,
        objective: String,
        notes: String,
        transcriptParagraphs: [String]
    ) async throws -> String {
        let session = LanguageModelSession(instructions: """
        You are a live meeting copilot inside a professional note-taking app.
        Generate a short catch-up for someone who wants to rejoin the conversation quickly.
        Return exactly 3 concise bullet points.
        Focus on where the meeting stands now, the most important signal or decision, and the next action or open question.
        Do not invent facts that are not supported by the notes or transcript.
        """)

        let transcriptContext = transcriptParagraphs.suffix(8).joined(separator: "\n")
        let prompt = """
        Meeting title: \(title)
        Objective: \(objective)

        Rough notes:
        \(notes.isEmpty ? "No rough notes yet." : notes)

        Transcript context:
        \(transcriptContext.isEmpty ? "No transcript context yet." : transcriptContext)

        Write the catch-up now.
        """

        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
