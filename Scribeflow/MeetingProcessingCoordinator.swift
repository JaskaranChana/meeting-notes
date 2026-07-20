import BackgroundTasks
import AVFoundation
import Foundation
import UIKit
import UserNotifications
#if canImport(FluidAudio)
import FluidAudio
#endif

struct PendingMeetingRecoveryPayload: Codable, Hashable, Sendable {
    var title: String
    var workspace: String
    var attendees: [String]
    var objective: String
    var liveTranscript: String
    var capturedAt: Date
    var durationMinutes: Int
    var durationSeconds: Int? = nil
    var selectedTemplate: NoteTemplate
    var meetingMode: MeetingMode
    var consentState: ConsentState
    var retentionPolicy: RetentionPolicy
    var calendarEventID: String?
    var calendarStartDate: Date?
    var calendarEndDate: Date?

    var transcriptParagraphs: [String] {
        liveTranscript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct PendingMeetingProcessingJob: Codable, Hashable, Identifiable, Sendable {
    var id: Meeting.ID { meetingID }
    var meetingID: Meeting.ID
    var fileName: String
    var context: SpeechRecognitionContext
    var capturedNotes: String
    var pendingNotes: String
    var moments: [String]
    var liveWordCount: Int
    var recovery: PendingMeetingRecoveryPayload? = nil
    var attempts = 0
    var state: TranscriptionJobState = .queued
    var lastError: String?
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
        let delay = min(pow(2, Double(max(attempts - 1, 0))) * 20, 600)
        nextRetryAt = canRetry ? now.addingTimeInterval(delay) : nil
        updatedAt = now
    }

    mutating func markQueuedAfterInterruption(now: Date = .now) {
        // App suspension and BGTask expiration are scheduling events, not
        // transcription failures, so they must not consume a retry attempt.
        attempts = max(0, attempts - 1)
        state = .queued
        lastError = "Processing paused and will resume automatically."
        nextRetryAt = now.addingTimeInterval(10)
        updatedAt = now
    }
}

enum PendingMeetingAudioStore {
    private static let directoryName = "PendingMeetingAudio"

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Scribeflow", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func adopt(_ temporaryURL: URL) throws -> String {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        var folder = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)

        let pathExtension = temporaryURL.pathExtension.isEmpty ? "caf" : temporaryURL.pathExtension
        let fileName = "\(UUID().uuidString).\(pathExtension)"
        let destination = directoryURL.appendingPathComponent(fileName)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        return fileName
    }

    static func url(for fileName: String) -> URL {
        directoryURL.appendingPathComponent(
            URL(fileURLWithPath: fileName).lastPathComponent
        )
    }

    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func deleteOrphans(keeping fileNames: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where !fileNames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

actor PendingMeetingFileTransfer {
    static let shared = PendingMeetingFileTransfer()

    func adoptForProcessing(_ sourceURL: URL) throws -> String {
        try PendingMeetingAudioStore.adopt(sourceURL)
    }

    func preserveAsRecording(_ sourceURL: URL) throws -> URL {
        try RecordingFileStore.adoptFile(at: sourceURL)
    }

    func deletePending(_ fileName: String) {
        PendingMeetingAudioStore.delete(fileName)
    }

    func deleteAllPending() {
        PendingMeetingAudioStore.deleteAll()
    }
}

actor PendingMeetingProcessingQueue {
    static let shared = PendingMeetingProcessingQueue()

    private let folderURL: URL
    private let fileURL: URL
    private var jobs: [PendingMeetingProcessingJob] = []
    private var hasLoaded = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = base.appendingPathComponent("Scribeflow", isDirectory: true)
        folderURL = folder
        fileURL = folder.appendingPathComponent("meeting-processing-queue.json")
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
        var recovered: [PendingMeetingProcessingJob] = []
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            do {
                recovered = try decoder.decode([PendingMeetingProcessingJob].self, from: data)
            } catch {
                let quarantineURL = folderURL.appendingPathComponent(
                    "meeting-processing-queue-corrupt-\(UUID().uuidString).json"
                )
                try? FileManager.default.moveItem(at: fileURL, to: quarantineURL)
            }
        }
        var recoveredInterruptedJob = false
        for index in recovered.indices where recovered[index].state == .running {
            recovered[index].markQueuedAfterInterruption()
            recoveredInterruptedJob = true
        }
        jobs = recovered
        PendingMeetingAudioStore.deleteOrphans(
            keeping: Set(recovered.map(\.fileName))
        )
        if recoveredInterruptedJob {
            try? Self.persist(recovered, to: fileURL)
        }
    }

