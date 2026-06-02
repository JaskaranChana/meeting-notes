import SwiftUI
import Speech
import AVFoundation

// MARK: - Voice Input Manager

@MainActor
@Observable
final class VoiceNoteManager {
    var isRecording = false
    var error: String?

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: .current)

    var onTranscription: ((String) -> Void)?
 
    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                completion(status == .authorized)
            }
        }
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition unavailable."
            return
        }

        do {
            // .playAndRecord (not .record) keeps ambient audio alive.
            // .mixWithOthers prevents silencing music or podcasts.
            try AudioSessionManager.shared.configureForVoiceNote()
        } catch {
            self.error = "Microphone unavailable."
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.onTranscription?(text) }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in self.stop() }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            error = nil
        } catch {
            stop()
            self.error = "Could not start recording."
        }
    }

    func stop() {
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
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
                let result = interim
                manager.stop()
                interim = ""
                if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onAppend(result)
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
            if manager.isRecording { manager.stop() }
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
            manager.start()
        } else {
            manager.requestPermission { granted in
                authorized = granted
                if granted { manager.start() }
            }
        }
    }
}
