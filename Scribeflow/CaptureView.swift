import SwiftUI

/// Unified capture surface.
///
/// One screen replaces the previous trio of LiveMeetingView, NewMeetingView,
/// and (deleted) PhoneCallCaptureView. The user picks **Record** (audio +
/// live transcript + notes) or **Type** (notes only). Title, notes, and the
/// Save flow are shared across modes so the mental model collapses to a
/// single "take a note" affordance.
///
/// State engine: a single `LiveMeetingCoordinator` holds title/objective/
/// notes/transcript regardless of mode. In Type mode we simply never start
/// the audio engine. On save, we branch:
/// - audio captured  → `coordinator.saveMeeting(into:)` (preserves transcript)
/// - text only       → `store.addMeetingWithTransformation(...)` (clean fast path)
struct CaptureView: View {
    enum Mode: String, Hashable {
        case record
        case type
    }

    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedMeetingID: Meeting.ID?
    @Binding var toast: ToastItem?

    @State private var mode: Mode
    @State private var coordinator = LiveMeetingCoordinator()
    @State private var isSaving = false
    @State private var savedMeetingID: Meeting.ID?
    @State private var hasAnimatedIn = false
    @State private var defaultsCleared = false
    @State private var showingDiscardConfirm = false
    @State private var recordingStartedAt: Date?
    @State private var markFlash = false
    @State private var calendarEvent: CalendarEventSnapshot?
    @AppStorage("scribeflow.capture.recordTemplate") private var lastRecordTemplateRaw = NoteTemplate.general.rawValue
    @AppStorage("scribeflow.capture.typeTemplate") private var lastTypeTemplateRaw = NoteTemplate.general.rawValue
    @State private var minutePulse = false
    @State private var showsCaptureDetails = false
    @Namespace private var templateNS