    func enqueue(_ job: PendingMeetingProcessingJob) throws {
        loadIfNeeded()
        let previous = jobs
        if let index = jobs.firstIndex(where: { $0.meetingID == job.meetingID }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        do {
            try persist()
        } catch {
            jobs = previous
            throw error
        }
    }

    func readyJobs(now: Date = .now) -> [PendingMeetingProcessingJob] {
        loadIfNeeded()
        return jobs
            .filter {
                $0.canRetry
                    && $0.state != .completed
                    && ($0.nextRetryAt == nil || $0.nextRetryAt! <= now)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func markRunning(_ id: Meeting.ID) throws -> PendingMeetingProcessingJob? {
        loadIfNeeded()
        guard let index = jobs.firstIndex(where: { $0.meetingID == id }) else { return nil }
        let previous = jobs[index]
        jobs[index].markRunning()
        do {
            try persist()
        } catch {
            jobs[index] = previous
            throw error
        }
        return jobs[index]
    }

    func markFailed(_ id: Meeting.ID, message: String) throws -> PendingMeetingProcessingJob? {
        loadIfNeeded()
        guard let index = jobs.firstIndex(where: { $0.meetingID == id }) else { return nil }
        let previous = jobs[index]
        jobs[index].markFailed(message)
        do {
            try persist()
        } catch {
            jobs[index] = previous
            throw error
        }
        return jobs[index]
    }

    func requeueInterrupted(_ id: Meeting.ID) throws {
        loadIfNeeded()
        guard let index = jobs.firstIndex(where: { $0.meetingID == id }) else { return }
        let previous = jobs[index]
        jobs[index].markQueuedAfterInterruption()
        do {
            try persist()
        } catch {
            jobs[index] = previous
            throw error
        }
    }

    @discardableResult
    func remove(_ id: Meeting.ID) throws -> PendingMeetingProcessingJob? {
        loadIfNeeded()
        let previous = jobs
        let removed = jobs.first { $0.meetingID == id }
        jobs.removeAll { $0.meetingID == id }
        do {
            try persist()
        } catch {
            jobs = previous
            throw error
        }
        return removed
    }

    func earliestRetryDate() -> Date? {
        loadIfNeeded()
        return jobs.compactMap(\.nextRetryAt).min()
    }

    func pendingJobs() -> [PendingMeetingProcessingJob] {
        loadIfNeeded()
        return jobs
    }

    func hasPendingJobs() -> Bool {
        loadIfNeeded()
        return !jobs.isEmpty
    }

    func clear() {
        hasLoaded = true
        jobs = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() throws {
        try Self.persist(jobs, to: fileURL)
    }

    private static func persist(_ jobs: [PendingMeetingProcessingJob], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(jobs)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        var protectedURL = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedURL.setResourceValues(values)
    }
}

private enum TranscriptQualityEvaluator {
    struct Assessment {
        let wordCount: Int
        let score: Double
        let isUsable: Bool
        let isStrong: Bool
    }

    static func assess(
        _ result: TranscriptionResult,
        liveWordCount: Int,
        audioURL: URL
    ) -> Assessment {
        let words = TranscriptAssembler.canonicalWords(in: result.text)
        guard !words.isEmpty else {
            return Assessment(wordCount: 0, score: 0, isUsable: false, isStrong: false)
        }

        let duration = audioDuration(at: audioURL)
        let frequencies = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
        let dominantShare = Double(frequencies.values.max() ?? 0) / Double(words.count)
        let uniqueShare = Double(frequencies.count) / Double(words.count)
        let liveBaseline = max(0, liveWordCount)
        let completionRatio = liveBaseline > 0
            ? Double(words.count) / Double(liveBaseline)
            : 1

        var longestRun = 1
        var currentRun = 1
        if words.count > 1 {
            for index in 1..<words.count {
                if words[index] == words[index - 1] {
                    currentRun += 1
                    longestRun = max(longestRun, currentRun)
                } else {
                    currentRun = 1
                }
            }
        }

        let enoughForDuration = duration < 4 || words.count >= 2
        let enoughComparedWithLive = liveBaseline < 12 || completionRatio >= 0.50
        let plausibleMaximum = duration < 5
            || words.count <= Int((duration / 60) * 330) + 16
        let repetitionLooksNatural = words.count < 12
            || (dominantShare < 0.50 && uniqueShare > 0.14 && longestRun < 5)
        let isUsable = enoughForDuration
            && enoughComparedWithLive
            && plausibleMaximum
            && repetitionLooksNatural

        let timedSegments = result.segments.filter { segment in
            guard let start = segment.startTime, let end = segment.endTime else { return false }
            return start.isFinite && end.isFinite && end >= start
        }.count
        let timingCoverage = result.segments.isEmpty
            ? 0
            : Double(timedSegments) / Double(result.segments.count)

        var score = min(Double(words.count) / 40, 1) * 20
        score += min(max(completionRatio, 0), 1) * 35
        score += min(uniqueShare / 0.55, 1) * 15
        score += timingCoverage * 10
        if result.diarizationAvailable { score += 8 }
        if !isUsable { score -= 40 }

        let isStrong = isUsable
            && score >= 52
            && (liveBaseline < 12 || completionRatio >= 0.80)
        return Assessment(
            wordCount: words.count,
            score: score,
            isUsable: isUsable,
            isStrong: isStrong
        )
    }

    static func preferred(
        from candidates: [TranscriptionResult],
        liveWordCount: Int,
        audioURL: URL
    ) -> TranscriptionResult? {
        let assessed = candidates.compactMap { result -> (TranscriptionResult, Assessment)? in
            let assessment = assess(result, liveWordCount: liveWordCount, audioURL: audioURL)
            return assessment.isUsable ? (result, assessment) : nil
        }
        let preferred = assessed.max { left, right in
                let leftAssessment = left.1
                let rightAssessment = right.1
                if abs(leftAssessment.score - rightAssessment.score) > 0.5 {
                    return leftAssessment.score < rightAssessment.score
                }
                if left.0.diarizationAvailable != right.0.diarizationAvailable {
                    return !left.0.diarizationAvailable
                }
                return leftAssessment.wordCount < rightAssessment.wordCount
            }
        return preferred?.0
    }

    private static func audioDuration(at url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return 0
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

@MainActor
final class EnhancedMeetingTranscriptionService {
    static let shared = EnhancedMeetingTranscriptionService()

    func transcribe(
        audioURL: URL,
        context: SpeechRecognitionContext,
        liveWordCount: Int
    ) async throws -> TranscriptionResult {
        var candidates: [TranscriptionResult] = []
        if TranscriptionProviderFactory.isRemoteTranscriptionEnabled {
            do {
                let localFallback = LocalVoiceRecordingService()
                localFallback.configureTranscriptionContext(
                    title: context.title,
                    workspace: context.workspace,
                    notes: [context.objective, context.notes, context.attendees.joined(separator: ", ")]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n"),
                    localeIdentifier: context.localeIdentifier,
                    attendees: context.attendees,
                    expectedSpeakerCount: context.expectedSpeakerCount
                )
                let provider = TranscriptionProviderFactory.make(localFallback: localFallback)
                let remoteResult = try await provider.transcribe(audioURL: audioURL)
                let assessment = TranscriptQualityEvaluator.assess(
                    remoteResult,
                    liveWordCount: liveWordCount,
                    audioURL: audioURL
                )
                if assessment.isUsable {
                    candidates.append(remoteResult)
                }
                if remoteResult.provider == .backend, assessment.isStrong {
                    return remoteResult
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A configured backend must never prevent the on-device path
                // from preserving the meeting.
            }
        }

        if EnhancedSpeechSettings.isEnabled, isEnglishRecognitionLocale(context) {
            do {
                let enhancedResult = try await EnhancedOnDeviceSpeechEngine.shared.transcribe(
                    audioURL: audioURL,
                    context: context,
                    liveWordCount: liveWordCount
                )
                let assessment = TranscriptQualityEvaluator.assess(
                    enhancedResult,
                    liveWordCount: liveWordCount,
                    audioURL: audioURL
                )
                if assessment.isUsable {
                    candidates.append(enhancedResult)
                }
                if assessment.isStrong {
                    if let preferred = TranscriptQualityEvaluator.preferred(
                        from: candidates,
                        liveWordCount: liveWordCount,
                        audioURL: audioURL
                    ) {
                        return preferred
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Continue to Apple Speech with any usable candidate retained
                // for comparison. A weak partial result must not suppress the
                // full-file recognition pass.
            }
        }

        do {
            let localResult = try await LocalVoiceRecordingService().transcribeMeetingAudio(
                audioURL: audioURL,
                context: context
            )
            candidates.append(localResult)
            if let preferred = TranscriptQualityEvaluator.preferred(
                from: candidates,
                liveWordCount: liveWordCount,
                audioURL: audioURL
            ) {
                return preferred
            }
            throw VoiceRecordingError.noTranscription
        } catch {
            if let preferred = TranscriptQualityEvaluator.preferred(
                from: candidates,
                liveWordCount: liveWordCount,
                audioURL: audioURL
            ) {
                return preferred
            }
            throw error
        }
    }

    func releaseModels() async {
        await EnhancedOnDeviceSpeechEngine.shared.releaseModels()
        await LocalSpeakerDiarizationService.shared.releaseModels()
    }

    private func isEnglishRecognitionLocale(_ context: SpeechRecognitionContext) -> Bool {
        context.recognitionLocale.language.languageCode?.identifier == "en"
    }
}

private actor EnhancedOnDeviceSpeechEngine {
    static let shared = EnhancedOnDeviceSpeechEngine()

    #if canImport(FluidAudio)
    private var manager: AsrManager?
    private var modelLoadTask: Task<AsrManager, Error>?
    #endif

    func transcribe(
        audioURL: URL,
        context: SpeechRecognitionContext,
        liveWordCount: Int
    ) async throws -> TranscriptionResult {
        #if canImport(FluidAudio)
        let manager = try await preparedManager()

        try Task.checkCancellation()
        let decoderLayers = await manager.decoderLayerCount
        var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(
            audioURL,
            decoderState: &decoderState
        )
        try Task.checkCancellation()

        guard let tokenTimings = result.tokenTimings,
              !tokenTimings.isEmpty
        else {
            throw VoiceRecordingError.noTranscription
        }

        let terms = ContextualTranscriptNormalizer.trustedTerms(from: context)
        let segments = buildWordTimings(from: tokenTimings).map {
            TranscriptionSegment(
                speaker: "Meeting",
                text: ContextualTranscriptNormalizer.correctedWord($0.word, using: terms),
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        let text = Self.joinedTranscript(from: segments)
        guard Self.isCredible(
            text: text,
            segments: segments,
            confidence: result.confidence,
            liveWordCount: liveWordCount,
            audioURL: audioURL
        ) else {
            throw VoiceRecordingError.noTranscription
        }

        let transcription = TranscriptionResult(
            text: text,
            segments: segments,
            provider: .localEnhancedSpeech,
            diarizationAvailable: false,
            usedFallback: false
        )
        return await LocalSpeakerDiarizationService.shared.enrich(
            transcription,
            audioURL: audioURL,
            expectedSpeakerCount: context.expectedSpeakerCount
        )
        #else
        throw VoiceRecordingError.speechUnavailable
        #endif
    }

    func releaseModels() async {
        #if canImport(FluidAudio)
        modelLoadTask?.cancel()
        modelLoadTask = nil
        if let manager {
            await manager.cleanup()
            self.manager = nil
        }
        #endif
    }

    #if canImport(FluidAudio)
    private func preparedManager() async throws -> AsrManager {
        if let manager { return manager }
        if let modelLoadTask {
            return try await withTaskCancellationHandler {
                try await modelLoadTask.value
            } onCancel: {
                modelLoadTask.cancel()
            }
        }
        guard EnhancedSpeechResourcePolicy.allowsModelPreparation else {
            throw VoiceRecordingError.speechUnavailable
        }

        let loadTask = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(version: .tdtCtc110m)
            try Task.checkCancellation()
            let prepared = AsrManager()
            try await prepared.loadModels(models)
            return prepared
        }
        modelLoadTask = loadTask

        do {
            let prepared = try await withTaskCancellationHandler {
                try await loadTask.value
            } onCancel: {
                loadTask.cancel()
            }
            manager = prepared
            modelLoadTask = nil
            return prepared
        } catch {
            modelLoadTask = nil
            throw error
        }
    }

    private static func isCredible(
        text: String,
        segments: [TranscriptionSegment],
        confidence: Float,
        liveWordCount: Int,
        audioURL: URL
    ) -> Bool {
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, !segments.isEmpty, confidence >= 0.15 else { return false }

        let duration: TimeInterval
        if let file = try? AVAudioFile(forReading: audioURL), file.fileFormat.sampleRate > 0 {
            duration = Double(file.length) / file.fileFormat.sampleRate
        } else {
            duration = 0
        }

        let plausibleLiveCount = duration > 0
            ? min(liveWordCount, max(1, Int((duration / 60) * 260) + 8))
            : liveWordCount
        let minimumExpected = duration < 3
            ? 1
            : max(2, Int(Double(plausibleLiveCount) * 0.22))
        guard words.count >= minimumExpected else { return false }

        if duration >= 5 {
            let maximumPlausible = Int((duration / 60) * 320) + 12
            guard words.count <= maximumPlausible else { return false }
        }

        if words.count >= 12 {
            let frequencies = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
            let dominantShare = Double(frequencies.values.max() ?? 0) / Double(words.count)
            let uniqueShare = Double(frequencies.count) / Double(words.count)
            guard dominantShare < 0.45, uniqueShare > 0.16 else { return false }

            var longestRun = 1
            var currentRun = 1
            for index in 1..<words.count {
                if words[index] == words[index - 1] {
                    currentRun += 1
                    longestRun = max(longestRun, currentRun)
                } else {
                    currentRun = 1
                }
            }
            guard longestRun < 5 else { return false }
        }

        var previousStart: TimeInterval = 0
        for segment in segments {
            guard let start = segment.startTime,
                  let end = segment.endTime,
                  start.isFinite,
                  end.isFinite,
                  start >= previousStart - 0.25,
                  end >= start
            else { return false }
            previousStart = start
        }
        if duration > 0, let finalEnd = segments.last?.endTime {
            guard finalEnd <= duration + 3 else { return false }
        }
        return true
    }

    private static func joinedTranscript(from segments: [TranscriptionSegment]) -> String {
        segments.reduce(into: "") { result, segment in
            let word = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return }
            if result.isEmpty || ",.!?:;)]}".contains(word.first ?? " ") {
                result += word
            } else {
                result += " \(word)"
            }
        }
    }
    #endif
}

private enum ContextualTranscriptNormalizer {
    struct Term: Sendable {
        var display: String
        var folded: String
        var allowsFuzzyMatch: Bool
    }

    static func trustedTerms(from context: SpeechRecognitionContext) -> [Term] {
        var terms: [Term] = []
        var seen: Set<String> = []

        func appendTerms(from text: String, allowsFuzzyMatch: Bool) {
            for token in tokens(in: text) {
                let folded = fold(token)
                guard folded.count >= 3,
                      !genericTerms.contains(folded),
                      seen.insert(folded).inserted
                else { continue }
                terms.append(Term(
                    display: token,
                    folded: folded,
                    allowsFuzzyMatch: allowsFuzzyMatch
                ))
            }
        }

        for attendee in context.attendees {
            appendTerms(from: attendee, allowsFuzzyMatch: true)
        }
        for vocabularyTerm in context.vocabulary {
            appendTerms(from: vocabularyTerm, allowsFuzzyMatch: false)
        }
        appendTerms(from: context.title, allowsFuzzyMatch: false)
        appendTerms(from: context.workspace, allowsFuzzyMatch: false)
        return terms
    }

    static func correctedWord(_ word: String, using terms: [Term]) -> String {
        guard !terms.isEmpty,
              let coreRange = coreRange(in: word)
        else { return word }

        let core = String(word[coreRange])
        let foldedCore = fold(core)
        guard !foldedCore.isEmpty,
              !genericTerms.contains(foldedCore),
              !protectedTerms.contains(foldedCore),
              core.rangeOfCharacter(from: .decimalDigits) == nil
        else { return word }

        if let exact = terms.first(where: { $0.folded == foldedCore }) {
            return word.replacingCharacters(in: coreRange, with: exact.display)
        }

        var best: (term: Term, distance: Int)?
        var isAmbiguous = false
        for term in terms where term.allowsFuzzyMatch {
            guard term.folded.count >= 6,
                  foldedCore.count >= 6,
                  term.folded.prefix(3) == foldedCore.prefix(3),
                  abs(term.folded.count - foldedCore.count) <= 1
            else { continue }

            let distance = editDistance(foldedCore, term.folded, limit: 1)
            guard distance == 1 else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (term, distance)
                    isAmbiguous = false
                } else if distance == current.distance {
                    isAmbiguous = true
                }
            } else {
                best = (term, distance)
            }
        }

        guard let best, !isAmbiguous else { return word }
        return word.replacingCharacters(in: coreRange, with: best.term.display)
    }

    private static let genericTerms: Set<String> = [
        "about", "after", "before", "capture", "client", "meeting", "notes",
        "personal", "project", "review", "speaker", "team", "today", "voice", "workspace"
    ]

    private static let protectedTerms: Set<String> = [
        "no", "not", "never", "none", "without", "cannot", "can't", "cant",
        "don't", "dont", "didn't", "didnt", "doesn't", "doesnt", "isn't", "isnt",
        "wasn't", "wasnt", "aren't", "arent", "weren't", "werent", "won't", "wont",
        "shouldn't", "shouldnt", "wouldn't", "wouldnt", "couldn't", "couldnt",
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "hundred", "thousand", "million", "billion"
    ]

    private static func tokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "'-"))
            .inverted)
            .filter { !$0.isEmpty }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func coreRange(in word: String) -> Range<String.Index>? {
        let accepted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-"))
        guard let first = word.indices.first(where: { index in
            word[index].unicodeScalars.contains { accepted.contains($0) }
        }),
        let last = word.indices.last(where: { index in
            word[index].unicodeScalars.contains { accepted.contains($0) }
        }) else { return nil }
        return first..<word.index(after: last)
    }

    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= limit else { return limit + 1 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            var rowMinimum = current[0]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let value = min(insertion, deletion, substitution)
                current.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous[right.count]
    }
}

enum MeetingProcessingNotification {
    @discardableResult
    static func sendReady(meetingID: Meeting.ID, title: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        var permission = await ScribeflowNotificationAuthorization.shared.currentPermission()
        if permission == .notDetermined {
            permission = await ScribeflowNotificationAuthorization.shared.requestIfNeeded()
        }
        guard permission.canSchedule else {
            await postInAppFallback(title: title, permission: permission)
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = "Your capture is ready"
        content.body = title
        content.sound = .default
        content.interruptionLevel = .active
        content.relevanceScore = 1
        content.threadIdentifier = meetingID.uuidString
        content.userInfo = ["meetingID": meetingID.uuidString]
        let request = UNNotificationRequest(
            identifier: "scribeflow.processing.\(meetingID.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            await postInAppFallback(title: title, permission: permission)
            return false
        }
    }

    @MainActor
    private static func postInAppFallback(
        title: String,
        permission: ScribeflowNotificationPermission
    ) {
        let suffix = permission == .denied ? " · notifications are off" : ""
        NotificationCenter.default.post(
            name: .scribeflowToast,
            object: ToastItem(message: "\(title) is ready\(suffix)", icon: "checkmark.circle.fill")
        )
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: "\(title) is ready")
        }
    }
}

@MainActor
final class MeetingProcessingCoordinator {
    static let shared = MeetingProcessingCoordinator()

    private weak var store: MeetingStore?
    private var processingTask: Task<Void, Never>?
    private var retryWakeTask: Task<Void, Never>?
    private var activeMeetingID: Meeting.ID?
    private var discardedMeetingIDs: Set<Meeting.ID> = []
    private var suspendedMeetingIDs: Set<Meeting.ID> = []
    private var isPausedForLibraryReplacement = false
    private var backgroundExecutionID = UIBackgroundTaskIdentifier.invalid

    func attach(_ store: MeetingStore) {
        self.store = store
    }

    func enqueue(_ job: PendingMeetingProcessingJob, using store: MeetingStore) async -> Bool {
        attach(store)
        do {
            try await PendingMeetingProcessingQueue.shared.enqueue(job)
        } catch {
            await PendingMeetingFileTransfer.shared.deletePending(job.fileName)
            store.finishPendingMeetingWithLiveTranscript(
                job.meetingID,
                message: "Saved with the live transcript"
            )
            return false
        }

        MeetingProcessingBackgroundScheduler.schedule()
        beginExtendedExecution()
        startProcessingIfNeeded()
        return true
    }

    func resume(using store: MeetingStore) async {
        attach(store)
        await restorePendingMeetingsIfNeeded(using: store)
        startProcessingIfNeeded()
    }

    func discard(_ meetingID: Meeting.ID) {
        suspendedMeetingIDs.remove(meetingID)
        discardedMeetingIDs.insert(meetingID)
        if activeMeetingID == meetingID {
            processingTask?.cancel()
        }

        Task { @MainActor [weak self] in
            let removed: PendingMeetingProcessingJob?
            do {
                removed = try await PendingMeetingProcessingQueue.shared.remove(meetingID)
            } catch {
                return
            }
            if let removed {
                await PendingMeetingFileTransfer.shared.deletePending(removed.fileName)
            }
            self?.discardedMeetingIDs.remove(meetingID)
        }
    }

    func suspend(_ meetingID: Meeting.ID) {
        suspendedMeetingIDs.insert(meetingID)
        if activeMeetingID == meetingID {
            processingTask?.cancel()
        }
    }

    func resume(_ meetingID: Meeting.ID, using store: MeetingStore) {
        attach(store)
        suspendedMeetingIDs.remove(meetingID)
        startProcessingIfNeeded()
    }

    func pauseForLibraryReplacement() async {
        isPausedForLibraryReplacement = true
        retryWakeTask?.cancel()
        retryWakeTask = nil

        let activeTask = processingTask
        activeTask?.cancel()
        if let activeTask {
            await activeTask.value
        }
        processingTask = nil
        activeMeetingID = nil
        endExtendedExecution()
    }

    func resumeAfterLibraryReplacement(using store: MeetingStore) {
        attach(store)
        isPausedForLibraryReplacement = false
        startProcessingIfNeeded()
    }

    func discardAll() async {
        isPausedForLibraryReplacement = true
        processingTask?.cancel()
        retryWakeTask?.cancel()
        if let processingTask {
            await processingTask.value
        }
        retryWakeTask?.cancel()
        processingTask = nil
        retryWakeTask = nil
        activeMeetingID = nil
        suspendedMeetingIDs.removeAll()
        discardedMeetingIDs.removeAll()
        await PendingMeetingProcessingQueue.shared.clear()
        await PendingMeetingFileTransfer.shared.deleteAllPending()
        endExtendedExecution()
        isPausedForLibraryReplacement = false
    }

    func processPendingAndWait() async -> Bool {
        if store == nil {
            attach(ScribeflowRuntime.shared.store)
        }
        guard let store else {
            MeetingProcessingBackgroundScheduler.schedule(
                earliestBeginDate: .now.addingTimeInterval(60)
            )
            return false
        }
        await store.loadLibraryIfNeeded()
        await restorePendingMeetingsIfNeeded(using: store)
        startProcessingIfNeeded()
        guard let processingTask else {
            return !(await PendingMeetingProcessingQueue.shared.hasPendingJobs())
        }
        await processingTask.value
        return !(await PendingMeetingProcessingQueue.shared.hasPendingJobs())
    }

    func pauseForSystemExpiration() {
        processingTask?.cancel()
        MeetingProcessingBackgroundScheduler.schedule(
            earliestBeginDate: .now.addingTimeInterval(30)
        )
    }

    private func startProcessingIfNeeded() {
        guard !isPausedForLibraryReplacement,
              processingTask == nil,
              store != nil
        else { return }
        beginExtendedExecution()
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runReadyJobs()
            self.processingTask = nil
            self.endExtendedExecution()
            await self.scheduleRemainingWorkIfNeeded()
        }
    }

    private func restorePendingMeetingsIfNeeded(using store: MeetingStore) async {
        let jobs = await PendingMeetingProcessingQueue.shared.pendingJobs()
        for job in jobs where store.meeting(withID: job.meetingID) == nil {
            guard !discardedMeetingIDs.contains(job.meetingID),
                  let recovery = job.recovery
            else { continue }
            store.restorePendingLiveMeeting(
                id: job.meetingID,
                recovery: recovery,
                capturedNotes: job.capturedNotes,
                pendingNotes: job.pendingNotes,
                moments: job.moments
            )
        }
    }

    private func runReadyJobs() async {
        guard let store else { return }
        let queue = PendingMeetingProcessingQueue.shared
        let jobs = await queue.readyJobs()

        for pendingJob in jobs {
            if Task.isCancelled { break }
            if suspendedMeetingIDs.contains(pendingJob.meetingID) { continue }
            guard store.meeting(withID: pendingJob.meetingID) != nil else {
                _ = await removeJobAndAudio(pendingJob, from: queue)
                continue
            }

            let audioURL = PendingMeetingAudioStore.url(for: pendingJob.fileName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                store.finishPendingMeetingWithLiveTranscript(
                    pendingJob.meetingID,
                    message: "Saved with the live transcript"
                )
                if await removeJobAndAudio(pendingJob, from: queue) {
                    let title = store.meeting(withID: pendingJob.meetingID)?.title ?? "Capture"
                    await MeetingProcessingNotification.sendReady(
                        meetingID: pendingJob.meetingID,
                        title: title
                    )
                }
                continue
            }

            guard let runningJob = try? await queue.markRunning(pendingJob.meetingID) else { continue }
            activeMeetingID = runningJob.meetingID
            let canUseEnhancedModels = EnhancedSpeechSettings.isEnabled
                && EnhancedSpeechResourcePolicy.allowsModelPreparation
            store.updateMeetingProcessingStage(
                canUseEnhancedModels && LocalSpeakerDiarizationSettings.isEnabled
                    ? "Refining transcript and separating speakers"
                    : (canUseEnhancedModels
                        ? "Applying enhanced speech recognition"
                        : "Refining the full transcript"),
                for: runningJob.meetingID
            )

            do {
                let result = try await EnhancedMeetingTranscriptionService.shared.transcribe(
                    audioURL: audioURL,
                    context: runningJob.context,
                    liveWordCount: runningJob.liveWordCount
                )
                try Task.checkCancellation()
                store.updateMeetingProcessingStage(
                    "Organizing the transcript into final notes",
                    for: runningJob.meetingID
                )
                let completed = await store.completePendingLiveMeeting(
                    id: runningJob.meetingID,
                    result: result,
                    capturedNotes: runningJob.capturedNotes,
                    pendingNotes: runningJob.pendingNotes,
                    moments: runningJob.moments
                )
                if completed {
                    let title = store.meeting(withID: runningJob.meetingID)?.title ?? "Meeting"
                    if await removeJobAndAudio(runningJob, from: queue) {
                        await MeetingProcessingNotification.sendReady(
                            meetingID: runningJob.meetingID,
                            title: title
                        )
                    }
                } else {
                    _ = await removeJobAndAudio(runningJob, from: queue)
                }
            } catch is CancellationError {
                if discardedMeetingIDs.contains(runningJob.meetingID) {
                    _ = await removeJobAndAudio(runningJob, from: queue)
                } else {
                    try? await queue.requeueInterrupted(runningJob.meetingID)
                    store.updateMeetingProcessingStage(
                        "Saved · refinement will resume automatically",
                        for: runningJob.meetingID
                    )
                }
                activeMeetingID = nil
                break
            } catch {
                let failedJob = try? await queue.markFailed(
                    runningJob.meetingID,
                    message: error.localizedDescription
                )
                if failedJob?.canRetry == true {
                    store.updateMeetingProcessingStage(
                        "Saved · refinement will retry automatically",
                        for: runningJob.meetingID
                    )
                } else {
                    let preservedURL = try? await PendingMeetingFileTransfer.shared
                        .preserveAsRecording(audioURL)
                    if let preservedURL {
                        if store.finishPendingMeetingPreservingAudio(
                            runningJob.meetingID,
                            recordingURL: preservedURL,
                            recovery: runningJob.recovery,
                            message: "Recording saved · transcript needs review"
                        ) {
                            _ = try? await queue.remove(runningJob.meetingID)
                            let title = store.meeting(withID: runningJob.meetingID)?.title ?? "Meeting"
                            await MeetingProcessingNotification.sendReady(
                                meetingID: runningJob.meetingID,
                                title: title
                            )
                        } else {
                            RecordingFileStore.deleteFile(
                                named: RecordingFileStore.fileName(for: preservedURL)
                            )
                            _ = try? await queue.remove(runningJob.meetingID)
                        }
                    } else {
                        store.finishPendingMeetingWithLiveTranscript(
                            runningJob.meetingID,
                            message: "Saved with the best available live transcript"
                        )
                        // Preserve the protected source audio even if it could
                        // not be moved into the visible recording library.
                        _ = try? await queue.remove(runningJob.meetingID)
                        let title = store.meeting(withID: runningJob.meetingID)?.title ?? "Capture"
                        await MeetingProcessingNotification.sendReady(
                            meetingID: runningJob.meetingID,
                            title: title
                        )
                    }
                }
            }
            activeMeetingID = nil
        }

        await EnhancedMeetingTranscriptionService.shared.releaseModels()
    }

    private func removeJobAndAudio(
        _ job: PendingMeetingProcessingJob,
        from queue: PendingMeetingProcessingQueue
    ) async -> Bool {
        do {
            let removed = try await queue.remove(job.meetingID)
            await PendingMeetingFileTransfer.shared.deletePending(
                removed?.fileName ?? job.fileName
            )
            discardedMeetingIDs.remove(job.meetingID)
            return true
        } catch {
            return false
        }
    }

    private func scheduleRemainingWorkIfNeeded() async {
        guard !isPausedForLibraryReplacement else {
            retryWakeTask?.cancel()
            retryWakeTask = nil
            return
        }
        let queue = PendingMeetingProcessingQueue.shared
        guard await queue.hasPendingJobs() else {
            retryWakeTask?.cancel()
            retryWakeTask = nil
            return
        }

        let retryDate = await queue.earliestRetryDate()
        MeetingProcessingBackgroundScheduler.schedule(earliestBeginDate: retryDate)
        retryWakeTask?.cancel()
        let delay = max(1, retryDate?.timeIntervalSinceNow ?? 10)
        retryWakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.startProcessingIfNeeded()
        }
    }

    private func beginExtendedExecution() {
        guard backgroundExecutionID == .invalid else { return }
        backgroundExecutionID = UIApplication.shared.beginBackgroundTask(
            withName: "Scribeflow meeting processing"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.processingTask?.cancel()
                MeetingProcessingBackgroundScheduler.schedule()
                self?.endExtendedExecution()
            }
        }
    }

