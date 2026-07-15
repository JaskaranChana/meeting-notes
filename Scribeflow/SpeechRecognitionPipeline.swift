import AVFoundation
import Foundation
import Speech

struct SpeechRecognitionContext: Codable, Hashable, Sendable {
    var title: String = ""
    var workspace: String = ""
    var objective: String = ""
    var attendees: [String] = []
    var notes: String = ""
    var templateTitle: String = ""
    var templateGuidance: String = ""
    var vocabulary: [String] = []
    var localeIdentifier: String? = nil
    var expectedSpeakerCount: Int? = nil

    var recognitionLocale: Locale {
        SpeechRecognitionSupport.resolvedLocale(identifier: localeIdentifier)
    }

    var contextualPhrases: [String] {
        let placeholders: Set<String> = [
            "live meeting",
            "personal workspace",
            "voice notes",
            "quick note",
            "capture the key points while i stay present in the meeting.",
            "capture the speaker's exact words clearly."
        ]
        let directCandidates = attendees
            + vocabulary
            + [title, workspace, objective, templateTitle]
        let contextCandidates = [notes, templateGuidance]
            .flatMap(Self.contextSnippets)
        let candidates = directCandidates + contextCandidates
        var seen: Set<String> = []

        return candidates.compactMap { value in
            let cleaned = value
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }

            let phrase = String(cleaned.prefix(100))
            let key = phrase.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard !placeholders.contains(key) else { return nil }
            guard seen.insert(key).inserted else { return nil }
            return phrase
        }
        .prefix(100)
        .map { $0 }
    }

    private static func contextSnippets(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let fragments = normalized
            .components(separatedBy: CharacterSet(charactersIn: "\n.!?;"))
            .map {
                $0.split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        var phrases: [String] = []
        for fragment in fragments.prefix(24) {
            phrases.append(String(fragment.prefix(100)))
            phrases.append(contentsOf: distinctiveTerms(in: fragment))
        }
        return phrases
    }

    private static func distinctiveTerms(in text: String) -> [String] {
        let stopWords: Set<String> = [
            "about", "after", "again", "also", "because", "before", "being",
            "between", "could", "from", "have", "into", "meeting", "notes",
            "should", "their", "there", "these", "they", "this", "through",
            "today", "with", "would", "your"
        ]
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#.'-"))
                .inverted)
            .filter { $0.count >= 3 }

        return tokens.compactMap { token in
            let lower = token.lowercased()
            guard !stopWords.contains(lower) else { return nil }
            let hasSignal = token != lower
                || token.rangeOfCharacter(from: .decimalDigits) != nil
                || token.contains("+")
                || token.contains("#")
                || token.contains("-")
                || token.count >= 8
            return hasSignal ? String(token.prefix(48)) : nil
        }
    }
}

enum SpeechRecognitionSupport {
    static let localePreferenceKey = "scribeflow.speechLocaleIdentifier"

    private static let supportedLegacyLocales = SFSpeechRecognizer.supportedLocales()
        .sorted { lhs, rhs in
            displayName(for: lhs).localizedStandardCompare(displayName(for: rhs)) == .orderedAscending
        }