    init(
        initialMode: Mode = .record,
        selectedMeetingID: Binding<Meeting.ID?>,
        toast: Binding<ToastItem?>
    ) {
        self._mode = State(initialValue: initialMode)
        self._selectedMeetingID = selectedMeetingID
        self._toast = toast
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modePicker
                        .motionEntrance(step: 0, active: hasAnimatedIn)
                    titleBlock
                        .motionEntrance(step: 1, active: hasAnimatedIn)
                    if mode == .type {
                        notesPanel
                            .motionEntrance(step: 2, active: hasAnimatedIn)
                    }
                    captureDetails
                        .motionEntrance(step: 2, active: hasAnimatedIn)
                    if mode == .record {
                        recordPanel
                            .motionEntrance(step: 3, active: hasAnimatedIn)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if mode == .record, showCopilotRail {
                        MeetingCopilotRail(
                            meetings: store.meetings,
                            libraryRevision: store.revision,
                            attendees: attendeeList,
                            paragraphs: coordinator.transcriptParagraphs,
                            purpose: coordinator.currentPurpose,
                            isRecording: coordinator.isRecording,
                            onFile: fileCopilotSignal
                        )
                        .motionEntrance(step: 4, active: hasAnimatedIn)
                        .transition(.opacity)
                    }
                    if mode == .record {
                        notesPanel
                            .motionEntrance(step: 4, active: hasAnimatedIn)
                    }
                    if mode == .record, !coordinator.transcriptParagraphs.isEmpty {
                        transcriptPanel
                            .motionEntrance(step: 5, active: hasAnimatedIn)
                            .transition(.opacity)
                    }
                }
                .appScreenContent(top: AppSpacing.md, bottom: 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppPalette.background.ignoresSafeArea())
            .accessibilityIdentifier("capture.view")
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        if canSave {
                            HapticEngine.tap(.light)
                            showingDiscardConfirm = true
                        } else {
                            coordinator.stopCapture()
                            dismiss()
                        }
                    }
                    .disabled(coordinator.isFinalizingSpeech)
                    .foregroundStyle(AppPalette.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(coordinator.isFinalizingSpeech ? "Finalizing…" : (isSaving ? "Saving…" : "Save")) {
                        saveAndClose()
                    }
                    .disabled(!canSave || isSaving || coordinator.isFinalizingSpeech)
                    .fontWeight(.semibold)
                    .tint(canSave && !isSaving ? AppPalette.accent : AppPalette.secondaryInk.opacity(0.45))
                    .accessibilityIdentifier("capture.saveButton")
                }
            }
            .confirmationDialog(
                "Discard this capture?",
                isPresented: $showingDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    HapticEngine.notify(.warning)
                    coordinator.stopCapture()
                    dismiss()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Your title, notes, and any transcript haven't been saved. This can't be undone.")
            }
        }
        .modifier(ScribeflowChrome())
        .interactiveDismissDisabled(coordinator.isRecording || isSaving || coordinator.isFinalizingSpeech)
        .sensoryFeedback(trigger: coordinator.isRecording) { _, new in
            new ? .impact(weight: .heavy) : .impact(weight: .light)
        }
        .sensoryFeedback(.success, trigger: savedMeetingID)
        .task {
            clearDefaultsOnce()
            restoreTemplate(for: mode)
            consumeUpcomingTitleIfNeeded()
            if mode == .record {
                await coordinator.prepare()
            }
            hasAnimatedIn = true
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, mode == .record, !coordinator.isRecording else { return }
            Task { await coordinator.prepare() }
        }
        .onDisappear {
            coordinator.stopCapture()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: coordinator.isRecording) { _, isRec in
            // Keep the screen awake through a live meeting; capture the start
            // time for the session stamp.
            UIApplication.shared.isIdleTimerDisabled = isRec
            recordingStartedAt = isRec ? .now : nil
        }
        .onChange(of: coordinator.elapsedSeconds) { _, secs in
            // A soft tick + micro-pulse at each whole minute — a calm sense of
            // time passing, never a distraction.
            guard coordinator.isRecording, !coordinator.isPaused, secs > 0, secs % 60 == 0 else { return }
            HapticEngine.tap(.light)
            minutePulse = true
            Task {
                try? await Task.sleep(for: .milliseconds(240))
                minutePulse = false
            }
        }
        .onChange(of: recognitionContextInputs) { _, _ in
            coordinator.refreshRecognitionContext()
        }
        .onChange(of: mode) { _, newMode in
            restoreTemplate(for: newMode)
            if newMode == .record {
                Task { await coordinator.prepare() }
            } else if coordinator.isRecording {
                Task { await coordinator.finishCapture() }
            }
        }
        .onChange(of: savedMeetingID) { _, newID in
            // Saved-flow collapse: skip the intermediate MeetingSavedSheet.
            // Land the user back in the host with a success toast; the
            // host's `selectedMeetingID` binding routes them to the meeting
            // detail if they're on Library.
            guard let id = newID else { return }
            selectedMeetingID = id
            let isProcessing = store.meeting(withID: id)?.status == .processing
            toast = ToastItem(
                message: isProcessing
                    ? "Saved. Refining in background — we'll notify you if enabled."
                    : "Saved — find it in Library",
                icon: isProcessing ? "waveform.badge.magnifyingglass" : "checkmark.seal.fill"
            )
            HapticEngine.notify(.success)
            dismiss()
        }
    }

    private var recognitionContextInputs: [String] {
        [
            coordinator.title,
            coordinator.workspace,
            coordinator.objective,
            coordinator.attendees,
            coordinator.manualNotes,
            coordinator.selectedTemplate.rawValue,
            coordinator.purposeOverride?.rawValue ?? "automatic",
            coordinator.expectedSpeakerCount.map { String($0) } ?? "auto"
        ]
    }

    // MARK: Mode picker

    private var modePicker: some View {
        HStack(spacing: 4) {
            modePill(.record, label: "Record", icon: "waveform.badge.mic")
            modePill(.type, label: "Type", icon: "square.and.pencil")
        }
        .padding(4)
        .background(AppPalette.softSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
    }

    private func modePill(_ pill: Mode, label: String, icon: String) -> some View {
        Button {
            HapticEngine.tap(.light)
            withAnimation(AppMotion.smooth) { mode = pill }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.footnote.weight(.bold))
                Text(label)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(mode == pill ? .white : AppPalette.secondaryInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .frame(minHeight: AppLayout.minimumTapTarget)
            .background(
                ZStack {
                    if mode == pill {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        AppPalette.accent,
                                        Color(red: 0.047, green: 0.298, blue: 0.329)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("capture.mode.\(pill.rawValue)")
    }

    // MARK: Title block

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "",
                text: $coordinator.title,
                prompt: Text(mode == .record ? "Capture title" : "Note title")
                    .foregroundStyle(AppPalette.ink.opacity(colorScheme == .dark ? 0.58 : 0.42))
            )
            .scaledFont(size: 28, weight: .medium, design: .serif, relativeTo: .title)
            .foregroundStyle(AppPalette.ink)
            .accessibilityIdentifier("capture.titleField")

            HStack(alignment: .top, spacing: 8) {
                TextField(
                    "",
                text: $coordinator.objective,
                prompt: Text("What is this about?")
                        .foregroundStyle(AppPalette.secondaryInk.opacity(colorScheme == .dark ? 0.82 : 0.55)),
                    axis: .vertical
                )
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .accessibilityIdentifier("capture.objectiveField")

                if coordinator.title.isEmpty,
                   !coordinator.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        coordinator.title = suggestedMeetingTitle(
                            objective: coordinator.objective,
                            notes: coordinator.manualNotes,
                            fallback: mode == .record ? "Capture" : "Note"
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.bold))
                            Text("Suggest")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(AppPalette.accent)
                        .appTapTarget()
                    }
                    .buttonStyle(.plain)
                }
            }

        }
    }

    private var captureDetails: some View {
        DisclosureGroup(isExpanded: $showsCaptureDetails) {
            VStack(alignment: .leading, spacing: 16) {
                noteTypeRow
                templateStrip
                if mode == .record {
                    attendeeDetails
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Label("Details", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer(minLength: 8)
                Text(selectedPurposeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
            }
            .frame(minHeight: 44)
        }
        .tint(AppPalette.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.45), lineWidth: 0.7)
        )
        .accessibilityIdentifier("capture.details")
    }

    private var selectedPurposeTitle: String {
        coordinator.purposeOverride?.title ?? coordinator.currentPurpose.displayTitle
    }

    private var noteTypeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: coordinator.purposeOverride?.systemImage ?? "wand.and.stars")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Note type")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.ink)
                Text(coordinator.purposeOverride == nil ? "Detected automatically" : "Chosen for this capture")
                    .font(.caption)
                    .foregroundStyle(AppPalette.tertiaryInk)
            }

            Spacer(minLength: 8)

            Menu {
                Button {
                    HapticEngine.select()
                    coordinator.purposeOverride = nil
                } label: {
                    Label("Automatic", systemImage: coordinator.purposeOverride == nil ? "checkmark" : "wand.and.stars")
                }

                Section("Personal") {
                    ForEach([CapturePurposeKind.personalNote, .reflection, .idea, .personalPlan], id: \.self) { purpose in
                        purposeMenuButton(purpose)
                    }
                }

                Section("Conversations") {
                    ForEach([CapturePurposeKind.conversation, .appointment, .learning, .meeting, .call], id: \.self) { purpose in
                        purposeMenuButton(purpose)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedPurposeTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                .frame(minHeight: AppLayout.minimumTapTarget)
            }
            .accessibilityLabel("Note type, \(selectedPurposeTitle)")
        }
    }

    private func purposeMenuButton(_ purpose: CapturePurposeKind) -> some View {
        Button {
            HapticEngine.select()
            coordinator.purposeOverride = purpose
        } label: {
            Label(
                purpose.title,
                systemImage: coordinator.purposeOverride == purpose ? "checkmark" : purpose.systemImage
            )
        }
    }

    private var attendeeDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("People and speakers", systemImage: "person.2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryInk)
            TextField(
                "",
                text: $coordinator.attendees,
                prompt: Text("People in this capture")
                    .foregroundStyle(AppPalette.secondaryInk.opacity(0.5))
            )
            .font(.subheadline)
            .foregroundStyle(AppPalette.secondaryInk)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .accessibilityIdentifier("capture.attendeesField")

            expectedSpeakerCountMenu
        }
    }

    // MARK: Record panel

    /// Spoken-word green used on the dark capture stage (matches design).
    static let captureGreen = Color(red: 0.490, green: 0.820, blue: 0.639) // #7DD1A3

    private var transcribedWordCount: Int {
        coordinator.transcriptWordCount
    }

    /// Most recent meaningful spoken line, for the on-stage live caption.
    private var liveCaptionText: String? {
        coordinator.transcriptParagraphs.last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Stage accent shifts with the chosen template — subtle personalization
    /// kept inside the brand family so it never reads as noise.
    private var stageTint: Color {
        switch coordinator.selectedTemplate {
        case .general, .discovery, .interview: return AppPalette.accent
        case .exec, .brainstorm:     return AppPalette.gold
        case .manager:               return AppPalette.accentDeep
        case .standup:               return Self.captureGreen
        }
    }

    /// One calm status line under the timer that adapts to what's happening.
    private var stageStatus: String {
        let feedback = coordinator.speechFeedback
        if feedback == .hearingSpeech, transcribedWordCount > 0 {
            return "\(feedback.title) · \(transcribedWordCount) draft words"
        }
        return feedback.title
    }

    private var speechFeedbackTint: Color {
        switch coordinator.speechFeedback {
        case .hearingSpeech, .captured:
            Self.captureGreen
        case .quietInput, .paused, .finalizing:
            AppPalette.gold
        case .captionsUnavailable, .microphoneBlocked, .microphoneUnavailable:
            AppPalette.coral
        case .permissionNeeded, .ready, .listening:
            .white.opacity(0.55)
        }
    }

    private var speechLanguageMenu: some View {
        Menu {
            Button {
                HapticEngine.tap(.light)
                coordinator.selectRecognitionLocale(identifier: nil)
            } label: {
                Label(
                    "Automatic (\(SpeechRecognitionSupport.displayName(for: SpeechRecognitionSupport.automaticLocale)))",
                    systemImage: coordinator.recognitionLocaleIdentifier == nil ? "checkmark" : "globe"
                )
            }

            Divider()

            ForEach(SpeechRecognitionSupport.availableLocales, id: \.identifier) { locale in
                Button {
                    HapticEngine.tap(.light)
                    coordinator.selectRecognitionLocale(identifier: locale.identifier)
                } label: {
                    Label(
                        SpeechRecognitionSupport.displayName(for: locale),
                        systemImage: coordinator.recognitionLocaleIdentifier == locale.identifier
                            ? "checkmark"
                            : "waveform"
                    )
                }
            }
        } label: {
            Label(coordinator.recognitionLanguageTitle, systemImage: "globe")
                .font(.caption2.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(minHeight: 44)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .disabled(coordinator.isRecording || coordinator.isFinalizingSpeech)
        .opacity(coordinator.isRecording || coordinator.isFinalizingSpeech ? 0.55 : 1)
        .accessibilityLabel("Transcription language, \(coordinator.recognitionLanguageTitle)")
    }

    private var expectedSpeakerCountMenu: some View {
        Menu {
            Button {
                HapticEngine.tap(.light)
                coordinator.selectExpectedSpeakerCount(nil)
            } label: {
                Label(
                    "Automatic",
                    systemImage: coordinator.expectedSpeakerCount == nil ? "checkmark" : "person.wave.2"
                )
            }

            Divider()

            ForEach(1...6, id: \.self) { count in
                Button {
                    HapticEngine.tap(.light)
                    coordinator.selectExpectedSpeakerCount(count)
                } label: {
                    Label(
                        "\(count) speaker\(count == 1 ? "" : "s")",
                        systemImage: coordinator.expectedSpeakerCount == count ? "checkmark" : "person.wave.2"
                    )
                }
            }
        } label: {
            Label(coordinator.expectedSpeakerCountTitle, systemImage: "person.wave.2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryInk)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(AppPalette.softSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.35), lineWidth: 0.5))
        }
        .disabled(coordinator.isRecording || coordinator.isFinalizingSpeech)
        .opacity(coordinator.isRecording || coordinator.isFinalizingSpeech ? 0.55 : 1)
        .accessibilityLabel("Expected speakers, \(coordinator.expectedSpeakerCountTitle)")
        .accessibilityIdentifier("capture.expectedSpeakerCount")
    }

    private var liveCaptionDisplayText: String {
        if let liveCaptionText { return liveCaptionText }
        return coordinator.speechFeedback.detail
    }

    /// Bookmark the current moment with a confirming flash + haptic.
    private func flashMark() {
        HapticEngine.notify(.success)
        coordinator.bookmarkCurrentMoment()
        withAnimation(AppMotion.snappy) { markFlash = true }
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(AppMotion.fade) { markFlash = false }
        }
    }

    /// Dark recording stage: ambient teal glow, recording pill, big mono timer,
    /// live input waveform, and the record toggle.
    private var recordPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Header — eyebrow + recording / ready pill
            HStack(alignment: .center) {
                Text("LIVE CAPTURE · \(coordinator.selectedTemplate.title.uppercased())")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if coordinator.isFinalizingSpeech {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(AppPalette.gold)
                        Text("FINALIZING")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppPalette.gold)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppPalette.gold.opacity(0.16), in: Capsule())
                } else if coordinator.isRecording {
                    let paused = coordinator.isPaused
                    HStack(spacing: 6) {
                        if paused {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(AppPalette.gold)
                        } else {
                            Circle()
                                .fill(AppPalette.coral)
                                .frame(width: 6, height: 6)
                                .shadow(color: AppPalette.coral, radius: 5)
                        }
                        Text(paused ? "PAUSED" : "RECORDING")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(paused ? AppPalette.gold : AppPalette.coral)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((paused ? AppPalette.gold : AppPalette.coral).opacity(0.20), in: Capsule())
                } else {
                    Text("READY")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Self.captureGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Self.captureGreen.opacity(0.16), in: Capsule())
                }
            }

            // Big timer
            VStack(alignment: .leading, spacing: 8) {
                Text(coordinator.elapsedLabel)
                    .scaledFont(size: 60, weight: .regular, design: .monospaced, relativeTo: .largeTitle)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .scaleEffect(reduceMotion ? 1 : (minutePulse ? 1.04 : 1.0), anchor: .leading)
                    .animation(reduceMotion ? nil : AppMotion.bounce, value: minutePulse)
                HStack(spacing: 8) {
                    Text(stageStatus)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    if let started = recordingStartedAt {
                        Text("· started \(started.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                }
            }

            // Keep a stable caption footprint while recognition revises partial
            // words. Replacing and animating the whole text on every update made
            // the recording stage jump and compete with the audio meter.
            if coordinator.isRecording || coordinator.isFinalizingSpeech {
                Button {
                    guard liveCaptionText != nil else { return }
                    flashMark()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("DRAFT CAPTION")
                                .font(AppFont.mono(.caption2, weight: .medium))
                                .foregroundStyle(Self.captureGreen.opacity(0.7))
                            Spacer(minLength: 8)
                            Label("Mark", systemImage: "bookmark.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(liveCaptionText == nil ? 0.32 : 0.72))
                        }
                        Text(liveCaptionDisplayText)
                            .font(AppFont.serif(.title3, weight: .medium))
                            .foregroundStyle(.white.opacity(liveCaptionText == nil ? 0.48 : 0.92))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 72, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(liveCaptionText == nil)
                .accessibilityLabel(liveCaptionText == nil ? "Draft caption pending" : "Mark this spoken moment")
            }

            // Waveform card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("INPUT · MIC")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    speechLanguageMenu
                }
                // Isolated leaf — reads inputLevel itself, so the ~12Hz level
                // updates re-render only the waveform, not the whole stage.
                LiveWaveform(coordinator: coordinator)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 36)
                Label(
                    coordinator.speechFeedback.title.uppercased(),
                    systemImage: coordinator.speechFeedback.systemImage
                )
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(speechFeedbackTint)
                .lineLimit(1)
                Text(coordinator.speechFeedback.detail)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(2)
                    .frame(minHeight: 26, alignment: .topLeading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )

            if coordinator.isRecording {
                liveControls
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !coordinator.bookmarks.isEmpty {
                bookmarksStrip
                    .transition(.opacity)
            }

            if coordinator.catchUpSummary != nil {
                catchUpCard
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if let errorMessage = coordinator.errorMessage {
                let recordingContinues = coordinator.isRecording
                    && coordinator.speechFeedback == .captionsUnavailable
                HStack(alignment: .top, spacing: 10) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(recordingContinues ? AppPalette.gold : AppPalette.coral)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if coordinator.needsPermissionSettings {
                        Button {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.10), in: Circle())
                                .appTapTarget()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(recordingContinues ? AppPalette.gold : AppPalette.coral)
                        .accessibilityLabel("Open Scribeflow settings")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (recordingContinues ? AppPalette.gold : AppPalette.coral).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                )
            }

            if let speakerStatus = coordinator.speakerStatus,
               !coordinator.isRecording || coordinator.isFinalizingSpeech {
                Label(
                    speakerStatus,
                    systemImage: coordinator.isFinalizingSpeech
                        ? "lock.fill"
                        : (coordinator.hasPendingAudio ? "tray.and.arrow.down.fill" : "person.wave.2.fill")
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(coordinator.isFinalizingSpeech ? AppPalette.gold : Self.captureGreen)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (coordinator.isFinalizingSpeech ? AppPalette.gold : Self.captureGreen).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                )
            }

            // Record toggle, centered — flanked by Pause while live so the mic
            // stays optically centered.
            HStack(spacing: 20) {
                Spacer()
                if coordinator.isRecording {
                    pauseButton
                }
                recordToggleButton
                if coordinator.isRecording {
                    Color.clear.frame(width: 52, height: 52)
                }
                Spacer()
            }
            .padding(.top, 2)
            .disabled(coordinator.isFinalizingSpeech)

            // On-device trust cue — quiet, always reassuring.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Recording stays on this device")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth: .infinity)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(recordPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(alignment: .top) {
            // Ambient elapsed hairline — fills gently over the hour.
            if coordinator.isRecording {
                GeometryReader { geo in
                    Capsule()
                        .fill(stageTint.opacity(0.85))
                        .frame(width: geo.size.width * min(1, Double(coordinator.elapsedSeconds) / 3600.0), height: 2)
                        .animation(.linear(duration: 1), value: coordinator.elapsedSeconds)
                }
                .frame(height: 2)
            }
        }
        .overlay {
            if markFlash {
                VStack(spacing: 10) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Self.captureGreen)
                    Text("Moment marked")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(28)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .appShadow(coordinator.isRecording ? AppShadow.hero : AppShadow.floating)
        .animation(AppMotion.smooth, value: coordinator.isRecording)
        .animation(AppMotion.smooth, value: coordinator.isPaused)
        .animation(AppMotion.smooth, value: coordinator.bookmarks.count)
        .animation(AppMotion.smooth, value: coordinator.catchUpSummary)
    }

    // MARK: Live controls (during recording)

    private var liveControls: some View {
        HStack(spacing: 10) {
            liveControlButton(
                icon: "bookmark.fill",
                label: "Mark moment",
                tint: Self.captureGreen
            ) {
                flashMark()
            }
            liveControlButton(
                icon: coordinator.isGeneratingCatchUp ? "ellipsis" : "sparkles",
                label: coordinator.isGeneratingCatchUp ? "Summarizing…" : "Catch me up",
                tint: AppPalette.accent
            ) {
                HapticEngine.tap(.medium)
                Task { await coordinator.generateCatchUp() }
            }
            .disabled(coordinator.isGeneratingCatchUp)
        }
    }

    private func liveControlButton(
        icon: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.footnote.weight(.bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.96))
        .accessibilityLabel(label)
    }

    private var bookmarksStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MARKED MOMENTS · \(coordinator.bookmarks.count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(coordinator.bookmarks) { bookmark in
                        Button {
                            HapticEngine.tap(.light)
                            coordinator.removeBookmark(bookmark)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Self.captureGreen)
                                Text(bookmark.text)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(minHeight: AppLayout.minimumTapTarget)
                            .background(Color.white.opacity(0.05), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: 230)
                        .accessibilityLabel("Marked moment: \(bookmark.text). Tap to remove.")
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var catchUpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                Text("CATCH ME UP")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button {
                    HapticEngine.tap(.light)
                    coordinator.catchUpSummary = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.35))
                        .appTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss catch-up")
            }
            Text(coordinator.catchUpSummary ?? "")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.accent.opacity(0.12),
            in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(AppPalette.accent.opacity(0.30), lineWidth: 1)
        )
    }

    private var pauseButton: some View {
        Button {
            HapticEngine.tap(.light)
            withAnimation(AppMotion.snappy) {
                if coordinator.isPaused { coordinator.resumeCapture() }
                else { coordinator.pauseCapture() }
            }
        } label: {
            Image(systemName: coordinator.isPaused ? "play.fill" : "pause.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.92))
        .accessibilityLabel(coordinator.isPaused ? "Resume recording" : "Pause recording")
    }

    private var recordToggleButton: some View {
        Button {
            HapticEngine.tap(.medium)
            Task {
                if coordinator.isRecording {
                    await coordinator.finishCapture()
                } else {
                    await coordinator.startCapture()
                }
            }
        } label: {
            ZStack {
                // Voice-reactive ring — tracks live input level in real time.
                // Isolated leaf so per-frame level updates don't re-render the
                // button (or its parent) — only this ring repaints.
                if coordinator.isRecording {
                    ReactiveRing(coordinator: coordinator)
                }
                recordButtonCore
            }
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.92))
        .accessibilityLabel(coordinator.isRecording ? "Stop recording" : "Start recording")
        .accessibilityIdentifier("capture.recordToggle")
    }

    private var recordButtonCore: some View {
            ZStack {
                if coordinator.isRecording {
                    Circle()
                        .stroke(AppPalette.coral.opacity(0.30), lineWidth: 2)
                        .frame(width: 80, height: 80)
                        .scaleEffect(coordinator.isRecording ? 1.3 : 0.9)
                        .opacity(coordinator.isRecording ? 0 : 1)
                        .animation(reduceMotion ? nil : AppMotion.breathe, value: coordinator.isRecording)
                        .allowsHitTesting(false)
                }
                Circle()
                    .fill(
                        coordinator.isRecording
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [AppPalette.coral, Color(red: 0.55, green: 0.20, blue: 0.16)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(AppPalette.accentButton)
                    )
                    .frame(width: 64, height: 64)
                    .shadow(
                        color: (coordinator.isRecording ? AppPalette.coral : AppPalette.accent).opacity(0.22),
                        radius: 12,
                        y: 5
                    )
                Image(systemName: coordinator.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: coordinator.isRecording)
            }
    }

    @ViewBuilder
    private var recordPanelBackground: some View {
        ZStack {
            Color(red: 0.059, green: 0.067, blue: 0.082) // #0F1115

            LinearGradient(
                colors: [
                    AppPalette.accent.opacity(coordinator.isRecording ? 0.16 : 0.10),
                    .clear,
                    AppPalette.coral.opacity(coordinator.isRecording ? 0.06 : 0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .animation(AppMotion.smooth, value: coordinator.isRecording)

            RadialGradient(
                colors: [.clear, .black.opacity(0.28)],
                center: .center, startRadius: 130, endRadius: 360
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: Notes panel

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                Text("NOTES")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(AppPalette.secondaryInk)
                Spacer()
                if !coordinator.manualNotes.isEmpty {
                    let chars = coordinator.manualNotes.count
                    Text("\(chars)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppPalette.tertiaryInk)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $coordinator.manualNotes)
                    .font(.body)
                    .foregroundStyle(AppPalette.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 240)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .accessibilityIdentifier("capture.notesField")

                if coordinator.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(coordinator.currentPurpose.allowsMeetingSignals
                        ? "Key points, decisions, owners, risks…"
                        : "Thoughts, ideas, and details worth remembering…")
                        .font(.body)
                        .foregroundStyle(AppPalette.secondaryInk.opacity(colorScheme == .dark ? 0.78 : 0.42))
                        .padding(.top, 14)
                        .padding(.leading, 17)
                        .allowsHitTesting(false)
                }
            }

            Divider()
                .background(AppPalette.divider.opacity(0.4))

            HStack(spacing: 12) {
                Text(mode == .record
                    ? "Write while you record"
                    : (coordinator.currentPurpose.allowsMeetingSignals
                        ? "Capture decisions and next steps"
                        : "Capture what matters in your own words"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)

                Spacer()

                VoiceNoteButton { transcribed in
                    let prefix = coordinator.manualNotes.isEmpty ? "" : "\n"
                    coordinator.manualNotes += prefix + transcribed
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if coordinator.manualNotes.count > 12 {
                SmartNotesPreview(
                    notes: coordinator.manualNotes,
                    transcriptTail: Array(coordinator.transcriptParagraphs.suffix(12)),
                    attendees: attendeeList
                )
                .equatable()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(AppPalette.paper, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.8)
        )
        .appShadow(AppShadow.soft)
    }

    // MARK: Transcript panel (live)

    private var transcriptPanel: some View {
        let visible = Array(coordinator.transcriptParagraphs.suffix(6).enumerated())
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("TRANSCRIPT PREVIEW")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Self.captureGreen)
                    Text("DRAFT")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Self.captureGreen)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppPalette.accent.opacity(0.30), in: Capsule())
                .overlay(Capsule().strokeBorder(Self.captureGreen.opacity(0.25), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(visible, id: \.offset) { offset, paragraph in
                    let isLast = offset == visible.count - 1
                    Text(paragraph)
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(.white.opacity(isLast ? 0.92 : 0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Label("Final wording and speaker names improve after Save", systemImage: "person.wave.2")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(Color(red: 0.078, green: 0.086, blue: 0.102)) // #14161A
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: Save / helpers

    private var canSave: Bool {
        let hasNotes = !coordinator.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTranscript = !coordinator.transcriptParagraphs.isEmpty
        let hasTitle = !coordinator.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasNotes || hasTranscript || hasTitle || coordinator.hasPendingAudio
    }

    /// Clear legacy placeholder defaults from coordinators restored across an
    /// app update so purpose inference starts from the user's own words.
    private func clearDefaultsOnce() {
        guard !defaultsCleared else { return }
        defaultsCleared = true
        if coordinator.title == "Live meeting" || coordinator.title == "New capture" {
            coordinator.title = ""
        }
        if coordinator.objective == "Capture the key points while I stay present in the meeting."
            || coordinator.objective == "Understand and organize what matters." {
            coordinator.objective = ""
        }
    }

    /// Pull a preset event from Home's "Capture" tap on an upcoming calendar
    /// event. The context is single-shot so subsequent captures start blank.
    private func consumeUpcomingTitleIfNeeded() {
        guard coordinator.title.isEmpty else { return }
        if let event = UpcomingCaptureContext.shared.consume() {
            calendarEvent = event
            coordinator.hasCalendarContext = true
            coordinator.title = event.title
            coordinator.workspace = event.isVideoCall ? "Calls" : "Meetings"
            coordinator.objective = event.objective
            coordinator.attendees = event.attendees.joined(separator: ", ")
        }
    }

    // MARK: Template strip

    /// Optional structure for a capture. General stays neutral; specialized
    /// templates are explicit choices for conversations that need them.
    private var templateStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SUMMARY STYLE")
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppPalette.tertiaryInk)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(NoteTemplate.allCases) { template in
                        templateChip(template)
                    }
                }
                .padding(.vertical, 2)
            }
            Text(coordinator.selectedTemplate.description)
                .font(.caption)
                .foregroundStyle(AppPalette.tertiaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(AppMotion.smooth, value: coordinator.selectedTemplate)
        }
    }

    private func templateChip(_ template: NoteTemplate) -> some View {
        let selected = coordinator.selectedTemplate == template
        return Button {
            HapticEngine.tap(.light)
            withAnimation(AppMotion.snappy) { coordinator.selectedTemplate = template }
            persistTemplate(template, for: mode)
        } label: {
            Text(template.title)
                .font(.caption.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : AppPalette.secondaryInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: AppLayout.minimumTapTarget)
                .background {
                    if selected {
                        Capsule().fill(AppPalette.accentButton)
                            .matchedGeometryEffect(id: "template.pill", in: templateNS)
                    } else {
                        Capsule().fill(AppPalette.softSurface.opacity(0.6))
                    }
                }
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("\(template.title) template")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func restoreTemplate(for mode: Mode) {
        let rawValue = mode == .record ? lastRecordTemplateRaw : lastTypeTemplateRaw
        coordinator.selectedTemplate = NoteTemplate(rawValue: rawValue) ?? .general
    }

    private func persistTemplate(_ template: NoteTemplate, for mode: Mode) {
        if mode == .record {
            lastRecordTemplateRaw = template.rawValue
        } else {
            lastTypeTemplateRaw = template.rawValue
        }
    }

    /// A title taken from the note itself — its first non-empty line, stripped of
    /// bullet markers and clipped — so a quick note is never labeled "Untitled"
    /// or given prefilled boilerplate.
    private func noteTitle(from notes: String) -> String {
        let firstLine = notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•\t")) }
            .first(where: { !$0.isEmpty })
        guard let line = firstLine, !line.isEmpty else { return "Quick note" }
        return line.count > 50 ? String(line.prefix(50)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    private func saveAndClose() {
        guard !isSaving, !coordinator.isFinalizingSpeech else { return }
        isSaving = true

        let hasAudio = !coordinator.transcriptParagraphs.isEmpty
            || coordinator.hasPendingAudio
            || mode == .record
        let id: Meeting.ID
        if hasAudio {
            // Create the pending row immediately. Speech/audio finalization and
            // enhanced processing continue after this screen dismisses.
            id = coordinator.saveMeeting(into: store, calendarEvent: calendarEvent)
        } else {
            // Text-only path — preserve exactly what the user typed. We do
            // NOT auto-rewrite the note: that fabricates structure for thin
            // or garbage input and discards the original. The title and
            // objective are derived from the text (never prefilled), and
            // every surfaced item (synopsis, actions, decisions) is extracted
            // from the actual note. The user can Enhance on demand later.
            let typed = coordinator.manualNotes
            let typedTitle = coordinator.title.trimmingCharacters(in: .whitespacesAndNewlines)
            id = store.addMeeting(
                title: typedTitle.isEmpty ? noteTitle(from: typed) : typedTitle,
                workspace: calendarEvent.map { $0.isVideoCall ? "Calls" : "Meetings" } ?? "Personal workspace",
                attendees: calendarEvent?.attendees ?? [],
                objective: coordinator.objective.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: typed,
                when: calendarEvent?.startDate ?? .now,
                durationMinutes: calendarEvent?.durationMinutes ?? 0,
                calendarEventID: calendarEvent?.id,
                calendarStartDate: calendarEvent?.startDate,
                calendarEndDate: calendarEvent?.endDate,
                selectedTemplate: coordinator.selectedTemplate,
                purposeOverride: coordinator.purposeOverride
            )
        }

        if hasAudio {
            Task {
                _ = await ScribeflowNotificationAuthorization.shared.requestIfNeeded()
            }
        }
        isSaving = false
        savedMeetingID = id
    }

    // MARK: Copilot rail

    private var attendeeList: [String] {
        coordinator.attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Cheap gate for showing the rail — avoids scanning every meeting on each
    /// (50Hz) waveform-driven body render. The rail subview itself decides
    /// section contents, and only re-renders when its inputs actually change.
    private var showCopilotRail: Bool {
        coordinator.isRecording
            || !attendeeList.isEmpty
            || !coordinator.transcriptParagraphs.isEmpty
    }

    /// Drop a Copilot signal into the running notes as a labeled bullet.
    private func fileCopilotSignal(_ signal: CopilotSignal) {
        let prefix: String
        switch signal.kind {
        case .remember: prefix = "Carryover:"
        case .decision: prefix = "Decision:"
        case .action:   prefix = "Action:"
        case .ask:      prefix = "Ask:"
        case .insight:  prefix = "Note:"
        }
        let bullet = "- \(prefix) \(signal.text)"
        if coordinator.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            coordinator.manualNotes = bullet
        } else {
            coordinator.manualNotes += "\n\(bullet)"
        }
        toast = ToastItem(message: "Added to notes", icon: "plus.circle.fill")
    }
}

// MARK: - Smart Notes preview

/// The "messy notes → clean structure" moment, live and on-device. Runs the
/// same text-aware extractor that powers the saved meeting, so what you see
/// while typing is exactly what gets captured. Equatable on its inputs so it
/// only re-derives when the notes / transcript / attendees actually change.
struct SmartNotesPreview: View, Equatable {
    private struct AnalysisInput: Hashable {
        let notes: String
        let transcriptTail: [String]
        let attendees: [String]
    }

    let notes: String
    let transcriptTail: [String]
    let attendees: [String]

    @State private var decisions: [String] = []
    @State private var actions: [ExtractedActionItem] = []
    @State private var analysisWorker = SmartNotesAnalysisWorker()

    static func == (lhs: SmartNotesPreview, rhs: SmartNotesPreview) -> Bool {
        lhs.notes == rhs.notes
            && lhs.transcriptTail == rhs.transcriptTail
            && lhs.attendees == rhs.attendees
    }

    private var meeting: Meeting {
        Meeting(
            title: "",
            workspace: "Personal",
            when: .now,
            durationMinutes: 0,
            attendees: attendees,
            status: .ready,
            stage: "",
            objective: "",
            rawNotes: notes,
            transcript: transcriptTail.map { TranscriptLine(speaker: "You", role: "", text: $0) },
            summaries: [],
            prompts: [],
            destinations: [],
            selectedTemplate: .general,
            selectedPromptID: nil,
            isPinned: false
        )
    }

    private var analysisInput: AnalysisInput {
        AnalysisInput(notes: notes, transcriptTail: transcriptTail, attendees: attendees)
    }

    var body: some View {
        Group {
        if !decisions.isEmpty || !actions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.caption2.weight(.bold))
                    Text("SMART NOTES").font(.caption2.weight(.bold))
                    Spacer()
                    Text("on-device").font(.caption2.weight(.medium)).foregroundStyle(AppPalette.tertiaryInk)
                }
                .foregroundStyle(AppPalette.accent)

                if !decisions.isEmpty {
                    smartSection(icon: "checkmark.seal.fill", label: "Decisions", tint: AppPalette.accent)
                    ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                        smartBullet(decision, tint: AppPalette.accent)
                    }
                }

                if !actions.isEmpty {
                    smartSection(icon: "arrow.right.circle.fill", label: "Actions", tint: AppPalette.gold)
                    ForEach(actions) { action in
                        actionRow(action)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.accentSoft.opacity(0.45), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(AppPalette.accent.opacity(0.18), lineWidth: 0.8)
            )
            .transition(.opacity)
        }
        }
        .task(id: analysisInput) {
            // Debounce: run the extraction engine after a typing pause, not on
            // every keystroke (which hung the keyboard).
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let result = await analysisWorker.analyze(meeting)
            guard !Task.isCancelled else { return }
            decisions = result.decisions
            actions = result.actions
        }
    }

    private func smartSection(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(label.uppercased()).font(.caption2.weight(.bold))
        }
        .foregroundStyle(tint)
    }

    private func smartBullet(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(tint).frame(width: 5, height: 5).padding(.top, 6)
            Text(text)
                .scaledFont(size: 13, relativeTo: .body)
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionRow(_ action: ExtractedActionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(AppPalette.gold).frame(width: 5, height: 5).padding(.top, 6)
                Text(action.text)
                    .scaledFont(size: 13, weight: .medium, relativeTo: .body)
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                metaChip(
                    icon: action.owner == "You" ? "person.fill" : "person",
                    text: action.owner == "Owner not named" ? "Unassigned" : action.owner,
                    tint: action.owner == "Owner not named" ? AppPalette.secondaryInk : AppPalette.accent
                )
                if let due = action.dueHint {
                    metaChip(icon: "clock", text: due.capitalized, tint: AppPalette.coral)
                }
            }
            .padding(.leading, 13)
        }
    }

    private func metaChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct SmartNotesAnalysisSnapshot {
    let decisions: [String]
    let actions: [ExtractedActionItem]
}

private actor SmartNotesAnalysisWorker {
    func analyze(_ meeting: Meeting) -> SmartNotesAnalysisSnapshot {
        guard !Task.isCancelled else {
            return SmartNotesAnalysisSnapshot(decisions: [], actions: [])
        }
        let decisions = MeetingIntelligenceEngine.decisions(for: meeting, limit: 3)
        guard !Task.isCancelled else {
            return SmartNotesAnalysisSnapshot(decisions: [], actions: [])
        }
        return SmartNotesAnalysisSnapshot(
            decisions: decisions,
            actions: MeetingIntelligenceEngine.structuredActions(for: meeting, limit: 4)
        )
    }
}

// MARK: - Live level leaves

/// The mic waveform. Reads `inputLevel` itself so the high-frequency level
/// stream re-renders only this view, not the whole capture stage.
private struct LiveWaveform: View {
    let coordinator: LiveMeetingCoordinator
    var body: some View {
        MicLevelMeter(
            level: coordinator.isRecording ? coordinator.inputLevel : 0,
            color: CaptureView.captureGreen,
            bars: 36,
            maxHeight: 36
        )
    }
}

/// Voice-reactive ring around the record button, isolated for the same reason.
private struct ReactiveRing: View {
    let coordinator: LiveMeetingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .stroke(CaptureView.captureGreen.opacity(0.45), lineWidth: 2.5)
            .frame(width: 72, height: 72)
            .scaleEffect(reduceMotion ? 1 : 1.0 + coordinator.inputLevel * 0.6)
            .opacity(0.25 + coordinator.inputLevel * 0.55)
            .allowsHitTesting(false)
    }
}

// MARK: - Copilot rail

/// Live Copilot rail. Isolated as its own view so it recomputes its (meeting-
/// scanning) signals only when its inputs change — not on every waveform tick
/// that re-renders the parent capture screen.
fileprivate struct MeetingCopilotSnapshot: Equatable {
    var remember: [CopilotSignal] = []
    var detected: [CopilotSignal] = []
    var ask: [CopilotSignal] = []
}

private struct MeetingCopilotSnapshotKey: Hashable {
    let libraryRevision: Int
    let attendees: [String]
    let paragraphTail: [String]
    let purpose: CapturePurpose
    let isRecording: Bool
}

private actor MeetingCopilotSnapshotBuilder {
    func make(
        meetings: [Meeting],
        attendees: [String],
        paragraphs: [String],
        purpose: CapturePurpose
    ) -> MeetingCopilotSnapshot {
        MeetingCopilot.snapshot(
            attendees: attendees,
            paragraphs: paragraphs,
            purpose: purpose,
            meetings: meetings
        )
    }
}

private struct MeetingCopilotRail: View {
    let meetings: [Meeting]
    let libraryRevision: Int
    let attendees: [String]
    let paragraphs: [String]
    let purpose: CapturePurpose
    let isRecording: Bool
    let onFile: (CopilotSignal) -> Void
    @State private var snapshot = MeetingCopilotSnapshot()
    @State private var snapshotBuilder = MeetingCopilotSnapshotBuilder()

    private var snapshotKey: MeetingCopilotSnapshotKey {
        MeetingCopilotSnapshotKey(
            libraryRevision: libraryRevision,
            attendees: attendees,
            paragraphTail: Array(paragraphs.suffix(10)),
            purpose: purpose,
            isRecording: isRecording
        )
    }

    var body: some View {
        let isWorkCapture = purpose.allowsMeetingSignals

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                Text("COPILOT")
                    .font(.caption2.weight(.bold))

                    .foregroundStyle(AppPalette.accent)
                Label(purpose.displayTitle, systemImage: purpose.kind.systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(1)
                Spacer()
                if isRecording {
                    Text("● LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.coral)
                }
            }

            if isWorkCapture {
                section(
                    "REMEMBER", icon: "brain", tint: AppPalette.accent,
                    signals: snapshot.remember,
                    emptyHint: attendees.isEmpty
                        ? "Add attendees above to recall open promises with these people."
                        : "No open items carried over with these people."
                )
            }
            section(
                isWorkCapture ? "DETECTED NOW" : purpose.kind.insightTitle.uppercased(),
                icon: isWorkCapture ? "dot.radiowaves.left.and.right" : purpose.kind.systemImage,
                tint: AppPalette.gold,
                signals: snapshot.detected,
                emptyHint: isRecording
                    ? (isWorkCapture
                        ? "Listening for decisions and action items…"
                        : "Listening for ideas and details worth keeping…")
                    : nil
            )
            if isWorkCapture {
                section(
                    "ASK THEM", icon: "questionmark.bubble", tint: AppPalette.coral,
                    signals: snapshot.ask,
                    emptyHint: nil
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.cardBackground,
            in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.accent.opacity(0.18), lineWidth: 0.8)
        )
        .appShadow(AppShadow.soft)
        .task(id: snapshotKey) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let nextSnapshot = await snapshotBuilder.make(
                meetings: meetings,
                attendees: attendees,
                paragraphs: paragraphs,
                purpose: purpose
            )
            guard !Task.isCancelled else { return }
            if snapshot != nextSnapshot {
                snapshot = nextSnapshot
            }
        }
    }

    @ViewBuilder
    private func section(
        _ label: String,
        icon: String,
        tint: Color,
        signals: [CopilotSignal],
        emptyHint: String?
    ) -> some View {
        if !signals.isEmpty || emptyHint != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption2.weight(.bold))
                    Text(label)
                        .font(.caption2.weight(.bold))

                }
                .foregroundStyle(tint)

                if signals.isEmpty, let hint = emptyHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk.opacity(0.85))
                } else {
                    ForEach(signals) { signal in
                        row(signal, tint: tint)
                    }
                }
            }
        }
    }

    private func row(_ signal: CopilotSignal, tint: Color) -> some View {
        Button {
            HapticEngine.tap(.light)
            onFile(signal)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(signal.text)
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = signal.detail {
                        Text(detail)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint.opacity(0.7))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                tint.opacity(0.06),
                in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            )
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.98))
        .accessibilityHint("Adds this to your notes")
    }
}

