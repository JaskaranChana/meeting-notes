import AVFoundation
import Foundation
import Speech

struct VoiceRecordingPermissionSnapshot: Equatable {
    var microphone: CapturePermissionState
    var speech: CapturePermissionState

    var isReady: Bool {
        microphone == .ready && speech == .ready
    }

    var isBlocked: Bool {
        microphone == .denied || speech == .denied
    }
}

struct CompletedVoiceRecording {
    var id: UUID
    var title: String
    var fileURL: URL
    var startedAt: Date
    var durationSeconds: Int
    var fileSizeBytes: Int
}

enum TranscriptionProviderKind: String, Codable, Equatable, Sendable {
    case localAppleSpeech
    case localEnhancedSpeech
    case backend

    var title: String {
        switch self {
        case .localAppleSpeech:
            "Apple Speech"
        case .localEnhancedSpeech:
            "Enhanced on-device speech"
        case .backend:
            "Backend"
        }
    }
}

struct TranscriptionSegment: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var speaker: String
    var text: String
    var startTime: TimeInterval?
    var endTime: TimeInterval?
}

struct TranscriptionResult: Codable, Hashable, Sendable {
    var text: String
    var segments: [TranscriptionSegment]
    var provider: TranscriptionProviderKind
    var diarizationAvailable: Bool
    var usedFallback: Bool
}

@MainActor
protocol TranscriptionProviding {
    var requiresSpeechAuthorization: Bool { get }
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

protocol MeetingSummarizing {
    func summarize(meeting: Meeting) async throws -> MeetingIntelligenceReport
}

struct LocalMeetingSummarizer: MeetingSummarizing {
    func summarize(meeting: Meeting) async throws -> MeetingIntelligenceReport {
        MeetingIntelligenceEngine.report(for: meeting)
    }
}

enum TranscriptionJobState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case failed
    case completed

    var title: String {
        switch self {
        case .queued:
            "Queued"
        case .running:
            "Transcribing"
        case .failed:
            "Failed"
        case .completed:
            "Completed"
        }
    }
}

struct TranscriptionRetryJob: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var recordingID: UUID
    var fileName: String
    var attempts = 0
    var state: TranscriptionJobState = .queued
    var lastError: String?
    var meetingID: Meeting.ID?
    var expectedSpeakerCount: Int? = nil
    var nextRetryAt: Date?
    var createdAt = Date()
    var updatedAt = Date()

    var canRetry: Bool {
        attempts < 3 && state != .completed
    }

    mutating func markRunning(now: Date = .now) {
        attempts += 1
        state = .running
        lastError = nil
        nextRetryAt = nil
        updatedAt = now
    }

    mutating func markFailed(_ message: String, now: Date = .now) {
        state = .failed
        lastError = message
        let delay = min(pow(2, Double(max(attempts - 1, 0))) * 30, 3_600)
        nextRetryAt = now.addingTimeInterval(delay)
        updatedAt = now
    }

    mutating func markCompleted(now: Date = .now) {
        state = .completed
        lastError = nil
        nextRetryAt = nil
        updatedAt = now
    }
}

enum VoiceRecordingError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case speechUnavailable
    case recorderUnavailable
    case recordingDidNotStart
    case noRecording
    case noTranscription

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is blocked. Enable it in Settings to record voice notes."
        case .speechDenied:
            "Speech recognition is blocked. You can still record audio, but transcript generation needs speech access."
        case .speechUnavailable:
            "Speech recognition is unavailable on this device right now."
        case .recorderUnavailable:
            "The recorder could not be prepared."
        case .recordingDidNotStart:
            "The recorder did not start. Check your microphone route and try again."
        case .noRecording:
            "No voice recording is ready to save."
        case .noTranscription:
            "No transcript was produced from this recording."
        }
    }
}

enum VoiceRecordingPermissionService {
    static func current() -> VoiceRecordingPermissionSnapshot {
        VoiceRecordingPermissionSnapshot(
            microphone: currentMicrophonePermissionState(),
            speech: speechPermissionState(for: SFSpeechRecognizer.authorizationStatus())
        )
    }

    static func request() async -> VoiceRecordingPermissionSnapshot {
        let microphone = await requestMicrophonePermission()
        let speech = await requestSpeechPermission()
        return VoiceRecordingPermissionSnapshot(microphone: microphone, speech: speech)
    }

