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
    var transcriptionJob: TranscriptionRetryJob?
    var transcriptionResult: TranscriptionResult?

    @ObservationIgnored private let recorder: LocalVoiceRecordingService
    @ObservationIgnored private let transcriptionProvider: any TranscriptionProviding
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    init(
        recorder: LocalVoiceRecordingService? = nil,
        transcriptionProvider: (any TranscriptionProviding)? = nil
    ) {
        let recorder = recorder ?? LocalVoiceRecordingService()
        self.recorder = recorder
        self.transcriptionProvider = transcriptionProvider
            ?? TranscriptionProviderFactory.make(localFallback: recorder)
    }

    var canRecord: Bool {
        permissions.microphone != .denied && permissions.microphone != .unsupported
    }

    var canSave: Bool {
        completedRecording != nil
    }

    var canRetryTranscript: Bool {
        completedRecording != nil
            && (!transcriptionProvider.requiresSpeechAuthorization || permissions.speech == .ready)
            && phase != .processing
            && phase != .saving
            && (transcriptionJob?.canRetry ?? true)
    }

    var isRecording: Bool {
        phase == .recording
    }

    var elapsedLabel: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var transcriptionJobStatusText: String? {
        guard let transcriptionJob else { return nil }
        switch transcriptionJob.state {
        case .queued:
            return "Transcript queued"
        case .running:
            return "Transcript attempt \(transcriptionJob.attempts)"
        case .failed:
            return transcriptionJob.lastError.map { "Transcript failed: \($0)" } ?? "Transcript failed"
        case .completed:
            return "Transcript completed"
        }
    }

    var speakerReadText: String? {
        guard let transcriptionResult, !transcriptionResult.segments.isEmpty else { return nil }
        let count = Set(transcriptionResult.segments.map {
            SpeakerIdentityResolver.canonicalKey(for: $0.speaker)
        }).filter { !$0.isEmpty }.count
        guard count > 0 else { return nil }
        return transcriptionResult.diarizationAvailable
            ? "\(count) voice\(count == 1 ? "" : "s") separated"
            : "Single speaker track"
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
            transcriptionResult = nil
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
            transcriptionJob = TranscriptionRetryJob(
                recordingID: completed.id,
                fileName: RecordingFileStore.fileName(for: completed.fileURL)
            )

            if let transcriptionJob, TranscriptionProviderFactory.isRemoteTranscriptionEnabled {
                await TranscriptionRetryQueue.shared.upsert(transcriptionJob)
            }

            guard !transcriptionProvider.requiresSpeechAuthorization || permissions.speech == .ready else {
                transcript = ""
                phase = .readyToSave
                statusMessage = "Audio saved. Speech permission is needed for a transcript."
                return
            }

            phase = .processing
            statusMessage = "Generating transcript"
            await generateTranscript(for: completed, retrying: false)
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

    func retryTranscript() async {
        guard let completedRecording else {
            phase = .failed(VoiceRecordingError.noRecording.localizedDescription)
            statusMessage = VoiceRecordingError.noRecording.localizedDescription
            return
        }

        refreshPermissions()
        guard !transcriptionProvider.requiresSpeechAuthorization || permissions.speech == .ready else {
            phase = .readyToSave
            statusMessage = "Speech permission is needed to retry transcription."
            return
        }
        guard transcriptionJob?.canRetry ?? true else {
            phase = .readyToSave
            statusMessage = "Transcript retry limit reached. Audio is still ready to save."
            return
        }

        phase = .processing
        statusMessage = "Retrying transcript"
        await generateTranscript(for: completedRecording, retrying: true)
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
            fileSizeBytes: completedRecording.fileSizeBytes,
            transcriptionSegments: transcriptionResult?.segments ?? [],
            transcriptionProvider: transcriptionResult?.provider,
            diarizationAvailable: transcriptionResult?.diarizationAvailable ?? false
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

        if var job = transcriptionJob,
           job.state != .completed,
           TranscriptionProviderFactory.isRemoteTranscriptionEnabled {
            job.meetingID = savedID
            transcriptionJob = job
            await TranscriptionRetryQueue.shared.upsert(job)
        }

        phase = .saved(savedID)
        statusMessage = "Saved"
        return savedID
    }

    func discard() {
        let queuedJobID = transcriptionJob?.id
        meterTask?.cancel()
        recorder.discard()
        completedRecording = nil
        transcriptionJob = nil
        transcriptionResult = nil
        elapsedSeconds = 0
        inputLevel = 0
        phase = .idle
        statusMessage = "Ready to record"
        if let queuedJobID {
            Task { await TranscriptionRetryQueue.shared.remove(id: queuedJobID) }
        }
    }

    private func generateTranscript(for completed: CompletedVoiceRecording, retrying: Bool) async {
        var job = transcriptionJob ?? TranscriptionRetryJob(
            recordingID: completed.id,
            fileName: RecordingFileStore.fileName(for: completed.fileURL)
        )
        job.markRunning()
        transcriptionJob = job
        if TranscriptionProviderFactory.isRemoteTranscriptionEnabled {
            await TranscriptionRetryQueue.shared.upsert(job)
        }

        do {
            var result = try await transcriptionProvider.transcribe(audioURL: completed.fileURL)
            result.segments = SpeakerIdentityResolver.normalizedSegments(result.segments)
            transcriptionResult = result
            transcript = result.text
            job.markCompleted()
            transcriptionJob = job
            if TranscriptionProviderFactory.isRemoteTranscriptionEnabled {
                await TranscriptionRetryQueue.shared.remove(id: job.id)
            }
            phase = .readyToSave
            let speakerCount = Set(result.segments.map {
                SpeakerIdentityResolver.canonicalKey(for: $0.speaker)
            }).filter { !$0.isEmpty }.count
            if transcript.isEmpty {
                statusMessage = "Audio ready"
            } else if result.diarizationAvailable, speakerCount > 0 {
                statusMessage = "Transcript ready · \(speakerCount) voice\(speakerCount == 1 ? "" : "s") separated"
            } else {
                statusMessage = "Transcript ready via \(result.provider.title) · single speaker track"
            }
        } catch {
            job.markFailed(error.localizedDescription)
            transcriptionJob = job
            if TranscriptionProviderFactory.isRemoteTranscriptionEnabled {
                await TranscriptionRetryQueue.shared.upsert(job)
            }
            phase = .readyToSave
            statusMessage = retrying
                ? "Transcript retry failed. Audio is still ready to save."
                : "Audio ready. Transcript could not be generated."
        }
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