// MARK: - Meeting Copilot engine

/// What a Copilot signal represents. Drives icon, tint, and how it's filed
/// into notes when tapped.
enum CopilotSignalKind: Equatable {
    case remember   // an open promise carried over from a past meeting
    case decision   // a decision detected in the live transcript
    case action     // an action item detected in the live transcript
    case ask        // a suggested question to raise now
    case insight    // a useful thought from a non-work capture
}

struct CopilotSignal: Identifiable, Equatable {
    let kind: CopilotSignalKind
    let text: String
    let detail: String?
    /// Content-derived identity so repeated recomputation diffs stably.
    var id: String { "\(kind)|\(text)" }
}

/// Pure, view-agnostic logic for the Live Meeting Copilot. Splits into three
/// feeds: memory recall from past meetings with the same people (REMEMBER /
/// ASK THEM) and live extraction from the running transcript (DETECTED NOW).
/// Kept as static functions so it stays trivially testable and side-effect free.
enum MeetingCopilot {

    fileprivate static func snapshot(
        attendees: [String],
        paragraphs: [String],
        purpose: CapturePurpose,
        meetings: [Meeting]
    ) -> MeetingCopilotSnapshot {
        let detected = detect(paragraphs: paragraphs, purpose: purpose)
        guard purpose.allowsMeetingSignals, !Task.isCancelled else {
            return MeetingCopilotSnapshot(detected: detected)
        }

        let related = relatedMeetings(attendees: attendees, in: meetings)
        let accountable = related.filter {
            guard !Task.isCancelled else { return false }
            return $0.allowsAccountabilityExtraction
        }
        return MeetingCopilotSnapshot(
            remember: remember(in: accountable),
            detected: detected,
            ask: askThem(in: accountable)
        )
    }