    static var selectedLocaleIdentifier: String? {
        let value = UserDefaults.standard.string(forKey: localePreferenceKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static var preferredLocale: Locale {
        resolvedLocale(identifier: selectedLocaleIdentifier)
    }

    static var availableLocales: [Locale] {
        supportedLegacyLocales
    }

    static var automaticLocale: Locale {
        resolvedLocale(identifier: nil, includesStoredPreference: false)
    }

    static func resolvedLocale(identifier: String?) -> Locale {
        resolvedLocale(identifier: identifier, includesStoredPreference: true)
    }

    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    static func persistSelectedLocale(identifier: String?) {
        let cleaned = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleaned.isEmpty {
            UserDefaults.standard.removeObject(forKey: localePreferenceKey)
        } else {
            UserDefaults.standard.set(cleaned, forKey: localePreferenceKey)
        }
    }

    static func makeLegacyRecognizer(locale: Locale? = nil) -> SFSpeechRecognizer? {
        guard let locale = bestSupportedLocale(matching: locale ?? preferredLocale) else {
            return nil
        }
        return SFSpeechRecognizer(locale: locale)
    }

    private static func resolvedLocale(
        identifier: String?,
        includesStoredPreference: Bool
    ) -> Locale {
        let storedIdentifier = includesStoredPreference ? selectedLocaleIdentifier : nil
        let requestedIdentifier = identifier?.isEmpty == false
            ? identifier
            : storedIdentifier
        let deviceIdentifier = Locale.preferredLanguages.first
        let requested = requestedIdentifier.map(Locale.init(identifier:))
            ?? deviceIdentifier.map(Locale.init(identifier:))
            ?? .current

        return bestSupportedLocale(matching: requested) ?? requested
    }

    private static func bestSupportedLocale(matching requested: Locale) -> Locale? {
        let exact = supportedLegacyLocales.first {
            $0.identifier.compare(requested.identifier, options: [.caseInsensitive]) == .orderedSame
        }
        let languageMatch = supportedLegacyLocales.first {
            $0.language.languageCode == requested.language.languageCode
        }
        let englishFallback = supportedLegacyLocales.first { $0.identifier == "en-US" }

        return exact ?? languageMatch ?? englishFallback ?? supportedLegacyLocales.first
    }

    static func configureLegacyRequest(
        _ request: SFSpeechRecognitionRequest,
        recognizer: SFSpeechRecognizer,
        context: SpeechRecognitionContext,
        reportsPartialResults: Bool
    ) {
        request.shouldReportPartialResults = reportsPartialResults
        request.taskHint = .dictation
        request.contextualStrings = context.contextualPhrases
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
    }
}

final class SpeechAudioBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((AVAudioPCMBuffer) -> Void)?

    func replaceHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(buffer)
    }
}

@MainActor
protocol LiveSpeechTranscribing: AnyObject {
    nonisolated var audioSink: SpeechAudioBufferSink { get }
    func updateContext(_ context: SpeechRecognitionContext) async
    func finish() async -> String
    func cancel()
}

enum SpeechRecognitionPipelineError: LocalizedError {
    case recognizerUnavailable
    case unsupportedLocale
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "Speech recognition is temporarily unavailable."
        case .unsupportedLocale:
            "Speech recognition does not support the device language yet."
        case .unsupportedAudioFormat:
            "The microphone audio format could not be prepared for transcription."
        }
    }
}

@MainActor
enum SpeechRecognitionPipeline {
    static func makeLiveSession(
        inputFormat: AVAudioFormat,
        context: SpeechRecognitionContext,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async throws -> any LiveSpeechTranscribing {
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
           let session = try? await AnalyzerLiveSpeechSession.make(
               inputFormat: inputFormat,
               context: context,
               onTranscript: onTranscript,
               onError: onError
           ) {
            return session
        }

        guard let recognizer = SpeechRecognitionSupport.makeLegacyRecognizer(
            locale: context.recognitionLocale
        ),
              recognizer.isAvailable else {
            throw SpeechRecognitionPipelineError.recognizerUnavailable
        }

        return LegacyLiveSpeechSession(
            recognizer: recognizer,
            context: context,
            onTranscript: onTranscript,
            onError: onError
        )
    }
}

@MainActor
private final class LegacyLiveSpeechSession: LiveSpeechTranscribing {
    nonisolated let audioSink = SpeechAudioBufferSink()

    private let recognizer: SFSpeechRecognizer
    private var context: SpeechRecognitionContext
    private let onTranscript: @MainActor (String, Bool) -> Void
    private let onError: @MainActor (String) -> Void

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var rotationTask: Task<Void, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var committedTranscript = ""
    private var currentTranscript = ""
    private var generation = 0
    private var isFinishing = false
    private var isCancelled = false

    init(
        recognizer: SFSpeechRecognizer,
        context: SpeechRecognitionContext,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        self.recognizer = recognizer
        self.context = context
        self.onTranscript = onTranscript
        self.onError = onError
        replaceRecognitionSegment()
    }

