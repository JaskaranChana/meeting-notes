import Foundation
import OSLog

private let productionServicesLog = Logger(
    subsystem: "ai.scribeflow.app",
    category: "ProductionServices"
)

struct BackendConfiguration: Equatable, Sendable {
    static let baseURLKey = "SCRIBEFLOW_API_BASE_URL"
    static let transcriptionPathKey = "SCRIBEFLOW_TRANSCRIPTION_PATH"
    static let authenticationRequiredKey = "SCRIBEFLOW_API_REQUIRES_AUTH"

    let baseURL: URL
    let transcriptionPath: String
    let requiresAuthentication: Bool
    let requestTimeout: TimeInterval

    var transcriptionURL: URL {
        URL(string: transcriptionPath, relativeTo: baseURL)?.absoluteURL
            ?? baseURL.appendingPathComponent("v1/transcriptions")
    }

    static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BackendConfiguration? {
        let rawBaseURL = environment[baseURLKey]
            ?? bundle.object(forInfoDictionaryKey: baseURLKey) as? String
        guard let rawBaseURL = rawBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBaseURL.isEmpty,
              let baseURL = URL(string: rawBaseURL),
              isAllowed(baseURL)
        else { return nil }

        let rawPath = environment[transcriptionPathKey]
            ?? bundle.object(forInfoDictionaryKey: transcriptionPathKey) as? String
            ?? "/v1/transcriptions"
        let path = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
        let requiresAuthentication = environment[authenticationRequiredKey]
            .flatMap(Bool.init)
            ?? bundle.object(forInfoDictionaryKey: authenticationRequiredKey) as? Bool
            ?? true

        return BackendConfiguration(
            baseURL: baseURL,
            transcriptionPath: path,
            requiresAuthentication: requiresAuthentication,
            requestTimeout: 180
        )
    }

    private static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return false
        }
        if scheme == "https" { return true }
        #if DEBUG
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1")
        #else
        return false
        #endif
    }
}

enum ProductionServiceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case authenticationRequired
    case recordingMissing
    case recordingTooLarge
    case insufficientTemporaryStorage
    case invalidResponse
    case invalidPayload
    case server(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "The production service is not configured for this build."
        case .authenticationRequired:
            "Your secure session is missing or expired. Sign in again and retry."
        case .recordingMissing:
            "The recording is no longer available on this device."
        case .recordingTooLarge:
            "This recording is too large to upload. Keep it locally or split it into smaller captures."
        case .insufficientTemporaryStorage:
            "There isn’t enough free space to prepare this recording for upload. Free some storage or keep the capture on device."
        case .invalidResponse, .invalidPayload:
            "The transcription service returned an unreadable response."
        case .server(_, let message):
            message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "The transcription service is temporarily unavailable."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .server(let statusCode, _):
            statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        case .invalidResponse:
            true
        case .notConfigured, .authenticationRequired, .recordingMissing,
             .recordingTooLarge, .insufficientTemporaryStorage, .invalidPayload:
            false
        }
    }
}

protocol BackendTokenProviding: Sendable {
    func validAccessToken() async -> String?
}

actor KeychainBackendTokenProvider: BackendTokenProviding {
    private let sessionStore: AuthSessionStoring

    init(sessionStore: AuthSessionStoring = KeychainAuthSessionStore()) {
        self.sessionStore = sessionStore
    }

    func validAccessToken() async -> String? {
        guard let session = try? sessionStore.loadSession(),
              !session.isExpired,
              session.kind.canAuthenticateBackend
        else { return nil }
        return session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

protocol TranscriptionAPIClient: Sendable {
    func transcribe(audioURL: URL, idempotencyKey: String) async throws -> TranscriptionResult
}

private struct BackendTranscriptionResponse: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        let speaker: String?
        let text: String
        let startTime: TimeInterval?
        let endTime: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case speaker
            case text
            case startTime
            case endTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            startTime = try container.decodeIfPresent(TimeInterval.self, forKey: .startTime)
            endTime = try container.decodeIfPresent(TimeInterval.self, forKey: .endTime)
            if let label = try? container.decodeIfPresent(String.self, forKey: .speaker) {
                speaker = label
            } else if let label = try? container.decodeIfPresent(Int.self, forKey: .speaker) {
                speaker = String(label)
            } else if let label = try? container.decodeIfPresent(Double.self, forKey: .speaker) {
                speaker = String(Int(label))
            } else {
                speaker = nil
            }
        }
    }

    let text: String?
    let segments: [Segment]?
    let diarizationAvailable: Bool?
}