    /// Past meetings that share at least one attendee (by name) with the
    /// current set. Title is also matched so a "QBR: Meridian" recalls when
    /// "Meridian" is an attendee. Newest first.
    static func relatedMeetings(attendees: [String], in meetings: [Meeting]) -> [Meeting] {
        let needles = attendees.map { $0.lowercased() }.filter { $0.count >= 2 }
        guard !needles.isEmpty else { return [] }
        return meetings
            .filter { meeting in
                let haystack = (meeting.attendees + [meeting.title]).map { $0.lowercased() }
                return needles.contains { needle in
                    haystack.contains { $0.contains(needle) || needle.contains($0) }
                }
            }
            .sorted { $0.when > $1.when }
    }

    /// REMEMBER — open or at-risk promises from past meetings with these
    /// people, so nothing carries over forgotten.
    static func remember(attendees: [String], in meetings: [Meeting], limit: Int = 3) -> [CopilotSignal] {
        let related = relatedMeetings(attendees: attendees, in: meetings)
            .filter(\.allowsAccountabilityExtraction)
        return remember(in: related, limit: limit)
    }

    private static func remember(in related: [Meeting], limit: Int = 3) -> [CopilotSignal] {
        guard !related.isEmpty else { return [] }
        var out: [CopilotSignal] = []
        for meeting in related {
            guard !Task.isCancelled else { break }
            for c in meeting.commitments where c.status == .open || c.status == .atRisk {
                let detail = [ownerLabel(c.owner), meeting.title]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                out.append(CopilotSignal(kind: .remember, text: clipped(c.statement), detail: detail))
            }
        }
        return Array(dedup(out).prefix(limit))
    }