    private static func requestSpeechPermission() async -> CapturePermissionState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: speechPermissionState(for: status))
            }
        }
    }

    private static func requestMicrophonePermission() async -> CapturePermissionState {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted ? .ready : .denied)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted ? .ready : .denied)
                }
            }
        }
    }

    private static func speechPermissionState(for status: SFSpeechRecognizerAuthorizationStatus) -> CapturePermissionState {
        switch status {
        case .authorized:
            .ready
        case .denied, .restricted:
            .denied
        case .notDetermined:
            .unknown
        @unknown default:
            .unsupported
        }
    }

    private static func currentMicrophonePermissionState() -> CapturePermissionState {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                .ready
            case .denied:
                .denied
            case .undetermined:
                .unknown
            @unknown default:
                .unsupported
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                .ready
            case .denied:
                .denied
            case .undetermined:
                .unknown
            @unknown default:
                .unsupported
            }
        }
    }
}

@MainActor
final class LocalVoiceRecordingService: NSObject, AVAudioRecorderDelegate, TranscriptionProviding {
    let requiresSpeechAuthorization = true

    private var recorder: AVAudioRecorder?
    private var recordingID: UUID?
    private var startedAt: Date?
    private var title = "Voice note"
    private var transcriptionContext = SpeechRecognitionContext(
        title: "Voice note",
        workspace: "Voice Notes"
    )

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    var currentTime: TimeInterval {
        recorder?.currentTime ?? 0
    }

