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
    var expectedSpeakerCount: Int?

    @ObservationIgnored private let recorder: LocalVoiceRecordingService
    @ObservationIgnored private let transcriptionProvider: any TranscriptionProviding
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration: UInt = 0
    @ObservationIgnored private weak var savedStore: MeetingStore?
    @ObservationIgnored private var savedMeetingID: Meeting.ID?

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

    var hasUnsavedRecording: Bool {
        completedRecording != nil || phase == .recording || phase == .paused
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

    var expectedSpeakerCountTitle: String {
        expectedSpeakerCount.map { "\($0) speaker\($0 == 1 ? "" : "s")" } ?? "Automatic"
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
            : "Speaker separation was not available"
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
        let generation = operationGeneration
        phase = .requestingPermission
        let requestedPermissions = await VoiceRecordingPermissionService.request()
        guard generation == operationGeneration, !Task.isCancelled else { return }
        permissions = requestedPermissions
        phase = .idle
    }

    func start() async {
        guard phase != .requestingPermission,
              phase != .recording,
              phase != .paused,
              phase != .processing,
              phase != .saving
        else { return }

        operationGeneration &+= 1
        let generation = operationGeneration
        await requestPermissionsIfNeeded()
        guard generation == operationGeneration, !Task.isCancelled else { return }

        guard permissions.microphone == .ready else {
            phase = .failed(VoiceRecordingError.microphoneDenied.localizedDescription)
            statusMessage = VoiceRecordingError.microphoneDenied.localizedDescription
            return
        }

        do {
            let previousRecording = completedRecording
            let previousJobID = transcriptionJob?.id
            _ = try recorder.start(title: title)
            if let previousRecording {
                RecordingFileStore.deleteFile(
                    named: RecordingFileStore.fileName(for: previousRecording.fileURL)
                )
            }
            if let previousJobID {
                Task { await TranscriptionRetryQueue.shared.remove(id: previousJobID) }
            }
            elapsedSeconds = 0
            inputLevel = 0
            transcript = ""
            transcriptionResult = nil
            completedRecording = nil
            transcriptionJob = nil
            savedStore = nil
            savedMeetingID = nil
            phase = .recording
            statusMessage = "Recording"
            startMetering()
        } catch {
            if completedRecording != nil {
                phase = .readyToSave
                statusMessage = "Couldn't start again. Your previous audio is still ready to save."
            } else {
                phase = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
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
        let generation = operationGeneration
        meterTask?.cancel()
        inputLevel = 0

        do {
            let completed = try recorder.stop()
            completedRecording = completed
            elapsedSeconds = completed.durationSeconds
            transcriptionJob = TranscriptionRetryJob(
                recordingID: completed.id,
                fileName: RecordingFileStore.fileName(for: completed.fileURL),
                expectedSpeakerCount: expectedSpeakerCount
            )

            if let transcriptionJob {
                await TranscriptionRetryQueue.shared.upsert(transcriptionJob)
                guard generation == operationGeneration, !Task.isCancelled else {
                    await TranscriptionRetryQueue.shared.remove(id: transcriptionJob.id)
                    return
                }
            }

            guard !transcriptionProvider.requiresSpeechAuthorization || permissions.speech == .ready else {
                transcript = ""
                phase = .readyToSave
                statusMessage = "Audio saved. Speech permission is needed for a transcript."
                return
            }

            phase = .processing
            statusMessage = "Generating transcript"
            await generateTranscript(for: completed, retrying: false, generation: generation)
        } catch {
            guard generation == operationGeneration, !Task.isCancelled else { return }
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
        guard phase != .processing, phase != .saving else { return }
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

        let generation = operationGeneration
        phase = .processing
        statusMessage = "Retrying transcript"
        await generateTranscript(
            for: completedRecording,
            retrying: true,
            generation: generation
        )
    }

    func save(into store: MeetingStore, linkedMeetingID: Meeting.ID? = nil) async -> Meeting.ID? {
        guard phase != .saving else { return nil }
        guard let completedRecording else {
            phase = .failed(VoiceRecordingError.noRecording.localizedDescription)
            statusMessage = VoiceRecordingError.noRecording.localizedDescription
            return nil
        }

        phase = .saving
        statusMessage = "Saving"

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Voice note" : title
        let validLinkedMeetingID = linkedMeetingID.flatMap { id in
            store.meeting(withID: id) == nil ? nil : id
        }
        let attachment = AudioRecordingAttachment(
            id: completedRecording.id,
            title: cleanTitle,
            createdAt: completedRecording.startedAt,
            durationSeconds: completedRecording.durationSeconds,
            fileName: RecordingFileStore.fileName(for: completedRecording.fileURL),
            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            linkedNote: noteText.trimmingCharacters(in: .whitespacesAndNewlines),
            source: validLinkedMeetingID == nil ? .voiceNote : .noteAttachment,
            fileSizeBytes: completedRecording.fileSizeBytes,
            transcriptionSegments: transcriptionResult?.segments ?? [],
            transcriptionProvider: transcriptionResult?.provider,
            diarizationAvailable: transcriptionResult?.diarizationAvailable ?? false
        )

        let savedID: Meeting.ID
        if let linkedMeetingID = validLinkedMeetingID {
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

        savedStore = store
        savedMeetingID = savedID

        if var job = transcriptionJob,
           job.state != .completed {
            job.meetingID = savedID
            job.expectedSpeakerCount = expectedSpeakerCount
            transcriptionJob = job
            await TranscriptionRetryQueue.shared.upsert(job)
            if let latestJob = transcriptionJob, latestJob.id == job.id {
                if latestJob.state == .completed {
                    await TranscriptionRetryQueue.shared.remove(id: job.id)
                } else if latestJob != job {
                    // Foreground transcription may have changed state while
                    // this save was awaiting queue persistence. The newest
                    // state always wins so a stale `running` receipt cannot
                    // resurrect completed or failed work.
                    await TranscriptionRetryQueue.shared.upsert(latestJob)
                }
            }
        }

        phase = .saved(savedID)
        if transcriptionJob?.state == .completed {
            statusMessage = "Saved with transcript"
        } else {
            statusMessage = validLinkedMeetingID == nil && linkedMeetingID != nil
                ? "Original note unavailable. Saved as a new voice note."
                : "Saved"
            scheduleTranscriptionRecovery(using: store)
        }
        return savedID
    }

    func discard() {
        if case .saved = phase { return }
        discardUnsavedRecording()
    }

    private func discardUnsavedRecording() {
        operationGeneration &+= 1
        let queuedJobID = transcriptionJob?.id
        let completedFileName = completedRecording.map {
            RecordingFileStore.fileName(for: $0.fileURL)
        }
        meterTask?.cancel()
        meterTask = nil
        recorder.discard()
        if let completedFileName {
            RecordingFileStore.deleteFile(named: completedFileName)
        }
        completedRecording = nil
        transcriptionJob = nil
        transcriptionResult = nil
        transcript = ""
        elapsedSeconds = 0
        inputLevel = 0
        savedStore = nil
        savedMeetingID = nil
        phase = .idle
        statusMessage = "Ready to record"
        if let queuedJobID {
            Task { await TranscriptionRetryQueue.shared.remove(id: queuedJobID) }
        }
    }

    private func generateTranscript(
        for completed: CompletedVoiceRecording,
        retrying: Bool,
        generation: UInt
    ) async {
        recorder.configureTranscriptionContext(
            title: title,
            workspace: workspace,
            notes: noteText,
            expectedSpeakerCount: expectedSpeakerCount
        )
        var job = transcriptionJob ?? TranscriptionRetryJob(
            recordingID: completed.id,
            fileName: RecordingFileStore.fileName(for: completed.fileURL),
            expectedSpeakerCount: expectedSpeakerCount
        )
        job.markRunning()
        transcriptionJob = job
        await TranscriptionRetryQueue.shared.upsert(job)
        guard generation == operationGeneration, !Task.isCancelled else {
            await TranscriptionRetryQueue.shared.remove(id: job.id)
            return
        }

        do {
            var result = try await transcriptionProvider.transcribe(audioURL: completed.fileURL)
            guard generation == operationGeneration, !Task.isCancelled else {
                await TranscriptionRetryQueue.shared.remove(id: job.id)
                return
            }
            result.segments = SpeakerIdentityResolver.normalizedSegments(result.segments)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceRecordingError.noTranscription
            }
            transcriptionResult = result
            transcript = result.text

            if let savedMeetingID, let savedStore {
                if savedStore.applyRecoveredTranscript(
                    result,
                    recordingID: completed.id,
                    meetingID: savedMeetingID
                ) {
                    job.markCompleted()
                    transcriptionJob = job
                    await TranscriptionRetryQueue.shared.remove(id: job.id)
                    _ = await MeetingProcessingNotification.sendReady(
                        meetingID: savedMeetingID,
                        title: savedStore.meeting(withID: savedMeetingID)?.title ?? title
                    )
                    statusMessage = "Saved with transcript"
                } else {
                    job.markFailed(VoiceRecordingError.noTranscription.localizedDescription)
                    transcriptionJob = job
                    await TranscriptionRetryQueue.shared.upsert(job)
                    statusMessage = "Saved. Transcript will retry later."
                    scheduleTranscriptionRecovery(using: savedStore)
                }
                return
            }

            job.markCompleted()
            transcriptionJob = job
            await TranscriptionRetryQueue.shared.remove(id: job.id)
            phase = .readyToSave
            let speakerCount = result.distinctSpeakerCount
            if transcript.isEmpty {
                statusMessage = "Audio ready"
            } else if result.diarizationAvailable, speakerCount > 1 {
                statusMessage = result.effectiveSpeakerSeparationConfidence == .strong
                    ? "Transcript ready · \(speakerCount) voice patterns separated"
                    : "Transcript ready · \(speakerCount) likely speakers · review labels"
            } else {
                statusMessage = "Transcript ready via \(result.provider.title) · speaker count unconfirmed"
            }
        } catch is CancellationError {
            guard generation == operationGeneration else {
                await TranscriptionRetryQueue.shared.remove(id: job.id)
                return
            }
            job.markFailed("Transcription was interrupted and will retry later.")
            transcriptionJob = job
            await TranscriptionRetryQueue.shared.upsert(job)
            if savedMeetingID != nil {
                statusMessage = "Saved. Transcript will retry later."
                if let savedStore {
                    scheduleTranscriptionRecovery(using: savedStore)
                }
            } else {
                phase = .readyToSave
                statusMessage = "Audio ready. Transcript was interrupted."
            }
        } catch {
            guard generation == operationGeneration else {
                await TranscriptionRetryQueue.shared.remove(id: job.id)
                return
            }
            job.markFailed(error.localizedDescription)
            transcriptionJob = job
            await TranscriptionRetryQueue.shared.upsert(job)

            if savedMeetingID != nil {
                statusMessage = "Saved. Transcript will retry later."
                if let savedStore {
                    scheduleTranscriptionRecovery(using: savedStore)
                }
                return
            }
            phase = .readyToSave
            statusMessage = retrying
                ? "Transcript retry failed. Audio is still ready to save."
                : "Audio ready. Transcript could not be generated."
        }
    }

    private func scheduleTranscriptionRecovery(using store: MeetingStore) {
        Task { @MainActor [weak store] in
            guard let store else { return }
            await TranscriptionRecoveryCoordinator.shared.processPending(using: store)
        }
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Int(round(self.recorder.currentTime))
                if self.elapsedSeconds != elapsed {
                    self.elapsedSeconds = elapsed
                }
                self.inputLevel = self.recorder.normalizedPower
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
