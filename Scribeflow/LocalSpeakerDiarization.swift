import AVFoundation
import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

enum LocalSpeakerDiarizationSettings {
    static let enabledKey = "scribeflow.localSpeakerDiarizationEnabled"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }
}

enum EnhancedSpeechSettings {
    static let enabledKey = "scribeflow.enhancedLocalTranscriptionEnabled"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }
}

enum EnhancedSpeechResourcePolicy {
    private static let minimumAvailableCapacity: Int64 = 1_000_000_000

    /// Large speech models should never compete with a thermally constrained
    /// device, Low Power Mode, or the user's last gigabyte of storage. The
    /// transcription pipeline automatically falls back to Apple Speech.
    static var allowsModelPreparation: Bool {
        let processInfo = ProcessInfo.processInfo
        guard !processInfo.isLowPowerModeEnabled else { return false }
        switch processInfo.thermalState {
        case .serious, .critical:
            return false
        case .nominal, .fair:
            break
        @unknown default:
            return false
        }

        let volumeURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let values = try? volumeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else {
            return true
        }
        return available >= minimumAvailableCapacity
    }
}

actor LocalSpeakerDiarizationService {
    static let shared = LocalSpeakerDiarizationService()

    #if canImport(FluidAudio)
    private struct AlignedWordChunk {
        var speaker: String
        var words: [String]
        var firstWordIndex: Int
        var lastWordIndex: Int
    }

    private var manager: OfflineDiarizerManager?
    private var managerSpeakerCount: Int?
    #endif

    func releaseModels() {
        #if canImport(FluidAudio)
        manager = nil
        managerSpeakerCount = nil
        #endif
    }

    func enrich(
        _ result: TranscriptionResult,
        audioURL: URL,
        expectedSpeakerCount: Int? = nil
    ) async -> TranscriptionResult {
        guard LocalSpeakerDiarizationSettings.isEnabled,
              result.provider == .localAppleSpeech || result.provider == .localEnhancedSpeech,
              result.segments.contains(where: { $0.startTime != nil && $0.endTime != nil }),
              audioDuration(at: audioURL) >= 4
        else {
            return coalesced(result)
        }

        #if canImport(FluidAudio)
        do {
            let constrainedSpeakerCount = expectedSpeakerCount.map { min(max($0, 1), 8) }
            let manager: OfflineDiarizerManager
            if let existing = self.manager,
               managerSpeakerCount == constrainedSpeakerCount {
                manager = existing
            } else {
                guard EnhancedSpeechResourcePolicy.allowsModelPreparation else {
                    return coalesced(result)
                }
                var configuration = OfflineDiarizerConfig.default
                // Meeting turns are often shorter than the library default.
                // Retain enough audio for stable embeddings while allowing
                // brief handoffs to register as a distinct speaker.
                configuration.embedding.minSegmentDurationSeconds = 0.75
                configuration.zeroVoteReembed = .init(
                    enabled: true,
                    minDurationSeconds: 0.35
                )
                configuration.clustering.numSpeakers = constrainedSpeakerCount
                let prepared = OfflineDiarizerManager(config: configuration)
                try await prepared.prepareModels()
                self.manager = prepared
                managerSpeakerCount = constrainedSpeakerCount
                manager = prepared
            }

            let diarization = try await manager.process(audioURL)
            let orderedTurns = diarization.segments
                .filter { $0.endTimeSeconds > $0.startTimeSeconds }
                .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            guard !orderedTurns.isEmpty else { return coalesced(result) }

            var displayNames: [String: String] = [:]
            for turn in orderedTurns where displayNames[turn.speakerId] == nil {
                displayNames[turn.speakerId] = "Speaker \(displayNames.count + 1)"
            }

            let aligned = result.segments.flatMap { segment in
                alignedSegments(
                    for: segment,
                    turns: orderedTurns,
                    displayNames: displayNames
                )
            }

            var enriched = result
            enriched.segments = Self.coalesce(aligned)
            enriched.diarizationAvailable = true
            return enriched
        } catch {
            return coalesced(result)
        }
        #else
        return coalesced(result)
        #endif
    }

    private func coalesced(_ result: TranscriptionResult) -> TranscriptionResult {
        var revised = result
        revised.segments = Self.coalesce(result.segments)
        return revised
    }

    private func audioDuration(at url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return 0
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    #if canImport(FluidAudio)
    private func alignedSegments(
        for segment: TranscriptionSegment,
        turns: [TimedSpeakerSegment],
        displayNames: [String: String]
    ) -> [TranscriptionSegment] {
        guard let start = segment.startTime,
              let end = segment.endTime,
              end > start
        else {
            var revised = segment
            revised.speaker = SpeakerIdentityResolver.normalizedDisplayName(segment.speaker)
            return [revised]
        }

        let relevantTurns = turns.filter { turn in
            let overlap = max(
                0,
                min(end, Double(turn.endTimeSeconds))
                    - max(start, Double(turn.startTimeSeconds))
            )
            return overlap >= 0.18
        }
        let distinctSpeakerIDs = Set(relevantTurns.map(\.speakerId))
        let words = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)

        guard distinctSpeakerIDs.count > 1,
              end - start >= 1.5,
              words.count >= max(4, distinctSpeakerIDs.count * 2)
        else {
            var revised = segment
            revised.speaker = bestSpeaker(
                for: segment,
                turns: turns,
                displayNames: displayNames
            ) ?? SpeakerIdentityResolver.normalizedDisplayName(segment.speaker)
            return [revised]
        }

        var chunks: [AlignedWordChunk] = []
        for (wordIndex, word) in words.enumerated() {
            let progress = (Double(wordIndex) + 0.5) / Double(words.count)
            let wordTime = start + ((end - start) * progress)
            let speakerID = speakerID(at: wordTime, turns: relevantTurns)
            let speaker = speakerID.flatMap { displayNames[$0] }
                ?? bestSpeaker(for: segment, turns: turns, displayNames: displayNames)
                ?? SpeakerIdentityResolver.normalizedDisplayName(segment.speaker)

            if chunks.last?.speaker == speaker {
                chunks[chunks.count - 1].words.append(word)
                chunks[chunks.count - 1].lastWordIndex = wordIndex
            } else {
                chunks.append(AlignedWordChunk(
                    speaker: speaker,
                    words: [word],
                    firstWordIndex: wordIndex,
                    lastWordIndex: wordIndex
                ))
            }
        }

        guard chunks.count > 1 else {
            var revised = segment
            revised.speaker = chunks.first?.speaker
                ?? SpeakerIdentityResolver.normalizedDisplayName(segment.speaker)
            return [revised]
        }

        return chunks.map { chunk in
            let chunkStart = start + ((end - start) * Double(chunk.firstWordIndex) / Double(words.count))
            let chunkEnd = start + ((end - start) * Double(chunk.lastWordIndex + 1) / Double(words.count))
            return TranscriptionSegment(
                speaker: chunk.speaker,
                text: chunk.words.joined(separator: " "),
                startTime: chunkStart,
                endTime: chunkEnd
            )
        }
    }

    private func speakerID(
        at time: TimeInterval,
        turns: [TimedSpeakerSegment]
    ) -> String? {
        let active = turns.filter {
            Double($0.startTimeSeconds) <= time && time <= Double($0.endTimeSeconds)
        }
        if let strongest = active.max(by: { $0.qualityScore < $1.qualityScore }) {
            return strongest.speakerId
        }

        guard let nearest = turns.min(by: {
            distance(from: time, to: $0) < distance(from: time, to: $1)
        }), distance(from: time, to: nearest) <= 0.75 else {
            return nil
        }
        return nearest.speakerId
    }

    private func bestSpeaker(
        for segment: TranscriptionSegment,
        turns: [TimedSpeakerSegment],
        displayNames: [String: String]
    ) -> String? {
        guard let start = segment.startTime,
              let end = segment.endTime,
              end > start
        else { return nil }

        var overlapBySpeaker: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap = max(
                0,
                min(end, Double(turn.endTimeSeconds))
                    - max(start, Double(turn.startTimeSeconds))
            )
            if overlap > 0 {
                overlapBySpeaker[turn.speakerId, default: 0] += overlap
            }
        }

        if let speakerID = overlapBySpeaker.max(by: { $0.value < $1.value })?.key {
            return displayNames[speakerID]
        }

        let midpoint = start + ((end - start) / 2)
        guard let nearest = turns.min(by: {
            distance(from: midpoint, to: $0) < distance(from: midpoint, to: $1)
        }), distance(from: midpoint, to: nearest) <= 1.5 else {
            return nil
        }
        return displayNames[nearest.speakerId]
    }

    private func distance(from time: TimeInterval, to turn: TimedSpeakerSegment) -> TimeInterval {
        let start = Double(turn.startTimeSeconds)
        let end = Double(turn.endTimeSeconds)
        if time < start { return start - time }
        if time > end { return time - end }
        return 0
    }
    #endif

    private static func coalesce(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        let ordered = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                switch ($0.startTime, $1.startTime) {
                case let (left?, right?): left < right
                case (nil, nil): false
                case (.some, nil): true
                case (nil, .some): false
                }
            }

        var output: [TranscriptionSegment] = []
        for segment in ordered {
            var cleaned = segment
            cleaned.speaker = SpeakerIdentityResolver.normalizedDisplayName(segment.speaker)
            cleaned.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard var previous = output.last else {
                output.append(cleaned)
                continue
            }

            let sameSpeaker = SpeakerIdentityResolver.canonicalKey(for: previous.speaker)
                == SpeakerIdentityResolver.canonicalKey(for: cleaned.speaker)
            let gap = gapBetween(previous, cleaned)
            let wordCount = previous.text.split(whereSeparator: \.isWhitespace).count
            let sentenceComplete = previous.text.last.map { ".!?".contains($0) } ?? false
            let shouldMerge = sameSpeaker
                && gap <= 1.4
                && wordCount < 38
                && !(sentenceComplete && wordCount >= 12)

            if shouldMerge {
                previous.text = joined(previous.text, cleaned.text)
                previous.startTime = previous.startTime ?? cleaned.startTime
                previous.endTime = cleaned.endTime ?? previous.endTime
                output[output.count - 1] = previous
            } else {
                output.append(cleaned)
            }
        }
        return output
    }

    private static func gapBetween(
        _ leading: TranscriptionSegment,
        _ trailing: TranscriptionSegment
    ) -> TimeInterval {
        guard let end = leading.endTime, let start = trailing.startTime else { return 0 }
        return max(0, start - end)
    }

    private static func joined(_ leading: String, _ trailing: String) -> String {
        TranscriptAssembler.joining(leading, trailing)
    }
}

