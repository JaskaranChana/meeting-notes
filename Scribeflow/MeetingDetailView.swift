import SwiftUI

private struct MeetingTranscriptSnapshotKey: Hashable {
    let revision: Int
    let query: String
}

private struct MeetingAnswerSources: View {
    let citations: [RAGResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryInk)

            ForEach(citations.prefix(5)) { citation in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(citation.sourceID)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 28, minHeight: 22)
                            .padding(.horizontal, 4)
                            .background(AppPalette.accent, in: Capsule())

                        Text(citation.sourceLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.ink)
                    }

                    Text(citation.snippet)
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer sources")
    }
}

private struct MeetingTranscriptDisplaySnapshot {
    let lines: [TranscriptLine]
    let wordCount: Int
}

private actor MeetingTranscriptSnapshotBuilder {
    private var cachedRevision = -1
    private var cachedLines: [TranscriptLine] = []
    private var cachedWordCount = 0

    func make(
        lines: [TranscriptLine],
        revision: Int,
        query: String
    ) -> MeetingTranscriptDisplaySnapshot {
        if revision != cachedRevision {
            cachedLines = lines
            cachedWordCount = lines.reduce(into: 0) { count, line in
                count += line.text.split(whereSeparator: \.isWhitespace).count
            }
            cachedRevision = revision
        }

        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [TranscriptLine]
        if cleanedQuery.isEmpty {
            filtered = cachedLines
        } else {
            var matches: [TranscriptLine] = []
            matches.reserveCapacity(min(cachedLines.count, 32))
            for line in cachedLines {
                guard !Task.isCancelled else { break }
                if line.speaker.localizedCaseInsensitiveContains(cleanedQuery)
                    || line.text.localizedCaseInsensitiveContains(cleanedQuery) {
                    matches.append(line)
                }
            }
            filtered = matches
        }
        return MeetingTranscriptDisplaySnapshot(lines: filtered, wordCount: cachedWordCount)
    }
}