actor URLSessionTranscriptionAPIClient: TranscriptionAPIClient {
    private static let maximumUploadBytes = 750 * 1_024 * 1_024

    private let configuration: BackendConfiguration
    private let tokenProvider: BackendTokenProviding
    private let session: URLSession
    private let uploadBuilder = MultipartAudioUploadBuilder()

    init(
        configuration: BackendConfiguration,
        tokenProvider: BackendTokenProviding = KeychainBackendTokenProvider(),
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        if let session {
            self.session = session
        } else {
            let urlConfiguration = URLSessionConfiguration.ephemeral
            urlConfiguration.waitsForConnectivity = true
            urlConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
            urlConfiguration.timeoutIntervalForResource = configuration.requestTimeout
            urlConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: urlConfiguration)
        }
    }

    func transcribe(audioURL: URL, idempotencyKey: String) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ProductionServiceError.recordingMissing
        }
        let fileSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= Self.maximumUploadBytes else {
            throw ProductionServiceError.recordingTooLarge
        }

        return try await RetryPolicy.withBackoff(
            attempts: 3,
            initialDelaySeconds: 0.8,
            maxDelaySeconds: 6,
            retryableCheck: { error in
                if let serviceError = error as? ProductionServiceError {
                    return serviceError.isRetryable
                }
                if let urlError = error as? URLError {
                    return urlError.code != .cancelled
                        && urlError.code != .userAuthenticationRequired
                        && urlError.code != .userCancelledAuthentication
                }
                return false
            }
        ) { [self] in
            try await performTranscription(audioURL: audioURL, idempotencyKey: idempotencyKey)
        }
    }

    private func performTranscription(audioURL: URL, idempotencyKey: String) async throws -> TranscriptionResult {
        let accessToken: String?
        if configuration.requiresAuthentication {
            guard let token = await tokenProvider.validAccessToken() else {
                throw ProductionServiceError.authenticationRequired
            }
            accessToken = token
        } else {
            accessToken = nil
        }

        let boundary = "Scribeflow-\(UUID().uuidString)"
        let uploadURL = try await uploadBuilder.build(
            audioURL: audioURL,
            boundary: boundary,
            fields: [
                "diarization": "true",
                "speaker_labels": "true"
            ]
        )
        defer { try? FileManager.default.removeItem(at: uploadURL) }

        var request = URLRequest(url: configuration.transcriptionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("Scribeflow-iOS", forHTTPHeaderField: "X-Scribeflow-Client")

        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.upload(for: request, fromFile: uploadURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProductionServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw ProductionServiceError.server(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(BackendTranscriptionResponse.self, from: data) else {
            throw ProductionServiceError.invalidPayload
        }

        let rawSegments = (payload.segments ?? []).compactMap { segment -> TranscriptionSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptionSegment(
                speaker: segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Speaker 1",
                text: text,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }
        let segments = SpeakerIdentityResolver.normalizedSegments(rawSegments)
        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? segments.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { throw ProductionServiceError.invalidPayload }
        let distinctSpeakers = Set(segments.map { SpeakerIdentityResolver.canonicalKey(for: $0.speaker) }).count

        return TranscriptionResult(
            text: text,
            segments: segments,
            provider: .backend,
            diarizationAvailable: payload.diarizationAvailable ?? (distinctSpeakers > 1),
            usedFallback: false
        )
    }
}

private actor MultipartAudioUploadBuilder {
    private static let temporaryFilePrefix = "scribeflow-upload-"
    private static let minimumFreeSpaceBuffer: Int64 = 64 * 1_024 * 1_024

    func build(audioURL: URL, boundary: String, fields: [String: String]) throws -> URL {
        let manager = FileManager.default
        removeStaleTemporaryUploads(using: manager)
        let audioBytes = Int64(
            (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        if let available = try? manager.temporaryDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           available < audioBytes + Self.minimumFreeSpaceBuffer {
            throw ProductionServiceError.insufficientTemporaryStorage
        }

        let uploadURL = manager.temporaryDirectory
            .appendingPathComponent("\(Self.temporaryFilePrefix)\(UUID().uuidString).multipart")
        guard manager.createFile(atPath: uploadURL.path, contents: nil) else {
            throw ProductionServiceError.recordingMissing
        }

        do {
            let input = try FileHandle(forReadingFrom: audioURL)
            let output = try FileHandle(forWritingTo: uploadURL)
            defer {
                try? input.close()
                try? output.close()
            }

            for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                let safeName = sanitized(name)
                let safeValue = value
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                let field = """
                --\(boundary)\r
                Content-Disposition: form-data; name="\(safeName)"\r
                \r
                \(safeValue)\r

                """
                try output.write(contentsOf: Data(field.utf8))
            }

            let fileName = audioURL.lastPathComponent
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            let header = """
            --\(boundary)\r
            Content-Disposition: form-data; name="audio"; filename="\(fileName)"\r
            Content-Type: \(mimeType(for: audioURL.pathExtension))\r
            \r

            """
            try output.write(contentsOf: Data(header.utf8))

            while let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }

            let footer = "\r\n--\(boundary)--\r\n"
            try output.write(contentsOf: Data(footer.utf8))
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: uploadURL.path
            )
            return uploadURL
        } catch {
            try? manager.removeItem(at: uploadURL)
            throw error
        }
    }

    private func removeStaleTemporaryUploads(using manager: FileManager) {
        let cutoff = Date.now.addingTimeInterval(-60 * 60)
        guard let files = try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(Self.temporaryFilePrefix) {
            guard let modified = try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else {
                try? manager.removeItem(at: file)
                continue
            }
            if modified < cutoff {
                try? manager.removeItem(at: file)
            }
        }
    }

    private func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "caf": "audio/x-caf"
        case "mp3": "audio/mpeg"
        default: "audio/mp4"
        }
    }
}