    func finish() async -> String {
        guard !isCancelled else { return combinedTranscript }
        guard recognitionRequest != nil else { return combinedTranscript }

        isFinishing = true
        rotationTask?.cancel()
        rotationTask = nil
        audioSink.replaceHandler(nil)

        await withCheckedContinuation { continuation in
            finishContinuation = continuation
            recognitionRequest?.endAudio()
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.completeFinish()
            }
        }

        teardown()
        return combinedTranscript
    }

    func updateContext(_ context: SpeechRecognitionContext) async {
        self.context = context
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        commitCurrentTranscript()
        completeFinish()
        teardown()
    }

    private var combinedTranscript: String {
        Self.joined(committedTranscript, currentTranscript)
    }

    private func replaceRecognitionSegment() {
        guard !isCancelled, !isFinishing else { return }

        let oldRequest = recognitionRequest
        let oldTask = recognitionTask
        commitCurrentTranscript()
        generation += 1
        let currentGeneration = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        SpeechRecognitionSupport.configureLegacyRequest(
            request,
            recognizer: recognizer,
            context: context,
            reportsPartialResults: true
        )

        recognitionRequest = request
        audioSink.replaceHandler { [request] buffer in
            request.append(buffer)
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription

            Task { @MainActor [weak self] in
                self?.handleRecognitionUpdate(
                    text: text,
                    isFinal: isFinal,
                    errorDescription: errorDescription,
                    generation: currentGeneration
                )
            }
        }

        oldRequest?.endAudio()
        oldTask?.cancel()
        scheduleRotation()
    }

    private func handleRecognitionUpdate(
        text: String?,
        isFinal: Bool,
        errorDescription: String?,
        generation: Int
    ) {
        guard generation == self.generation, !isCancelled else { return }

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentTranscript = text
            onTranscript(combinedTranscript, isFinal)
        }

        if isFinal {
            commitCurrentTranscript()
            if isFinishing {
                completeFinish()
            } else {
                replaceRecognitionSegment()
            }
            return
        }

        guard errorDescription != nil else { return }
        if isFinishing {
            completeFinish()
        } else if recognizer.isAvailable {
            replaceRecognitionSegment()
        } else {
            onError("Speech recognition became unavailable. Your transcript was preserved up to this point.")
            cancel()
        }
    }

    private func scheduleRotation() {
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(50))
            guard !Task.isCancelled else { return }
            self?.replaceRecognitionSegment()
        }
    }

    private func commitCurrentTranscript() {
        let current = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }
        committedTranscript = Self.joined(committedTranscript, current)
        currentTranscript = ""
        onTranscript(committedTranscript, true)
    }

    private func completeFinish() {
        commitCurrentTranscript()
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume()
    }

    private func teardown() {
        rotationTask?.cancel()
        rotationTask = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        audioSink.replaceHandler(nil)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private static func joined(_ leading: String, _ trailing: String) -> String {
        let leading = leading.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if leading.isEmpty { return trailing }
        if trailing.isEmpty { return leading }
        return "\(leading) \(trailing)"
    }
}

@available(iOS 26.0, *)
@MainActor
private final class AnalyzerLiveSpeechSession: LiveSpeechTranscribing {
    nonisolated let audioSink = SpeechAudioBufferSink()

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let audioPump: AnalyzerAudioBufferPump
    private let onTranscript: @MainActor (String, Bool) -> Void
    private let onError: @MainActor (String) -> Void
    private var resultsTask: Task<Void, Never>?
    private var finalizedTranscript = AttributedString()
    private var volatileTranscript = AttributedString()
    private var isFinished = false

