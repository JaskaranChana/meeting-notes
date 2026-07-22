import AVFoundation
import Foundation
import Speech

enum TranscriptAssembler {
    private struct Token {
        let folded: String
        let range: Range<String.Index>
    }

    static func joining(
        _ leadingValue: String,
        _ trailingValue: String,
        maximumOverlapWords: Int = 24
    ) -> String {
        let leading = normalizedWhitespace(leadingValue)
        let trailing = normalizedWhitespace(trailingValue)
        guard !leading.isEmpty else { return trailing }
        guard !trailing.isEmpty else { return leading }

        let leadingTokens = tokens(in: leading)
        let trailingTokens = tokens(in: trailing)
        let maximumOverlap = min(maximumOverlapWords, leadingTokens.count, trailingTokens.count)
        var overlapCount = 0

        if maximumOverlap >= 2 {
            for candidate in stride(from: maximumOverlap, through: 2, by: -1) {
                let leadingStart = leadingTokens.count - candidate
                let matches = (0..<candidate).allSatisfy { offset in
                    leadingTokens[leadingStart + offset].folded == trailingTokens[offset].folded
                }
                if matches {
                    overlapCount = candidate
                    break
                }
            }
        }

        guard overlapCount > 0 else {
            return appendWithoutOverlap(leading, trailing)
        }

        let consumedEnd = trailingTokens[overlapCount - 1].range.upperBound
        let remainder = normalizedWhitespace(String(trailing[consumedEnd...]))
        return appendWithoutOverlap(leading, remainder)
    }

    static func wordCount(in text: String) -> Int {
        tokens(in: text).count
    }

    static func canonicalWords(in text: String) -> [String] {
        tokens(in: text).map(\.folded)
    }

    private static func appendWithoutOverlap(_ leading: String, _ trailing: String) -> String {
        guard !trailing.isEmpty else { return leading }
        guard let first = trailing.first else { return leading }
        if ",.!?:;".contains(first), let last = leading.last, ",.!?:;".contains(last) {
            var revisedLeading = leading
            revisedLeading.removeLast()
            return revisedLeading + trailing
        }
        if ",.!?:;)]}".contains(first) || "([{\"".contains(leading.last ?? " ") {
            return leading + trailing
        }
        return "\(leading) \(trailing)"
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func tokens(in text: String) -> [Token] {
        var output: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }

            let start = index
            index = text.index(after: index)
            while index < text.endIndex {
                let character = text[index]
                if character.isLetter || character.isNumber {
                    index = text.index(after: index)
                    continue
                }
                if character == "'" || character == "’" || character == "-" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next].isLetter || text[next].isNumber {
                        index = next
                        continue
                    }
                }
                break
            }

            let range = start..<index
            let folded = String(text[range])
                .replacingOccurrences(of: "’", with: "'")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            output.append(Token(folded: folded, range: range))
        }
        return output
    }
}

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
    static let appleServiceFallbackPreferenceKey = "scribeflow.appleSpeechServiceFallbackEnabled"

    static var allowsAppleSpeechServiceFallback: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: appleServiceFallbackPreferenceKey) != nil else {
            return true
        }
        return defaults.bool(forKey: appleServiceFallbackPreferenceKey)
    }

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
            || !allowsAppleSpeechServiceFallback

        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
    }
}

final class SpeechAudioBufferSink: @unchecked Sendable {
    private final class BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    /// Recognition segments rotate during long recordings. Serialize both the
    /// handler swap and delivery without ever blocking the audio render thread.
    private let queue = DispatchQueue(
        label: "ai.scribeflow.live-speech-buffer-sink",
        qos: .userInitiated
    )
    private var handler: ((AVAudioPCMBuffer) -> Void)?