struct MeetingDetailView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("preferredRewriteStyle") private var preferredRewriteStyleRaw = NoteRewriteStyle.concise.rawValue
    let meetingID: Meeting.ID
    @State private var isRewriting = false
    @State private var rewriteMessage: String?
    @State private var isGeneratingPrompt = false
    @State private var promptResponse: String?
    @State private var promptCitations: [RAGResult] = []
    @State private var promptTitle = ""
    @State private var shareText = ""
    @State private var showingShareSheet = false
    @State private var transcriptSearchText = ""
    @State private var exportFormat: MeetingExportFormat = .internalBrief
    @State private var evidenceFilter: EvidenceFilter = .all
    @State private var includeInferredInShare = true
    @State private var includePrivateNotesInShare = true
    @State private var includeTranscriptInShare = false
    @State private var hasAnimatedIn = false
    @State private var showEnhanced = false
    @State private var trustControlsExpanded = false
    @State private var shareOptionsExpanded = false
    @State private var showingChat = false
    @State private var showingContextPicker = false
    @State private var showingShareCustomize = false
    @State private var showingPresentation = false
    @State private var showingPeopleCard: String? = nil
    @State private var showingAttachRecorder = false
    @State private var showingDeleteConfirmation = false
    @State private var sendingWebhookIDs: Set<UUID> = []
    @State private var recordingRenameText = ""
    @State private var recordingPendingRename: AudioRecordingAttachment?
    @State private var recordingPendingDelete: AudioRecordingAttachment?
    @State private var recordingTranscriptionIDs: Set<AudioRecordingAttachment.ID> = []
    @State private var showingSpeakerEditor = false
    @State private var transcriptLinePendingSpeakerEdit: TranscriptLine?
    @State private var selectedSourceProof: SourceProofSelection?
    @State private var rewriteTask: Task<Void, Never>?
    @State private var promptTask: Task<Void, Never>?
    @State private var cachedSignals = MeetingSignals(decisions: [], actions: [], risks: [])
    @State private var cachedPrepBrief = PrepBrief(headline: "", bullets: [], questions: [])
    @State private var cachedSynopsis: String = ""
    @State private var cachedIntelligenceReport: MeetingIntelligenceReport?
    @State private var cachedPurpose: CapturePurpose?
    @State private var cachedTranscriptLines: [TranscriptLine] = []
    @State private var cachedTranscriptWordCount = 0
    @State private var transcriptSnapshotBuilder = MeetingTranscriptSnapshotBuilder()
    @State private var isPreparingContent = true
    @State private var selectedTab: HubTab = .overview
    @AppStorage("hasUsedMeetingTabs") private var hasUsedTabs = false

    /// Top-of-page segmented picker. Each tab shows the cards a user most
    /// likely wants in that context — so the meeting page reads as one
    /// balanced screen, not a wall of cards or a list of destinations.
    enum HubTab: String, CaseIterable, Identifiable {
        case overview, tasks, transcript, more
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview:   return "Overview"
            case .tasks:      return "Tasks"
            case .transcript: return "Transcript"
            case .more:       return "More"
            }
        }
    }

    func visibleTabs(for meeting: Meeting) -> [HubTab] {
        resolvedPurpose(for: meeting).allowsAccountabilityExtraction
            ? HubTab.allCases
            : [.overview, .transcript, .more]
    }

    /// Per-tab count badge that appears next to the title. Reinforces the
    /// info inside each tab without the user opening it.
    func count(for tab: HubTab, in meeting: Meeting) -> Int? {
        switch tab {
        case .overview:
            return nil
        case .tasks:
            guard resolvedPurpose(for: meeting).allowsAccountabilityExtraction else { return nil }
            // Commitments and signal actions are the same extractor now — don't
            // sum them. Open commitments when present, else the live signals.
            let open = meeting.commitments.filter { $0.status == .open || $0.status == .atRisk }.count
            let total = open > 0 ? open : meetingSignals.actions.count
            return total > 0 ? total : nil
        case .transcript:
            return meeting.transcript.isEmpty ? nil : meeting.transcript.count
        case .more:
            return nil
        }
    }

    /// Routes for the sub-detail screens pushed from the hub. Used with
    /// value-based NavigationLink so destinations build lazily on push.
    enum DetailRoute: Hashable {
        case transcript, notes, commitments, action, signalBoard, recordings,
             intelligence, score, prep

        var title: String {
            switch self {
            case .transcript:    return "Transcript"
            case .notes:         return "Notes"
            case .commitments:   return "Commitments"
            case .action:        return "Action plan"
            case .signalBoard:   return "Decisions & risks"
            case .recordings:    return "Recordings"
            case .intelligence:  return "Intelligence"
            case .score:         return "Meeting score"
            case .prep:          return "Prep for next"
            }
        }
    }

    var meeting: Meeting? {
        store.meeting(withID: meetingID)
    }

    var meetingSignals: MeetingSignals { cachedSignals }
    var prepBrief: PrepBrief { cachedPrepBrief }

    private func resolvedPurpose(for meeting: Meeting) -> CapturePurpose {
        cachedPurpose ?? meeting.purpose
    }

    private var transcriptSnapshotKey: MeetingTranscriptSnapshotKey {
        MeetingTranscriptSnapshotKey(
            revision: store.semanticRevision(for: meetingID),
            query: transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// One-tap share path — builds a clean readable digest (Markdown) and
    /// presents the system share sheet without the customize step.
    private func quickShareDigest(_ m: Meeting) {
        shareText = buildDigestMarkdown(for: m)
        showingShareSheet = true
        HapticEngine.notify(.success)
    }

    private func buildDigestMarkdown(for m: Meeting) -> String {
        meetingDigestMarkdown(m, signals: store.signals(for: m))
    }

    private func refreshDerived(expectedSemanticRevision: Int) async {
        guard let m = meeting else { return }
        let bundle = await store.analysisBundle(for: m)
        guard !Task.isCancelled,
              store.meeting(withID: m.id) != nil,
              store.semanticRevision(for: m.id) == expectedSemanticRevision
        else { return }
        cachedSignals = bundle.signals
        cachedSynopsis = synopsisFor(m, summary: m.summary(for: m.selectedTemplate))
        cachedIntelligenceReport = bundle.report
        cachedPurpose = bundle.purpose
        if transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cachedTranscriptLines = m.transcript
        }
        if selectedTab == .more {
            cachedPrepBrief = store.prepBrief(for: m)
        }
        isPreparingContent = false
    }

    private func refreshPrepIfNeeded() {
        guard selectedTab == .more, let meeting else { return }
        cachedPrepBrief = store.prepBrief(for: meeting)
    }

    private var preferredRewriteStyle: NoteRewriteStyle {
        get { NoteRewriteStyle(rawValue: preferredRewriteStyleRaw) ?? .concise }
        nonmutating set { preferredRewriteStyleRaw = newValue.rawValue }
    }

    private func availableExportFormats(for meeting: Meeting) -> [MeetingExportFormat] {
        resolvedPurpose(for: meeting).allowsAccountabilityExtraction
            ? MeetingExportFormat.allCases
            : [.internalBrief, .markdown]
    }

    private func exportFormatTitle(_ format: MeetingExportFormat, for meeting: Meeting) -> String {
        if !resolvedPurpose(for: meeting).allowsAccountabilityExtraction,
           format == .internalBrief {
            return "Clean note"
        }
        return format.title
    }

    var body: some View {
        Group {
            if let meeting {
                meetingScreen(meeting)
            } else {
                ContentUnavailableView("Meeting not found", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func meetingScreen(_ meeting: Meeting) -> some View {
        let page = meetingPage(meeting)
        let primaryPresentations = attachPrimaryPresentations(to: page, meeting: meeting)
        let editorPresentations = attachEditorPresentations(to: primaryPresentations, meeting: meeting)
        let contextPresentations = attachContextPresentations(to: editorPresentations, meeting: meeting)
        return attachLifecycle(to: contextPresentations, meeting: meeting)
    }

    private func meetingPage(_ meeting: Meeting) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                meetingDetailHero(meeting)
                    .padding(.horizontal, AppLayout.screenHorizontalPadding)
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, AppSpacing.xs)
                    .readingWidth()

                hubTabPicker(meeting)
                    .padding(.horizontal, AppLayout.screenHorizontalPadding)
                    .padding(.top, AppSpacing.md)
                    .readingWidth()

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    if isPreparingContent {
                        meetingContentLoadingState
                    } else {
                        hubTabContent(meeting)
                    }
                }
                .appScreenContent(top: AppSpacing.md, bottom: 40)
            }
        }
        .background(AppPalette.background.ignoresSafeArea())
        .accessibilityIdentifier("meetingdetail.view")
        .navigationTitle(resolvedPurpose(for: meeting).isPersonalCapture ? "Note" : "Meeting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            meetingToolbar(for: meeting)
        }
    }

    @ToolbarContentBuilder
    private func meetingToolbar(for meeting: Meeting) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    HapticEngine.tap(.light)
                    quickShareDigest(meeting)
                } label: {
                    Label("Share digest", systemImage: "doc.plaintext")
                }
                Button {
                    HapticEngine.tap(.light)
                    showingShareCustomize = true
                } label: {
                    Label("Customize…", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")

            Menu {
                Button("Present", systemImage: "play.rectangle.fill") {
                    HapticEngine.tap(.medium)
                    showingPresentation = true
                }
                Button(meeting.isPinned ? "Unpin" : "Pin", systemImage: meeting.isPinned ? "pin.slash" : "pin") {
                    HapticEngine.select()
                    let wasPinned = meeting.isPinned
                    store.togglePinned(for: meeting.id)
                    NotificationCenter.default.post(
                        name: .scribeflowToast,
                        object: ToastItem(
                            message: wasPinned ? "Unpinned" : "Pinned to Today",
                            icon: wasPinned ? "pin.slash" : "pin.fill"
                        )
                    )
                }
                Button("Duplicate", systemImage: "doc.on.doc") {
                    _ = store.duplicateMeeting(meeting.id)
                    dismiss()
                }
                ShareLink(
                    item: store.safeSharePreview(
                        for: meeting.id,
                        format: .markdown,
                        includeInferred: true,
                        includePrivateNotes: false,
                        includeTranscript: false
                    ) ?? meeting.title,
                    subject: Text(meeting.title)
                ) {
                    Label("Share as Markdown", systemImage: "doc.text")
                }
                if !WebhookStore.shared.configs.isEmpty {
                    Menu("Send to") {
                        ForEach(WebhookStore.shared.configs) { config in
                            Button {
                                sendToWebhook(meeting: meeting, config: config)
                            } label: {
                                Label(
                                    webhookTitle(for: config),
                                    systemImage: sendingWebhookIDs.contains(config.id)
                                        ? "arrow.triangle.2.circlepath"
                                        : config.target.systemImage
                                )
                            }
                            .disabled(sendingWebhookIDs.contains(config.id))
                        }
                    }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    HapticEngine.notify(.warning)
                    showingDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More options")
        }
    }

    private func webhookTitle(for config: WebhookConfig) -> String {
        let label = config.label.isEmpty ? config.target.title : config.label
        return sendingWebhookIDs.contains(config.id) ? "Sending to \(label)" : label
    }

    private func attachPrimaryPresentations<Content: View>(
        to content: Content,
        meeting: Meeting
    ) -> some View {
        content
            .sheet(isPresented: $showingShareCustomize) {
                shareCustomizeSheet(meeting)
            }
            .sheet(isPresented: $showingShareSheet) {
                ActivityView(items: [shareText]) { completed in
                    if completed {
                        store.markShared(for: meeting.id)
                        HapticEngine.notify(.success)
                    }
                }
            }
            .fullScreenCover(isPresented: $showingPresentation) {
                MeetingPresentationSheet(meeting: meeting, signals: store.signals(for: meeting))
            }
            .sheet(isPresented: $showingChat) {
                SourceCitedChatView(meeting: meeting)
                    .presentationCornerRadius(30)
            }
            .sheet(isPresented: $showingAttachRecorder) {
                VoiceRecorderView(selectedMeetingID: .constant(meeting.id), presentationMode: .attach(meeting.id))
                    .presentationCornerRadius(30)
            }
    }

    private func attachEditorPresentations<Content: View>(
        to content: Content,
        meeting: Meeting
    ) -> some View {
        content
            .sheet(isPresented: $showingSpeakerEditor) {
                SpeakerEditorView(meetingID: meeting.id)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(30)
            }
            .sheet(item: $transcriptLinePendingSpeakerEdit) { line in
                TranscriptSpeakerAssignmentView(meetingID: meeting.id, line: line)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(30)
            }
            .sheet(item: $selectedSourceProof) { selection in
                SourceProofInspectorView(selection: selection)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(30)
            }
            .alert("Rename recording", isPresented: recordingRenamePresented) {
                TextField("Recording title", text: $recordingRenameText)
                Button("Save") {
                    if let recordingPendingRename {
                        store.updateRecordingTitle(
                            recordingRenameText,
                            recordingID: recordingPendingRename.id,
                            in: meeting.id
                        )
                    }
                    recordingPendingRename = nil
                }
                Button("Cancel", role: .cancel) {
                    recordingPendingRename = nil
                }
            }
            .confirmationDialog(
                "Delete recording?",
                isPresented: recordingDeletePresented,
                titleVisibility: .visible
            ) {
                if let recordingPendingDelete {
                    Button("Delete \(recordingPendingDelete.title)", role: .destructive) {
                        store.deleteRecording(recordingPendingDelete.id, from: meeting.id)
                        self.recordingPendingDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    recordingPendingDelete = nil
                }
            } message: {
                Text("This removes the local audio file from this device.")
            }
            .confirmationDialog(
                resolvedPurpose(for: meeting).isPersonalCapture ? "Delete this note?" : "Delete this meeting?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let meetingID = meeting.id
                    dismiss()
                    Task { @MainActor in
                        await Task.yield()
                        let undoToast = withAnimation(reduceMotion ? nil : AppMotion.snappy) {
                            MeetingDeletionCoordinator.shared.deleteMeeting(meetingID, from: store)
                        }
                        guard let undoToast else { return }
                        HapticEngine.notify(.warning)
                        NotificationCenter.default.post(
                            name: .scribeflowToast,
                            object: undoToast
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The note, transcript, and recordings disappear now, and you can undo for a few seconds.")
            }
    }

    private var recordingRenamePresented: Binding<Bool> {
        Binding(
            get: { recordingPendingRename != nil },
            set: { if !$0 { recordingPendingRename = nil } }
        )
    }

    private var recordingDeletePresented: Binding<Bool> {
        Binding(
            get: { recordingPendingDelete != nil },
            set: { if !$0 { recordingPendingDelete = nil } }
        )
    }

    private func attachContextPresentations<Content: View>(
        to content: Content,
        meeting: Meeting
    ) -> some View {
        content
            .sheet(isPresented: $showingContextPicker) {
                MeetingContextPickerView(selectedMode: Binding(
                    get: { meeting.contextMode },
                    set: { store.updateContextMode($0, for: meeting.id) }
                ))
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(30)
            }
            .sheet(item: selectedPersonBinding) { item in
                peopleIntelligenceSheet(for: item.value)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(30)
            }
    }

    private var selectedPersonBinding: Binding<IdentifiableString?> {
        Binding(
            get: { showingPeopleCard.map { IdentifiableString(value: $0) } },
            set: { showingPeopleCard = $0?.value }
        )
    }

    private func peopleIntelligenceSheet(for personName: String) -> some View {
        NavigationStack {
            ScrollView {
                PeopleIntelligenceCard(
                    person: store.personIntelligence(for: personName)
                )
                .appScreenContent(top: AppSpacing.md)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle(personName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingPeopleCard = nil }
                        .tint(AppPalette.accent)
                }
            }
        }
    }

    private func attachLifecycle<Content: View>(
        to content: Content,
        meeting: Meeting
    ) -> some View {
        content
            .onAppear {
                hasAnimatedIn = true
            }
            .task(id: store.semanticRevision(for: meetingID)) {
                // Only source-content changes restart intelligence work. Pin,
                // share, reminder, and score mutations still redraw their
                // affected controls without re-running note analysis.
                let expectedSemanticRevision = store.semanticRevision(for: meetingID)
                if cachedIntelligenceReport != nil {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                guard !Task.isCancelled,
                      store.semanticRevision(for: meetingID) == expectedSemanticRevision
                else { return }
                if !visibleTabs(for: meeting).contains(selectedTab) {
                    selectedTab = .overview
                }
                await refreshDerived(expectedSemanticRevision: expectedSemanticRevision)
                guard !Task.isCancelled,
                      store.semanticRevision(for: meetingID) == expectedSemanticRevision
                else { return }
                await store.scoreAndSave(
                    for: meeting.id,
                    allowsAccountability: resolvedPurpose(for: meeting).allowsAccountabilityExtraction
                )
            }
            .task(id: transcriptSnapshotKey) {
                await refreshTranscriptSnapshot(for: transcriptSnapshotKey)
            }
            .onChange(of: selectedTab) { _, _ in
                refreshPrepIfNeeded()
            }
            .navigationDestination(for: DetailRoute.self) { route in
                detailDestination(route)
            }
            .onDisappear {
                rewriteTask?.cancel()
                promptTask?.cancel()
                rewriteTask = nil
                promptTask = nil
            }
    }

    private var meetingContentLoadingState: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(AppPalette.accent)

            VStack(alignment: .leading, spacing: 3) {
                Text("Preparing this note")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("Organizing sources and meeting intelligence")
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing this note")
    }

    // MARK: - Navigable detail rows
    //
    // Use value-based NavigationLink + navigationDestination so destinations
    // build lazily on push (not eagerly when the hub renders). Avoids
    // expensive views being constructed up-front and the crashes that come
    // from nesting heavy NavigationLink-closure destinations.

    private func transcriptNavRow(_ meeting: Meeting) -> some View {
        let lineCount = meeting.transcript.count
        let preview = meeting.transcript.first?.text ?? "No transcript captured yet."
        return NavigationLink(value: DetailRoute.transcript) {
            detailNavRow(
                icon: "waveform",
                tint: AppPalette.accent,
                title: "Transcript",
                subtitle: preview,
                trailingDigits: lineCount > 0 ? "\(lineCount)" : nil,
                trailingLabel: lineCount == 1 ? "line" : "lines"
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    private func notesNavRow(_ meeting: Meeting) -> some View {
        let preview = meeting.rawNotes
            .split(separator: "\n")
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? "No notes yet."
        let count = meeting.rawNotes
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        return NavigationLink(value: DetailRoute.notes) {
            detailNavRow(
                icon: "square.and.pencil",
                tint: AppPalette.ink,
                title: "Notes",
                subtitle: preview.isEmpty ? "No notes yet." : preview,
                trailingDigits: count > 0 ? "\(count)" : nil,
                trailingLabel: count == 1 ? "line" : "lines"
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    private func commitmentsNavRow(_ meeting: Meeting) -> some View {
        let allowsAccountability = resolvedPurpose(for: meeting).allowsAccountabilityExtraction
        let open = meeting.commitments.filter { $0.status == .open || $0.status == .atRisk }
        let preview = allowsAccountability
            ? (open.first?.statement ?? meeting.commitments.first?.statement ?? "No commitments yet.")
            : "Personal notes stay private and are not treated as tasks."
        return NavigationLink(value: DetailRoute.commitments) {
            detailNavRow(
                icon: allowsAccountability ? "checklist" : "lock.doc",
                tint: allowsAccountability ? AppPalette.coral : AppPalette.accent,
                title: allowsAccountability ? "Commitments" : "Personal note",
                subtitle: preview,
                trailingDigits: allowsAccountability && !open.isEmpty ? "\(open.count)" : nil,
                trailingLabel: allowsAccountability ? "open" : nil
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    private func actionNavRow(_ meeting: Meeting) -> some View {
        let actionCount = meetingSignals.actions.count
        let preview = meetingSignals.actions.first ?? "No follow-ups extracted yet."
        return NavigationLink(value: DetailRoute.action) {
            detailNavRow(
                icon: "arrow.right.circle.fill",
                tint: AppPalette.success,
                title: "Action plan",
                subtitle: preview,
                trailingDigits: actionCount > 0 ? "\(actionCount)" : nil,
                trailingLabel: actionCount == 1 ? "action" : "actions"
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    private func signalBoardNavRow(_ meeting: Meeting) -> some View {
        let decisions = meetingSignals.decisions.count
        let risks = meetingSignals.risks.count
        let total = decisions + risks
        let preview = meetingSignals.decisions.first
            ?? meetingSignals.risks.first
            ?? "Decisions, risks, and signals."
        return NavigationLink(value: DetailRoute.signalBoard) {
            detailNavRow(
                icon: "checkmark.seal.fill",
                tint: AppPalette.gold,
                title: "Decisions & risks",
                subtitle: preview,
                trailingDigits: total > 0 ? "\(total)" : nil,
                trailingLabel: total == 1 ? "signal" : "signals"
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    private func recordingsNavRow(_ meeting: Meeting) -> some View {
        let count = meeting.audioRecordings.count
        let preview: String
        if let first = meeting.audioRecordings.first {
            let mins = max(1, first.durationSeconds / 60)
            preview = "\(first.title) · \(mins) min"
        } else {
            preview = "No recordings attached."
        }
        return NavigationLink(value: DetailRoute.recordings) {
            detailNavRow(
                icon: "waveform.badge.mic",
                tint: AppPalette.gold,
                title: "Recordings",
                subtitle: preview,
                trailingDigits: count > 0 ? "\(count)" : nil,
                trailingLabel: count == 1 ? "clip" : "clips"
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    // MARK: - Hub tabs

    /// Premium segmented picker — four short tabs, accent pill on selected.
    /// Each tab shows a tiny inline count badge so the user knows what's
    /// inside before tapping.
    private func hubTabPicker(_ meeting: Meeting) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(visibleTabs(for: meeting)) { tab in
                    let selected = selectedTab == tab
                    Button {
                        HapticEngine.select()
                        hasUsedTabs = true
                        withAnimation(reduceMotion ? nil : AppMotion.smooth) { selectedTab = tab }
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 5) {
                                Text(tab.title)
                                    .font(.subheadline.weight(selected ? .semibold : .medium))
                                if let n = count(for: tab, in: meeting) {
                                    Text("\(n)")
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .contentTransition(.numericText())
                                        .foregroundStyle(selected ? AppPalette.accent : AppPalette.tertiaryInk)
                                }
                            }
                            .foregroundStyle(selected ? AppPalette.ink : AppPalette.tertiaryInk)
                            Rectangle()
                                .fill(selected ? AppPalette.accent : .clear)
                                .frame(height: 2)
                        }
                        .frame(minHeight: 44)
                        .overlay(alignment: .topTrailing) {
                            if !hasUsedTabs && !selected && tab != .overview {
                                Circle()
                                    .fill(AppPalette.accent)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 7, y: -1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("meetingdetail.tab.\(tab.rawValue)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        }
        .scrollClipDisabled()
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppPalette.border.opacity(0.7)).frame(height: 1)
        }
    }

    /// Inline content for the active tab. Each tab pulls a small set of the
    /// most-used cards; deep / one-off destinations live behind the `More` tab.
    @ViewBuilder
    private func hubTabContent(_ meeting: Meeting) -> some View {
        switch selectedTab {
        case .overview:
            overviewCanvas(meeting)
        case .tasks:
            tasksCanvas(meeting)
        case .transcript:
            transcriptCanvas(meeting)
        case .more:
            sectionGroup(title: "NOTES & MEDIA") {
                notesNavRow(meeting)
                recordingsNavRow(meeting)
            }
            sectionGroup(title: "INTELLIGENCE") {
                if resolvedPurpose(for: meeting).allowsMeetingSignals {
                    signalBoardNavRow(meeting)
                }
                intelligenceNavRow(meeting)
                if resolvedPurpose(for: meeting).allowsAccountabilityExtraction {
                    scoreNavRow(meeting)
                }
            }
            if resolvedPurpose(for: meeting).allowsAccountabilityExtraction {
                sectionGroup(title: "PREP") {
                    prepNavRow(meeting)
                }
            }
        }
    }

    // MARK: - Overview canvas

    @ViewBuilder
    func overviewCanvas(_ meeting: Meeting) -> some View {
        overviewSnapshot(meeting)
        overviewTrustSummary(meeting)
        if resolvedPurpose(for: meeting).allowsAccountabilityExtraction {
            overviewStatsRow(meeting)
        }
        editorialWhatMatters(meeting)
        overviewNextAction(meeting)
        if resolvedPurpose(for: meeting).isPersonalCapture {
            notesNavRow(meeting)
        }
        overviewPrimaryAction
    }

    @ViewBuilder
    func editorialWhatMatters(_ meeting: Meeting) -> some View {
        let generatedItems = meeting.aiBrief?.whatMatters ?? []
        let items = generatedItems.isEmpty
            ? Array((cachedIntelligenceReport?.suggestedSummary ?? []).prefix(4))
            : generatedItems
        if !items.isEmpty {
            editorialPointList(
                title: resolvedPurpose(for: meeting).allowsMeetingSignals
                    ? "What matters"
                    : resolvedPurpose(for: meeting).kind.insightTitle,
                items: items,
                tint: AppPalette.accent,
                limit: 4,
                meeting: meeting,
                showsSourceProof: true
            )
        }
    }

    @ViewBuilder
    private func overviewNextAction(_ meeting: Meeting) -> some View {
        if resolvedPurpose(for: meeting).allowsAccountabilityExtraction,
           let commitment = meeting.commitments.first(where: {
               $0.status == .atRisk || $0.status == .open
           }) {
            VStack(alignment: .leading, spacing: 6) {
                EditorialSectionHead(title: "Next action", titleSize: 18)
                editorialActionRow(commitment, in: meeting)
            }
        } else if resolvedPurpose(for: meeting).allowsAccountabilityExtraction,
                  let action = meetingSignals.actions.first {
            editorialPointList(
                title: "Next action",
                items: [action],
                tint: AppPalette.coral,
                limit: 1,
                meeting: meeting,
                showsSourceProof: true
            )
        }
    }

    /// Synopsis rendered as an editorial pull-quote: italic serif with an
    /// accent rule down the left edge.
    func overviewSnapshot(_ meeting: Meeting) -> some View {
        let synopsis = cachedSynopsis.isEmpty
            ? synopsisFor(meeting, summary: meeting.summary(for: meeting.selectedTemplate))
            : cachedSynopsis
        return VStack(alignment: .leading, spacing: 10) {
            EditorialEyebrow(text: "Synopsis")
            Text(synopsis)
                .scaledFont(size: 19, design: .serif, relativeTo: .title3)
                .italic()
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AppPalette.accent).frame(width: 2)
                }
            aiStatusRow(meeting)
            briefFocusRow(meeting)
            SourceProofButton(proof: store.sourceProof(for: synopsis, in: meeting)) {
                inspectSource(for: synopsis, in: meeting)
            }
            .padding(.leading, 14)
        }
        .padding(.top, 4)
        .animation(reduceMotion ? nil : AppMotion.smooth, value: store.isProcessingAI(meeting.id))
        .animation(reduceMotion ? nil : AppMotion.smooth, value: meeting.aiBrief != nil)
    }

    private func briefFocusRow(_ meeting: Meeting) -> some View {
        let report = cachedIntelligenceReport ?? store.intelligenceReport(for: meeting)
        return HStack(spacing: 10) {
            Menu {
                ForEach(NoteTemplate.allCases) { template in
                    Button {
                        HapticEngine.select()
                        store.selectTemplate(template, for: meeting.id)
                    } label: {
                        Label(template.title, systemImage: template == meeting.selectedTemplate ? "checkmark" : template.systemImage)
                    }
                }
            } label: {
                Label("Focus: \(meeting.selectedTemplate.title)", systemImage: "scope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.accent)
            }

            Label(
                report.speakerDetection.detectedCount == 0
                    ? "Speakers not identified"
                    : "\(report.speakerDetection.detectedCount) speaker label\(report.speakerDetection.detectedCount == 1 ? "" : "s")",
                systemImage: "person.wave.2"
            )
                .font(.caption.weight(.medium))
                .foregroundStyle(AppPalette.secondaryInk)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
    }

    /// Tells the user which engine produced the brief: a live "Processing…"
    /// state while the on-device model runs, then an "Enhanced" mark once it has.
    @ViewBuilder
    private func aiStatusRow(_ meeting: Meeting) -> some View {
        if store.isPreparingDerivedData(meeting.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Organizing notes and sources…")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppPalette.accent)
            }
            .padding(.leading, 14)
            .transition(.opacity)
        } else if store.isProcessingAI(meeting.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Processing with Apple Intelligence…")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppPalette.accent)
            }
            .padding(.leading, 14)
            .transition(.opacity)
        } else if meeting.aiBrief != nil {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                Text("Enhanced by Apple Intelligence")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(AppPalette.secondaryInk)
            .padding(.leading, 14)
            .transition(.opacity)
        }
    }

    /// Single source of truth lives in `meetingSynopsis` (SharedViews), so the
    /// brief and the shared/exported digest always read the same.
    func synopsisFor(_ meeting: Meeting, summary: MeetingSummary) -> String {
        meetingSynopsis(for: meeting, summary: summary)
    }

    private func overviewTrustSummary(_ meeting: Meeting) -> some View {
        let report = cachedIntelligenceReport ?? store.intelligenceReport(for: meeting)
        let sourceCounts = sourceProofCounts(for: meeting)
        let sourceTotal = sourceCounts.notes + sourceCounts.transcript + sourceCounts.audio
        let purpose = resolvedPurpose(for: meeting)
        let isProcessing = meeting.status == .processing
        let heading: String
        if isProcessing {
            heading = "Refining saved capture"
        } else if purpose.confidence == .conservative {
            heading = "Review: \(purpose.displayTitle)"
        } else {
            heading = purpose.displayTitle
        }

        var detailParts: [String] = []
        if let topic = purpose.topic { detailParts.append(topic) }
        if let domain = purpose.domain,
           !detailParts.contains(where: { $0.caseInsensitiveCompare(domain) == .orderedSame }) {
            detailParts.append(domain)
        }
        if purpose.confidence == .strong { detailParts.append("Likely note type") }
        if purpose.confidence == .conservative { detailParts.append("Note type needs review") }
        detailParts.append(report.confidenceLabel)
        detailParts.append("\(sourceTotal) source\(sourceTotal == 1 ? "" : "s")")
        if report.speakerDetection.detectedCount > 0 {
            detailParts.append("\(report.speakerDetection.detectedCount) voice\(report.speakerDetection.detectedCount == 1 ? "" : "s")")
        }

        return NavigationLink(value: DetailRoute.intelligence) {
            HStack(spacing: 12) {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppPalette.gold)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: sourceTotal > 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(sourceTotal > 0 ? AppPalette.accent : AppPalette.gold)
                        .frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(heading)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(detailParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorialRowStyle())
        .overlay(alignment: .top) { EditorialRule() }
        .overlay(alignment: .bottom) { EditorialRule() }
    }

    private func sourceProofCounts(for meeting: Meeting) -> (notes: Int, transcript: Int, audio: Int) {
        let noteEvidenceCount = meeting.evidenceItems.reduce(into: 0) { count, item in
            if item.sourceReferences.contains(where: { $0.kind == .note }) {
                count += 1
            }
        }
        let notes = noteEvidenceCount > 0 ? noteEvidenceCount : (meeting.trustedSourceNotes.isEmpty ? 0 : 1)
        let audio = meeting.audioRecordings.filter {
            !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.linkedNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        return (notes, meeting.transcript.count, audio)
    }

    /// Flat decisions / actions / risks / score row, divided by hairlines and
    /// bracketed top and bottom — the editorial stat strip.
    func overviewStatsRow(_ meeting: Meeting) -> some View {
        let decisions = meetingSignals.decisions.count
        // Commitments and signal actions are the same extractor now, so don't
        // sum them — count commitments when present, else the live signals.
        let actions = resolvedPurpose(for: meeting).allowsAccountabilityExtraction
            ? (meeting.commitments.isEmpty ? meetingSignals.actions.count : meeting.commitments.count)
            : 0
        let risks = meetingSignals.risks.count
        let score = resolvedPurpose(for: meeting).allowsAccountabilityExtraction
            ? meeting.score?.overall
            : nil
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    overviewMetaStat("Decisions", "\(decisions)", nil, AppPalette.success)
                    EditorialRule()
                    overviewMetaStat("Actions", "\(actions)", nil, AppPalette.coral)
                    EditorialRule()
                    overviewMetaStat("Risks", "\(risks)", nil, AppPalette.ink)
                    EditorialRule()
                    overviewMetaStat("Score", score.map { "\($0)" } ?? "—", score != nil ? "/100" : nil, AppPalette.ink)
                }
            } else {
                HStack(spacing: 0) {
                    overviewMetaStat("Decisions", "\(decisions)", nil, AppPalette.success)
                    overviewStatDivider
                    overviewMetaStat("Actions", "\(actions)", nil, AppPalette.coral)
                    overviewStatDivider
                    overviewMetaStat("Risks", "\(risks)", nil, AppPalette.ink)
                    overviewStatDivider
                    overviewMetaStat("Score", score.map { "\($0)" } ?? "—", score != nil ? "/100" : nil, AppPalette.ink)
                }
            }
        }
        .overlay(alignment: .top) { EditorialRule() }
        .overlay(alignment: .bottom) { EditorialRule() }
    }

    private var overviewStatDivider: some View {
        Rectangle().fill(AppPalette.border.opacity(0.7)).frame(width: 1, height: 28)
    }

    private func overviewMetaStat(_ label: String, _ value: String, _ suffix: String?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            EditorialEyebrow(text: label)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(AppFont.serif(.title3, weight: .medium))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                if let suffix {
                    Text(suffix).font(.system(size: 11)).foregroundStyle(AppPalette.secondaryInk)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(suffix ?? "") \(label)")
    }

    /// One calm, consistent treatment for every read-only section: a small
    /// colored dot + serif line. Keeps the brief from becoming a wall of
    /// competing icons, bars, and tinted cards.
    @ViewBuilder
    func editorialPointList(
        title: String,
        items: [String],
        tint: Color,
        limit: Int,
        quiet: Bool = false,
        meeting: Meeting? = nil,
        showsSourceProof: Bool = false
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                EditorialSectionHead(title: title, titleSize: 18) {
                    EditorialMeta(text: "\(items.count)", tint: tint)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(tint).frame(width: 7, height: 7).padding(.top, 8)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(text)
                                    .font(.system(size: 16, design: .serif))
                                    .foregroundStyle(quiet ? AppPalette.secondaryInk : AppPalette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if showsSourceProof, let meeting {
                                    SourceProofButton(proof: store.sourceProof(for: text, in: meeting)) {
                                        inspectSource(for: text, in: meeting)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .editorialReveal()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func personalNoteAccountabilityMessage() -> some View {
        Text("This is saved as a personal note, so Scribeflow keeps the writing as notes instead of turning it into tasks or risks.")
            .font(.footnote)
            .foregroundStyle(AppPalette.secondaryInk)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func personalNoteTasksEmptyState() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Personal note")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.ink)
            Text("No tasks or risks are extracted from personal captures. Move this into a meeting context when you want accountability tracking.")
                .font(.footnote)
                .foregroundStyle(AppPalette.secondaryInk)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
    }

    private func editorialActionRow(_ c: Commitment, in meeting: Meeting) -> some View {
        let done = c.status == .fulfilled || c.status == .superseded
        let proof = store.sourceProof(for: c, in: meeting)
        return HStack(alignment: .center, spacing: 12) {
            Button {
                HapticEngine.notify(done ? .warning : .success)
                store.updateCommitmentStatus(done ? .open : .fulfilled, commitmentID: c.id, for: meeting.id)
            } label: {
                ZStack {
                    Circle()
                        .fill(done ? AppPalette.success : Color.clear)
                        .overlay(Circle().strokeBorder(done ? AppPalette.success : AppPalette.border, lineWidth: 1.5))
                        .frame(width: 18, height: 18)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.85))
            .accessibilityLabel(done ? "Mark open" : "Mark done")

            VStack(alignment: .leading, spacing: 3) {
                Text(c.statement)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(done ? AppPalette.secondaryInk : AppPalette.ink)
                    .strikethrough(done)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !done, let why = c.rationale?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty {
                    Text(why)
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let meta = actionMetaLine(c)
                if !meta.isEmpty { EditorialMeta(text: meta) }
                SourceProofButton(proof: proof) {
                    inspectSource(for: c.statement, proof: proof)
                }
            }
            Spacer(minLength: 8)
            if c.owner != "Owner not named" {
                EditorialAvatar(name: c.owner, size: 22)
            }
        }
        .padding(.vertical, 12)
    }

    private func actionMetaLine(_ c: Commitment) -> String {
        var parts: [String] = []
        if c.priority?.lowercased() == "high" { parts.append("High priority") }
        if c.owner != "Owner not named" { parts.append(c.owner) }
        if let due = c.dueHint { parts.append("due \(due)") }
        return parts.joined(separator: " · ")
    }

    func initial(for name: String) -> String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased() }
    func displayName(for name: String) -> String { name.components(separatedBy: " ").first ?? name }

    var overviewPrimaryAction: some View {
        Button { HapticEngine.tap(.medium); showingChat = true } label: {
            HStack(spacing: 10) { Image(systemName: "quote.bubble.fill").font(.subheadline.weight(.heavy)); Text("Ask this note anything").font(.subheadline.weight(.bold)); Spacer(minLength: 0); Image(systemName: "arrow.up.right").font(.footnote.weight(.heavy)) }
                .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity)
                .background(AppPalette.accentButton, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: AppPalette.accent.opacity(0.32), radius: 14, y: 8)
        }.buttonStyle(PressScaleButtonStyle(scale: 0.97))
    }

    // MARK: - Tasks canvas

    @ViewBuilder
    private func tasksCanvas(_ meeting: Meeting) -> some View {
        if !resolvedPurpose(for: meeting).allowsAccountabilityExtraction {
            tasksStatusStrip(open: 0, atRisk: 0, done: 0)
            personalNoteTasksEmptyState()
        } else {
            let open    = meeting.commitments.filter { $0.status == .open }
            let atRisk  = meeting.commitments.filter { $0.status == .atRisk }
            let done    = meeting.commitments.filter { $0.status == .fulfilled || $0.status == .superseded }
            let actions = meeting.commitments.isEmpty ? meetingSignals.actions : []

            tasksStatusStrip(open: open.count, atRisk: atRisk.count, done: done.count)

            if !atRisk.isEmpty {
                tasksGroup(title: "AT RISK", tint: AppPalette.coral) {
                    ForEach(atRisk) { commitmentRow($0, in: meeting) }
                }
            }

            if !open.isEmpty {
                tasksGroup(title: "OPEN", tint: AppPalette.accent) {
                    ForEach(open) { commitmentRow($0, in: meeting) }
                }
            }

            if !actions.isEmpty {
                tasksGroup(title: "EXTRACTED FOLLOW-UPS", tint: AppPalette.gold) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        actionLineRow(action, in: meeting)
                    }
                }
            }

            if !done.isEmpty {
                tasksGroup(title: "DONE", tint: AppPalette.success) {
                    ForEach(done) { commitmentRow($0, in: meeting) }
                }
            }

            if open.isEmpty && atRisk.isEmpty && done.isEmpty && actions.isEmpty {
                tasksEmptyState
            }
        }
    }

    private func tasksStatusStrip(open: Int, atRisk: Int, done: Int) -> some View {
        HStack(spacing: 0) {
            tasksStatusTile(value: open,   label: "Open",    tint: AppPalette.accent)
            tasksTileRule
            tasksStatusTile(value: atRisk, label: "At risk", tint: AppPalette.coral)
            tasksTileRule
            tasksStatusTile(value: done,   label: "Done",    tint: AppPalette.success)
        }
        .overlay(alignment: .top) { EditorialRule() }
        .overlay(alignment: .bottom) { EditorialRule() }
    }

    private var tasksTileRule: some View {
        Rectangle().fill(AppPalette.border.opacity(0.7)).frame(width: 1, height: 30)
    }

    private func tasksStatusTile(value: Int, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            EditorialEyebrow(text: label)
            Text("\(value)")
                .font(.system(size: 24, weight: .medium, design: .serif))
                .foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    private func tasksGroup<Content: View>(
        title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let nice = title.prefix(1).uppercased() + title.dropFirst().lowercased()
        return VStack(alignment: .leading, spacing: 6) {
            EditorialSectionHead(title: nice, titleSize: 18) {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            VStack(spacing: 0) {
                content()
            }
        }
    }

    private func commitmentRow(_ c: Commitment, in meeting: Meeting) -> some View {
        let icon: String
        let tint: Color
        let proof = store.sourceProof(for: c, in: meeting)
        switch c.status {
        case .open:       icon = "circle";                       tint = AppPalette.accent
        case .atRisk:     icon = "exclamationmark.triangle.fill"; tint = AppPalette.coral
        case .fulfilled:  icon = "checkmark.circle.fill";        tint = AppPalette.success
        case .superseded: icon = "arrow.uturn.left.circle";      tint = AppPalette.tertiaryInk
        }
        return HStack(alignment: .top, spacing: 12) {
            Button {
                HapticEngine.tap(.light)
                cycleStatus(c, in: meeting)
            } label: {
                Image(systemName: icon)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.86))
            .accessibilityLabel(c.status == .fulfilled ? "Mark open" : "Mark done")

            VStack(alignment: .leading, spacing: 5) {
                Text(c.statement)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.ink.opacity(0.88))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !c.owner.isEmpty {
                        metaPill(systemImage: "person.fill", text: c.owner, tint: AppPalette.accent)
                    }
                    if let due = c.dueHint, !due.isEmpty {
                        metaPill(systemImage: "calendar", text: due, tint: AppPalette.coral)
                    }
                }
                SourceProofButton(proof: proof) {
                    inspectSource(for: c.statement, proof: proof)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider()
                .background(AppPalette.divider.opacity(0.4))
                .padding(.leading, 52)
        }
    }

    private func actionLineRow(_ text: String, in meeting: Meeting) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(AppPalette.gold)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 7) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.ink.opacity(0.88))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                SourceProofButton(proof: store.sourceProof(for: text, in: meeting)) {
                    inspectSource(for: text, in: meeting)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider()
                .background(AppPalette.divider.opacity(0.4))
                .padding(.leading, 52)
        }
    }

    private func metaPill(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .heavy))
            Text(text)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }

    private func cycleStatus(_ c: Commitment, in meeting: Meeting) {
        let next: CommitmentStatus
        switch c.status {
        case .open:       next = .fulfilled
        case .atRisk:     next = .fulfilled
        case .fulfilled:  next = .open
        case .superseded: next = .open
        }
        store.updateCommitmentStatus(next, commitmentID: c.id, for: meeting.id)
        HapticEngine.notify(.success)
    }

    private var tasksEmptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(AppPalette.success.opacity(0.14)).frame(width: 56, height: 56)
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(AppPalette.success)
            }
            Text("Nothing pending")
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.ink)
            Text("This meeting has no tasks or follow-ups.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Transcript canvas

    @ViewBuilder
    private func transcriptCanvas(_ meeting: Meeting) -> some View {
        if !meeting.transcriptVisibilityEnabled {
            transcriptHiddenState(meeting)
        } else if meeting.transcript.isEmpty {
            transcriptEmptyState
        } else {
            transcriptReadinessRow(meeting)
            transcriptStatStrip(meeting)
            transcriptSearchField
            transcriptLineList(meeting)
            transcriptControlsRow(meeting)
        }
    }

    private func transcriptReadinessRow(_ meeting: Meeting) -> some View {
        let report = cachedIntelligenceReport ?? store.intelligenceReport(for: meeting)
        let voiceCount = report.speakerDetection.detectedCount
        let isProcessing = meeting.status == .processing
        let title = isProcessing ? "Draft transcript" : "Transcript ready"
        let detail: String
        if isProcessing {
            detail = "Audio saved · wording and speaker names may improve"
        } else if voiceCount > 1 {
            detail = "\(voiceCount) speakers detected · review names before sharing"
        } else if voiceCount == 1 {
            detail = resolvedPurpose(for: meeting).isPersonalCapture
                ? "Single voice detected · label can be renamed"
                : "1 speaker label detected · review if others spoke"
        } else {
            detail = "Speakers not identified · transcript remains searchable"
        }

        return HStack(spacing: 12) {
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppPalette.gold)
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: voiceCount > 0 ? "person.wave.2.fill" : "waveform")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(voiceCount > 0 ? AppPalette.accent : AppPalette.secondaryInk)
                    .frame(width: 30, height: 30)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !isProcessing, voiceCount > 0 {
                Button {
                    HapticEngine.tap(.light)
                    showingSpeakerEditor = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.accent)
                        .frame(width: 44, height: 44)
                        .background(AppPalette.accent.opacity(0.10), in: Circle())
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                .accessibilityLabel("Review speaker labels")
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { EditorialRule() }
        .overlay(alignment: .bottom) { EditorialRule() }
    }

    private func transcriptStatStrip(_ meeting: Meeting) -> some View {
        let lineCount = meeting.transcript.count
        let speakers = (cachedIntelligenceReport ?? store.intelligenceReport(for: meeting))
            .speakerDetection.detectedCount
        let words = cachedTranscriptWordCount
        return HStack(spacing: 0) {
            tasksStatusTile(value: lineCount, label: "Lines", tint: AppPalette.accent)
            tasksTileRule
            tasksStatusTile(value: speakers, label: "Voices", tint: AppPalette.gold)
            tasksTileRule
            tasksStatusTile(value: words, label: "Words", tint: AppPalette.ink)
        }
        .overlay(alignment: .top) { EditorialRule() }
        .overlay(alignment: .bottom) { EditorialRule() }
    }

    private var transcriptSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.secondaryInk)
            TextField("Search transcript", text: $transcriptSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .foregroundStyle(AppPalette.ink)
            if !transcriptSearchText.isEmpty {
                Button {
                    HapticEngine.tap(.light)
                    transcriptSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppPalette.cardBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
    }

    private func transcriptLineList(_ meeting: Meeting) -> some View {
        let lines = cachedTranscriptLines
        return Group {
            if lines.isEmpty {
                Text("No transcript lines match your search.")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.softSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                            .strokeBorder(AppPalette.border.opacity(0.4), lineWidth: 0.6)
                    )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(lines) { line in
                        transcriptLineCard(line)
                    }
                }
            }
        }
    }

    private func transcriptLineCard(_ line: TranscriptLine) -> some View {
        let speakerTint = editorialSpeakerColor(for: line.speaker)
        return HStack(alignment: .top, spacing: 12) {
            EditorialAvatar(name: line.speaker, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(line.speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(speakerTint)
                Text(line.text)
                    .font(.body)
                    .fontDesign(.serif)
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { EditorialRule() }
        .contentShape(Rectangle())
        .contextMenu {
                Button("Copy line") { UIPasteboard.general.string = line.text }
                Button("Change speaker", systemImage: "person.crop.circle.badge.checkmark") {
                    transcriptLinePendingSpeakerEdit = line
                }
                Button("Delete snippet", role: .destructive) {
                    store.deleteTranscriptLine(for: meetingID, lineID: line.id)
                }
        }
        .editorialReveal()
    }

    private func transcriptControlsRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Button {
                HapticEngine.tap(.light)
                showingSpeakerEditor = true
            } label: {
                Label("Speakers", systemImage: "person.crop.circle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(AppPalette.accent.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(AppPalette.accent.opacity(0.22), lineWidth: 0.6))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.95))

            Button {
                HapticEngine.tap(.light)
                store.setTranscriptVisibility(false, for: meeting.id)
            } label: {
                Label("Hide", systemImage: "eye.slash")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(AppPalette.softSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.6))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.95))

            Spacer(minLength: 0)
        }
    }

    private var transcriptEmptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(AppPalette.accent.opacity(0.14)).frame(width: 56, height: 56)
                Image(systemName: "waveform")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(AppPalette.accent)
            }
            Text("No transcript captured")
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.ink)
            Text("Recordings will appear here as live transcript lines.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func transcriptHiddenState(_ meeting: Meeting) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(AppPalette.tertiaryInk.opacity(0.16)).frame(width: 56, height: 56)
                Image(systemName: "lock.shield.fill")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }
            Text("Transcript hidden")
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.ink)
            Text("Reveal it only when you need supporting language.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .multilineTextAlignment(.center)
            Button {
                HapticEngine.tap(.light)
                store.setTranscriptVisibility(true, for: meeting.id)
            } label: {
                Label("Reveal transcript", systemImage: "eye.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(AppPalette.accentButton, in: Capsule())
                    .shadow(color: AppPalette.accent.opacity(0.3), radius: 10, y: 4)
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.96))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    /// Groups several nav rows under a small uppercase eyebrow. Keeps the
    /// hub scannable when there are many destinations.
    private func sectionGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorialEyebrow(text: title)
                .padding(.horizontal, 2)
            VStack(spacing: 10) {
                content()
            }
        }
    }

    private func intelligenceNavRow(_ meeting: Meeting) -> some View {
        let speakerRead = (cachedIntelligenceReport ?? store.intelligenceReport(for: meeting)).speakerDetection
        let speakers = speakerRead.detectedCount
        let actions = meetingSignals.actions.count
        let subtitle: String = {
            if speakers > 0 || actions > 0 {
                let parts: [String] = [
                    speakers > 0 ? "\(speakers) speaker label\(speakers == 1 ? "" : "s")" : nil,
                    actions > 0 ? "\(actions) action\(actions == 1 ? "" : "s")" : nil
                ].compactMap { $0 }
                return parts.joined(separator: " · ")
            } else {
                return "Confidence, speakers, and signals."
            }
        }()
        return NavigationLink(value: DetailRoute.intelligence) {
            detailNavRow(
                icon: "sparkles",
                tint: AppPalette.accent,
                title: "Intelligence",
                subtitle: subtitle,
                trailingDigits: nil,
                trailingLabel: nil
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    private func scoreNavRow(_ meeting: Meeting) -> some View {
        let subtitle: String
        let trailingDigits: String?
        let trailingLabel: String?
        if resolvedPurpose(for: meeting).allowsAccountabilityExtraction, let score = meeting.score {
            subtitle = score.insight.isEmpty
                ? "Decisiveness \(score.decisiveness) · Action \(score.actionability)"
                : score.insight
            trailingDigits = "\(score.overall)"
            trailingLabel = "score"
        } else {
            subtitle = "Read quality and completeness."
            trailingDigits = nil
            trailingLabel = nil
        }
        return NavigationLink(value: DetailRoute.score) {
            detailNavRow(
                icon: "chart.bar.fill",
                tint: AppPalette.accentDeep,
                title: "Meeting score",
                subtitle: subtitle,
                trailingDigits: trailingDigits,
                trailingLabel: trailingLabel
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    private func prepNavRow(_ meeting: Meeting) -> some View {
        let bullets = cachedPrepBrief.bullets.count
        let preview = cachedPrepBrief.headline.isEmpty
            ? "Open questions and next-meeting prep."
            : cachedPrepBrief.headline
        return NavigationLink(value: DetailRoute.prep) {
            detailNavRow(
                icon: "doc.text.magnifyingglass",
                tint: AppPalette.gold,
                title: "Prep for next",
                subtitle: preview,
                trailingDigits: bullets > 0 ? "\(bullets)" : nil,
                trailingLabel: bullets == 1 ? "note" : "notes"
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    /// Wraps a card function in a properly titled ScrollView for the pushed
    /// detail screen. Lookup is via the meeting ID so the destination stays
    /// valid even if the meeting struct churns.
    @ViewBuilder
    private func detailDestination(_ route: DetailRoute) -> some View {
        if let m = store.meeting(withID: meetingID) {
            ScrollView {
                Group {
                    switch route {
                    case .transcript:    transcriptCard(m)
                    case .notes:         notesCard(m)
                    case .commitments:   commitmentsCard(m)
                    case .action:        actionCard(m)
                    case .signalBoard:   signalBoardCard(m)
                    case .recordings:    recordingsCard(m)
                    case .intelligence:  intelligenceCard(m)
                    case .score:
                        MeetingScoreCard(
                            meeting: m,
                            allowsAccountability: resolvedPurpose(for: m).allowsAccountabilityExtraction
                        )
                    case .prep:          prepCard(m)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyView()
        }
    }

    /// Generic hub-row: icon disc + title + one-line preview + count badge +
    /// chevron. Used to replace heavy inline cards with a navigation link.
    private func detailNavRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        trailingDigits: String?,
        trailingLabel: String?
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.08))
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let digits = trailingDigits, let label = trailingLabel {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(digits)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tint)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppPalette.border)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.30), lineWidth: 0.5)
        )
        .appShadow(AppShadow.hairline)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            trailingDigits != nil && trailingLabel != nil
                ? "\(title), \(subtitle), \(trailingDigits ?? "") \(trailingLabel ?? "")"
                : "\(title), \(subtitle)"
        )
    }

    private func shareCustomizeSheet(_ meeting: Meeting) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overviewCard(meeting)
                    shareSafelyCard(meeting)
                    prepCard(meeting)
                }
                .appScreenContent(top: AppSpacing.md)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Customize share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingShareCustomize = false }
                        .foregroundStyle(AppPalette.accent)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(AppRadius.xl)
    }

    private func meetingDetailHero(_ meeting: Meeting) -> some View {
        let words = cachedTranscriptWordCount
        return VStack(alignment: .leading, spacing: 12) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        EditorialEyebrow(text: "\(meeting.workspace) · \(meeting.when.formatted(.dateTime.month(.abbreviated).day()))")
                        purposeMenu(meeting)
                    }
                } else {
                    HStack(alignment: .top) {
                        EditorialEyebrow(text: "\(meeting.workspace) · \(meeting.when.formatted(.dateTime.month(.abbreviated).day()))")
                        Spacer(minLength: 8)
                        purposeMenu(meeting)
                    }
                }
            }

            Text(meeting.title)
                .font(AppFont.serif(.largeTitle, weight: .medium))
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        meetingHeroMetadata(meeting, words: words)
                    }
                } else {
                    HStack(spacing: 12) {
                        meetingHeroMetadata(meeting, words: words)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func meetingHeroMetadata(_ meeting: Meeting, words: Int) -> some View {
        if !meeting.attendees.isEmpty {
            EditorialAvatarStack(names: meeting.attendees, size: 22, max: 4, borderColor: AppPalette.cardBackground)
        }
        EditorialMeta(text: meetingMetaLine(meeting, words: words))
        if resolvedPurpose(for: meeting).allowsMeetingSignals {
            Button {
                showingContextPicker = true
            } label: {
                Label(meeting.contextMode.title, systemImage: meeting.contextMode.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Meeting mode, \(meeting.contextMode.title)")
        }
    }

    private func purposeMenu(_ meeting: Meeting) -> some View {
        let purpose = resolvedPurpose(for: meeting)
        return Menu {
            Button {
                store.updatePurposeOverride(nil, for: meeting.id)
            } label: {
                Label("Automatic", systemImage: meeting.purposeOverride == nil ? "checkmark" : "wand.and.stars")
            }
            Divider()
            ForEach(CapturePurposeKind.allCases, id: \.self) { purpose in
                Button {
                    store.updatePurposeOverride(purpose, for: meeting.id)
                } label: {
                    Label(purpose.title, systemImage: meeting.purposeOverride == purpose ? "checkmark" : purpose.systemImage)
                }
            }
        } label: {
            Label(purpose.displayTitle, systemImage: purpose.kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(AppPalette.accent.opacity(0.08), in: Capsule())
        }
        .accessibilityLabel("Capture purpose: \(purpose.displayTitle)")
    }

    private func meetingMetaLine(_ meeting: Meeting, words: Int) -> String {
        var parts: [String] = []
        let detectedVoices = cachedIntelligenceReport?.speakerDetection.detectedCount ?? 0
        if meeting.durationMinutes > 0 { parts.append("\(meeting.durationMinutes)m") }
        if detectedVoices > 0 {
            parts.append("\(detectedVoices) voice\(detectedVoices == 1 ? "" : "s")")
        } else if !meeting.attendees.isEmpty {
            parts.append("\(meeting.attendees.count) participant\(meeting.attendees.count == 1 ? "" : "s")")
        }
        if words > 0 { parts.append("\(words) words") }
        return parts.joined(separator: " · ")
    }

    private func overviewCard(_ meeting: Meeting) -> some View {
        SurfaceCard(title: "Meeting", subtitle: meeting.title) {
            VStack(alignment: .leading, spacing: 16) {
                Text(meeting.objective)
                    .font(.body)
                    .foregroundStyle(AppPalette.secondaryInk)

                HStack(spacing: 10) {
                    StatusBadge(status: meeting.status)

                    Text(meeting.stage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(AppPalette.softSurface, in: Capsule())
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        MetaPill(systemImage: "briefcase", text: meeting.workspace)
                        MetaPill(systemImage: "calendar", text: meeting.when.formatted(date: .abbreviated, time: .shortened))
                        MetaPill(systemImage: "clock", text: "\(meeting.durationMinutes) min")
                        MetaPill(systemImage: "lock.shield", text: meeting.meetingMode.title)
                        MetaPill(systemImage: "checkmark.shield", text: meeting.consentState.title)
                        MetaPill(systemImage: "archivebox", text: meeting.retentionPolicy.title)
                    }
                }

                Button {
                    withAnimation(AppMotion.snappy) {
                        trustControlsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppPalette.accent)
                        Text("Privacy settings")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                        Spacer()
                        Text(meeting.meetingMode.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppPalette.accent.opacity(0.10), in: Capsule())
                        Image(systemName: trustControlsExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AppPalette.cardBackground.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                if trustControlsExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        trustControlRow(
                            title: "Meeting mode",
                            selection: Binding(
                                get: { meeting.meetingMode },
                                set: { store.updateMeetingMode($0, for: meeting.id) }
                            ),
                            label: \.title
                        )

                        trustControlRow(
                            title: "Consent",
                            selection: Binding(
                                get: { meeting.consentState },
                                set: { store.updateConsentState($0, for: meeting.id) }
                            ),
                            label: \.title
                        )

                        trustControlRow(
                            title: "Retention",
                            selection: Binding(
                                get: { meeting.retentionPolicy },
                                set: { store.updateRetentionPolicy($0, for: meeting.id) }
                            ),
                            label: \.title
                        )

                        Text(meeting.retentionPolicy.detail)
                            .font(.caption)
                            .foregroundStyle(AppPalette.tertiaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !meeting.attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("People")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.secondaryInk)

                        Text(meeting.attendees.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.ink)
                    }
                }

                let tags = store.tags(for: meeting)
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AppPalette.ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(AppPalette.softSurface, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private func trustControlRow<Value: Hashable & CaseIterable & Identifiable>(
        title: String,
        selection: Binding<Value>,
        label: KeyPath<Value, String>
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryInk)

            Spacer(minLength: 0)

            Picker(title, selection: selection) {
                ForEach(Array(Value.allCases), id: \.id) { value in
                    Text(value[keyPath: label]).tag(value)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppPalette.cardBackground.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func signalBoardCard(_ meeting: Meeting) -> some View {
        let clarifications = meeting.aiBrief?.needsClarification ?? []
        let questions = (meetingSignals.questions + clarifications).reduce(into: [String]()) { result, item in
            if !result.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
                result.append(item)
            }
        }
        let hasSignals = !meetingSignals.decisions.isEmpty || !meetingSignals.risks.isEmpty || !questions.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DIGEST")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryInk)
                Text(meeting.objective.isEmpty ? meeting.title : meeting.objective)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            if !hasSignals {
                Text(resolvedPurpose(for: meeting).allowsAccountabilityExtraction
                     ? "Add more detail to your notes and Scribeflow will pull out decisions, risks, and open questions here."
                     : "This is saved as a personal note, so Scribeflow keeps it as searchable notes instead of turning it into tasks or risks.")
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            } else {
                VStack(spacing: 0) {
                    if !meetingSignals.decisions.isEmpty {
                        signalSection(
                            title: "Decisions",
                            systemImage: "checkmark.circle.fill",
                            items: meetingSignals.decisions,
                            tint: AppPalette.accent,
                            meeting: meeting
                        )
                    }
                    if !meetingSignals.risks.isEmpty {
                        if !meetingSignals.decisions.isEmpty { Divider().padding(.horizontal, 20) }
                        signalSection(
                            title: "Risks",
                            systemImage: "exclamationmark.triangle.fill",
                            items: meetingSignals.risks,
                            tint: AppPalette.coral,
                            meeting: meeting
                        )
                    }
                    if !questions.isEmpty {
                        if !meetingSignals.decisions.isEmpty || !meetingSignals.risks.isEmpty {
                            Divider().padding(.horizontal, 20)
                        }
                        signalSection(
                            title: "Open questions",
                            systemImage: "questionmark.circle.fill",
                            items: questions,
                            tint: AppPalette.gold,
                            meeting: meeting
                        )
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.7))
                .allowsHitTesting(false)
        )
        .shadow(color: AppPalette.shadow.opacity(0.07), radius: 8, y: 4)
    }

    private func intelligenceCard(_ meeting: Meeting) -> some View {
        let report = cachedIntelligenceReport ?? store.intelligenceReport(for: meeting)
        let purpose = resolvedPurpose(for: meeting)
        let allowsAccountability = purpose.allowsAccountabilityExtraction

        return SurfaceCard(
            title: purpose.kind.intelligenceTitle,
            subtitle: report.headline
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    IntelligencePill(title: "Read", value: report.confidenceLabel, tint: AppPalette.accent)
                    IntelligencePill(title: "Voices", value: "\(report.speakerDetection.detectedCount)", tint: AppPalette.gold)
                    if allowsAccountability {
                        IntelligencePill(title: "Actions", value: "\(report.actionItems.count)", tint: AppPalette.coral)
                    }
                }

                intelligenceSection("Smart summary", icon: "sparkles", items: report.suggestedSummary, tint: AppPalette.accent, meeting: meeting)
                if allowsAccountability {
                    if report.structuredActionItems.isEmpty {
                        intelligenceSection("Action items", icon: "arrow.forward.circle.fill", items: report.actionItems, tint: AppPalette.gold, meeting: meeting)
                    } else {
                        structuredActionSection(report.structuredActionItems, meeting: meeting)
                    }
                }
                if allowsAccountability {
                    intelligenceSection("Decisions", icon: "checkmark.circle.fill", items: report.decisions, tint: AppPalette.accent, meeting: meeting)
                }
                intelligenceSection("Open questions", icon: "questionmark.circle.fill", items: report.openQuestions, tint: AppPalette.coral, meeting: meeting)
                if let sections = meeting.aiBrief?.sections {
                    ForEach(Array(sections.prefix(4).enumerated()), id: \.offset) { _, section in
                        intelligenceSection(section.heading, icon: "scope", items: section.items, tint: AppPalette.accent, meeting: meeting)
                    }
                }
                if let clarifications = meeting.aiBrief?.needsClarification {
                    intelligenceSection("Needs clarification", icon: "exclamationmark.bubble.fill", items: clarifications, tint: AppPalette.gold, meeting: meeting)
                }
                if allowsAccountability {
                    intelligenceSection("Suggested follow-up", icon: "paperplane.fill", items: report.followUps, tint: AppPalette.ink, meeting: meeting)
                }

                if !report.speakerSegments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Speaker read", systemImage: "person.wave.2.fill")
                            Spacer(minLength: 8)
                            Text(report.speakerDetection.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppPalette.secondaryInk)
                            Button {
                                showingSpeakerEditor = true
                            } label: {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Review speaker labels")
                        }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.accent)

                        ForEach(report.speakerSegments.prefix(4)) { segment in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(AppPalette.accent.opacity(0.14))
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Text(String(segment.speaker.prefix(1)))
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(AppPalette.accent)
                                    )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(segment.speaker)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppPalette.ink)
                                    Text("\(segment.lineCount) turn\(segment.lineCount == 1 ? "" : "s") · \(Int((segment.talkShare * 100).rounded()))% of transcript")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AppPalette.secondaryInk)
                                    if !segment.sample.isEmpty {
                                        Text(segment.sample)
                                            .font(.caption)
                                            .foregroundStyle(AppPalette.secondaryInk)
                                            .lineLimit(2)
                                    }
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label(report.mode.title, systemImage: "cpu")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                    Text(report.mode.detail)
                    Text(report.speakerDetectionNote)
                }
                .font(.footnote)
                .foregroundStyle(AppPalette.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }


    @ViewBuilder
    private func intelligenceSection(_ title: String, icon: String, items: [String], tint: Color, meeting: Meeting) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)

                ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(item, systemImage: "circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.secondaryInk)
                            .labelStyle(BulletLabelStyle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SourceProofButton(proof: store.sourceProof(for: item, in: meeting)) {
                            inspectSource(for: item, in: meeting)
                        }
                    }
                }
            }
            .padding(14)
            .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func structuredActionSection(_ items: [ExtractedActionItem], meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Action items", systemImage: "arrow.forward.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.gold)

            ForEach(items.prefix(4)) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.secondaryInk)
                    HStack(spacing: 8) {
                        Text(item.owner)
                        if let dueHint = item.dueHint {
                            Text(dueHint)
                        }
                        Text(item.sourceSpeaker)
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.gold)
                    SourceProofButton(proof: store.sourceProof(for: item.text, in: meeting)) {
                        inspectSource(for: item.text, in: meeting)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }
        }
        .padding(14)
        .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func signalSection(title: String, systemImage: String, items: [String], tint: Color, meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 14) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(tint)
                            .frame(width: 2)
                            .frame(minHeight: 20)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item)
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            SourceProofButton(proof: store.sourceProof(for: item, in: meeting)) {
                                inspectSource(for: item, in: meeting)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func shareSafelyCard(_ meeting: Meeting) -> some View {
        SurfaceCard(title: "Share safely", subtitle: "Rewrite notes and share a clean, trust-reviewed version.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(isRewriting ? "Rewriting..." : "Rewrite notes") {
                        rewrite(meeting.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.accent)
                    .disabled(isRewriting)

                    Button("Share safely") {
                        share(meeting.id, format: exportFormat)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.ink)
                }

                if let rewriteMessage {
                    Text(rewriteMessage)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                }

                Button {
                    withAnimation(AppMotion.snappy) {
                        shareOptionsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                        Text("Share options")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                        Spacer()
                        Text(exportFormatTitle(exportFormat, for: meeting))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppPalette.accent.opacity(0.10), in: Capsule())
                        Image(systemName: shareOptionsExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AppPalette.cardBackground.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                if shareOptionsExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Rewrite style", selection: Binding(
                            get: { preferredRewriteStyle },
                            set: { preferredRewriteStyle = $0 }
                        )) {
                            ForEach(NoteRewriteStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(preferredRewriteStyle.helperText)
                            .font(.footnote)
                            .foregroundStyle(AppPalette.secondaryInk)

                        Picker("Share format", selection: $exportFormat) {
                            ForEach(availableExportFormats(for: meeting)) { format in
                                Text(exportFormatTitle(format, for: meeting)).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Include inferred bullets", isOn: $includeInferredInShare)
                            Toggle("Include private-note context", isOn: $includePrivateNotesInShare)
                            Toggle("Include transcript snippets", isOn: $includeTranscriptInShare)
                                .disabled(meeting.transcript.isEmpty)
                        }
                        .font(.subheadline)

                        let flags = store.shareReviewFlags(
                            for: meeting.id,
                            includeInferred: includeInferredInShare,
                            includePrivateNotes: includePrivateNotesInShare,
                            includeTranscript: includeTranscriptInShare
                        )
                        if !flags.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Review flags")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppPalette.secondaryInk)

                                ForEach(flags, id: \.self) { flag in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "exclamationmark.shield")
                                            .foregroundStyle(AppPalette.gold)
                                        Text(flag)
                                            .font(.subheadline)
                                            .foregroundStyle(AppPalette.ink)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(12)
                                    .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                            }
                        }

                        if let preview = store.safeSharePreview(
                            for: meeting.id,
                            format: exportFormat,
                            includeInferred: includeInferredInShare,
                            includePrivateNotes: includePrivateNotesInShare,
                            includeTranscript: includeTranscriptInShare
                        ) {
                            Text(preview)
                                .font(.footnote)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .lineLimit(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                        }

                        HStack(spacing: 10) {
                            Button("Copy preview") {
                                copyExport(meeting.id)
                            }
                            .buttonStyle(.bordered)
                            .tint(AppPalette.ink)

                            Button("Delete source media") {
                                store.purgeTranscript(for: meeting.id)
                            }
                            .buttonStyle(.bordered)
                            .tint(AppPalette.coral)
                            .disabled(meeting.transcript.isEmpty && meeting.audioRecordings.isEmpty)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func recordingsCard(_ meeting: Meeting) -> some View {
        SurfaceCard(title: "Recordings", subtitle: meeting.audioRecordings.isEmpty ? "Attach audio to keep context with the note." : "Original audio, transcript, and notes in one place.") {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    showingAttachRecorder = true
                } label: {
                    Label("Attach voice note", systemImage: "mic.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))

                if meeting.audioRecordings.isEmpty {
                    EmptyStateCard(
                        title: "No audio yet",
                        subtitle: "Record a voice note right here, or start one from Today."
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(meeting.audioRecordings) { recording in
                            recordingRow(recording, meeting: meeting)
                        }
                    }
                }
            }
        }
    }

    private func recordingRow(_ recording: AudioRecordingAttachment, meeting: Meeting) -> some View {
        let audioURL = store.audioURL(for: recording)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppPalette.accent.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: recording.source.systemImage)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("\(recording.source.title) · \(recording.durationLabel) · \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryInk)
                    if let provider = recording.transcriptionProvider {
                        let voices = recording.detectedSpeakerCount
                        Label(
                            recording.diarizationAvailable
                                ? "\(provider.title) · \(voices) speaker\(voices == 1 ? "" : "s") separated"
                                : "\(provider.title) · speaker separation unavailable",
                            systemImage: recording.diarizationAvailable ? "person.wave.2.fill" : "waveform"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(recording.diarizationAvailable ? AppPalette.accent : AppPalette.tertiaryInk)
                    }
                    if recordingTranscriptionIDs.contains(recording.id) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Rebuilding transcript")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(AppPalette.accent)
                    }
                }

                Spacer()

                Menu {
                    Button("Rename") {
                        recordingRenameText = recording.title
                        recordingPendingRename = recording
                    }
                    Menu {
                        Button {
                            requestRecordingTranscription(
                                recording,
                                meeting: meeting,
                                expectedSpeakerCount: nil
                            )
                        } label: {
                            Label("Detect speakers", systemImage: "person.wave.2")
                        }

                        ForEach(1...6, id: \.self) { count in
                            Button {
                                requestRecordingTranscription(
                                    recording,
                                    meeting: meeting,
                                    expectedSpeakerCount: count
                                )
                            } label: {
                                Label(
                                    "\(count) voice\(count == 1 ? "" : "s")",
                                    systemImage: "person.wave.2"
                                )
                            }
                        }
                    } label: {
                        Label(
                            recording.hasTranscript ? "Improve transcript" : "Create transcript",
                            systemImage: "waveform.badge.magnifyingglass"
                        )
                    }
                    .disabled(recordingTranscriptionIDs.contains(recording.id))
                    ShareLink("Share audio", item: audioURL)
                    if !recording.transcript.isEmpty {
                        ShareLink("Share transcript", item: recording.transcript)
                    }
                    Button("Delete", role: .destructive) {
                        recordingPendingDelete = recording
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(AppPalette.secondaryInk)
                }
                .accessibilityLabel("Recording options")
            }

            AudioPlaybackControls(url: audioURL, durationSeconds: recording.durationSeconds)

            if !recording.linkedNote.isEmpty {
                Text(recording.linkedNote)
                    .font(.footnote)
                    .foregroundStyle(AppPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppPalette.cardBackground.opacity(0.90), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if !recording.transcript.isEmpty {
                DisclosureGroup {
                    Text(recording.transcript)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } label: {
                    Label("Transcript", systemImage: "quote.bubble.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppPalette.accent)
                }
            }
        }
        .padding(14)
        .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppPalette.border.opacity(0.45)))
    }

    private func requestRecordingTranscription(
        _ recording: AudioRecordingAttachment,
        meeting: Meeting,
        expectedSpeakerCount: Int?
    ) {
        guard recordingTranscriptionIDs.insert(recording.id).inserted else { return }
        HapticEngine.tap(.light)

        Task { @MainActor in
            let outcome = await TranscriptionRecoveryCoordinator.shared.requestRetranscription(
                recording: recording,
                meetingID: meeting.id,
                expectedSpeakerCount: expectedSpeakerCount,
                using: store
            )
            recordingTranscriptionIDs.remove(recording.id)

            let toast: ToastItem
            switch outcome {
            case .completed:
                let voices = store.meeting(withID: meeting.id)?.audioRecordings.first {
                    $0.id == recording.id
                }?.detectedSpeakerCount ?? 0
                toast = ToastItem(
                    message: voices > 1
                        ? "Transcript rebuilt · \(voices) speakers separated"
                        : "Transcript rebuilt",
                    icon: "checkmark.seal.fill"
                )
            case .queued:
                toast = ToastItem(
                    message: "Transcript queued · you can leave this screen",
                    icon: "clock.arrow.circlepath"
                )
            case .failed:
                toast = ToastItem(
                    message: "Transcript needs another try · original audio is safe",
                    icon: "exclamationmark.triangle.fill"
                )
            }
            NotificationCenter.default.post(name: .scribeflowToast, object: toast)
        }
    }

    private func notesCard(_ meeting: Meeting) -> some View {
        let visibleEvidence = store.evidenceItems(for: meeting, filter: evidenceFilter)

        return SurfaceCard(title: "Evidence-backed notes", subtitle: "Saved notes now show what is verified, inferred, or still personal.") {
            VStack(alignment: .leading, spacing: 12) {
                if let rewriteMessage {
                    Text(rewriteMessage)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                } else {
                    Text("These notes are processed automatically on save, and you can run Apple Intelligence again any time.")
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                }

                Picker("Evidence filter", selection: $evidenceFilter) {
                    ForEach(EvidenceFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if visibleEvidence.isEmpty {
                    Text("No evidence bullets are ready yet. Rewrite the note or add a little more detail and Scribeflow will structure them here.")
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        ForEach(visibleEvidence) { item in
                            let proof = store.sourceProof(for: item, in: meeting)
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 10) {
                                    if item.supportingSnippets.isEmpty {
                                        Text("No transcript proof was saved for this point.")
                                            .font(.footnote)
                                            .foregroundStyle(AppPalette.secondaryInk)
                                    } else {
                                        ForEach(Array(item.supportingSnippets.enumerated()), id: \.offset) { _, snippet in
                                            Text(snippet)
                                                .font(.footnote)
                                                .foregroundStyle(AppPalette.secondaryInk)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(12)
                                                .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        }
                                    }

                                    SourceProofButton(proof: proof) {
                                        inspectSource(for: item.text, proof: proof)
                                    }

                                    Button("Remove point", role: .destructive) {
                                        store.deleteEvidenceItem(for: meeting.id, evidenceID: item.id)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(AppPalette.coral)
                                }
                                .padding(.top, 8)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    evidenceBadge(for: item.level)

                                    Text(item.text)
                                        .font(.subheadline)
                                        .foregroundStyle(AppPalette.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(item.confidenceLabel)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppPalette.accent)
                                }
                            }
                            .padding(14)
                            .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                        }
                    }
                }

                MeetingNotesEditor(
                    meetingID: meeting.id,
                    persistedNotes: meeting.rawNotes
                )

                if meeting.hasRecoverableOriginalNotes {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(meeting.originalCaptureNotes)
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 10) {
                                Button {
                                    UIPasteboard.general.string = meeting.originalCaptureNotes
                                } label: {
                                    Label("Copy original", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    store.restoreOriginalNotes(for: meeting.id)
                                } label: {
                                    Label("Restore as note", systemImage: "arrow.uturn.backward")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppPalette.accent)
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        Label("Original capture", systemImage: "quote.opening")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.ink)
                    }
                    .tint(AppPalette.secondaryInk)
                    .padding(14)
                    .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHint("Shows the first saved version of this capture")
                }

                // Messy → clean → share, in one place.
                if !meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 10) {
                        enhancePill(
                            icon: "wand.and.stars",
                            title: showEnhanced ? "Hide smart notes" : "Enhance notes",
                            filled: !showEnhanced
                        ) {
                            HapticEngine.tap(.medium)
                            withAnimation(AppMotion.smooth) { showEnhanced.toggle() }
                        }
                        enhancePill(icon: "square.and.arrow.up", title: "Share recap", filled: false) {
                            quickShareDigest(meeting)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)

                    if showEnhanced {
                        SmartNotesPreview(
                            notes: meeting.rawNotes,
                            transcriptTail: Array(meeting.transcript.map(\.text).suffix(12)),
                            attendees: meeting.attendees
                        )
                        .equatable()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    private func enhancePill(icon: String, title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.bold))
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(filled ? .white : AppPalette.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                filled ? AnyShapeStyle(AppPalette.accentButton) : AnyShapeStyle(AppPalette.accentSoft),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(AppPalette.accent.opacity(filled ? 0 : 0.25), lineWidth: 0.8))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.96))
    }

    private func addToReminders(_ commitment: Commitment, meeting: Meeting) {
        Task {
            let due = DueDateParser.date(from: commitment.dueHint, capturedAt: meeting.when)
            var notes = "From “\(meeting.title)” · Scribeflow"
            if commitment.owner != "Owner not named" {
                notes = "Owner: \(commitment.owner)\n" + notes
            }
            switch await RemindersExporter.add(title: commitment.statement, due: due, notes: notes) {
            case .success: HapticEngine.notify(.success)
            case .failure: HapticEngine.notify(.warning)
            }
        }
    }

    private func commitMetaChip(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(text).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
    }

    @ViewBuilder
    private func commitDueChip(_ c: Commitment, capturedAt: Date) -> some View {
        let due = c.dueDateOverride ?? DueDateParser.date(from: c.dueHint, capturedAt: capturedAt)
        let isLive = c.status == .open || c.status == .atRisk
        if isLive, let due, due < Date() {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark.fill").font(.caption2.weight(.bold))
                Text("Overdue").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppPalette.coral, in: Capsule())
        } else if let override = c.dueDateOverride {
            commitMetaChip(
                override.formatted(.dateTime.month(.abbreviated).day()),
                icon: "clock.fill",
                tint: AppPalette.gold
            )
        } else if let hint = c.dueHint, !hint.isEmpty {
            commitMetaChip(hint.capitalized, icon: "clock.fill", tint: AppPalette.gold)
        }
    }

    private func commitmentsCard(_ meeting: Meeting) -> some View {
        let allowsAccountability = resolvedPurpose(for: meeting).allowsAccountabilityExtraction
        return SurfaceCard(
            title: allowsAccountability ? "Commitments" : "Personal note",
            subtitle: allowsAccountability
                ? "Track promises, owners, timing, and anything that still needs attention."
                : "Personal captures stay as notes unless you move them into a meeting context."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !allowsAccountability {
                    personalNoteAccountabilityMessage()
                } else if meeting.commitments.isEmpty {
                    Text("No commitments were extracted yet. Once the note contains clear promises or next steps, Scribeflow will track them here.")
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                } else {
                    ForEach(meeting.commitments) { commitment in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                commitmentBadge(commitment.status)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(commitment.statement)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppPalette.ink)

                                    HStack(spacing: 8) {
                                        commitMetaChip(
                                            commitment.owner == "Owner not named" ? "Unassigned" : commitment.owner,
                                            icon: commitment.owner == "You" ? "person.fill" : "person",
                                            tint: commitment.owner == "You" ? AppPalette.accent : AppPalette.secondaryInk
                                        )
                                        commitDueChip(commitment, capturedAt: meeting.when)
                                        if !commitment.sourceSpeaker.isEmpty, commitment.sourceSpeaker != "Meeting" {
                                            commitMetaChip(
                                                commitment.sourceSpeaker == "AI" ? "AI inferred" : commitment.sourceSpeaker,
                                                icon: "quote.bubble.fill",
                                                tint: commitment.sourceSpeaker == "AI" ? AppPalette.gold : AppPalette.accent
                                            )
                                        }
                                    }
                                }

                                Spacer(minLength: 0)
                            }

                            HStack(spacing: 8) {
                                ForEach([CommitmentStatus.open, .atRisk, .fulfilled]) { status in
                                    Button(status.title) {
                                        store.updateCommitmentStatus(status, commitmentID: commitment.id, for: meeting.id)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(commitment.status == status ? AppPalette.accent : AppPalette.ink)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    addToReminders(commitment, meeting: meeting)
                                } label: {
                                    Image(systemName: "list.bullet.rectangle")
                                }
                                .buttonStyle(.bordered)
                                .tint(AppPalette.secondaryInk)
                                .accessibilityLabel("Add to Reminders")
                            }
                        }
                        .padding(14)
                        .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                    }
                }
            }
        }
    }

    private func prepCard(_ meeting: Meeting) -> some View {
        SurfaceCard(title: "Prep for next meeting", subtitle: "A calm handoff from this note into the next conversation.") {
            VStack(alignment: .leading, spacing: 14) {
                Text(prepBrief.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)

                if !prepBrief.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Carry forward")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.secondaryInk)

                        ForEach(Array(prepBrief.bullets.enumerated()), id: \.offset) { _, bullet in
                            Label(bullet, systemImage: "circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .labelStyle(BulletLabelStyle())
                        }
                    }
                    .padding(16)
                    .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                if !prepBrief.questions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Make sure you ask")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.secondaryInk)

                        ForEach(Array(prepBrief.questions.enumerated()), id: \.offset) { _, question in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "arrow.turn.down.right")
                                    .foregroundStyle(AppPalette.accent)
                                Text(question)
                                    .font(.subheadline)
                                    .foregroundStyle(AppPalette.ink)
                            }
                        }
                    }
                }
            }
        }
    }

    private func actionCard(_ meeting: Meeting) -> some View {
        SurfaceCard(title: "AI actions", subtitle: "Use one tap prompts for the follow-up you actually need.") {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(meeting.prompts.prefix(5))) { prompt in
                            Button {
                                runPrompt(prompt.prompt, meetingID: meeting.id)
                            } label: {
                                Text(prompt.prompt)
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        promptTitle == prompt.prompt ? AppPalette.accent.opacity(0.18) : AppPalette.cardBackground.opacity(0.90),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppPalette.ink)
                            .disabled(isGeneratingPrompt)
                        }
                    }
                }

                if isGeneratingPrompt {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(promptTitle.isEmpty ? "Working…" : promptTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                        SkeletonBlock(lines: 3, height: 12, lastLineFraction: 0.50)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.softSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if let promptResponse {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(promptTitle)
                                .font(.headline)
                                .foregroundStyle(AppPalette.ink)
                            Spacer()
                        }

                        Text(promptResponse)
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !promptCitations.isEmpty {
                            MeetingAnswerSources(citations: promptCitations)
                        }

                        HStack(spacing: 10) {
                            Button("Copy") {
                                UIPasteboard.general.string = promptResponse
                            }
                            .buttonStyle(.bordered)
                            .tint(AppPalette.ink)

                            Button("Share result") {
                                shareText = promptResponse
                                showingShareSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppPalette.accent)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    Text("Draft a follow-up, extract next steps, write a Slack update, or turn the meeting into a cleaner decision note.")
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                }
            }
        }
    }

    private func transcriptCard(_ meeting: Meeting) -> some View {
        let filteredTranscript = cachedTranscriptLines

        return SurfaceCard(title: "Transcript", subtitle: "Recent meeting language that shaped the saved note.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(meeting.transcriptVisibilityEnabled ? "Hide transcript" : "Reveal transcript") {
                        store.setTranscriptVisibility(!meeting.transcriptVisibilityEnabled, for: meeting.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.ink)

                    Button("Speakers") {
                        showingSpeakerEditor = true
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.accent)
                    .disabled(meeting.transcript.isEmpty)

                    Button("Delete source media") {
                        store.purgeTranscript(for: meeting.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.coral)
                    .disabled(meeting.transcript.isEmpty && meeting.audioRecordings.isEmpty)
                }

                if !meeting.transcriptVisibilityEnabled {
                    Text("Transcript is hidden for privacy right now. Reveal it only when you need supporting language, or purge it entirely and keep the enhanced note.")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(AppPalette.cardBackground.opacity(0.90), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(AppPalette.secondaryInk)

                        TextField("Search transcript", text: $transcriptSearchText)
                            .textFieldStyle(.plain)

                        if !transcriptSearchText.isEmpty {
                            Button {
                                transcriptSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AppPalette.secondaryInk)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AppPalette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if meeting.transcript.isEmpty {
                        if hasImportedAudioWithoutTranscript(meeting) {
                            importedAudioTranscriptPlaceholder
                        } else {
                            Text("No transcript was captured for this meeting.")
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(AppPalette.cardBackground.opacity(0.90), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                        }
                    } else if filteredTranscript.isEmpty {
                        Text("No transcript lines match your search yet.")
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(AppPalette.cardBackground.opacity(0.90), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredTranscript) { line in
                                HStack(alignment: .top, spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(AppPalette.accent.opacity(0.14))
                                        Circle()
                                            .strokeBorder(AppPalette.accent.opacity(0.22), lineWidth: 0.8)
                                        Text(String(line.speaker.prefix(1)).uppercased())
                                            .font(.headline.weight(.bold))
                                            .foregroundStyle(AppPalette.accent)
                                    }
                                    .frame(width: 38, height: 38)

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(line.speaker)
                                            .font(.footnote.weight(.heavy))
                                            .foregroundStyle(AppPalette.ink)

                                        Text(line.text)
                                            .font(.body)
                                            .foregroundStyle(AppPalette.ink.opacity(0.85))
                                            .lineSpacing(3)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(16)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                                        .fill(AppPalette.cardBackground)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                                        .strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5)
                                )
                                .appShadow(AppShadow.hairline)
                                .contextMenu {
                                    Button("Copy line") {
                                        UIPasteboard.general.string = line.text
                                    }
                                    Button("Delete snippet", role: .destructive) {
                                        store.deleteTranscriptLine(for: meeting.id, lineID: line.id)
                                    }
                                }
                            }
                        }

                        Text("Tip: long-press any transcript snippet to copy or delete it before sharing.")
                            .font(.footnote)
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                }
            }
        }
    }

    private func inspectSource(for text: String, in meeting: Meeting) {
        inspectSource(for: text, proof: store.sourceProof(for: text, in: meeting))
    }

    private func inspectSource(for text: String, proof: SourceProof) {
        HapticEngine.tap(.light)
        selectedSourceProof = SourceProofSelection(claim: text, proof: proof)
    }


    private func evidenceBadge(for level: EvidenceLevel) -> some View {
        Text(level.title)
            .font(.caption.weight(.bold))
            .foregroundStyle(evidenceColor(for: level))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(evidenceColor(for: level).opacity(0.12), in: Capsule())
    }

    private func commitmentBadge(_ status: CommitmentStatus) -> some View {
        Text(status.title)
            .font(.caption.weight(.bold))
            .foregroundStyle(commitmentColor(for: status))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(commitmentColor(for: status).opacity(0.12), in: Capsule())
    }

    private func evidenceColor(for level: EvidenceLevel) -> Color {
        switch level {
        case .verified:
            return AppPalette.accent
        case .inferred:
            return AppPalette.gold
        case .personalNote:
            return AppPalette.secondaryInk
        }
    }

    private func commitmentColor(for status: CommitmentStatus) -> Color {
        switch status {
        case .open:
            return AppPalette.accent
        case .atRisk:
            return AppPalette.gold
        case .fulfilled:
            return AppPalette.success
        case .superseded:
            return AppPalette.secondaryInk
        }
    }

    private func rewrite(_ meetingID: Meeting.ID) {
        guard !isRewriting else { return }
        isRewriting = true
        rewriteMessage = "Rewriting notes..."

        rewriteTask?.cancel()
        rewriteTask = Task {
            let message = await store.rewriteMeetingNotes(for: meetingID, style: preferredRewriteStyle)
            guard !Task.isCancelled else { return }
            rewriteMessage = message
            isRewriting = false
        }
    }

    private func runPrompt(_ prompt: String, meetingID: Meeting.ID) {
        guard !isGeneratingPrompt else { return }
        isGeneratingPrompt = true
        promptTitle = prompt
        promptResponse = nil
        promptCitations = []
        if let promptID = store.meeting(withID: meetingID)?.prompts.first(where: { $0.prompt == prompt })?.id {
            store.selectPrompt(promptID, for: meetingID)
        }

        promptTask?.cancel()
        promptTask = Task {
            let response = await store.groundedAnswerMeetingPrompt(for: meetingID, prompt: prompt)
            guard !Task.isCancelled else { return }
            promptResponse = response.text
            promptCitations = response.citations
            isGeneratingPrompt = false
        }
    }

    private func sendToWebhook(meeting: Meeting, config: WebhookConfig) {
        guard sendingWebhookIDs.insert(config.id).inserted else { return }
        let destination = config.label.isEmpty ? config.target.title : config.label
        let body = store.safeSharePreview(
            for: meeting.id,
            format: .markdown,
            includeInferred: true,
            includePrivateNotes: false,
            includeTranscript: false
        ) ?? meeting.title

        HapticEngine.tap(.light)
        NotificationCenter.default.post(
            name: .scribeflowToast,
            object: ToastItem(
                message: "Sending to \(destination)…",
                icon: "arrow.up.circle"
            )
        )
        Task {
            do {
                try await WebhookStore.shared.send(
                    meetingTitle: meeting.title,
                    body: body,
                    to: config
                )
                await MainActor.run {
                    sendingWebhookIDs.remove(config.id)
                    HapticEngine.notify(.success)
                    AnalyticsLog.shared.log("webhook.sent", ["target": config.target.rawValue])
                    NotificationCenter.default.post(
                        name: .scribeflowToast,
                        object: ToastItem(
                            message: "Sent to \(destination)",
                            icon: "checkmark.circle.fill"
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    sendingWebhookIDs.remove(config.id)
                    HapticEngine.notify(.error)
                    let failure = error as NSError
                    AnalyticsLog.shared.log("webhook.failed", [
                        "target": config.target.rawValue,
                        "domain": failure.domain,
                        "code": "\(failure.code)"
                    ])
                    NotificationCenter.default.post(
                        name: .scribeflowToast,
                        object: ToastItem(
                            message: "Couldn’t send to \(destination)",
                            icon: "exclamationmark.triangle.fill",
                            actionTitle: "Retry",
                            action: {
                                sendToWebhook(meeting: meeting, config: config)
                            }
                        )
                    )
                }
            }
        }
    }

    private func share(_ meetingID: Meeting.ID, format: MeetingExportFormat = .internalBrief) {
        guard let export = store.safeSharePreview(
            for: meetingID,
            format: format,
            includeInferred: includeInferredInShare,
            includePrivateNotes: includePrivateNotesInShare,
            includeTranscript: includeTranscriptInShare
        ) else { return }
        shareText = export
        showingShareSheet = true
    }

    private func copyExport(_ meetingID: Meeting.ID) {
        UIPasteboard.general.string = store.safeSharePreview(
            for: meetingID,
            format: exportFormat,
            includeInferred: includeInferredInShare,
            includePrivateNotes: includePrivateNotesInShare,
            includeTranscript: includeTranscriptInShare
        )
    }

    private func refreshTranscriptSnapshot(for key: MeetingTranscriptSnapshotKey) async {
        guard let meeting else { return }
        if !key.query.isEmpty {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }

        let nextSnapshot = await transcriptSnapshotBuilder.make(
            lines: meeting.transcript,
            revision: key.revision,
            query: key.query
        )
        guard !Task.isCancelled, key == transcriptSnapshotKey else { return }
        cachedTranscriptLines = nextSnapshot.lines
        cachedTranscriptWordCount = nextSnapshot.wordCount
    }

    private func hasImportedAudioWithoutTranscript(_ meeting: Meeting) -> Bool {
        meeting.transcript.isEmpty
            && meeting.audioRecordings.contains { $0.source == .noteAttachment }
    }

    private var importedAudioTranscriptPlaceholder: some View {
        let isProcessing = meeting?.status == .processing
        return HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(AppPalette.accent.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppPalette.accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(isProcessing ? "Transcribing imported audio" : "No transcript yet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(isProcessing
                    ? "You can close Scribeflow. Processing will continue and the original audio stays available."
                    : "The original audio is saved. Use Retry transcription from the recording menu when you're ready.")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(AppPalette.accent.opacity(0.18), lineWidth: 0.8)
        )
    }

}

/// Keeps high-frequency TextEditor state local. Publishing each keystroke into
/// MeetingStore invalidates every root tab and restarts persistence work; this
/// editor commits after a short pause and flushes immediately on navigation or
/// backgrounding so responsiveness does not trade away data safety.
private struct MeetingNotesEditor: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let meetingID: Meeting.ID
    let persistedNotes: String

    @State private var draft: String
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    init(meetingID: Meeting.ID, persistedNotes: String) {
        self.meetingID = meetingID
        self.persistedNotes = persistedNotes
        _draft = State(initialValue: persistedNotes)
    }

    var body: some View {
        TextEditor(text: $draft)
            .focused($isFocused)
            .frame(minHeight: 220)
            .padding(12)
            .scrollContentBackground(.hidden)
            .background(AppPalette.paper, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .foregroundStyle(AppPalette.ink)
            .onChange(of: draft) { _, updatedNotes in
                scheduleCommit(updatedNotes)
            }
            .onChange(of: persistedNotes) { _, updatedNotes in
                guard !isFocused, draft != updatedNotes else { return }
                draft = updatedNotes
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    commitImmediately()
                }
            }
            .onDisappear {
                commitImmediately()
            }
            .accessibilityLabel("Meeting notes")
    }

    private func scheduleCommit(_ notes: String) {
        commitTask?.cancel()
        guard notes != persistedNotes else {
            commitTask = nil
            return
        }

        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            commit(notes)
        }
    }

    private func commitImmediately() {
        commitTask?.cancel()
        commitTask = nil
        commit(draft)
    }

    private func commit(_ notes: String) {
        guard store.meeting(withID: meetingID)?.rawNotes != notes else { return }
        store.updateNotes(for: meetingID, notes: notes)
    }
}

private struct TranscriptSpeakerAssignmentView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let meetingID: Meeting.ID
    let line: TranscriptLine
    @State private var speakerName: String

    init(meetingID: Meeting.ID, line: TranscriptLine) {
        self.meetingID = meetingID
        self.line = line
        _speakerName = State(initialValue: line.speaker)
    }

    private var knownSpeakers: [String] {
        guard let meeting = store.meeting(withID: meetingID) else { return [] }
        return Array(Set(meeting.transcript.map(\.speaker)))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        EditorialEyebrow(text: "TRANSCRIPT TURN")
                        Text(line.text)
                            .font(.body)
                            .fontDesign(.serif)
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !knownSpeakers.isEmpty {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Text("Choose a speaker")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: AppSpacing.sm) {
                                    ForEach(knownSpeakers, id: \.self) { speaker in
                                        Button {
                                            speakerName = speaker
                                        } label: {
                                            Label(
                                                speaker,
                                                systemImage: speakerName.caseInsensitiveCompare(speaker) == .orderedSame
                                                    ? "checkmark.circle.fill"
                                                    : "person.crop.circle"
                                            )
                                            .font(.subheadline.weight(.semibold))
                                            .frame(minHeight: 44)
                                            .padding(.horizontal, AppSpacing.md)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(AppPalette.accent)
                                    }
                                }
                            }
                        }
                    }

                    TextField("Speaker name", text: $speakerName)
                        .textInputAutocapitalization(.words)
                        .font(.body)
                        .padding(.horizontal, AppSpacing.md)
                        .frame(minHeight: 50)
                        .background(
                            AppPalette.cardBackground,
                            in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        )

                    Button {
                        store.reassignSpeaker(for: line.id, to: speakerName, in: meetingID)
                        HapticEngine.notify(.success)
                        dismiss()
                    } label: {
                        Label("Apply to this turn", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.accent)
                    .disabled(speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(AppSpacing.lg)
                .readingWidth()
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Change speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct SpeakerEditorView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let meetingID: Meeting.ID

    @State private var selectedSpeaker = ""
    @State private var replacementName = ""
    @State private var speakers: [SpeakerSegment] = []
    @State private var detection: SpeakerDetectionSummary?
    @State private var isLoadingSpeakers = true

    private func refreshSpeakers(selectFirstIfNeeded: Bool = false) async {
        guard let meeting = store.meeting(withID: meetingID) else {
            speakers = []
            detection = nil
            isLoadingSpeakers = false
            return
        }
        let bundle = await store.analysisBundle(for: meeting)
        guard !Task.isCancelled,
              store.meeting(withID: meetingID) == meeting
        else { return }
        speakers = bundle.report.speakerSegments
        detection = bundle.report.speakerDetection
        isLoadingSpeakers = false
        guard selectFirstIfNeeded, selectedSpeaker.isEmpty, let first = speakers.first else { return }
        selectedSpeaker = first.speaker
        replacementName = first.speaker
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SurfaceCard(title: "Speakers", subtitle: "Clean up transcript labels before sharing.") {
                        VStack(alignment: .leading, spacing: 12) {
                            if isLoadingSpeakers {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(AppPalette.accent)
                                    Text("Reading speaker turns")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(AppPalette.secondaryInk)
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 64)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Reading speaker turns")
                            } else if speakers.isEmpty {
                                EmptyStateCard(title: "No speakers yet", subtitle: "Record or import a transcript and speaker labels will appear here.")
                            } else {
                                ForEach(speakers) { speaker in
                                    speakerRow(speaker)
                                }
                            }
                        }
                    }

                    SurfaceCard(title: "Rename", subtitle: selectedSpeaker.isEmpty ? "Choose a speaker above." : "Apply one clean label across this note.") {
                        VStack(alignment: .leading, spacing: 12) {
                    TextField("Speaker name", text: $replacementName)
                        .textInputAutocapitalization(.words)
                        .padding(.horizontal, AppSpacing.md)
                        .frame(minHeight: 50)
                        .background(AppPalette.paper, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.8)
                        )

                            Button {
                                store.renameSpeaker(selectedSpeaker, to: replacementName, for: meetingID)
                                selectedSpeaker = replacementName.trimmingCharacters(in: .whitespacesAndNewlines)
                                replacementName = ""
                                HapticEngine.notify(.success)
                            } label: {
                                Label("Apply to transcript", systemImage: "person.crop.circle.badge.checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppPalette.accent)
                            .disabled(selectedSpeaker.isEmpty || replacementName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Text(detection?.detail ?? "Speaker names stay editable so you can correct labels before sharing.")
                                .font(.footnote)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .appScreenContent(top: AppSpacing.lg)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Speaker labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(AppPalette.ink)
                }
            }
            .task(id: store.revision) {
                await refreshSpeakers(selectFirstIfNeeded: true)
            }
        }
        .modifier(ScribeflowChrome())
    }

    private func speakerRow(_ speaker: SpeakerSegment) -> some View {
        Button {
            selectedSpeaker = speaker.speaker
            replacementName = speaker.speaker
            HapticEngine.select()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(selectedSpeaker == speaker.speaker ? AppPalette.accent.opacity(0.18) : AppPalette.softSurface)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Text(String(speaker.speaker.prefix(1)))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(selectedSpeaker == speaker.speaker ? AppPalette.accent : AppPalette.secondaryInk)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(speaker.speaker)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("\(speaker.lineCount) turn\(speaker.lineCount == 1 ? "" : "s") · \(Int((speaker.talkShare * 100).rounded()))% of transcript")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.secondaryInk)
                    if !speaker.sample.isEmpty {
                        Text(speaker.sample)
                            .font(.caption)
                            .foregroundStyle(AppPalette.secondaryInk)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if selectedSpeaker == speaker.speaker {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppPalette.accent)
                }
            }
            .padding(12)
            .background(AppPalette.paper.opacity(0.86), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MeetingDetail sub-views (extracted)

/// Capsule pill carrying a label + icon — used in meta strips, share metadata.
struct MetaPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppPalette.secondaryInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppPalette.cardBackground.opacity(0.85), in: Capsule())
    }
}

/// Tile in the intelligence card showing a labeled value with a tint.
struct IntelligencePill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.secondaryInk)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
}

