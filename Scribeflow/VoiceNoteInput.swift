import SwiftUI
import AVFoundation

// MARK: - Voice Input Manager

@MainActor
@Observable
final class VoiceNoteManager {
    var isRecording = false
    var error: String?

    private let audioEngine = AVAudioEngine()
    private var speechSession: (any LiveSpeechTranscribing)?
    private var captureGeneration = 0

    var onTranscription: ((String) -> Void)?
 
    func requestPermission(completion: @escaping (Bool) -> Void) {
        Task {
            let permissions = await VoiceRecordingPermissionService.request()
            completion(permissions.isReady)
        }
    }

    func start() async {
        cancel()
        captureGeneration &+= 1
        let generation = captureGeneration

        do {
            try AudioSessionManager.shared.configureForVoiceNote()
            let inputNode = audioEngine.inputNode
            if inputNode.isVoiceProcessingEnabled {
                try inputNode.setVoiceProcessingEnabled(false)
            }
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                throw SpeechRecognitionPipelineError.unsupportedAudioFormat
            }

            let session = try await SpeechRecognitionPipeline.makeLiveSession(
                inputFormat: format,
                context: SpeechRecognitionContext(
                    title: "Quick note",
                    workspace: "Personal workspace",
                    objective: "Capture the speaker's exact words clearly."
                ),
                onTranscript: { [weak self] text, _ in
                    guard self?.captureGeneration == generation else { return }
                    self?.onTranscription?(text)
                },
                onError: { [weak self] message in
                    guard let self, self.captureGeneration == generation else { return }
                    self.error = message
                    if self.isRecording {
                        self.cancel()
                    }
                }
            )
            guard generation == captureGeneration else {
                session.cancel()
                return
            }
            speechSession = session
            let audioSink = session.audioSink

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [audioSink] buffer, _ in
                audioSink.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            error = nil
        } catch {
            cancel()
            self.error = "Could not start recording."
        }
    }

    func finish() async -> String {
        guard isRecording || speechSession != nil else { return "" }
        captureGeneration &+= 1
        isRecording = false
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        let finalTranscript = await speechSession?.finish() ?? ""
        speechSession = nil
        onTranscription?(finalTranscript)
        AudioSessionManager.shared.deactivate()
        return finalTranscript
    }

    func cancel() {
        captureGeneration &+= 1
        isRecording = false
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        speechSession?.cancel()
        speechSession = nil
        AudioSessionManager.shared.deactivate()
    }
}

// MARK: - Voice Note Button

struct VoiceNoteButton: View {
    @State private var manager = VoiceNoteManager()
    @State private var authorized = false
    @State private var interim = ""
    var onAppend: (String) -> Void

    var body: some View {
        Button {
            if manager.isRecording {
                Task {
                    let result = await manager.finish()
                    interim = ""
                    if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onAppend(result)
                    }
                }
            } else {
                requestAndStart()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(manager.isRecording ? AppPalette.coral : AppPalette.softSurface)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                manager.isRecording ? AppPalette.coral : AppPalette.border,
                                lineWidth: 0.8
                            )
                    )
                    .shadow(color: manager.isRecording ? AppPalette.coral.opacity(0.25) : .clear, radius: 8, y: 2)

                Image(systemName: manager.isRecording ? "stop.fill" : "mic")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(manager.isRecording ? .white : AppPalette.secondaryInk)
            }
            .scaleEffect(manager.isRecording ? 1.08 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: manager.isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(manager.isRecording ? "Stop recording" : "Record voice note")
        .onAppear {
            manager.onTranscription = { text in interim = text }
        }
        .onDisappear {
            if manager.isRecording { manager.cancel() }
        }
        .overlay(alignment: .bottom) {
            if manager.isRecording {
                Text(interim.isEmpty ? "Listening…" : interim)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.coral)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 200)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .adaptiveMaterial(.thinMaterial, solid: AppPalette.elevated, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                    .offset(y: 52)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: manager.isRecording)
    }

    private func requestAndStart() {
        if authorized {
            Task { await manager.start() }
        } else {
            manager.requestPermission { granted in
                authorized = granted
                if granted { Task { await manager.start() } }
            }
        }
    }
}