@MainActor
final class ProductionTranscriptionProvider: TranscriptionProviding {
    let requiresSpeechAuthorization = false

    private let client: TranscriptionAPIClient
    private let fallback: any TranscriptionProviding

    init(client: TranscriptionAPIClient, fallback: any TranscriptionProviding) {
        self.client = client
        self.fallback = fallback
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        do {
            return try await client.transcribe(
                audioURL: audioURL,
                idempotencyKey: audioURL.deletingPathExtension().lastPathComponent
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            productionServicesLog.notice(
                "Backend transcription unavailable; using local fallback: \(error.localizedDescription, privacy: .public)"
            )
            var localResult = try await fallback.transcribe(audioURL: audioURL)
            localResult.usedFallback = true
            return localResult
        }
    }
}

@MainActor
enum TranscriptionProviderFactory {
    static let remoteTranscriptionConsentKey = "scribeflow.remoteTranscriptionEnabled"

    static var isBackendConfigured: Bool {
        BackendConfiguration.current() != nil
    }

    static var isRemoteTranscriptionEnabled: Bool {
        isBackendConfigured && UserDefaults.standard.bool(forKey: remoteTranscriptionConsentKey)
    }

    static func make(localFallback: LocalVoiceRecordingService) -> any TranscriptionProviding {
        guard isRemoteTranscriptionEnabled,
              let configuration = BackendConfiguration.current()
        else { return localFallback }
        return ProductionTranscriptionProvider(
            client: URLSessionTranscriptionAPIClient(configuration: configuration),
            fallback: localFallback
        )
    }
}

actor TranscriptionRetryQueue {
    static let shared = TranscriptionRetryQueue()

    private let folderURL: URL
    private let fileURL: URL
    private var jobs: [TranscriptionRetryJob] = []
    private var hasLoaded = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = base.appendingPathComponent("Scribeflow", isDirectory: true)
        folderURL = folder
        fileURL = folder.appendingPathComponent("transcription-queue.json")
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        try? FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([TranscriptionRetryJob].self, from: data) {
            jobs = decoded
            var recoveredInterruptedJob = false
            for index in jobs.indices where jobs[index].state == .running {
                // A running state cannot survive process termination. Make it
                // immediately retryable on the next launch instead of leaving
                // a job permanently stuck or starting duplicate work.
                jobs[index].state = .failed
                jobs[index].lastError = "The previous transcription was interrupted and will retry."
                jobs[index].nextRetryAt = nil
                jobs[index].updatedAt = .now
                recoveredInterruptedJob = true
            }
            if recoveredInterruptedJob {
                persist()
            }
        }
    }

    func upsert(_ job: TranscriptionRetryJob) {
        loadIfNeeded()
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        persist()
    }

    func enqueueFresh(_ job: TranscriptionRetryJob) {
        loadIfNeeded()
        jobs.removeAll {
            $0.recordingID == job.recordingID && $0.meetingID == job.meetingID
        }
        jobs.append(job)
        persist()
    }

    func remove(id: TranscriptionRetryJob.ID) {
        loadIfNeeded()
        jobs.removeAll { $0.id == id }
        persist()
    }