/// "Chat with Notes" entry button. Parent owns the chat presentation state;
/// this struct only fires a callback.
struct ChatWithNotesButton: View {
    let onTap: () -> Void

    var body: some View {
        Button {
            HapticEngine.tap(.medium)
            onTap()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(AppPalette.accent.opacity(0.12)).frame(width: 36, height: 36)
                    Image(systemName: "quote.bubble.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat with Notes")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("Ask anything — answers link back to source")
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.border)
            }
            .padding(14)
            .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Meeting Presentation (PPT-style slides)

/// Full-screen, presenter-grade slide deck built from a meeting. Dark scrim
/// around a cream paper slide card. Story-style segmented progress bar on
/// top. Tap right half = next, left half = back; swipe also works. Status
/// bar hidden for an immersive feel.
struct MeetingPresentationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let signals: MeetingSignals
    @State private var page = 0
    @State private var direction: TransitionDirection = .forward
    @State private var shown = false
    @State private var autoplay = false
    @State private var autoplayProgress: Double = 0
    @State private var autoplayTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let autoplayDuration: TimeInterval = 5.5

    private enum TransitionDirection { case forward, backward }

    private enum Slide: Hashable {
        case title, synopsis, decisions, actions, risks, score, end
    }

    private var slides: [Slide] {
        var out: [Slide] = [.title, .synopsis]
        if !signals.decisions.isEmpty { out.append(.decisions) }
        if !meeting.commitments.isEmpty || !signals.actions.isEmpty { out.append(.actions) }
        if !signals.risks.isEmpty { out.append(.risks) }
        if meeting.score != nil { out.append(.score) }
        out.append(.end)
        return out
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dark presenter scrim (replaces system nav chrome — no more
                // content hiding under the navigation bar).
                LinearGradient(
                    colors: [
                        Color(red: 0.063, green: 0.071, blue: 0.090),
                        Color(red: 0.039, green: 0.047, blue: 0.063)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                slideCard(size: geo.size)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if location.x > geo.size.width / 2 { goForward() } else { goBack() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                if value.translation.width < -40 { goForward() }
                                else if value.translation.width > 40 { goBack() }
                            }
                    )

                chromeOverlay
            }
        }
        .statusBarHidden(true)
        .sensoryFeedback(.selection, trigger: page)
        .onAppear { replayReveal() }
        .onChange(of: page) { _, _ in
            replayReveal()
            if autoplay { startAutoplaySegment() }
        }
        .onDisappear { autoplayTask?.cancel() }
    }