    private func endExtendedExecution() {
        guard backgroundExecutionID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundExecutionID)
        backgroundExecutionID = .invalid
    }
}

enum MeetingProcessingBackgroundScheduler {
    private static let lastSchedulingErrorKey = "scribeflow.backgroundProcessing.lastSchedulingError"

    static var identifier: String {
        "\(Bundle.main.bundleIdentifier ?? "ai.scribeflow.app").meeting-processing"
    }

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let work = Task { @MainActor in
                let success = await MeetingProcessingCoordinator.shared.processPendingAndWait()
                processingTask.setTaskCompleted(success: success)
            }
            processingTask.expirationHandler = {
                work.cancel()
                Task { @MainActor in
                    MeetingProcessingCoordinator.shared.pauseForSystemExpiration()
                }
            }
        }
    }

    @MainActor
    @discardableResult
    static func schedule(earliestBeginDate: Date? = nil) -> Bool {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = TranscriptionProviderFactory.isRemoteTranscriptionEnabled
        request.requiresExternalPower = false
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
            UserDefaults.standard.removeObject(forKey: lastSchedulingErrorKey)
            return true
        } catch {
            let message = error.localizedDescription
            UserDefaults.standard.set(message, forKey: lastSchedulingErrorKey)
            AnalyticsLog.shared.log("background.processing.schedule_failed", ["error": message])
            return false
        }
    }
}

@MainActor
final class ScribeflowAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationRouter.shared.configure()
        MeetingProcessingBackgroundScheduler.register()
        MeetingProcessingCoordinator.shared.attach(ScribeflowRuntime.shared.store)
        return true
    }
}