    func readyJobs(now: Date = .now) -> [TranscriptionRetryJob] {
        loadIfNeeded()
        return jobs
            .filter { job in
                job.meetingID != nil
                    && job.canRetry
                    && job.state != .running
                    && job.state != .completed
                    && (job.nextRetryAt == nil || job.nextRetryAt! <= now)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func nextRetryDate(now: Date = .now) -> Date? {
        loadIfNeeded()
        return jobs.lazy
            .filter {
                $0.meetingID != nil
                    && $0.canRetry
                    && $0.state != .running
                    && $0.state != .completed
            }
            .map { $0.nextRetryAt ?? now }
            .min()
    }

    func job(id: TranscriptionRetryJob.ID) -> TranscriptionRetryJob? {
        loadIfNeeded()
        return jobs.first { $0.id == id }
    }

    func clear() {
        hasLoaded = true
        jobs.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(jobs) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }
}

@MainActor
final class TranscriptionRecoveryCoordinator {
    static let shared = TranscriptionRecoveryCoordinator()

    private var isProcessing = false
    private var retryWakeTask: Task<Void, Never>?

    enum RequestOutcome: Equatable {
        case completed
        case queued
        case failed(String)
    }

    func requestRetranscription(
        recording: AudioRecordingAttachment,
        meetingID: Meeting.ID,
        expectedSpeakerCount: Int?,
        using store: MeetingStore
    ) async -> RequestOutcome {
        let audioURL = RecordingFileStore.url(for: recording.fileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return .failed("The original audio file is no longer available.")
        }

        let job = TranscriptionRetryJob(
            recordingID: recording.id,
            fileName: recording.fileName,
            meetingID: meetingID,
            expectedSpeakerCount: expectedSpeakerCount
        )
        await TranscriptionRetryQueue.shared.enqueueFresh(job)

        guard !isProcessing else { return .queued }
        await processPending(using: store)

        if let pending = await TranscriptionRetryQueue.shared.job(id: job.id) {
            if pending.state == .failed {
                return .failed(pending.lastError ?? "The transcript could not be rebuilt yet.")
            }
            return .queued
        }

        let completed = store.meeting(withID: meetingID)?.audioRecordings.first {
            $0.id == recording.id
        }?.hasTranscript == true
        return completed
            ? .completed
            : .failed("The recording finished without a usable transcript.")
    }

    func processPending(using store: MeetingStore) async {
        guard !isProcessing else { return }
        isProcessing = true
        retryWakeTask?.cancel()
        retryWakeTask = nil
        defer { isProcessing = false }

        let queue = TranscriptionRetryQueue.shared
        while !Task.isCancelled {
            let jobs = await queue.readyJobs()
            guard !jobs.isEmpty else { break }

            for var job in jobs {
                guard !Task.isCancelled else { break }
                guard let meetingID = job.meetingID,
                      let meeting = store.meeting(withID: meetingID),
                      meeting.audioRecordings.contains(where: { $0.id == job.recordingID })
                else {
                    await queue.remove(id: job.id)
                    continue
                }

                let audioURL = RecordingFileStore.url(for: job.fileName)
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    await queue.remove(id: job.id)
                    continue
                }

                let preferredLocale = UserDefaults.standard.string(
                    forKey: SpeechRecognitionSupport.localePreferenceKey
                )
                let context = SpeechRecognitionContext(
                    title: meeting.title,
                    workspace: meeting.workspace,
                    objective: meeting.objective,
                    attendees: meeting.attendees,
                    notes: meeting.trustedSourceNotes,
                    templateTitle: meeting.selectedTemplate.title,
                    templateGuidance: meeting.selectedTemplate.aiHint,
                    vocabulary: meeting.attendees,
                    localeIdentifier: preferredLocale?.isEmpty == false ? preferredLocale : nil,
                    expectedSpeakerCount: job.expectedSpeakerCount
                )

                job.markRunning()
                await queue.upsert(job)
                do {
                    let result = try await EnhancedMeetingTranscriptionService.shared.transcribe(
                        audioURL: audioURL,
                        context: context,
                        liveWordCount: 0
                    )
                    if store.applyRecoveredTranscript(
                        result,
                        recordingID: job.recordingID,
                        meetingID: meetingID
                    ) {
                        job.markCompleted()
                        await queue.remove(id: job.id)
                        _ = await MeetingProcessingNotification.sendReady(
                            meetingID: meetingID,
                            title: meeting.title
                        )
                    } else {
                        job.markFailed(VoiceRecordingError.noTranscription.localizedDescription)
                        await queue.upsert(job)
                    }
                } catch is CancellationError {
                    job.markFailed("Transcription was interrupted and will retry later.")
                    await queue.upsert(job)
                    break
                } catch {
                    job.markFailed(error.localizedDescription)
                    await queue.upsert(job)
                }
            }
        }

        await EnhancedMeetingTranscriptionService.shared.releaseModels()
        await scheduleNextRetry(using: store)
    }

    private func scheduleNextRetry(using store: MeetingStore) async {
        guard let retryDate = await TranscriptionRetryQueue.shared.nextRetryDate() else { return }
        let delay = max(1, retryDate.timeIntervalSinceNow)
        retryWakeTask = Task { @MainActor [weak self, weak store] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let store else { return }
            self.retryWakeTask = nil
            await self.processPending(using: store)
        }
    }
}