    // MARK: Slide card frame

    private func slideCard(size: CGSize) -> some View {
        let inset: CGFloat = 16
        let topRoom: CGFloat = 72   // progress bar + close
        let bottomRoom: CGFloat = 68 // counter + hint
        let cardWidth = size.width - inset * 2
        let cardHeight = max(360, size.height - topRoom - bottomRoom - inset * 2)
        return slideContent(for: slides[page])
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                        .fill(AppPalette.cardBackground)
                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppPalette.accent.opacity(0.10), .clear],
                                startPoint: .topLeading, endPoint: .center
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8)
            )
            .appShadow(AppShadow.hero)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.top, topRoom)
            .padding(.bottom, bottomRoom)
            .id(page) // forces transition on swap
            .transition(
                .asymmetric(
                    insertion: .move(edge: direction == .forward ? .trailing : .leading)
                        .combined(with: .opacity),
                    removal: .move(edge: direction == .forward ? .leading : .trailing)
                        .combined(with: .opacity)
                )
            )
    }

    // MARK: Chrome overlay

    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                progressBar
                HStack {
                    Button {
                        HapticEngine.tap(.light)
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.08), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.7))
                            .appTapTarget()
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                    .accessibilityLabel("Close presentation")

                    Spacer()

                    Button {
                        toggleAutoplay()
                    } label: {
                        Image(systemName: autoplay ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 30, height: 30)
                            .background(
                                Circle().fill(autoplay ? AppPalette.accent.opacity(0.85) : Color.white.opacity(0.08))
                            )
                            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.7))
                            .contentTransition(.symbolEffect(.replace))
                            .appTapTarget()
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                    .accessibilityLabel(autoplay ? "Pause auto-play" : "Auto-play")

                    Text("\(page + 1) of \(slides.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Spacer()

            HStack(spacing: 20) {
                hintLabel("chevron.left", "Tap to go back")
                hintLabel("hand.tap", "Swipe to navigate")
            }
            .padding(.bottom, 18)
        }
        .allowsHitTesting(true)
    }

    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(slides.indices, id: \.self) { i in
                ZStack(alignment: .leading) {
                    Capsule().fill(
                        i < page ? Color.white.opacity(0.7) :
                            (i == page && autoplay ? Color.white.opacity(0.20) :
                                (i == page ? Color.white : Color.white.opacity(0.18)))
                    )
                    if i == page && autoplay {
                        Capsule()
                            .fill(Color.white)
                            .scaleEffect(x: CGFloat(autoplayProgress), y: 1, anchor: .leading)
                    }
                }
                .frame(height: 3)
                .animation(AppMotion.smooth, value: page)
            }
        }
    }

    private func hintLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text.uppercased())
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.40))
        .allowsHitTesting(false)
    }

    private func goForward() {
        cancelAutoplay()
        guard page < slides.count - 1 else {
            HapticEngine.tap(.light); dismiss(); return
        }
        HapticEngine.tap(.light)
        direction = .forward
        withAnimation(.spring(response: 0.40, dampingFraction: 0.85)) { page += 1 }
    }

    private func goBack() {
        cancelAutoplay()
        guard page > 0 else { return }
        HapticEngine.tap(.light)
        direction = .backward
        withAnimation(.spring(response: 0.40, dampingFraction: 0.85)) { page -= 1 }
    }

    private func restartDeck() {
        cancelAutoplay()
        HapticEngine.tap(.medium)
        direction = .backward
        withAnimation(.spring(response: 0.50, dampingFraction: 0.85)) { page = 0 }
    }

    /// Re-fires the per-slide stagger reveal whenever the slide changes.
    private func replayReveal() {
        shown = false
        let delay: Double = reduceMotion ? 0 : 0.08
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if reduceMotion { shown = true }
            else { withAnimation(AppMotion.entrance) { shown = true } }
        }
    }

    // MARK: Auto-play

    private func toggleAutoplay() {
        HapticEngine.tap(.light)
        if autoplay { cancelAutoplay() }
        else {
            autoplay = true
            startAutoplaySegment()
        }
    }

    private func startAutoplaySegment() {
        autoplayTask?.cancel()
        autoplayProgress = 0
        withAnimation(.linear(duration: autoplayDuration)) { autoplayProgress = 1 }
        autoplayTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoplayDuration))
            guard !Task.isCancelled, autoplay else { return }
            if page < slides.count - 1 {
                direction = .forward
                withAnimation(.spring(response: 0.40, dampingFraction: 0.85)) { page += 1 }
                // Next segment kicks off via .onChange(of: page).
            } else {
                autoplay = false
                autoplayProgress = 0
            }
        }
    }

    private func cancelAutoplay() {
        autoplay = false
        autoplayTask?.cancel()
        autoplayTask = nil
        withAnimation(.easeOut(duration: 0.2)) { autoplayProgress = 0 }
    }

    // MARK: Slide content

    @ViewBuilder
    private func slideContent(for slide: Slide) -> some View {
        switch slide {
        case .title:     titleSlide
        case .synopsis:  synopsisSlide
        case .decisions: bulletSlide(title: "Decisions", count: signals.decisions.count, tint: AppPalette.success, items: signals.decisions)
        case .actions:   actionsSlide
        case .risks:     bulletSlide(title: "Risks", count: signals.risks.count, tint: AppPalette.coral, items: signals.risks)
        case .score:     scoreSlide
        case .end:       endSlide
        }
    }

    private var titleSlide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule().fill(AppPalette.accent).frame(width: 44, height: 3)
                .motionEntrance(step: 0, active: shown)
            EditorialEyebrow(
                text: "\(meeting.workspace) · \(meeting.when.formatted(.dateTime.month(.abbreviated).day().year()))",
                tint: AppPalette.accent
            )
            .motionEntrance(step: 1, active: shown)
            Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                .scaledFont(size: 36, weight: .medium, design: .serif, relativeTo: .largeTitle)
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .motionEntrance(step: 2, active: shown)
            Spacer(minLength: 0)
            if !meeting.attendees.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    EditorialEyebrow(text: "Presented to")
                    HStack(spacing: 12) {
                        EditorialAvatarStack(names: meeting.attendees, size: 28, max: 5)
                        Text(meeting.attendees.prefix(4).joined(separator: ", "))
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppPalette.secondaryInk)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .motionEntrance(step: 3, active: shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var synopsisSlide: some View {
        let synopsis = meetingSynopsis(for: meeting, summary: meeting.summary(for: meeting.selectedTemplate))
        return VStack(alignment: .leading, spacing: 16) {
            EditorialEyebrow(text: "Synopsis", tint: AppPalette.accent)
                .motionEntrance(step: 0, active: shown)
            Text(synopsis)
                .scaledFont(size: 22, weight: .regular, design: .serif, relativeTo: .title)
                .italic()
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(4)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AppPalette.accent).frame(width: 3)
                }
                .fixedSize(horizontal: false, vertical: true)
                .motionEntrance(step: 1, active: shown)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletSlide(title: String, count: Int, tint: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .scaledFont(size: 28, weight: .medium, design: .serif, relativeTo: .largeTitle)
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                EditorialMeta(text: "\(count)", tint: tint)
            }
            .motionEntrance(step: 0, active: shown)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { idx, text in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(tint).frame(width: 8, height: 8).padding(.top, 8)
                        Text(text)
                            .font(.system(size: 17, design: .serif))
                            .foregroundStyle(AppPalette.ink)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .motionEntrance(step: 1 + idx, active: shown)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionsSlide: some View {
        let visibleCommitments = meeting.commitments
        let open = visibleCommitments.filter { $0.status == .open || $0.status == .atRisk }
        let done = visibleCommitments.filter { $0.status == .fulfilled || $0.status == .superseded }
        let openList = Array(open.prefix(5))
        let doneList = Array(done.prefix(2))
        let signalList = Array(signals.actions.prefix(3))
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Actions")
                    .scaledFont(size: 28, weight: .medium, design: .serif, relativeTo: .largeTitle)
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                EditorialMeta(text: "\(open.count) open", tint: AppPalette.coral)
            }
            .motionEntrance(step: 0, active: shown)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(openList.enumerated()), id: \.element.id) { idx, c in
                    actionRow(c.statement, done: false, owner: c.owner)
                        .motionEntrance(step: 1 + idx, active: shown)
                }
                ForEach(Array(doneList.enumerated()), id: \.element.id) { idx, c in
                    actionRow(c.statement, done: true, owner: c.owner)
                        .motionEntrance(step: 1 + openList.count + idx, active: shown)
                }
                ForEach(Array(signalList.enumerated()), id: \.offset) { idx, t in
                    actionRow(t, done: false, owner: nil)
                        .motionEntrance(step: 1 + openList.count + doneList.count + idx, active: shown)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(_ text: String, done: Bool, owner: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? AppPalette.success : Color.clear)
                    .overlay(Circle().strokeBorder(done ? AppPalette.success : AppPalette.border, lineWidth: 1.5))
                    .frame(width: 18, height: 18)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
            }
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(done ? AppPalette.secondaryInk : AppPalette.ink)
                    .strikethrough(done)
                    .fixedSize(horizontal: false, vertical: true)
                if let owner, owner != "Owner not named" {
                    EditorialMeta(text: owner)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var scoreSlide: some View {
        let score = meeting.score
        return VStack(alignment: .leading, spacing: 16) {
            EditorialEyebrow(text: "Meeting score", tint: AppPalette.accent)
                .motionEntrance(step: 0, active: shown)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                CountUpNumber(
                    value: shown ? Double(score?.overall ?? 0) : 0,
                    font: .system(size: 84, weight: .medium, design: .serif),
                    color: AppPalette.ink
                )
                .animation(.easeOut(duration: 1.0), value: shown)
                Text("/ 100")
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppPalette.secondaryInk)
            }
            .motionEntrance(step: 1, active: shown)
            if let s = score, !s.insight.isEmpty {
                Text(s.insight)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .motionEntrance(step: 2, active: shown)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var endSlide: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Capsule().fill(AppPalette.accent).frame(width: 40, height: 3)
                .motionEntrance(step: 0, active: shown)
            Text("Thank you.")
                .scaledFont(size: 40, weight: .medium, design: .serif, relativeTo: .largeTitle)
                .foregroundStyle(AppPalette.ink)
                .motionEntrance(step: 1, active: shown)
            Text("Shared from Scribeflow")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(AppPalette.tertiaryInk)
                .motionEntrance(step: 2, active: shown)

            AdaptiveActionStack(spacing: 10) {
                Button {
                    restartDeck()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                        Text("Replay")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AppPalette.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: AppLayout.minimumTapTarget)
                    .background(AppPalette.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(AppPalette.border, lineWidth: 1))
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.95))

                ShareLink(
                    item: meetingDigestMarkdown(meeting, signals: signals),
                    subject: Text(meeting.title.isEmpty ? "Meeting" : meeting.title),
                    preview: SharePreview(meeting.title.isEmpty ? "Meeting" : meeting.title)
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                        Text("Share digest")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: AppLayout.minimumTapTarget)
                    .background(AppPalette.accentButton, in: Capsule())
                    .shadow(color: AppPalette.accent.opacity(0.28), radius: 10, y: 4)
                }

                Button {
                    HapticEngine.tap(.light)
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .padding(.horizontal, 14)
                        .frame(minHeight: AppLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
            .motionEntrance(step: 3, active: shown)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