final class TemporaryMeetingAudioWriter: @unchecked Sendable {
    private final class BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private let queue = DispatchQueue(
        label: "ai.scribeflow.live-audio-writer",
        qos: .userInitiated
    )
    private let url: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var isAcceptingAudio = true

    init(format: AVAudioFormat) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribeflow-live-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copied = AudioPCMBufferCopy.make(from: buffer) else { return }
        appendOwned(copied)
    }

    func appendOwned(_ buffer: AVAudioPCMBuffer) {
        let box = BufferBox(buffer)
        queue.async { [weak self, box] in
            guard let self, self.isAcceptingAudio else { return }
            self.write(box.buffer)
        }
    }

    func finish() async -> URL? {
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                isAcceptingAudio = false
                converter = nil
                file = nil
                let hasAudio = ((try? AVAudioFile(forReading: url).length) ?? 0) > 0
                if hasAudio {
                    continuation.resume(returning: url)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func discard() {
        queue.async { [self] in
            isAcceptingAudio = false
            converter = nil
            file = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ input: AVAudioPCMBuffer) {
        guard let file else { return }
        let outputFormat = file.processingFormat

        if input.format.isEqual(outputFormat) {
            try? file.write(from: input)
            return
        }

        if converter?.inputFormat.isEqual(input.format) != true
            || converter?.outputFormat.isEqual(outputFormat) != true {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter else { return }

        let rateRatio = outputFormat.sampleRate / max(input.format.sampleRate, 1)
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * rateRatio) + 32
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !suppliedInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return input
        }

        guard conversionError == nil,
              status == .haveData || status == .inputRanDry,
              output.frameLength > 0
        else { return }
        try? file.write(from: output)
    }

}