    private init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        audioPump: AnalyzerAudioBufferPump,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputContinuation = inputContinuation
        self.audioPump = audioPump
        self.onTranscript = onTranscript
        self.onError = onError
    }

    static func make(
        inputFormat: AVAudioFormat,
        context: SpeechRecognitionContext,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async throws -> AnalyzerLiveSpeechSession {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: context.recognitionLocale
        ) else {
            throw SpeechRecognitionPipelineError.unsupportedLocale
        }

        let preset = SpeechTranscriber.Preset.timeIndexedProgressiveTranscription
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions.union([.alternativeTranscriptions]),
            attributeOptions: preset.attributeOptions.union([.audioTimeRange, .transcriptionConfidence])
        )

        if let installationRequest = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installationRequest.downloadAndInstall()
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: inputFormat
        ) else {
            throw SpeechRecognitionPipelineError.unsupportedAudioFormat
        }

        let analysisContext = AnalysisContext()
        analysisContext.contextualStrings[.general] = context.contextualPhrases
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        try await analyzer.setContext(analysisContext)
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (inputStream, inputContinuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(192)
        )
        let converter = try SpeechPCMBufferConverter(from: inputFormat, to: analyzerFormat)
        let audioPump = AnalyzerAudioBufferPump(
            converter: converter,
            continuation: inputContinuation
        )
        let session = AnalyzerLiveSpeechSession(
            analyzer: analyzer,
            transcriber: transcriber,
            inputContinuation: inputContinuation,
            audioPump: audioPump,
            onTranscript: onTranscript,
            onError: onError
        )

        session.audioSink.replaceHandler { [audioPump] buffer in
            audioPump.append(buffer)
        }
        session.startResultsTask()
        try await analyzer.start(inputSequence: inputStream)
        return session
    }

    func finish() async -> String {
        guard !isFinished else { return combinedTranscript }
        isFinished = true
        audioSink.replaceHandler(nil)
        await audioPump.finish()
        inputContinuation.finish()

        // SpeechAnalyzer normally finalizes quickly, but framework or asset
        // stalls must never hold the Save flow indefinitely. Cancellation keeps
        // the best progressive transcript already delivered to the coordinator.
        let finalizationDeadline = Task { [analyzer] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await analyzer.cancelAndFinishNow()
        }
        defer { finalizationDeadline.cancel() }

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            onError("Final speech processing was interrupted. The best available transcript was kept.")
        }

        await resultsTask?.value
        resultsTask = nil
        volatileTranscript = AttributedString()
        onTranscript(combinedTranscript, true)
        return combinedTranscript
    }

    func updateContext(_ context: SpeechRecognitionContext) async {
        let analysisContext = AnalysisContext()
        analysisContext.contextualStrings[.general] = context.contextualPhrases
        try? await analyzer.setContext(analysisContext)
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        audioSink.replaceHandler(nil)
        audioPump.cancel()
        inputContinuation.finish()
        resultsTask?.cancel()
        resultsTask = nil
        Task { await analyzer.cancelAndFinishNow() }
    }

    private var combinedTranscript: String {
        var text = finalizedTranscript
        text += volatileTranscript
        return String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startResultsTask() {
        resultsTask = Task { @MainActor [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { return }
                    if result.isFinal {
                        self.finalizedTranscript += result.text
                        self.volatileTranscript = AttributedString()
                    } else {
                        self.volatileTranscript = result.text
                    }
                    self.onTranscript(self.combinedTranscript, result.isFinal)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.onError("Live transcription paused unexpectedly. The transcript already captured was preserved.")
            }
        }
    }
}

@available(iOS 26.0, *)
enum SpeechAnalyzerFileTranscriber {
    static func transcribe(
        audioURL: URL,
        context: SpeechRecognitionContext,
        defaultSpeaker: String
    ) async throws -> TranscriptionResult {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(
                  equivalentTo: context.recognitionLocale
              ) else {
            throw SpeechRecognitionPipelineError.unsupportedLocale
        }

        let preset = SpeechTranscriber.Preset.timeIndexedTranscriptionWithAlternatives
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions.union([.alternativeTranscriptions]),
            attributeOptions: preset.attributeOptions.union([.audioTimeRange, .transcriptionConfidence])
        )

