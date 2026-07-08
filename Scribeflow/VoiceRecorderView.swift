import AVFoundation
import SwiftUI

enum VoiceRecorderPresentationMode: Equatable {
    case newNote
    case attach(Meeting.ID)
}

struct VoiceRecorderView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Binding var selectedMeetingID: Meeting.ID?
    let presentationMode: VoiceRecorderPresentationMode

    @State private var viewModel = VoiceRecorderViewModel()
    @State private var showingDiscardConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case notes
    }

    private var linkedMeetingID: Meeting.ID? {
        if case let .attach(id) = presentationMode { return id }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    recorderHero
                    permissionCard
                    recordingControls
                    recordingSafetyCard
                    notesAndTranscriptCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 112)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle(presentationMode == .newNote ? "Voice note" : "Attach audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        close()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saveButtonTitle) {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(!viewModel.canSave || viewModel.phase == .saving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .confirmationDialog("Discard recording?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    viewModel.discard()
                    dismiss()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("This removes the unsaved audio file from this device.")
            }
            .onAppear {
                viewModel.refreshPermissions()
                if let linkedMeetingID, let meeting = store.meeting(withID: linkedMeetingID) {
                    viewModel.title = "\(meeting.title) voice note"
                    viewModel.workspace = meeting.workspace
                }
            }
            .onDisappear {
                if case .saved = viewModel.phase {
                    return
                }
                if viewModel.phase == .recording || viewModel.phase == .paused {
                    viewModel.discard()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    viewModel.pauseForInterruption("Paused while Scribeflow was not active")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                handleAudioInterruption(notification)
            }
        }
        .modifier(ScribeflowChrome())
    }

    private var recorderHero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("VOICE MEMORY")
                        .font(.caption2.weight(.medium))
                        .kerning(0.8)
                        .foregroundStyle(.white.opacity(0.50))
                    Text(viewModel.elapsedLabel)
                        .font(AppFont.mono(.largeTitle, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(viewModel.statusMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                        .contentTransition(.opacity)
                }

                Spacer()

                RecordingStateOrb(level: viewModel.inputLevel, isRecording: viewModel.isRecording)
            }

            VStack(spacing: 10) {
                TextField("Title", text: $viewModel.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused($focusedField, equals: .title)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if presentationMode == .newNote {
                    TextField("Workspace", text: $viewModel.workspace)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .tint(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(22)
        .background(AppPalette.captureGradient, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(permissionTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.permissionTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(permissionMessage)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if viewModel.permissions.microphone == .unknown || viewModel.permissions.speech == .unknown {
                Button {
                    Task { await viewModel.requestPermissionsIfNeeded() }
                } label: {
                    Label("Allow microphone and speech", systemImage: "hand.tap.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            } else if viewModel.permissions.isBlocked {
                Button {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.ink)
                .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }
        }
        .padding(16)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(AppPalette.border.opacity(0.7)))
    }

    private var recordingControls: some View {
        SurfaceCard(title: "Recorder", subtitle: "Audio is saved locally with file protection.") {
            VStack(spacing: 14) {
                VoiceAudioLevelBars(level: max(viewModel.inputLevel, viewModel.isRecording ? 0.08 : 0))
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 12) {
                    if viewModel.phase == .recording {
                        Button {
                            viewModel.pause()
                        } label: {
                            controlLabel("Pause", icon: "pause.fill", tint: AppPalette.gold)
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await viewModel.stopAndTranscribe() }
                        } label: {
                            primaryControlLabel("Stop", icon: "stop.fill", tint: AppPalette.coral)
                        }
                        .buttonStyle(.plain)
                    } else if viewModel.phase == .paused {
                        Button {
                            viewModel.resume()
                        } label: {
                            primaryControlLabel("Resume", icon: "play.fill", tint: AppPalette.accent)
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await viewModel.stopAndTranscribe() }
                        } label: {
                            controlLabel("Finish", icon: "checkmark", tint: AppPalette.ink)
                        }
                        .buttonStyle(.plain)
                    } else if viewModel.phase == .processing {
                        ProgressView()
                            .tint(AppPalette.accent)
                        Text("Transcribing…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                    } else {
                        Button {
                            focusedField = nil
                            Task { await viewModel.start() }
                        } label: {
                            primaryControlLabel(viewModel.completedRecording == nil ? "Record" : "Record again", icon: "mic.fill", tint: AppPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canRecord || viewModel.phase == .saving)
                        .opacity(viewModel.canRecord ? 1 : 0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var recordingSafetyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.accent)
            Text("If a call, Siri, alarm, or app switch interrupts recording, Scribeflow pauses so you can resume or finish cleanly.")
                .font(.footnote)
                .foregroundStyle(AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.55))
        )
    }

    private var notesAndTranscriptCard: some View {
        SurfaceCard(title: "Note", subtitle: "Transcript and notes stay together.") {
            VStack(alignment: .leading, spacing: 14) {
                TextEditor(text: $viewModel.noteText)
                    .frame(minHeight: 120)
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .background(AppPalette.paper, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if viewModel.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Add context, names, decisions, or follow-up while the recording is fresh.")
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.secondaryInk.opacity(0.55))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($focusedField, equals: .notes)

                if !viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    transcriptPreview
                } else if viewModel.completedRecording != nil {
                    EmptyStateCard(
                        title: "Audio ready",
                        subtitle: transcriptEmptySubtitle
                    )

                    if viewModel.phase == .processing {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(AppPalette.accent)
                            Text(viewModel.transcriptionJobStatusText ?? "Retrying transcript...")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AppPalette.secondaryInk)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else if viewModel.permissions.speech == .ready {
                        Button {
                            Task { await viewModel.retryTranscript() }
                        } label: {
                            Label("Retry transcript", systemImage: "arrow.clockwise")
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppPalette.accent)
                        .background(AppPalette.accentSoft, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        .disabled(!viewModel.canRetryTranscript)
                    }
                }
            }
        }
    }

    private var transcriptPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Transcript", systemImage: "quote.bubble.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                Spacer()
                Text(viewModel.completedRecording?.durationSeconds.formatted() ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
            }

            Text(viewModel.transcript)
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if let status = viewModel.transcriptionJobStatusText {
                Label(status, systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.accent)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { close() } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppPalette.softSurface.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle())

            Button { save() } label: {
                HStack(spacing: 6) {
                    if viewModel.phase == .saving {
                        ProgressView().tint(.white)
                    }
                    Text(saveButtonTitle)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppPalette.accentButton, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(viewModel.canSave && viewModel.phase != .saving ? 1 : 0.5)
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(!viewModel.canSave || viewModel.phase == .saving)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.regularMaterial)
    }

    private var saveButtonTitle: String {
        switch presentationMode {
        case .newNote:
            viewModel.phase == .saving ? "Saving..." : "Save note"
        case .attach:
            viewModel.phase == .saving ? "Attaching..." : "Attach"
        }
    }

    private var permissionTint: Color {
        if viewModel.permissions.isReady { return AppPalette.accent }
        if viewModel.permissions.isBlocked { return AppPalette.coral }
        return AppPalette.gold
    }

    private var permissionMessage: String {
        if viewModel.permissions.microphone == .denied {
            return "Scribeflow cannot record audio until microphone access is enabled."
        }
        if viewModel.permissions.speech == .denied {
            return "Audio recording still works. Turn on Speech Recognition for searchable transcripts."
        }
        if viewModel.permissions.microphone == .unknown || viewModel.permissions.speech == .unknown {
            return "iOS asks before recording or transcribing. Scribeflow starts only after you tap Record."
        }
        if viewModel.permissions.speech == .unsupported {
            return "This device can record audio, but system transcription is unavailable."
        }
        return "Microphone and speech are ready. Recordings stay in the app’s protected storage."
    }

    private var transcriptEmptySubtitle: String {
        if viewModel.permissions.speech == .ready {
            return "No transcript was produced. Retry transcription, save the audio now, or add notes manually."
        }
        if viewModel.permissions.speech == .denied {
            return "No transcript was produced because Speech Recognition is blocked. Save the audio now or enable Speech Recognition in Settings."
        }
        return "No transcript was produced. Save the recording now or add notes manually."
    }

    private func controlLabel(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func primaryControlLabel(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func save() {
        guard viewModel.canSave else { return }
        Task {
            if let id = await viewModel.save(into: store, linkedMeetingID: linkedMeetingID) {
                selectedMeetingID = id
                dismiss()
            }
        }
    }

    private func close() {
        if viewModel.phase == .recording || viewModel.phase == .paused || viewModel.completedRecording != nil {
            showingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            viewModel.pauseForInterruption("Paused for an audio interruption")
        case .ended:
            viewModel.markReadyToResume("Ready to resume")
        @unknown default:
            break
        }
    }
}

private struct RecordingStateOrb: View {
    let level: Double
    let isRecording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isRecording {
                Circle()
                    .stroke(.white.opacity(0.20), lineWidth: 1.5)
                    .frame(width: 88, height: 88)
                    .scaleEffect(isRecording ? 1.15 : 0.9)
                    .opacity(isRecording ? 0 : 1)
                    .animation(reduceMotion ? nil : AppMotion.breathe, value: isRecording)
            }
            Circle()
                .fill(.white.opacity(0.10))
                .frame(width: 80, height: 80)
            Circle()
                .fill(isRecording ? AppPalette.coral.opacity(0.8) : .white.opacity(0.6))
                .frame(width: 20 + CGFloat(level * 28), height: 20 + CGFloat(level * 28))
                .animation(.easeOut(duration: 0.12), value: level)
            Image(systemName: isRecording ? "waveform" : "mic.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isRecording ? .white : AppPalette.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

private struct VoiceAudioLevelBars: View {
    let level: Double

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<18, id: \.self) { index in
                Capsule()
                    .fill(barColor(index))
                    .frame(width: 4, height: barHeight(index))
                    .animation(.easeOut(duration: 0.16), value: level)
            }
        }
        .frame(height: 46)
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let wave = abs(sin(Double(index) * 0.62))
        let scaled = max(0.12, level)
        return 8 + CGFloat(wave * scaled) * 34
    }

    private func barColor(_ index: Int) -> Color {
        index % 3 == 0 ? AppPalette.gold : AppPalette.accent
    }
}