    var normalizedPower: Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let average = recorder.averagePower(forChannel: 0)
        guard average.isFinite else { return 0 }
        return min(max(Double(average + 55) / 55.0, 0), 1)
    }

    func start(title: String) throws -> URL {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Voice note" : title
        let id = UUID()
        let url = try RecordingFileStore.makeRecordingURL(id: id)

        try AudioSessionManager.shared.configureForVoiceNote()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        guard recorder.prepareToRecord() else {
            throw VoiceRecordingError.recorderUnavailable
        }
        guard recorder.record() else {
            throw VoiceRecordingError.recordingDidNotStart
        }

        recordingID = id
        startedAt = .now
        self.recorder = recorder
        return url
    }

    func pause() {
        recorder?.pause()
    }

    func resume() throws {
        guard let recorder else { throw VoiceRecordingError.noRecording }
        try AudioSessionManager.shared.configureForVoiceNote()
        guard recorder.record() else {
            throw VoiceRecordingError.recordingDidNotStart
        }
    }

    func stop() throws -> CompletedVoiceRecording {
        guard let recorder, let recordingID, let startedAt else {
            throw VoiceRecordingError.noRecording
        }

        let duration = max(1, Int(round(recorder.currentTime)))
        let url = recorder.url
        recorder.stop()
        AudioSessionManager.shared.deactivate()
        RecordingFileStore.protectFile(at: url)

        let completed = CompletedVoiceRecording(
            id: recordingID,
            title: title,
            fileURL: url,
            startedAt: startedAt,
            durationSeconds: duration,
            fileSizeBytes: RecordingFileStore.fileSize(at: url)
        )

        self.recorder = nil
        self.recordingID = nil
        self.startedAt = nil
        return completed
    }

    func discard() {
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        recordingID = nil
        startedAt = nil
        AudioSessionManager.shared.deactivate()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func configureTranscriptionContext(
        title: String,
        workspace: String,
        notes: String,
        localeIdentifier: String? = nil,
        attendees: [String] = [],
        expectedSpeakerCount: Int? = nil
    ) {
        transcriptionContext = SpeechRecognitionContext(
            title: title,
            workspace: workspace,
            objective: "Capture the speaker's exact words clearly.",
            attendees: attendees,
            notes: notes,
            localeIdentifier: SpeechRecognitionSupport.resolvedLocale(
                identifier: localeIdentifier
            ).identifier,
            expectedSpeakerCount: expectedSpeakerCount
        )
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let context = transcriptionContext.title.isEmpty
            ? SpeechRecognitionContext(
                title: title,
                workspace: "Voice Notes",
                objective: "Capture the speaker's exact words clearly."
            )
            : transcriptionContext
        var usedFallback = false
        let baseResult: TranscriptionResult

        if #available(iOS 26.0, *) {
            do {
                baseResult = try await SpeechAnalyzerFileTranscriber.transcribe(
                    audioURL: audioURL,
                    context: context,
                    defaultSpeaker: "Voice note"
                )
                return await LocalSpeakerDiarizationService.shared.enrich(
                    baseResult,
                    audioURL: audioURL,
                    expectedSpeakerCount: context.expectedSpeakerCount
                )
            } catch {
                usedFallback = true
            }
        }

        let legacy = try await transcribeLegacy(
            url: audioURL,
            context: context,
            defaultSpeaker: "Voice note"
        )
        let result = TranscriptionResult(
            text: legacy.text,
            segments: legacy.segments,
            provider: .localAppleSpeech,
            diarizationAvailable: false,
            usedFallback: usedFallback
        )
        return await LocalSpeakerDiarizationService.shared.enrich(
            result,
            audioURL: audioURL,
            expectedSpeakerCount: context.expectedSpeakerCount
        )
    }

    func transcribeMeetingAudio(
        audioURL: URL,
        context: SpeechRecognitionContext
    ) async throws -> TranscriptionResult {
        transcriptionContext = context
        var result = try await transcribe(audioURL: audioURL)
        if !result.diarizationAvailable {
            result.segments = result.segments.map { segment in
                var revised = segment
                revised.speaker = "Meeting"
                return revised
            }
        }
        return result
    }

    fileprivate struct LegacyFileTranscription {
        var text: String
        var segments: [TranscriptionSegment]
    }

    private func transcribeLegacy(
        url: URL,
        context: SpeechRecognitionContext,
        defaultSpeaker: String
    ) async throws -> LegacyFileTranscription {
        guard let recognizer = SpeechRecognitionSupport.makeLegacyRecognizer(
            locale: context.recognitionLocale
        ), recognizer.isAvailable else {
            throw VoiceRecordingError.speechUnavailable
        }

        do {
            let transcript = try await transcribe(
                url: url,
                recognizer: recognizer,
                requiresOnDevice: recognizer.supportsOnDeviceRecognition,
                context: context,
                defaultSpeaker: defaultSpeaker
            )
            if !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return transcript
            }
        } catch {
            if recognizer.supportsOnDeviceRecognition {
                return try await transcribe(
                    url: url,
                    recognizer: recognizer,
                    requiresOnDevice: false,
                    context: context,
                    defaultSpeaker: defaultSpeaker
                )
            }
            throw error
        }

        throw VoiceRecordingError.noTranscription
    }

    private func transcribe(
        url: URL,
        recognizer: SFSpeechRecognizer,
        requiresOnDevice: Bool,
        context: SpeechRecognitionContext,
        defaultSpeaker: String
    ) async throws -> LegacyFileTranscription {
        let request = SFSpeechURLRecognitionRequest(url: url)
        SpeechRecognitionSupport.configureLegacyRequest(
            request,
            recognizer: recognizer,
            context: context,
            reportsPartialResults: true
        )
        request.requiresOnDeviceRecognition = requiresOnDevice
        let timeout = transcriptionTimeout(for: url)

        return try await withCheckedThrowingContinuation { continuation in
            let state = LegacyTranscriptionCompletionState()

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let transcription = result?.bestTranscription {
                    state.update(Self.legacyPayload(
                        from: transcription,
                        defaultSpeaker: defaultSpeaker
                    ))
                }

                if let result, result.isFinal {
                    let completion = state.claim(Self.legacyPayload(
                        from: result.bestTranscription,
                        defaultSpeaker: defaultSpeaker
                    ))
                    guard completion.claimed else { return }
                    continuation.resume(returning: completion.payload)
                    return
                }

                if let error {
                    let completion = state.claim()
                    guard completion.claimed else { return }
                    if completion.payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: completion.payload)
                    }
                }
            }

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                let completion = state.claim()
                guard completion.claimed else { return }
                task.cancel()
                if completion.payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: VoiceRecordingError.noTranscription)
                } else {
                    continuation.resume(returning: completion.payload)
                }
            }
        }
    }

    private static func legacyPayload(
        from transcription: SFTranscription,
        defaultSpeaker: String
    ) -> LegacyFileTranscription {
        let segments = transcription.segments.compactMap { segment -> TranscriptionSegment? in
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptionSegment(
                speaker: defaultSpeaker,
                text: text,
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration
            )
        }
        return LegacyFileTranscription(
            text: transcription.formattedString,
            segments: segments
        )
    }

    private func transcriptionTimeout(for url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return 90
        }
        let duration = Double(file.length) / file.fileFormat.sampleRate
        return min(max((duration * 2) + 20, 60), 600)
    }
}

private final class LegacyTranscriptionCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private var latestPayload = LocalVoiceRecordingService.LegacyFileTranscription(
        text: "",
        segments: []
    )

    func update(_ payload: LocalVoiceRecordingService.LegacyFileTranscription) {
        lock.lock()
        latestPayload = payload
        lock.unlock()
    }

    func claim(
        _ payload: LocalVoiceRecordingService.LegacyFileTranscription? = nil
    ) -> (claimed: Bool, payload: LocalVoiceRecordingService.LegacyFileTranscription) {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else { return (false, latestPayload) }
        if let payload {
            latestPayload = payload
        }
        didComplete = true
        return (true, latestPayload)
    }
}