    /// ASK THEM — the other side's open promises, turned into questions to
    /// raise in this meeting.
    static func askThem(attendees: [String], in meetings: [Meeting], limit: Int = 2) -> [CopilotSignal] {
        let related = relatedMeetings(attendees: attendees, in: meetings)
            .filter(\.allowsAccountabilityExtraction)
        return askThem(in: related, limit: limit)
    }

    private static func askThem(in related: [Meeting], limit: Int = 2) -> [CopilotSignal] {
        guard !related.isEmpty else { return [] }
        var out: [CopilotSignal] = []
        for meeting in related {
            guard !Task.isCancelled else { break }
            for c in meeting.commitments
            where (c.status == .open || c.status == .atRisk) && !isSelf(c.owner) {
                out.append(CopilotSignal(kind: .ask, text: question(from: c.statement), detail: ownerLabel(c.owner)))
            }
        }
        return Array(dedup(out).prefix(limit))
    }

    /// DETECTED NOW — classify the most recent spoken lines into live
    /// decisions and action items. Newest surfaced first.
    static func detect(
        paragraphs: [String],
        purpose: CapturePurpose,
        limit: Int = 3
    ) -> [CopilotSignal] {
        var out: [CopilotSignal] = []
        for raw in paragraphs.suffix(10) {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.count >= 20 else { continue }
            if !purpose.allowsMeetingSignals {
                out.append(CopilotSignal(
                    kind: .insight,
                    text: clipped(p),
                    detail: purpose.displayTitle
                ))
                continue
            }
            // Same distilling/classifying engine as the saved-meeting surfaces,
            // so live signals read as "Send the MSA" — not the whole spoken line.
            if let decision = MeetingIntelligenceEngine.decision(from: p) {
                out.append(CopilotSignal(kind: .decision, text: clipped(decision), detail: nil))
            } else if let action = MeetingIntelligenceEngine.actionItem(from: p) {
                out.append(CopilotSignal(kind: .action, text: clipped(action), detail: nil))
            }
        }
        return Array(dedup(out.reversed()).prefix(limit))
    }

    // MARK: Helpers

    private static func isSelf(_ owner: String) -> Bool {
        let o = owner.lowercased().trimmingCharacters(in: .whitespaces)
        return o.isEmpty || o == "you" || o == "me" || o == "i" || o.contains("myself")
    }

    private static func ownerLabel(_ owner: String) -> String {
        isSelf(owner) ? "You owe" : owner
    }

    private static func question(from statement: String) -> String {
        let s = clipped(statement)
        if s.hasSuffix("?") { return s }
        return "Follow up — \(s)"
    }

    private static func clipped(_ s: String, max: Int = 120) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func dedup(_ items: [CopilotSignal]) -> [CopilotSignal] {
        var seen = Set<String>()
        var out: [CopilotSignal] = []
        for item in items where seen.insert(item.text.lowercased()).inserted {
            out.append(item)
        }
        return out
    }
}
