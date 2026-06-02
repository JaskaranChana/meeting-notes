import Foundation
import Observation

enum VoiceRecorderPhase: Equatable {
    case idle
    case requestingPermission
    case recording
    case paused
    case processing
    case readyToSave
    case saving
    case saved(Meeting.ID)
    case failed(String)
}

@MainActor
@Observable
final class VoiceRecorderViewModel {
    var title = "Voice note"
    var workspace = "Voice Notes"
    var noteText = ""
    var transcript = ""
    var elapsedSeconds = 0
    var inputLevel: Double = 0
    var phase: VoiceRecorderPhase = .idle
    var permissions = VoiceRecordingPermissionService.current()
    var statusMessage = "Ready to record"
    var completedRecording: CompletedVoiceRecording?

    @ObservationIgnored private let recorder = LocalVoiceRecordingService()
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    var canRecord: Bool {
        permissions.microphone != .denied && permissions.microphone != .unsupported
    }

    var canSave: Bool {
        completedRecording != nil
    }

    var isRecording: Bool {
        phase == .recording
    }

    var elapsedLabel: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var permissionTitle: String {
        if permissions.microphone == .denied { return "Microphone blocked" }
        if permissions.speech == .denied { return "Speech blocked" }
        if permissions.microphone == .unknown || permissions.speech == .unknown { return "Permissions needed" }
        if permissions.speech == .unsupported { return "Transcription unavailable" }
        return "Ready"
    }

    func refreshPermissions() {
        permissions = VoiceRecordingPermissionService.current()
    }

    func requestPermissionsIfNeeded() async {
        guard permissions.microphone == .unknown || permissions.speech == .unknown else { return }
        phase = .requestingPermission
        permissions = await VoiceRecordingPermissionService.request()
        phase = .idle
    }

    func start() async {
        await requestPermissionsIfNeeded()

        guard permissions.microphone == .ready else {
            phase = .failed(VoiceRecordingError.microphoneDenied.localizedDescription)
            statusMessage = VoiceRecordingError.microphoneDenied.localizedDescription
            return
        }

        do {
            _ = try recorder.start(title: title)
            elapsedSeconds = 0
            inputLevel = 0
            transcript = ""
            completedRecording = nil
            phase = .recording
            statusMessage = "Recording"
            startMetering()
        } catch {
            phase = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func pause() {
        guard phase == .recording else { return }
        recorder.pause()
        meterTask?.cancel()
        phase = .paused
        statusMessage = "Paused"
    }

    func resume() {
        guard phase == .paused else { return }
        do {
            try recorder.resume()
            phase = .recording
            statusMessage = "Recording"
            startMetering()
        } catch {
            phase = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func pauseForInterruption(_ message: String) {
        guard phase == .recording else { return }
        pause()
        statusMessage = message
    }

    func markReadyToResume(_ message: String) {
        guard phase == .paused else { return }
        statusMessage = message
    }

    func stopAndTranscribe() async {
        guard phase == .recording || phase == .paused else { return }
        meterTask?.cancel()
        inputLevel = 0

        do {
            let completed = try recorder.stop()
            completedRecording = completed
            elapsedSeconds = completed.durationSeconds

            guard permissions.speech == .ready else {
                transcript = ""
                phase = .readyToSave
                statusMessage = "Audio saved. Speech permission is needed for a transcript."
                return
            }

            phase = .processing
            statusMessage = "Generating transcript"
            transcript = try await recorder.transcribe(url: completed.fileURL)
            phase = .readyToSave
            statusMessage = transcript.isEmpty ? "Audio ready" : "Transcript ready"
        } catch {
            if completedRecording != nil {
                phase = .readyToSave
                statusMessage = "Audio ready. Transcript could not be generated."
            } else {
                phase = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    func save(into store: MeetingStore, linkedMeetingID: Meeting.ID? = nil) async -> Meeting.ID? {
        guard let completedRecording else {
            phase = .failed(VoiceRecordingError.noRecording.localizedDescription)
            statusMessage = VoiceRecordingError.noRecording.localizedDescription
            return nil
        }

        phase = .saving
        statusMessage = "Saving"

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Voice note" : title
        let attachment = AudioRecordingAttachment(
            id: completedRecording.id,
            title: cleanTitle,
            createdAt: completedRecording.startedAt,
            durationSeconds: completedRecording.durationSeconds,
            fileName: RecordingFileStore.fileName(for: completedRecording.fileURL),
            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            linkedNote: noteText.trimmingCharacters(in: .whitespacesAndNewlines),
            source: linkedMeetingID == nil ? .voiceNote : .noteAttachment,
            fileSizeBytes: completedRecording.fileSizeBytes
        )

        let savedID: Meeting.ID
        if let linkedMeetingID {
            store.attachVoiceRecording(attachment, to: linkedMeetingID, appendTranscriptToNotes: true)
            savedID = linkedMeetingID
        } else {
            savedID = await store.addVoiceRecording(
                title: cleanTitle,
                workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Voice Notes" : workspace,
                notes: noteText,
                recording: attachment
            )
        }

        phase = .saved(savedID)
        statusMessage = "Saved"
        return savedID
    }

    func discard() {
        meterTask?.cancel()
        recorder.discard()
        completedRecording = nil
        elapsedSeconds = 0
        inputLevel = 0
        phase = .idle
        statusMessage = "Ready to record"
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsedSeconds = Int(round(self.recorder.currentTime))
                self.inputLevel = self.recorder.normalizedPower
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