        if let installationRequest = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installationRequest.downloadAndInstall()
        }

        let analysisContext = AnalysisContext()
        analysisContext.contextualStrings[.general] = context.contextualPhrases
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(analysisContext)
        let audioFile = try AVAudioFile(forReading: audioURL)

        async let payload = collectSegments(from: transcriber, defaultSpeaker: defaultSpeaker)
        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let completed = try await payload
            let text = completed.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceRecordingError.noTranscription
            }
            return TranscriptionResult(
                text: text,
                segments: completed.segments,
                provider: .localAppleSpeech,
                diarizationAvailable: false,
                usedFallback: false
            )
        } catch {
            await analyzer.cancelAndFinishNow()
            _ = try? await payload
            throw error
        }
    }

    private struct FileTranscriptionPayload: Sendable {
        var text: String
        var segments: [TranscriptionSegment]
    }

    private static func collectSegments(
        from transcriber: SpeechTranscriber,
        defaultSpeaker: String
    ) async throws -> FileTranscriptionPayload {
        var completeText = ""
        var segments: [TranscriptionSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let resultText = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resultText.isEmpty else { continue }
            completeText = joined(completeText, resultText)

            var appendedTimedRun = false
            for run in result.text.runs {
                let runText = String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !runText.isEmpty, let timeRange = run.audioTimeRange else { continue }
                let start = timeRange.start.seconds
                let duration = timeRange.duration.seconds
                guard start.isFinite, duration.isFinite, duration > 0 else { continue }
                segments.append(
                    TranscriptionSegment(
                        speaker: defaultSpeaker,
                        text: runText,
                        startTime: start,
                        endTime: start + duration
                    )
                )
                appendedTimedRun = true
            }

            if !appendedTimedRun {
                let start = result.range.start.seconds
                let duration = result.range.duration.seconds
                segments.append(
                    TranscriptionSegment(
                        speaker: defaultSpeaker,
                        text: resultText,
                        startTime: start.isFinite ? start : nil,
                        endTime: start.isFinite && duration.isFinite ? start + duration : nil
                    )
                )
            }
        }
        return FileTranscriptionPayload(text: completeText, segments: segments)
    }

    private static func joined(_ leading: String, _ trailing: String) -> String {
        let leading = leading.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if leading.isEmpty { return trailing }
        if trailing.isEmpty { return leading }
        if ",.!?:;)]}".contains(trailing.first ?? " ") {
            return leading + trailing
        }
        return "\(leading) \(trailing)"
    }
}

@available(iOS 26.0, *)
private final class AnalyzerAudioBufferPump: @unchecked Sendable {
    private final class BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private let queue = DispatchQueue(
        label: "ai.scribeflow.speech-analyzer-input",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private let converter: SpeechPCMBufferConverter
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var isAcceptingAudio = true
    private var isCancelled = false
    private var pendingBufferCount = 0
    private let maximumPendingBuffers = 256

    init(
        converter: SpeechPCMBufferConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.converter = converter
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        let box = BufferBox(copy)
        stateLock.lock()
        guard isAcceptingAudio, pendingBufferCount < maximumPendingBuffers else {
            stateLock.unlock()
            return
        }
        pendingBufferCount += 1
        queue.async { [self, box] in
            defer {
                stateLock.withLock { pendingBufferCount = max(0, pendingBufferCount - 1) }
            }
            guard stateLock.withLock({ !isCancelled }),
                  let converted = try? converter.convert(box.buffer)
            else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        stateLock.unlock()
    }

    func finish() async {
        stateLock.withLock { isAcceptingAudio = false }
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    func cancel() {
        stateLock.withLock {
            isAcceptingAudio = false
            isCancelled = true
        }
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        destination.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData
            else { continue }
            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return destination
    }
}

@available(iOS 26.0, *)
private final class SpeechPCMBufferConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter
    private var inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechRecognitionPipelineError.unsupportedAudioFormat
        }
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }

        if !input.format.isEqual(inputFormat) {
            guard let replacement = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw SpeechRecognitionPipelineError.unsupportedAudioFormat
            }
            inputFormat = input.format
            converter = replacement
        }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw SpeechRecognitionPipelineError.unsupportedAudioFormat
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }

        if let conversionError { throw conversionError }
        guard status == .haveData || status == .inputRanDry, output.frameLength > 0 else {
            throw SpeechRecognitionPipelineError.unsupportedAudioFormat
        }
        return output
    }
}
