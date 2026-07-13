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
    case backend

    var title: String {
        switch self {
        case .localAppleSpeech:
            "Apple Speech"
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

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let text = try await transcribe(url: audioURL)
        let lines = SpeakerTranscriptParser.lines(
            from: text,
            defaultSpeaker: "Voice note",
            defaultRole: "Local transcript"
        )
        return TranscriptionResult(
            text: text,
            segments: lines.map {
                TranscriptionSegment(speaker: $0.speaker, text: $0.text, startTime: nil, endTime: nil)
            },
            provider: .localAppleSpeech,
            diarizationAvailable: false,
            usedFallback: false
        )
    }

    func transcribe(url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            throw VoiceRecordingError.speechUnavailable
        }

        do {
            let transcript = try await transcribe(url: url, recognizer: recognizer, requiresOnDevice: recognizer.supportsOnDeviceRecognition)
            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return transcript
            }
        } catch {
            if recognizer.supportsOnDeviceRecognition {
                return try await transcribe(url: url, recognizer: recognizer, requiresOnDevice: false)
            }
            throw error
        }

        throw VoiceRecordingError.noTranscription
    }

    private func transcribe(
        url: URL,
        recognizer: SFSpeechRecognizer,
        requiresOnDevice: Bool
    ) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = requiresOnDevice

        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            let task = recognizer.recognitionTask(with: request) { result, error in
                if didResume { return }

                if let result, result.isFinal {
                    didResume = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                    return
                }

                if let error {
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(45))
                guard !didResume else { return }
                didResume = true
                task.cancel()
                continuation.resume(throwing: VoiceRecordingError.noTranscription)
            }
        }
    }
}