    func replaceHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        queue.sync {
            self.handler = handler
        }
    }

    func appendOwned(_ buffer: AVAudioPCMBuffer) {
        let box = BufferBox(buffer)
        queue.async { [weak self, box] in
            self?.handler?(box.buffer)
        }
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
    case onDeviceRecognitionUnavailable
    case unsupportedLocale
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "Speech recognition is temporarily unavailable."
        case .onDeviceRecognitionUnavailable:
            "On-device speech recognition is unavailable for this language. Enable Apple Speech fallback in Recording privacy to continue."
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
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
           let session = try? await AnalyzerLiveSpeechSession.make(
               inputFormat: inputFormat,
               context: context,
               onTranscript: onTranscript,
               onError: onError
           ) {
            return session
        }
        #endif

        guard let recognizer = SpeechRecognitionSupport.makeLegacyRecognizer(
            locale: context.recognitionLocale
        ),
              recognizer.isAvailable else {
            throw SpeechRecognitionPipelineError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition
                || SpeechRecognitionSupport.allowsAppleSpeechServiceFallback
        else {
            throw SpeechRecognitionPipelineError.onDeviceRecognitionUnavailable
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
    private struct RetiredRecognitionSegment {
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
    }

    nonisolated let audioSink = SpeechAudioBufferSink()

    private let recognizer: SFSpeechRecognizer
    private var context: SpeechRecognitionContext
    private let onTranscript: @MainActor (String, Bool) -> Void
    private let onError: @MainActor (String) -> Void

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var rotationTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var completedSegmentTranscripts: [Int: String] = [:]
    private var retiredSegments: [Int: RetiredRecognitionSegment] = [:]
    private var currentTranscript = ""
    private var generation = 0
    private var requiresOnDeviceRecognition: Bool
    private var consecutiveRecognitionFailures = 0
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
        self.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
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
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.completeFinish()
            }
        }

        teardown()
        return combinedTranscript
    }

    func updateContext(_ context: SpeechRecognitionContext) async {
        let phrasesChanged = context.contextualPhrases != self.context.contextualPhrases
        self.context = context
        guard phrasesChanged, !isCancelled, !isFinishing else { return }

        // Legacy requests cannot update contextual strings in place. Rotate the
        // request after the coordinator's debounce so newly entered names and
        // terminology influence recognition immediately instead of waiting for
        // the next 50-second long-session rotation.
        replaceRecognitionSegment()
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        commitCurrentTranscript()
        completeFinish()
        teardown()
    }

    private var combinedTranscript: String {
        var combined = ""
        for segmentGeneration in completedSegmentTranscripts.keys.sorted() {
            guard let segment = completedSegmentTranscripts[segmentGeneration] else { continue }
            combined = TranscriptAssembler.joining(combined, segment)
        }
        return TranscriptAssembler.joining(combined, currentTranscript)
    }

    private func replaceRecognitionSegment() {
        guard !isCancelled, !isFinishing else { return }
        restartTask?.cancel()
        restartTask = nil

        let oldRequest = recognitionRequest
        let oldTask = recognitionTask
        let oldGeneration = generation
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
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition

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

        if let oldRequest, let oldTask, oldGeneration > 0 {
            retiredSegments[oldGeneration] = RetiredRecognitionSegment(
                request: oldRequest,
                task: oldTask
            )
            oldRequest.endAudio()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.retireRecognitionSegment(oldGeneration)
            }
        }
        scheduleRotation()
    }

    private func handleRecognitionUpdate(
        text: String?,
        isFinal: Bool,
        errorDescription: String?,
        generation: Int
    ) {
        guard !isCancelled else { return }

        if generation < self.generation {
            let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cleaned.isEmpty {
                let existing = completedSegmentTranscripts[generation] ?? ""
                if isFinal || TranscriptAssembler.wordCount(in: cleaned) > TranscriptAssembler.wordCount(in: existing) {
                    completedSegmentTranscripts[generation] = cleaned
                    onTranscript(combinedTranscript, isFinal)
                }
            }
            if isFinal || errorDescription != nil {
                retireRecognitionSegment(generation)
            }
            return
        }

        guard generation == self.generation else { return }

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consecutiveRecognitionFailures = 0
            currentTranscript = text
            onTranscript(combinedTranscript, isFinal)
        }

        if isFinal {
            commitCurrentTranscript()
            recognitionRequest = nil
            recognitionTask = nil
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
            if requiresOnDeviceRecognition,
               SpeechRecognitionSupport.allowsAppleSpeechServiceFallback {
                requiresOnDeviceRecognition = false
            }
            consecutiveRecognitionFailures += 1
            guard consecutiveRecognitionFailures < 3 else {
                onError("Live speech recognition paused after repeated system errors. The full recording is still safe.")
                cancel()
                return
            }
            scheduleRestartAfterFailure()
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

    private func scheduleRestartAfterFailure() {
        restartTask?.cancel()
        let delay: Duration = consecutiveRecognitionFailures == 1
            ? .milliseconds(200)
            : .milliseconds(600)
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.replaceRecognitionSegment()
        }
    }

    private func commitCurrentTranscript() {
        let current = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }
        completedSegmentTranscripts[generation] = current
        currentTranscript = ""
        onTranscript(combinedTranscript, true)
    }

    private func retireRecognitionSegment(_ segmentGeneration: Int) {
        guard let retired = retiredSegments.removeValue(forKey: segmentGeneration) else { return }
        retired.request.endAudio()
        retired.task.cancel()
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
        restartTask?.cancel()
        restartTask = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        audioSink.replaceHandler(nil)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        for retired in retiredSegments.values {
            retired.request.endAudio()
            retired.task.cancel()
        }
        retiredSegments.removeAll()
    }
}

#if compiler(>=6.2)
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
    private var finalizedTranscript = ""
    private var volatileTranscript = ""
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
            bufferingPolicy: .bufferingNewest(512)
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
            audioPump.appendOwned(buffer)
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
        volatileTranscript = ""
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
        TranscriptAssembler.joining(finalizedTranscript, volatileTranscript)
    }

    private func startResultsTask() {
        resultsTask = Task { @MainActor [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedTranscript = TranscriptAssembler.joining(
                            self.finalizedTranscript,
                            text
                        )
                        self.volatileTranscript = ""
                    } else {
                        self.volatileTranscript = text
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
            completeText = TranscriptAssembler.joining(completeText, resultText)

            var appendedTimedRun = false
            for run in result.text.runs {
                let runText = String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
                guard !runText.isEmpty, let timeRange else { continue }
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
    private let converter: SpeechPCMBufferConverter
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var isAcceptingAudio = true
    private var isCancelled = false

    init(
        converter: SpeechPCMBufferConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.converter = converter
        self.continuation = continuation
    }

    func appendOwned(_ buffer: AVAudioPCMBuffer) {
        let box = BufferBox(buffer)
        queue.async { [self, box] in
            guard isAcceptingAudio,
                  !isCancelled,
                  let converted = try? converter.convert(box.buffer)
            else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isAcceptingAudio = false
                continuation.resume()
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            isAcceptingAudio = false
            isCancelled = true
        }
    }
}

@available(iOS 26.0, *)
private final class SpeechPCMBufferConverter: @unchecked Sendable {
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
#endif
