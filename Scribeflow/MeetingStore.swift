import Foundation
import CryptoKit
import Observation
import OSLog
import UserNotifications
#if canImport(FoundationModels)
import FoundationModels
#endif

private let storeLog = Logger(subsystem: "ai.scribeflow.app", category: "MeetingStore")

private struct EventPrepCacheKey: Hashable {
    let event: CalendarEventSnapshot
    let excludingMeetingID: Meeting.ID?
}

private struct SourceProofCacheKey: Hashable {
    let meetingID: Meeting.ID
    let claim: String
}

private struct CommitmentSupersessionCandidate: Sendable {
    let meetingID: Meeting.ID
    let meetingDate: Date
    let commitmentID: Commitment.ID
    let statement: String
    let isOpen: Bool
}

private actor CommitmentSupersessionWorker {
    func supersededCommitmentIDs(
        from candidates: [CommitmentSupersessionCandidate]
    ) -> [Meeting.ID: Set<Commitment.ID>] {
        var latestByFingerprint: [String: (meetingID: Meeting.ID, meetingDate: Date)] = [:]

        for candidate in candidates {
            guard !Task.isCancelled else { return [:] }
            let fingerprint = candidate.statement
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
            guard !fingerprint.isEmpty else { continue }
            if let current = latestByFingerprint[fingerprint] {
                let shouldReplace = candidate.meetingDate > current.meetingDate
                    || (candidate.meetingDate == current.meetingDate
                        && candidate.meetingID.uuidString > current.meetingID.uuidString)
                guard shouldReplace else { continue }
            }
            latestByFingerprint[fingerprint] = (candidate.meetingID, candidate.meetingDate)
        }

        var superseded: [Meeting.ID: Set<Commitment.ID>] = [:]
        for candidate in candidates where candidate.isOpen {
            let fingerprint = candidate.statement
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
            guard let latest = latestByFingerprint[fingerprint],
                  latest.meetingID != candidate.meetingID
            else { continue }
            superseded[candidate.meetingID, default: []].insert(candidate.commitmentID)
        }
        return superseded
    }
}

private enum SensitiveContentDetector {
    private static let keywordGroups: [(SensitiveFlag, [String])] = [
        (.pricing, ["price", "pricing", "budget", "$"]),
        (.roadmap, ["roadmap", "launch", "q2", "q3"]),
        (.security, ["security", "legal", "retention", "permission"]),
        (.internalOnly, ["internal", "private", "not share", "do not share"])
    ]

    static func flags(for meeting: Meeting) -> [SensitiveFlag] {
        var flags = Set<SensitiveFlag>()
        let selfLabels: Set<String> = ["you", "me", "myself", "i", "self"]
        if meeting.attendees.contains(where: { attendee in
            let normalized = attendee.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && !selfLabels.contains(normalized)
        }) {
            flags.insert(.names)
        }

        func inspect(_ source: String) {
            guard flags.count < SensitiveFlag.allCases.count, !source.isEmpty else { return }
            let normalized = source.lowercased()
            for (flag, keywords) in keywordGroups where !flags.contains(flag) {
                if keywords.contains(where: normalized.contains) {
                    flags.insert(flag)
                }
            }
        }

        inspect(meeting.title)
        inspect(meeting.objective)
        inspect(meeting.trustedSourceNotes)
        for line in meeting.transcript where flags.count < SensitiveFlag.allCases.count {
            inspect(line.text)
        }
        for recording in meeting.audioRecordings where flags.count < SensitiveFlag.allCases.count {
            inspect(recording.linkedNote)
            inspect(recording.transcript)
        }

        return flags.sorted { $0.rawValue < $1.rawValue }
    }
}

/// Conservative lexical guardrail shared by generated briefs, source proof,
/// and workspace answers. A claim must be supported by one cited excerpt;
/// unrelated lines can never combine their tokens to manufacture support.
private enum ClaimEvidenceValidator {
    private static let ignoredTokens: Set<String> = [
        "about", "after", "again", "also", "around", "been", "being", "but", "from",
        "have", "into", "just", "more", "that", "than", "their", "them", "then",
        "they", "this", "what", "when", "with", "will", "would", "could", "should",
        "there", "here", "were", "your", "ours", "meeting", "notes", "please", "need",
        "needs", "task", "action", "the", "and", "for"
    ]

    private static let dateTerms: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", "today", "tomorrow", "tonight"
    ]

    private static let nonEntityCapitalizedWords: Set<String> = [
        "A", "An", "The", "This", "That", "These", "Those", "We", "I", "You", "They",
        "Decision", "Next", "Risk", "Summary", "Send", "Create", "Review", "Update",
        "Confirm", "Discuss", "Complete", "Prepare", "Share", "Follow"
    ]

    static func matchStrength(claim: String, source: String) -> SourceMatchStrength? {
        let normalizedClaim = normalizedText(claim)
        let normalizedSource = normalizedText(source)
        guard !normalizedClaim.isEmpty, !normalizedSource.isEmpty else { return nil }
        guard hasNegation(normalizedClaim) == hasNegation(normalizedSource) else { return nil }
        guard preservesAssertions(from: normalizedClaim, in: normalizedSource) else { return nil }
        guard criticalTerms(in: claim).isSubset(of: allTokens(in: source)) else { return nil }

        if fingerprint(normalizedClaim) == fingerprint(normalizedSource) {
            return .exact
        }
        if normalizedClaim.count >= 8,
           normalizedSource.contains(normalizedClaim) || normalizedClaim.contains(normalizedSource) {
            return .partial
        }

        let claimTokens = semanticTokens(in: normalizedClaim)
        let sourceTokens = semanticTokens(in: normalizedSource)
        guard !claimTokens.isEmpty, !sourceTokens.isEmpty else { return nil }
        let overlap = claimTokens.intersection(sourceTokens).count
        let required = claimTokens.count <= 3
            ? claimTokens.count
            : max(3, Int(ceil(Double(claimTokens.count) * 0.72)))
        return overlap >= required ? .partial : nil
    }

    static func supports(claim: String, sources: [String]) -> Bool {
        let claims = atomicClaims(in: claim)
        guard !claims.isEmpty else { return false }
        return claims.allSatisfy { atomicClaim in
            sources.contains { matchStrength(claim: atomicClaim, source: $0) != nil }
        }
    }

    static func bestSupportingSource(for claim: String, sources: [String]) -> String? {
        sources.first { matchStrength(claim: claim, source: $0) != nil }
    }

    static func isExact(_ claim: String, source: String) -> Bool {
        fingerprint(normalizedText(claim)) == fingerprint(normalizedText(source))
    }

    private static func atomicClaims(in text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ".!?;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func semanticTokens(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !ignoredTokens.contains($0) }
        )
    }

    private static func criticalTerms(in text: String) -> Set<String> {
        let lower = text.lowercased()
        var terms = Set(
            lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { token in
                    token.contains(where: \.isNumber) || dateTerms.contains(token)
                }
        )

        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
        for word in words where word.count > 1 {
            guard word.first?.isUppercase == true,
                  !nonEntityCapitalizedWords.contains(word)
            else { continue }
            terms.insert(word.lowercased())
        }
        return terms
    }

    private static func allTokens(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    private static func hasNegation(_ text: String) -> Bool {
        let markers = [" not ", " no ", " never ", " without ", " cannot ", "can't", "won't", "isn't", "wasn't"]
        let padded = " \(text.lowercased()) "
        return markers.contains { padded.contains($0) }
    }

    private static func preservesAssertions(from claim: String, in source: String) -> Bool {
        let decisionMarkers = ["decision", "decided", "approved", "agreed", "confirmed"]
        let commitmentMarkers = ["commit", "committed", "promised", "assigned", "must", "will"]
        let riskMarkers = ["risk", "blocked", "blocker", "at risk"]
        let uncertaintyMarkers = ["maybe", "might", "consider", "proposed", "pending", "not decided"]

        if containsAny(decisionMarkers, in: claim), !containsAny(decisionMarkers, in: source) { return false }
        if containsAny(commitmentMarkers, in: claim), !containsAny(commitmentMarkers, in: source) { return false }
        if containsAny(riskMarkers, in: claim), !containsAny(riskMarkers, in: source) { return false }
        if containsAny(uncertaintyMarkers, in: source),
           containsAny(decisionMarkers + commitmentMarkers, in: claim),
           !containsAny(uncertaintyMarkers, in: claim) {
            return false
        }
        return true
    }

    private static func containsAny(_ markers: [String], in text: String) -> Bool {
        markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func fingerprint(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}

struct WorkspaceAnswer {
    let text: String
    let citations: [RAGResult]
}

private actor MeetingAnalysisWorker {
    func analyze(_ meeting: Meeting) -> MeetingAnalysisBundle {
        let base = MeetingIntelligenceEngine.analysis(for: meeting)
        return MeetingAnalysisBundle(
            purpose: base.purpose,
            report: base.report,
            signals: base.signals,
            evidenceNoteLines: base.evidenceNoteLines,
            sourceReferencesByClaim: sourceReferencesByClaim(
                for: meeting,
                analysis: base
            ),
            sensitiveFlags: SensitiveContentDetector.flags(for: meeting)
        )
    }

    private func sourceReferencesByClaim(
        for meeting: Meeting,
        analysis: MeetingAnalysisBundle
    ) -> [String: [SourceReference]] {
        var claims = [
            analysis.report.headline
        ]
        claims.append(contentsOf: analysis.report.suggestedSummary)
        claims.append(contentsOf: analysis.report.decisions)
        claims.append(contentsOf: analysis.report.structuredActionItems.map(\.text))
        claims.append(contentsOf: analysis.report.risks)
        claims.append(contentsOf: analysis.report.openQuestions)
        claims.append(contentsOf: analysis.report.followUps)
        claims.append(contentsOf: meeting.commitments.map(\.statement))
        if let brief = meeting.aiBrief {
            claims.append(brief.summary)
            claims.append(contentsOf: brief.keyPoints)
            claims.append(contentsOf: brief.whatMatters)
            claims.append(contentsOf: brief.decisions)
            claims.append(contentsOf: brief.actions.map(\.task))
            claims.append(contentsOf: brief.openQuestions)
            claims.append(contentsOf: brief.risks)
            claims.append(contentsOf: brief.needsClarification)
            claims.append(contentsOf: brief.sections.flatMap(\.items))
            claims.append(contentsOf: brief.enhancedNotes.map(\.detail))
        }

        var referencesByClaim: [String: [SourceReference]] = [:]

        for claim in claims {
            guard referencesByClaim.count < 48 else { break }
            guard !Task.isCancelled else { break }
            let cleaned = claim.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = fingerprint(claim)
            guard !cleaned.isEmpty, !key.isEmpty, referencesByClaim[key] == nil else { continue }
            referencesByClaim[key] = references(
                for: cleaned,
                in: meeting,
                evidenceNoteLines: analysis.evidenceNoteLines
            )
        }
        return referencesByClaim
    }

    private func references(
        for claim: String,
        in meeting: Meeting,
        evidenceNoteLines: [IndexedSourceNoteLine]
    ) -> [SourceReference] {
        for line in evidenceNoteLines {
            guard let strength = ClaimEvidenceValidator.matchStrength(
                claim: claim,
                source: line.text
            ) else { continue }
            return [SourceReference(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                kind: .note,
                snippet: line.text,
                lineIndex: line.index,
                matchStrength: strength
            )]
        }

        var transcriptReferences: [SourceReference] = []
        transcriptReferences.reserveCapacity(2)
        for (index, line) in meeting.transcript.enumerated() {
            guard let strength = ClaimEvidenceValidator.matchStrength(
                claim: claim,
                source: line.text
            ) else { continue }
            transcriptReferences.append(SourceReference(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                kind: .transcript,
                snippet: line.text,
                speaker: line.speaker,
                transcriptLineID: line.id,
                lineIndex: index,
                matchStrength: strength
            ))
            if transcriptReferences.count == 2 { return transcriptReferences }
        }
        if !transcriptReferences.isEmpty { return transcriptReferences }

        for recording in meeting.audioRecordings {
            for source in [recording.linkedNote, recording.transcript] {
                guard let match = firstMatchingSnippet(for: claim, in: source) else { continue }
                return [SourceReference(
                    meetingID: meeting.id,
                    meetingTitle: meeting.title,
                    kind: .audioTranscript,
                    snippet: match.snippet,
                    speaker: recording.source.title,
                    matchStrength: match.strength
                )]
            }
        }

        guard meeting.calendarEventID != nil else { return [] }
        let calendarText = "\(meeting.title) \(meeting.attendees.joined(separator: " ")) \(meeting.objective)"
        guard let strength = ClaimEvidenceValidator.matchStrength(
            claim: claim,
            source: calendarText
        ) else { return [] }
        let end = meeting.calendarEndDate.map {
            " - \($0.formatted(date: .omitted, time: .shortened))"
        } ?? ""
        return [SourceReference(
            meetingID: meeting.id,
            meetingTitle: meeting.title,
            kind: .calendar,
            snippet: "\(meeting.when.formatted(date: .abbreviated, time: .shortened))\(end)",
            matchStrength: strength == .exact ? .exact : .contextual
        )]
    }

    private func firstMatchingSnippet(
        for claim: String,
        in source: String
    ) -> (snippet: String, strength: SourceMatchStrength)? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var result: (String, SourceMatchStrength)?
        trimmed.enumerateSubstrings(
            in: trimmed.startIndex..<trimmed.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, stop in
            let sentence = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return }
            if let match = self.matchingChunk(for: claim, in: sentence) {
                result = match
                stop = true
            }
        }
        return result
    }

    private func matchingChunk(
        for claim: String,
        in source: String
    ) -> (String, SourceMatchStrength)? {
        let text = source as NSString
        let chunkLength = 800
        guard text.length > chunkLength else {
            guard let strength = ClaimEvidenceValidator.matchStrength(
                claim: claim,
                source: source
            ) else { return nil }
            return (source, strength)
        }

        let step = 640
        var location = 0
        while location < text.length {
            let length = min(chunkLength, text.length - location)
            let chunk = text.substring(with: NSRange(location: location, length: length))
            if let strength = ClaimEvidenceValidator.matchStrength(
                claim: claim,
                source: chunk
            ) {
                return (chunk, strength)
            }
            if location + length == text.length { break }
            location += step
        }
        return nil
    }

    private func fingerprint(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

private actor MeetingScoreWorker {
    func score(for meeting: Meeting, allowsAccountability: Bool) -> MeetingScore? {
        guard allowsAccountability, !Task.isCancelled else { return nil }
        let hasSubstance = !meeting.commitments.isEmpty
            || meeting.transcript.count > 3
            || meeting.trustedSourceNotes.trimmingCharacters(in: .whitespacesAndNewlines).count >= 140
        guard hasSubstance else { return nil }
        return MeetingScorer.score(
            for: meeting,
            allowsAccountability: allowsAccountability
        )
    }
}

private actor MeetingPersistenceWriter {
    private static let maximumEncodedRowCacheBytes = 16 * 1_024 * 1_024

    private struct EncodedMeeting {
        let meeting: Meeting
        let data: Data
    }

    private var lastWrittenDigest: SHA256.Digest?
    private var currentFileIsKnownGood = false
    private var encodedMeetingsByID: [Meeting.ID: EncodedMeeting] = [:]
    private var lastEncodedLibraryByteCount = 0

    /// Encodes and atomically writes the library. Throws on encode/write
    /// failure so the caller can surface data loss instead of swallowing it.
    @discardableResult
    func saveMeetings(
        _ meetings: [Meeting],
        to url: URL,
        recoveryURL: URL
    ) throws -> Bool {
        // Debounced callers cancel stale snapshots while a newer mutation is
        // waiting. Drop those snapshots before they spend time encoding or
        // enter the serialized file-write path.
        guard !Task.isCancelled else { return false }
        let encodedLibrary: (data: Data, rowsByID: [Meeting.ID: EncodedMeeting])
        do {
            encodedLibrary = try encodeLibrary(meetings)
        } catch is CancellationError {
            return false
        }
        let data = encodedLibrary.data
        guard !Task.isCancelled else { return false }
        let digest = SHA256.hash(data: data)
        let fileManager = FileManager.default
        let currentFileExists = fileManager.fileExists(atPath: url.path)
        if lastWrittenDigest == digest, currentFileExists {
            encodedMeetingsByID = encodedLibrary.rowsByID
            return false
        }

        var existingData: Data?
        if currentFileExists, !currentFileIsKnownGood {
            existingData = try? Data(contentsOf: url, options: .mappedIfSafe)
            if lastWrittenDigest == nil,
               let existingData,
               SHA256.hash(data: existingData) == digest {
                lastWrittenDigest = digest
                currentFileIsKnownGood = true
                encodedMeetingsByID = encodedLibrary.rowsByID
                if !fileManager.fileExists(atPath: recoveryURL.path) {
                    try writeProtected(existingData, to: recoveryURL)
                }
                return false
            }
        }

        guard !Task.isCancelled else { return false }
        var preservedPreviousVersion = false
        if currentFileExists, currentFileIsKnownGood {
            try copyProtectedFile(from: url, to: recoveryURL)
            preservedPreviousVersion = true
        } else if let existingData, !existingData.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if (try? decoder.decode([Meeting].self, from: existingData)) != nil {
                try writeProtected(existingData, to: recoveryURL)
                preservedPreviousVersion = true
                currentFileIsKnownGood = true
            }
        }

        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        if !preservedPreviousVersion {
            try writeProtected(data, to: recoveryURL)
        }
        lastWrittenDigest = digest
        currentFileIsKnownGood = true
        encodedMeetingsByID = encodedLibrary.rowsByID
        return true
    }

    /// JSONEncoder work is proportional to changed rows rather than the whole
    /// library. The final array remains the same backwards-compatible JSON file
    /// and keeps the existing atomic write and recovery behavior.
    private func encodeLibrary(
        _ meetings: [Meeting]
    ) throws -> (data: Data, rowsByID: [Meeting.ID: EncodedMeeting]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var rowsByID: [Meeting.ID: EncodedMeeting] = [:]
        rowsByID.reserveCapacity(meetings.count)
        var cachedByteCount = 0
        var data = Data()
        data.reserveCapacity(max(lastEncodedLibraryByteCount, 2))
        data.append(0x5B)

        for (index, meeting) in meetings.enumerated() {
            try Task.checkCancellation()
            let row: EncodedMeeting
            if let cached = encodedMeetingsByID[meeting.id], cached.meeting == meeting {
                row = cached
            } else {
                row = EncodedMeeting(
                    meeting: meeting,
                    data: try encoder.encode(meeting)
                )
            }
            if cachedByteCount + row.data.count <= Self.maximumEncodedRowCacheBytes {
                rowsByID[meeting.id] = row
                cachedByteCount += row.data.count
            }
            if index > 0 { data.append(0x2C) }
            data.append(row.data)
        }
        data.append(0x5D)
        lastEncodedLibraryByteCount = data.count
        return (data, rowsByID)
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    /// APFS can clone this copy without materializing the complete JSON in app
    /// memory. Staging beside the destination keeps the recovery file atomic.
    private func copyProtectedFile(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let staged = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try fileManager.copyItem(at: source, to: staged)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: staged.path
            )
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staged,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    /// Copies the live file to a known-good backup — but only after verifying it
    /// still decodes. This snapshot is the recovery source if the main file is
    /// later truncated or corrupted. Called once per launch from a file we just
    /// loaded successfully, so it never propagates same-session bad state.
    func snapshotKnownGood(from source: URL, to backup: URL) {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard (try? decoder.decode([Meeting].self, from: data)) != nil else { return }
        do {
            try copyProtectedFile(from: source, to: backup)
            lastWrittenDigest = SHA256.hash(data: data)
            currentFileIsKnownGood = true
        } catch {
            return
        }
    }
}

@MainActor
@Observable
final class MeetingStore {
    private struct MutationEffects: OptionSet {
        let rawValue: UInt8

        static let collectionCaches = MutationEffects(rawValue: 1 << 0)
        static let semanticCaches = MutationEffects(rawValue: 1 << 1)
        static let prepCaches = MutationEffects(rawValue: 1 << 2)
        static let retentionSchedule = MutationEffects(rawValue: 1 << 3)

        static let presentation: MutationEffects = [.collectionCaches]
        static let commitments: MutationEffects = [.collectionCaches, .prepCaches]
        static let semanticContent: MutationEffects = [
            .collectionCaches,
            .semanticCaches,
            .prepCaches
        ]
        static let semanticContentAndRetention: MutationEffects = [
            .collectionCaches,
            .semanticCaches,
            .prepCaches,
            .retentionSchedule
        ]
        static let retention: MutationEffects = [.collectionCaches, .retentionSchedule]
        static let all: MutationEffects = [
            .collectionCaches,
            .semanticCaches,
            .prepCaches,
            .retentionSchedule
        ]
    }

    var meetings: [Meeting] {
        didSet {
            let effects = pendingMutationEffects
            let changedMeetingIDs = pendingChangedMeetingIDs
            pendingMutationEffects = .all
            pendingChangedMeetingIDs = nil
            revision &+= 1
            if !isApplyingInitialLoad {
                save()
            }
            if shouldRebuildIndex() {
                rebuildIndex()
            }
            if effects.contains(.collectionCaches) {
                _recentMeetings = nil
                _pinnedMeetings = nil
                _openLoopsCache = nil
                _smartCollectionsCache = nil
            }
            if effects.contains(.semanticCaches) {
                if let changedMeetingIDs {
                    for meetingID in changedMeetingIDs {
                        _signalsCache.removeValue(forKey: meetingID)
                        _intelligenceReportCache.removeValue(forKey: meetingID)
                        _purposeCache.removeValue(forKey: meetingID)
                        _evidenceNoteLinesCache.removeValue(forKey: meetingID)
                        _sourceReferencesByClaimCache.removeValue(forKey: meetingID)
                        _sensitiveFlagsCache.removeValue(forKey: meetingID)
                        _workspaceTagsCache.removeValue(forKey: meetingID)
                    }
                    let staleProofKeys = _sourceProofCache.keys.filter {
                        changedMeetingIDs.contains($0.meetingID)
                    }
                    for key in staleProofKeys {
                        _sourceProofCache.removeValue(forKey: key)
                    }
                } else {
                    _signalsCache.removeAll(keepingCapacity: true)
                    _intelligenceReportCache.removeAll(keepingCapacity: true)
                    _purposeCache.removeAll(keepingCapacity: true)
                    _evidenceNoteLinesCache.removeAll(keepingCapacity: true)
                    _sourceReferencesByClaimCache.removeAll(keepingCapacity: true)
                    _sensitiveFlagsCache.removeAll(keepingCapacity: true)
                    _workspaceTagsCache.removeAll(keepingCapacity: true)
                    _sourceProofCache.removeAll(keepingCapacity: true)
                }
            }
            if effects.contains(.prepCaches) {
                _prepBriefCache.removeAll(keepingCapacity: true)
                _eventPrepCache.removeAll(keepingCapacity: true)
            }
            if effects.contains(.retentionSchedule), !isApplyingInitialLoad {
                scheduleRetentionRecalculation()
            }
        }
    }

    private(set) var revision = 0

    /// Launch never waits for JSON decoding on the UI actor. The app renders a
    /// lightweight progress surface until this store has applied its library.
    private(set) var isLoadingLibrary = true
    private(set) var hasLoadedLibrary = false
    private(set) var libraryLoadingStage = "Opening your workspace"

    /// `true` when the most recent persistence attempt failed. Observed by the
    /// UI so data-loss is surfaced rather than silently swallowed.
    private(set) var lastSaveFailed = false

    /// Set at launch when the main library file was unreadable AND no backup
    /// could be recovered. The corrupt file is quarantined, not destroyed.
    private(set) var loadFailed = false

    /// Set at launch when the main file was unreadable but a backup restored
    /// the library. Surfaced so the user knows recovery happened.
    private(set) var recoveredFromBackup = false

    /// Bump when `Meeting`'s on-disk shape changes in a non-additive way.
    /// Backups carry this so a newer file isn't silently mis-read by an older
    /// build.
    static let currentSchemaVersion = 1
    private static let currentDerivedDataVersion = 3

    @ObservationIgnored private var _recentMeetings: [Meeting]? = nil
    @ObservationIgnored private var _pinnedMeetings: [Meeting]? = nil
    @ObservationIgnored private var _openLoopsCache: [OpenLoop]? = nil
    @ObservationIgnored private var _smartCollectionsCache: [SmartCollectionCard]? = nil
    @ObservationIgnored private var _signalsCache: [Meeting.ID: MeetingSignals] = [:]
    @ObservationIgnored private var _prepBriefCache: [Meeting.ID: PrepBrief] = [:]
    @ObservationIgnored private var _eventPrepCache: [EventPrepCacheKey: EventPrepBrief] = [:]
    @ObservationIgnored private var _intelligenceReportCache: [Meeting.ID: MeetingIntelligenceReport] = [:]
    @ObservationIgnored private var _purposeCache: [Meeting.ID: CapturePurpose] = [:]
    @ObservationIgnored private var _evidenceNoteLinesCache: [Meeting.ID: [IndexedSourceNoteLine]] = [:]
    @ObservationIgnored private var _sourceReferencesByClaimCache: [Meeting.ID: [String: [SourceReference]]] = [:]
    @ObservationIgnored private var _sensitiveFlagsCache: [Meeting.ID: [SensitiveFlag]] = [:]
    @ObservationIgnored private var _workspaceTagsCache: [Meeting.ID: [String]] = [:]
    @ObservationIgnored private var _sourceProofCache: [SourceProofCacheKey: SourceProof] = [:]
    @ObservationIgnored private var _recallIndex: LocalRAG.Index? = nil
    @ObservationIgnored private var _recallIndexRevision = -1
    @ObservationIgnored private var pendingMutationEffects: MutationEffects = .all
    @ObservationIgnored private var pendingChangedMeetingIDs: Set<Meeting.ID>?

    /// Dictionary index for O(1) `meeting(withID:)` lookup. Previously a
    /// linear `first(where:)` scan — measurable lag on libraries >100.
    @ObservationIgnored private var indexByID: [Meeting.ID: Int] = [:]

    /// Most edits change fields inside an existing row, not the row identity or
    /// position. Keep the lookup index out of those hot paths.
    @ObservationIgnored private var forceIndexRebuildAfterMutation = false

    /// A single welcoming example meeting for first launch. Notes are written
    /// to show the Smart Notes extraction at its best — a decision, owned
    /// actions (You / named), a due date, a risk — so the app feels alive and
    /// the core value is obvious on screen one.
    private static func firstRunExample() -> Meeting {
        Meeting(
            title: "Example · Acme kickoff",
            workspace: "Welcome",
            when: .now.addingTimeInterval(-1800),
            durationMinutes: 24,
            attendees: ["Maya", "Sam"],
            status: .ready,
            stage: "Captured and ready to review",
            objective: "See how Scribeflow turns rough notes into a clean, shareable recap.",
            rawNotes: """
            - We decided to start with the mobile rollout first
            - I'll send the security overview by Friday
            - Maya will confirm the integration scope
            - Risk: legal still needs to review the data terms
            - Budget approved at $25k for phase one
            """,
            transcript: [],
            summaries: [],
            prompts: [],
            destinations: [],
            selectedTemplate: .discovery,
            selectedPromptID: nil,
            isPinned: false
        )
    }

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        indexByID.reserveCapacity(meetings.count)
        for (i, m) in meetings.enumerated() {
            indexByID[m.id] = i
        }
    }

    private func shouldRebuildIndex() -> Bool {
        defer { forceIndexRebuildAfterMutation = false }
        return forceIndexRebuildAfterMutation || indexByID.count != meetings.count
    }

    private func index(for id: Meeting.ID) -> Int? {
        if let index = indexByID[id],
           meetings.indices.contains(index),
           meetings[index].id == id {
            return index
        }

        rebuildIndex()
        return indexByID[id]
    }

    private func replaceMeeting(
        _ meeting: Meeting,
        at index: Int,
        effects: MutationEffects = .all
    ) {
        guard meetings.indices.contains(index) else { return }
        pendingMutationEffects = effects
        pendingChangedMeetingIDs = [meeting.id]
        meetings[index] = meeting
    }

    private func replaceMeetings(
        _ updatedMeetings: [Meeting],
        effects: MutationEffects = .all
    ) {
        pendingMutationEffects = effects
        pendingChangedMeetingIDs = nil
        meetings = updatedMeetings
    }

    @ObservationIgnored
    private let saveURL: URL

    /// Known-good snapshot, refreshed once per launch from a file that decoded.
    @ObservationIgnored
    private let backupURL: URL

    @ObservationIgnored
    private let persistenceWriter = MeetingPersistenceWriter()

    @ObservationIgnored
    private let analysisWorker = MeetingAnalysisWorker()

    @ObservationIgnored
    private let commitmentSupersessionWorker = CommitmentSupersessionWorker()

    @ObservationIgnored
    private let meetingScoreWorker = MeetingScoreWorker()

    @ObservationIgnored
    private var saveTask: Task<Void, Never>?

    @ObservationIgnored
    private var libraryLoadTask: Task<Void, Never>?

    @ObservationIgnored
    private var isApplyingInitialLoad = false

    @ObservationIgnored
    private var regenerationTasks: [Meeting.ID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var regenerationRunIDs: [Meeting.ID: UUID] = [:]

    @ObservationIgnored
    private var regenerationDerivedRunIDs: [Meeting.ID: UUID] = [:]

    @ObservationIgnored
    private var derivedMigrationTask: Task<Void, Never>?

    @ObservationIgnored
    private var derivedMigrationRunID: UUID?

    @ObservationIgnored
    private var derivedMigrationPendingIDs: Set<Meeting.ID> = []

    @ObservationIgnored
    private var commitmentSupersessionTask: Task<Void, Never>?

    @ObservationIgnored
    private var commitmentSupersessionRunID: UUID?

    @ObservationIgnored
    private var retentionTask: Task<Void, Never>?

    @ObservationIgnored
    private var retentionRecalculationTask: Task<Void, Never>?

    @ObservationIgnored
    private var aiProcessingTasks: [Meeting.ID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var aiProcessingRunIDs: [Meeting.ID: UUID] = [:]

    init() {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = baseDirectory.appendingPathComponent("Scribeflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? RecordingFileStore.ensureDirectory()
        let mainURL = folder.appendingPathComponent("meetings.json")
        saveURL = mainURL
        backupURL = folder.appendingPathComponent("meetings.backup.json")
        // Clean up legacy wellness.json from older builds (fitness feature was removed).
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("wellness.json"))
        meetings = []
    }

    /// Loads and normalizes the library once. Multiple launch/resume callers
    /// await the same task, so recovery and indexing can never race an empty
    /// store or trigger duplicate work.
    func loadLibraryIfNeeded() async {
        if hasLoadedLibrary { return }
        if let libraryLoadTask {
            await libraryLoadTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitialLibraryLoad()
        }
        libraryLoadTask = task
        await task.value
        libraryLoadTask = nil
    }

    private func performInitialLibraryLoad() async {
        let shouldResetData = ProcessInfo.processInfo.arguments.contains("-SCRIBEFLOW_RESET_DATA")
        let shouldUseSeedData = ProcessInfo.processInfo.arguments.contains("-SCRIBEFLOW_USE_SEED_DATA")

        let fileManager = FileManager.default
        let hasSavedData = fileManager.fileExists(atPath: saveURL.path)
            || fileManager.fileExists(atPath: backupURL.path)
        var loadedMeetings: [Meeting]
        var didFailToLoad = false
        var didRecoverFromBackup = false

        if shouldResetData && shouldUseSeedData {
            libraryLoadingStage = "Preparing the demo workspace"
            loadedMeetings = Meeting.seed.map { meeting in
                var mutableMeeting = Self.normalizedMeeting(meeting)
                mutableMeeting.selectedPromptID = meeting.prompts.first?.id
                return mutableMeeting
            }
        } else if shouldResetData {
            loadedMeetings = []
        } else if hasSavedData {
            // Real data wins over seed. Recovers from the backup and quarantines
            // (never deletes) a corrupt main file rather than wiping the library.
            libraryLoadingStage = "Opening saved notes"
            let mainURL = saveURL
            let recoveryURL = backupURL
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.loadNormalizedMeetings(mainURL: mainURL, backupURL: recoveryURL)
            }.value
            loadedMeetings = outcome.meetings
            didFailToLoad = outcome.loadFailed
            didRecoverFromBackup = outcome.recoveredFromBackup
        } else if shouldUseSeedData {
            libraryLoadingStage = "Preparing the demo workspace"
            loadedMeetings = Meeting.seed.map { meeting in
                var mutableMeeting = Self.normalizedMeeting(meeting)
                mutableMeeting.selectedPromptID = meeting.prompts.first?.id
                return mutableMeeting
            }
        } else if !UserDefaults.standard.bool(forKey: "scribeflow.didSeedFirstRunExample") {
            // Genuine first launch — land in one labeled example so the app
            // isn't a blank slate. Happens exactly once; deleting it is final.
            UserDefaults.standard.set(true, forKey: "scribeflow.didSeedFirstRunExample")
            loadedMeetings = [Self.normalizedMeeting(Self.firstRunExample())]
        } else {
            loadedMeetings = []
        }

        libraryLoadingStage = "Preparing your workspace"
        isApplyingInitialLoad = true
        loadFailed = didFailToLoad
        recoveredFromBackup = didRecoverFromBackup
        replaceMeetings(loadedMeetings)
        isApplyingInitialLoad = false
        hasLoadedLibrary = true
        isLoadingLibrary = false

        // Snapshot a known-good backup off the file we just loaded, so a future
        // corrupt write has a recovery source. Skipped when we already recovered
        // (the backup is the source) or when there's nothing persisted yet.
        if !loadFailed, !recoveredFromBackup, !meetings.isEmpty {
            let source = saveURL
            let backup = backupURL
            let writer = persistenceWriter
            Task(priority: .utility) { await writer.snapshotKnownGood(from: source, to: backup) }
        }

        let defaults = UserDefaults.standard
        let automaticBackupKey = "scribeflow.automaticBackupsEnabled"
        let automaticBackupsEnabled = defaults.object(forKey: automaticBackupKey) == nil
            ? true
            : defaults.bool(forKey: automaticBackupKey)
        if automaticBackupsEnabled, !meetings.isEmpty {
            let snapshot = meetings
            Task(priority: .utility) {
                _ = try? await BackupArchiveService.shared.saveAutomaticBackup(
                    meetings: snapshot,
                    schemaVersion: Self.currentSchemaVersion
                )
            }
        }

        // Derived summaries and proof are persisted with each meeting. Repair
        // legacy or incomplete rows after first paint so a large library never
        // makes launch wait on note analysis.
        let rowsNeedingMigration = meetings
            .filter(Self.needsDerivedDataRefresh)
            .map(\.id)
        let authoredSeedIDs = shouldUseSeedData ? Set(meetings.map(\.id)) : []
        scheduleDerivedDataMigration(
            for: rowsNeedingMigration,
            preservingAuthoredCommitmentsFor: authoredSeedIDs
        )
        enforceRetentionPolicies()
    }

    deinit {
        libraryLoadTask?.cancel()
        saveTask?.cancel()
        regenerationTasks.values.forEach { $0.cancel() }
        derivedMigrationTask?.cancel()
        commitmentSupersessionTask?.cancel()
        retentionTask?.cancel()
        retentionRecalculationTask?.cancel()
        aiProcessingTasks.values.forEach { $0.cancel() }
    }

    private static func needsDerivedDataRefresh(_ meeting: Meeting) -> Bool {
        let hasEvidenceEligibleNotes = !meeting.trustedSourceNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return meeting.derivedDataVersion < currentDerivedDataVersion
            || meeting.summaries.isEmpty
            || (hasEvidenceEligibleNotes
                && meeting.evidenceItems.isEmpty
                && meeting.dismissedEvidenceFingerprints.isEmpty)
    }

    private func scheduleDerivedDataMigration(
        for meetingIDs: [Meeting.ID],
        preservingAuthoredCommitmentsFor authoredMeetingIDs: Set<Meeting.ID> = [],
        forceRefresh: Bool = false
    ) {
        let previouslyPendingIDs = derivedMigrationPendingIDs
        derivedMigrationTask?.cancel()
        derivedMigrationPendingIDs.removeAll()

        let pendingIDs = Set(meetingIDs)
        let runID = UUID()
        derivedMigrationRunID = runID
        derivedMigrationPendingIDs = pendingIDs
        updateDerivedProcessingStates(for: previouslyPendingIDs.union(pendingIDs))
        derivedMigrationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.derivedMigrationRunID == runID {
                    let remainingIDs = self.derivedMigrationPendingIDs
                    self.derivedMigrationPendingIDs.removeAll()
                    self.derivedMigrationRunID = nil
                    self.derivedMigrationTask = nil
                    self.updateDerivedProcessingStates(for: remainingIDs)
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            for id in meetingIDs {
                guard !Task.isCancelled,
                      let index = self.index(for: id),
                      forceRefresh || Self.needsDerivedDataRefresh(self.meetings[index])
                else { continue }
                let source = self.meetings[index]
                let analysis = await self.analysisWorker.analyze(source)
                guard !Task.isCancelled,
                      let currentIndex = self.index(for: id),
                      self.meetings[currentIndex] == source
                else { continue }
                self.refreshSummariesIfNeeded(
                    at: currentIndex,
                    applySupersededCommitments: false,
                    preserveAuthoredCommitments: authoredMeetingIDs.contains(id),
                    analysis: analysis
                )
                self.derivedMigrationPendingIDs.remove(id)
                self.updateDerivedProcessingState(for: id)
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled else { return }
            self.scheduleSupersededCommitmentRefresh()
        }
    }

    // MARK: - Load + recovery

    struct LoadOutcome: Equatable {
        var meetings: [Meeting]
        var loadFailed: Bool
        var recoveredFromBackup: Bool
    }

    nonisolated static func decodeMeetings(_ data: Data) -> [Meeting]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Meeting].self, from: data)
    }

    nonisolated private static func loadNormalizedMeetings(
        mainURL: URL,
        backupURL: URL
    ) -> LoadOutcome {
        var outcome = loadMeetings(mainURL: mainURL, backupURL: backupURL)
        outcome.meetings = outcome.meetings.map(normalizedMeeting)
        return outcome
    }

    /// Loads the library with a recovery ladder: main → backup → quarantine.
    /// A corrupt main file is moved aside (preserved for manual rescue), never
    /// deleted, so an empty save can't permanently destroy it.
    nonisolated static func loadMeetings(mainURL: URL, backupURL: URL) -> LoadOutcome {
        let fileManager = FileManager.default

        if let data = try? Data(contentsOf: mainURL, options: .mappedIfSafe), !data.isEmpty {
            if let meetings = decodeMeetings(data) {
                return LoadOutcome(meetings: meetings, loadFailed: false, recoveredFromBackup: false)
            }
            // Main is present but unreadable. Try the backup, then quarantine main.
            if let backupData = try? Data(contentsOf: backupURL, options: .mappedIfSafe),
               let meetings = decodeMeetings(backupData) {
                quarantine(mainURL, fileManager: fileManager)
                return LoadOutcome(meetings: meetings, loadFailed: false, recoveredFromBackup: true)
            }
            quarantine(mainURL, fileManager: fileManager)
            return LoadOutcome(meetings: [], loadFailed: true, recoveredFromBackup: false)
        }

        // No usable main file — fall back to the backup if one survived.
        if let backupData = try? Data(contentsOf: backupURL, options: .mappedIfSafe),
           let meetings = decodeMeetings(backupData), !meetings.isEmpty {
            return LoadOutcome(meetings: meetings, loadFailed: false, recoveredFromBackup: true)
        }
        return LoadOutcome(meetings: [], loadFailed: false, recoveredFromBackup: false)
    }

    /// Moves an unreadable file aside with a timestamp so the bytes survive for
    /// manual recovery instead of being overwritten by the next save.
    nonisolated static func quarantine(_ url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let dest = url.deletingLastPathComponent().appendingPathComponent("meetings.corrupt-\(stamp).json")
        do {
            try fileManager.moveItem(at: url, to: dest)
            storeLog.error("Quarantined unreadable library to \(dest.lastPathComponent, privacy: .public)")
        } catch {
            storeLog.error("Failed to quarantine unreadable library: \(error.localizedDescription, privacy: .public)")
        }
    }

    var pinnedMeetings: [Meeting] {
        _ = meetings // register observation dependency
        if let cached = _pinnedMeetings { return cached }
        let computed = meetings.filter(\.isPinned).sorted(by: Meeting.sortDescending)
        _pinnedMeetings = computed
        return computed
    }

    var recentMeetings: [Meeting] {
        _ = meetings // register observation dependency
        if let cached = _recentMeetings { return cached }
        let computed = meetings.sorted(by: Meeting.sortDescending)
        _recentMeetings = computed
        return computed
    }

    var totalMeetingsCount: Int {
        meetings.count
    }

    var liveMeetingsCount: Int {
        meetings.filter { $0.status == .live }.count
    }

    var followUpCount: Int {
        meetings.filter { meeting in
            meeting.allowsAccountabilityExtraction
                && meeting.commitments.contains {
                    $0.status == .open || $0.status == .atRisk
                }
        }.count
    }

    var sharedMeetingsCount: Int {
        meetings.filter { $0.status == .shared }.count
    }

    var phoneCallMeetingsCount: Int {
        meetings.filter(\.isCallMeeting).count
    }

    var workspacesCount: Int {
        Set(meetings.map(\.workspace)).count
    }

    var todayBrief: String {
        let recent = Array(recentMeetings.prefix(3))
        guard !recent.isEmpty else {
            return "Start with a quick note or live capture and Scribeflow will shape the rest."
        }

        let themes = topWorkspaceThemes(limit: 2)
        let firstTitle = recent[0].title

        if themes.isEmpty {
            return "Your latest thread is \(firstTitle). Scribeflow is ready to turn rough notes into a cleaner brief."
        }

        return "Your recent captures keep circling around \(themes.joined(separator: " and ")). Start from \(firstTitle) or ask across the full workspace."
    }

    var workspaceSignals: [WorkspaceSignal] {
        let recent = Array(recentMeetings.prefix(8))
        guard !recent.isEmpty else {
            return [
                WorkspaceSignal(
                    title: "Ready to capture",
                    detail: "No saved meetings yet. The first few notes will shape your workspace pulse here.",
                    systemImage: "sparkles"
                )
            ]
        }

        var signals: [WorkspaceSignal] = []

        if let latest = recent.first {
            signals.append(
                WorkspaceSignal(
                    title: "Latest momentum",
                    detail: "\(latest.title) is your freshest note and can anchor the next follow-up.",
                    systemImage: "clock.arrow.circlepath"
                )
            )
        }

        let themes = topWorkspaceThemes(limit: 3)
        if !themes.isEmpty {
            signals.append(
                WorkspaceSignal(
                    title: "Recurring themes",
                    detail: themes.joined(separator: ", ").capitalized,
                    systemImage: "chart.line.text.clipboard"
                )
            )
        }

        if phoneCallMeetingsCount > 0 {
            signals.append(
                WorkspaceSignal(
                    title: "Call capture",
                    detail: "\(phoneCallMeetingsCount) call note\(phoneCallMeetingsCount == 1 ? "" : "s") saved and ready to refine.",
                    systemImage: "phone.connection.fill"
                )
            )
        }

        if followUpCount > 0 {
            signals.append(
                WorkspaceSignal(
                    title: "Open follow-through",
                    detail: "\(followUpCount) meeting\(followUpCount == 1 ? "" : "s") still \(followUpCount == 1 ? "needs" : "need") a next move.",
                    systemImage: "checklist.checked"
                )
            )
        }

        return Array(signals.prefix(3))
    }

    var totalOpenLoopsCount: Int {
        openLoops(limit: 50).count
    }

    var captureStreakDays: Int {
        let calendar = Calendar.current
        let meetingDays = Set(meetings.map { calendar.startOfDay(for: $0.when) })
        guard !meetingDays.isEmpty else { return 0 }
        var streak = 0
        var cursor = calendar.startOfDay(for: .now)
        if !meetingDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  meetingDays.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        while meetingDays.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    var weeklyMeetingCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        return meetings.filter { $0.when >= cutoff }.count
    }

    var weeklyMinutesCaptured: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        return meetings.filter { $0.when >= cutoff }.reduce(0) { $0 + $1.durationMinutes }
    }


    func evidenceItems(for meeting: Meeting, filter: EvidenceFilter = .all) -> [EvidenceItem] {
        switch filter {
        case .all:
            return meeting.evidenceItems
        case .verifiedOnly:
            return meeting.evidenceItems.filter { $0.level == .verified }
        case .hideInferred:
            return meeting.evidenceItems.filter { $0.level != .inferred }
        }
    }

    func sourceProof(for text: String, in meeting: Meeting) -> SourceProof {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SourceProofCacheKey(
            meetingID: meeting.id,
            claim: cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        )
        if let cached = _sourceProofCache[key] {
            return cached
        }

        let fingerprint = normalizedFingerprint(cleaned)
        let proof: SourceProof
        if let prefetchedReferences = _sourceReferencesByClaimCache[meeting.id]?[fingerprint] {
            if prefetchedReferences.isEmpty {
                let hasSourceContext = !meeting.trustedSourceNotes
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !meeting.transcript.isEmpty
                    || meeting.audioRecordings.contains {
                        !$0.transcript.isEmpty || !$0.linkedNote.isEmpty
                    }
                proof = SourceProof(
                    confidence: hasSourceContext ? .inferred : .needsReview,
                    sourceMeetingTitle: meeting.title,
                    references: [],
                    fallbackDetail: hasSourceContext
                        ? "Generated from saved meeting context without a direct source line."
                        : "Add notes or transcript lines before treating this as fact."
                )
            } else {
                proof = sourceProof(
                    references: prefetchedReferences,
                    meeting: meeting,
                    fallbackDetail: "Matched a source in this meeting."
                )
            }
        } else {
            proof = makeSourceProof(for: cleaned, in: meeting)
        }
        if _sourceProofCache.count >= 128 {
            _sourceProofCache.removeAll(keepingCapacity: true)
        }
        _sourceProofCache[key] = proof
        return proof
    }

    private func makeSourceProof(for cleaned: String, in meeting: Meeting) -> SourceProof {
        guard !cleaned.isEmpty else {
            return SourceProof(
                confidence: .needsReview,
                sourceMeetingTitle: meeting.title,
                references: [],
                fallbackDetail: "No claim text was available to verify."
            )
        }

        if let evidence = bestEvidenceMatch(for: cleaned, in: meeting),
           !evidence.sourceReferences.isEmpty
        {
            return sourceProof(
                references: evidence.sourceReferences,
                meeting: meeting,
                fallbackDetail: "Matched saved evidence in this meeting."
            )
        }

        let noteReferences = matchingNoteReferences(for: cleaned, in: meeting)
        if !noteReferences.isEmpty {
            return sourceProof(
                references: noteReferences,
                meeting: meeting,
                fallbackDetail: "Matched saved notes in this meeting."
            )
        }

        let transcriptReferences = matchingTranscriptReferences(for: cleaned, in: meeting)
        if !transcriptReferences.isEmpty {
            return sourceProof(
                references: transcriptReferences,
                meeting: meeting,
                fallbackDetail: "Matched transcript proof in this meeting."
            )
        }

        let audioReferences = matchingAudioReferences(for: cleaned, in: meeting)
        if !audioReferences.isEmpty {
            return sourceProof(
                references: audioReferences,
                meeting: meeting,
                fallbackDetail: "Matched an attached audio transcript in this meeting."
            )
        }

        if let calendarReference = calendarReference(for: cleaned, in: meeting) {
            return sourceProof(
                references: [calendarReference],
                meeting: meeting,
                fallbackDetail: "Matched calendar context in this meeting."
            )
        }

        let hasSourceContext = !meeting.trustedSourceNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !meeting.transcript.isEmpty
            || meeting.audioRecordings.contains { !$0.transcript.isEmpty || !$0.linkedNote.isEmpty }

        return SourceProof(
            confidence: hasSourceContext ? .inferred : .needsReview,
            sourceMeetingTitle: meeting.title,
            references: [],
            fallbackDetail: hasSourceContext
                ? "Generated from saved meeting context without a direct source line."
                : "Add notes or transcript lines before treating this as fact."
        )
    }

    func sourceProof(for evidence: EvidenceItem, in meeting: Meeting) -> SourceProof {
        if !evidence.sourceReferences.isEmpty {
            return sourceProof(
                references: evidence.sourceReferences,
                meeting: meeting,
                fallbackDetail: "Matched the saved source for this point."
            )
        }

        return sourceProof(for: evidence.text, in: meeting)
    }

    func sourceProof(for commitment: Commitment, in meeting: Meeting) -> SourceProof {
        if !commitment.sourceReferences.isEmpty {
            return sourceProof(
                references: commitment.sourceReferences,
                meeting: meeting,
                fallbackDetail: "Matched the saved source for this action."
            )
        }

        return sourceProof(for: commitment.statement, in: meeting)
    }

    func sourceProof(for contribution: AISpeakerContribution, in meeting: Meeting) -> SourceProof {
        if !contribution.sourceReferences.isEmpty {
            return sourceProof(
                references: contribution.sourceReferences,
                meeting: meeting,
                fallbackDetail: "Matched the numbered transcript line used for this speaker point."
            )
        }
        return sourceProof(for: contribution.contribution, in: meeting)
    }

    func signals(for meeting: Meeting) -> MeetingSignals {
        if let cached = _signalsCache[meeting.id] {
            return cached
        }

        let result = makeSignals(for: meeting)
        _signalsCache[meeting.id] = result
        return result
    }

    private func makeSignals(for meeting: Meeting) -> MeetingSignals {
        MeetingIntelligenceEngine.signals(for: meeting)
    }

    func openLoops(limit: Int = 6) -> [OpenLoop] {
        _ = meetings // register observation dependency
        if _openLoopsCache == nil {
            _openLoopsCache = recentMeetings
                .filter { $0.status != .shared }
                .filter { !$0.isPersonalCapture }
                .flatMap { meeting -> [OpenLoop] in
                    let actionLoops = meeting.commitments
                        .filter { $0.status == .open || $0.status == .atRisk }
                        .prefix(2)
                        .map {
                            OpenLoop(
                                meetingID: meeting.id,
                                meetingTitle: meeting.title,
                                workspace: meeting.workspace,
                                kind: .action,
                                text: $0.formattedLine
                            )
                        }
                    let riskLoops = signals(for: meeting).risks.prefix(1).map {
                        OpenLoop(
                            meetingID: meeting.id,
                            meetingTitle: meeting.title,
                            workspace: meeting.workspace,
                            kind: .risk,
                            text: $0
                        )
                    }
                    return actionLoops + riskLoops
                }
        }
        return Array((_openLoopsCache!).prefix(limit))
    }

    func workspacePrepBrief() -> PrepBrief {
        let recent = Array(recentMeetings.prefix(4))
        guard let latest = recent.first else {
            return PrepBrief(
                headline: "Start a meeting or quick note and Scribeflow will build prep context here.",
                bullets: [],
                questions: []
            )
        }

        let themes = topWorkspaceThemes(limit: 3).map(\.capitalized)
        let latestSignals = signals(for: latest)

        var bullets: [String] = []
        if let firstDecision = latestSignals.decisions.first {
            bullets.append(firstDecision)
        }
        if let firstAction = latestSignals.actions.first {
            bullets.append(firstAction)
        }
        if bullets.isEmpty {
            bullets = recent.prefix(2).compactMap {
                firstMeaningfulLine(in: $0.trustedSourceNotes)
                    ?? $0.transcript.first?.text
            }
        }

        var questions: [String] = []
        if let firstRisk = latestSignals.risks.first {
            questions.append("Resolve: \(firstRisk)")
        }
        if latestSignals.actions.count > 1 {
            questions.append("Confirm owner: \(latestSignals.actions[1])")
        } else if let recentAction = recent.dropFirst().compactMap({ signals(for: $0).actions.first }).first {
            questions.append("Carry forward: \(recentAction)")
        }

        let headline: String
        if themes.isEmpty {
            headline = "Prep from \(latest.title) and carry its next move into the next conversation."
        } else {
            headline = "Prep for the next conversation around \(themes.joined(separator: ", "))."
        }

        return PrepBrief(
            headline: headline,
            bullets: Array(bullets.prefix(3)),
            questions: Array(questions.prefix(2))
        )
    }

    func eventPrepBrief(
        for event: CalendarEventSnapshot,
        excluding meetingID: Meeting.ID? = nil
    ) -> EventPrepBrief {
        let key = EventPrepCacheKey(event: event, excludingMeetingID: meetingID)
        if let cached = _eventPrepCache[key] {
            return cached
        }

        let brief = EventPrepEngine.make(for: event, meetings: recentMeetings, excluding: meetingID)
        if _eventPrepCache.count >= 16 {
            _eventPrepCache.removeAll(keepingCapacity: true)
        }
        _eventPrepCache[key] = brief
        return brief
    }

    func prepBrief(for meeting: Meeting) -> PrepBrief {
        if let cached = _prepBriefCache[meeting.id] {
            return cached
        }

        let brief = makePrepBrief(for: meeting)
        if _prepBriefCache.count >= 16 {
            _prepBriefCache.removeAll(keepingCapacity: true)
        }
        _prepBriefCache[meeting.id] = brief
        return brief
    }

    private func makePrepBrief(for meeting: Meeting) -> PrepBrief {
        if let event = CalendarEventSnapshot(preparedMeeting: meeting) {
            let eventBrief = eventPrepBrief(for: event, excluding: meeting.id)
            return PrepBrief(
                headline: eventBrief.headline,
                bullets: eventBrief.carryForward.map(\.text),
                questions: eventBrief.questions.map(\.text)
            )
        }

        let workspacePeers = recentMeetings.filter {
            $0.workspace == meeting.workspace && $0.id != meeting.id
        }
        let currentSignals = signals(for: meeting)

        var bullets: [String] = []
        if let decision = currentSignals.decisions.first {
            bullets.append(decision)
        }
        if let action = currentSignals.actions.first {
            bullets.append(action)
        }
        if let peer = workspacePeers.first,
           let sourceLine = firstMeaningfulLine(in: peer.trustedSourceNotes)
                ?? peer.transcript.first?.text {
            bullets.append(sourceLine)
        }

        var questions: [String] = []
        if let risk = currentSignals.risks.first {
            questions.append("Clarify: \(risk)")
        }
        if let nextAction = currentSignals.actions.dropFirst().first {
            questions.append("Lock next step: \(nextAction)")
        } else if let peerAction = workspacePeers.compactMap({ signals(for: $0).actions.first }).first {
            questions.append("Reconnect to prior thread: \(peerAction)")
        }

        return PrepBrief(
            headline: "Use this note as the launch point for your next \(meeting.workspace.lowercased()) conversation.",
            bullets: Array(bullets.prefix(3)),
            questions: Array(questions.prefix(2))
        )
    }

    func meeting(withID id: Meeting.ID) -> Meeting? {
        guard let index = index(for: id) else { return nil }
        return meetings[index]
    }

    func meeting(linkedTo event: CalendarEventSnapshot) -> Meeting? {
        if let direct = meetings.first(where: { $0.calendarEventID == event.id }) {
            return direct
        }

        let eventTitle = event.title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return meetings.first { meeting in
            guard let startDate = meeting.calendarStartDate else { return false }
            let meetingTitle = meeting.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return meetingTitle == eventTitle && abs(startDate.timeIntervalSince(event.startDate)) < 120
        }
    }

    func updateNotes(for id: Meeting.ID, notes: String) {
        guard let index = index(for: id) else { return }
        guard meetings[index].rawNotes != notes else { return }
        var meeting = meetings[index]
        meeting.rawNotes = notes
        meeting.authoredNotes = notes
        meeting.notesAreGenerated = false
        meeting.dismissedEvidenceFingerprints.removeAll()
        invalidateGeneratedIntelligence(in: &meeting)
        replaceMeeting(meeting, at: index, effects: .semanticContent)
        // Typing stays smooth: the raw text + autosave land immediately, but the
        // heavy summary/evidence/commitment regeneration is debounced so it runs
        // once the user pauses — not on every keystroke.
        scheduleRegeneration(for: id)
    }

    func restoreOriginalNotes(for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        var meeting = meetings[index]
        guard meeting.hasRecoverableOriginalNotes else { return }
        meeting.rawNotes = meeting.originalCaptureNotes
        meeting.authoredNotes = meeting.originalCaptureNotes
        meeting.notesAreGenerated = false
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(meeting, at: index)
    }

    private func scheduleRegeneration(
        for id: Meeting.ID,
        delayMilliseconds: Int = 450,
        shouldScheduleAIProcessing: Bool = true
    ) {
        regenerationTasks[id]?.cancel()
        let runID = UUID()
        regenerationRunIDs[id] = runID
        regenerationDerivedRunIDs[id] = runID
        updateDerivedProcessingState(for: id)
        regenerationTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.regenerationDerivedRunIDs[id] == runID {
                    self.regenerationDerivedRunIDs[id] = nil
                    self.updateDerivedProcessingState(for: id)
                }
                if self.regenerationRunIDs[id] == runID {
                    self.regenerationTasks[id] = nil
                    self.regenerationRunIDs[id] = nil
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let index = self.index(for: id) else { return }
            let source = self.meetings[index]
            let analysis = await self.analysisWorker.analyze(source)
            guard !Task.isCancelled,
                  let currentIndex = self.index(for: id),
                  self.meetings[currentIndex] == source
            else { return }
            self.refreshSummariesIfNeeded(at: currentIndex, analysis: analysis)
            if self.regenerationDerivedRunIDs[id] == runID {
                self.regenerationDerivedRunIDs[id] = nil
                self.updateDerivedProcessingState(for: id)
            }
            guard shouldScheduleAIProcessing else { return }
            do {
                try await Task.sleep(for: .milliseconds(550))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.scheduleAIProcessing(for: id)
        }
    }

    /// Publishes the user's source edit immediately, then rebuilds summaries,
    /// evidence, and commitments through the analysis worker. Keeping this as
    /// the common mutation path prevents taps from waiting on note intelligence.
    private func publishSemanticMutation(
        _ meeting: Meeting,
        at index: Int,
        effects: MutationEffects = .semanticContent,
        delayMilliseconds: Int = 80,
        shouldScheduleAIProcessing: Bool = true
    ) {
        replaceMeeting(meeting, at: index, effects: effects)
        scheduleRegeneration(
            for: meeting.id,
            delayMilliseconds: delayMilliseconds,
            shouldScheduleAIProcessing: shouldScheduleAIProcessing
        )
    }

    func updateTitle(_ title: String, for id: Meeting.ID) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = index(for: id) else { return }
        guard meetings[index].title != cleaned else { return }
        var meeting = meetings[index]
        meeting.title = cleaned
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(meeting, at: index)
    }

    func updateMeetingMode(_ mode: MeetingMode, for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        guard meetings[index].meetingMode != mode else { return }
        var meeting = meetings[index]
        meeting.meetingMode = mode
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(meeting, at: index)
    }

    func updateConsentState(_ state: ConsentState, for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        guard meetings[index].consentState != state else { return }
        var meeting = meetings[index]
        meeting.consentState = state
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(meeting, at: index)
    }

    func updateRetentionPolicy(_ policy: RetentionPolicy, for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        guard meetings[index].retentionPolicy != policy else { return }
        var meeting = meetings[index]
        meeting.retentionPolicy = policy
        meeting.retentionPolicyUpdatedAt = .now
        replaceMeeting(meeting, at: index, effects: .retention)
        if policy == .notesOnly, meeting.status != .processing, meeting.status != .live {
            purgeRetainedSources(for: id, stage: "Source media deleted by retention policy")
        }
        // A user extending retention near the previous deadline must cancel the
        // old timer immediately; ordinary meeting mutations use the coalesced path.
        scheduleRetentionEnforcement()
    }

    func setTranscriptVisibility(_ isVisible: Bool, for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        guard meetings[index].transcriptVisibilityEnabled != isVisible else { return }
        var meeting = meetings[index]
        meeting.transcriptVisibilityEnabled = isVisible
        replaceMeeting(meeting, at: index, effects: .presentation)
    }

    func purgeTranscript(for id: Meeting.ID) {
        purgeRetainedSources(for: id, stage: "Transcript and source audio deleted after review")
    }

    /// Applies persisted retention promises both while the app is running and
    /// when it next opens after a deadline elapsed in the background.
    @discardableResult
    func enforceRetentionPolicies(now: Date = .now) -> Int {
        let expiredIDs = meetings.compactMap { meeting -> Meeting.ID? in
            guard meeting.status != .processing,
                  meeting.status != .live,
                  hasRetainedSources(meeting),
                  let deadline = meeting.retentionPolicy.expirationDate(
                    startingAt: meeting.retentionPolicyUpdatedAt ?? meeting.when
                  ),
                  deadline <= now
            else { return nil }
            return meeting.id
        }

        for id in expiredIDs {
            purgeRetainedSources(for: id, stage: "Source media deleted by retention policy", now: now)
        }
        scheduleRetentionEnforcement(now: now)
        return expiredIDs.count
    }

    private func purgeRetainedSources(
        for id: Meeting.ID,
        stage: String,
        now: Date = .now
    ) {
        guard let index = index(for: id) else { return }
        var meeting = meetings[index]
        let fileNames = meeting.audioRecordings.map(\.fileName)

        MeetingProcessingCoordinator.shared.discard(id)
        fileNames.forEach { RecordingFileStore.deleteFile(named: $0) }
        meeting.transcript = []
        meeting.audioRecordings = []
        meeting.speakerSeparationConfidence = .unverified
        invalidateGeneratedIntelligence(in: &meeting)
        meeting.retentionPolicy = .notesOnly
        meeting.retentionPolicyUpdatedAt = now
        meeting.transcriptVisibilityEnabled = false
        meeting.stage = stage
        publishSemanticMutation(
            meeting,
            at: index,
            effects: .semanticContentAndRetention,
            shouldScheduleAIProcessing: false
        )
    }

    private func hasRetainedSources(_ meeting: Meeting) -> Bool {
        !meeting.transcript.isEmpty || !meeting.audioRecordings.isEmpty
    }

    private func scheduleRetentionRecalculation() {
        retentionRecalculationTask?.cancel()
        retentionRecalculationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.retentionRecalculationTask = nil
            self.scheduleRetentionEnforcement()
        }
    }

    private func scheduleRetentionEnforcement(now: Date = .now) {
        retentionRecalculationTask?.cancel()
        retentionRecalculationTask = nil
        retentionTask?.cancel()
        retentionTask = nil

        let nextDeadline = meetings.compactMap { meeting -> Date? in
            guard meeting.status != .processing,
                  meeting.status != .live,
                  hasRetainedSources(meeting)
            else { return nil }
            return meeting.retentionPolicy.expirationDate(
                startingAt: meeting.retentionPolicyUpdatedAt ?? meeting.when
            )
        }.min()
        guard let nextDeadline else { return }

        let delay = max(0, nextDeadline.timeIntervalSince(now))
        retentionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.retentionTask = nil
            self.enforceRetentionPolicies()
        }
    }

    func deleteEvidenceItem(for meetingID: Meeting.ID, evidenceID: EvidenceItem.ID) {
        guard let index = index(for: meetingID) else { return }
        var meeting = meetings[index]
        let oldCount = meeting.evidenceItems.count
        if let removed = meeting.evidenceItems.first(where: { $0.id == evidenceID }) {
            meeting.dismissedEvidenceFingerprints.insert(normalizedFingerprint(removed.text))
        }
        meeting.evidenceItems.removeAll { $0.id == evidenceID }
        guard meeting.evidenceItems.count != oldCount else { return }
        replaceMeeting(meeting, at: index, effects: .semanticContent)
    }

    func updateCommitmentStatus(_ status: CommitmentStatus, commitmentID: Commitment.ID, for meetingID: Meeting.ID) {
        guard let index = index(for: meetingID) else { return }
        guard let commitmentIndex = meetings[index].commitments.firstIndex(where: { $0.id == commitmentID }) else { return }
        guard meetings[index].commitments[commitmentIndex].status != status else { return }
        var commitment = meetings[index].commitments[commitmentIndex]
        commitment.status = status
        if status == .fulfilled || status == .superseded {
            ReminderScheduler.cancel(meetingID: meetingID, commitmentID: commitmentID)
            commitment.reminderID = nil
            commitment.reminderFireDate = nil
            commitment.reminderScheduledAt = nil
        }
        var meeting = meetings[index]
        meeting.commitments[commitmentIndex] = commitment
        replaceMeeting(meeting, at: index, effects: .commitments)
    }

    func updateCommitmentDetails(
        commitmentID: Commitment.ID,
        for meetingID: Meeting.ID,
        owner: String,
        dueDateOverride: Date?
    ) {
        let cleanedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = index(for: meetingID) else { return }
        guard let commitmentIndex = meetings[index].commitments.firstIndex(where: { $0.id == commitmentID }) else { return }
        let normalizedOwner = cleanedOwner.isEmpty ? "Owner not named" : cleanedOwner
        guard meetings[index].commitments[commitmentIndex].owner != normalizedOwner
                || meetings[index].commitments[commitmentIndex].dueDateOverride != dueDateOverride
        else { return }
        var commitment = meetings[index].commitments[commitmentIndex]
        commitment.owner = normalizedOwner
        commitment.dueDateOverride = dueDateOverride
        var meeting = meetings[index]
        meeting.commitments[commitmentIndex] = commitment
        replaceMeeting(meeting, at: index, effects: .commitments)
    }

    func updateCommitmentReminder(
        commitmentID: Commitment.ID,
        for meetingID: Meeting.ID,
        identifier: String,
        fireDate: Date
    ) {
        guard let index = index(for: meetingID) else { return }
        guard let commitmentIndex = meetings[index].commitments.firstIndex(where: { $0.id == commitmentID }) else { return }
        guard meetings[index].commitments[commitmentIndex].reminderID != identifier
                || meetings[index].commitments[commitmentIndex].reminderFireDate != fireDate
        else { return }
        var commitment = meetings[index].commitments[commitmentIndex]
        commitment.reminderID = identifier
        commitment.reminderFireDate = fireDate
        commitment.reminderScheduledAt = .now
        var meeting = meetings[index]
        meeting.commitments[commitmentIndex] = commitment
        replaceMeeting(meeting, at: index, effects: .commitments)
    }

    func clearCommitmentReminder(commitmentID: Commitment.ID, for meetingID: Meeting.ID) {
        guard let index = index(for: meetingID) else { return }
        guard let commitmentIndex = meetings[index].commitments.firstIndex(where: { $0.id == commitmentID }) else { return }
        guard meetings[index].commitments[commitmentIndex].reminderID != nil
                || meetings[index].commitments[commitmentIndex].reminderFireDate != nil
                || meetings[index].commitments[commitmentIndex].reminderScheduledAt != nil
        else { return }
        ReminderScheduler.cancel(meetingID: meetingID, commitmentID: commitmentID)
        var commitment = meetings[index].commitments[commitmentIndex]
        commitment.reminderID = nil
        commitment.reminderFireDate = nil
        commitment.reminderScheduledAt = nil
        var meeting = meetings[index]
        meeting.commitments[commitmentIndex] = commitment
        replaceMeeting(meeting, at: index, effects: .commitments)
    }

    func selectTemplate(_ template: NoteTemplate, for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        guard meetings[index].selectedTemplate != template else { return }
        var meeting = meetings[index]
        meeting.selectedTemplate = template
        replaceMeeting(meeting, at: index, effects: .presentation)
        scheduleAIProcessing(for: id)
    }

    func selectPrompt(_ promptID: AIResponse.ID, for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        guard meetings[index].selectedPromptID != promptID else { return }
        var meeting = meetings[index]
        meeting.selectedPromptID = promptID
        replaceMeeting(meeting, at: index, effects: .presentation)
    }

    func markShared(for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        guard meetings[index].status != .shared || meetings[index].stage != "Shared from iPhone" else { return }
        var meeting = meetings[index]
        meeting.status = .shared
        meeting.stage = "Shared from iPhone"
        replaceMeeting(meeting, at: index, effects: .presentation)
    }

    func togglePinned(for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        var meeting = meetings[index]
        meeting.isPinned.toggle()
        replaceMeeting(meeting, at: index, effects: .presentation)
    }

    // MARK: - Context Mode (Tier 2)

    func updateContextMode(_ mode: MeetingContextMode, for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        guard meetings[index].contextMode != mode else { return }
        var meeting = meetings[index]
        meeting.contextMode = mode
        invalidateGeneratedIntelligence(in: &meeting)
        // Re-tailor the model brief to the chosen lens (no-op without the model).
        publishSemanticMutation(meeting, at: index)
    }

    func updatePurposeOverride(_ purpose: CapturePurposeKind?, for id: Meeting.ID) {
        guard let index = index(for: id) else { return }
        guard meetings[index].purposeOverride != purpose else { return }
        var meeting = meetings[index]
        meeting.purposeOverride = purpose
        invalidateGeneratedIntelligence(in: &meeting)

        if !meeting.allowsAccountabilityExtraction {
            for commitment in meeting.commitments {
                ReminderScheduler.cancel(meetingID: id, commitmentID: commitment.id)
            }
            meeting.commitments = []
            meeting.score = nil
        }
        publishSemanticMutation(meeting, at: index)
    }

    // MARK: - Meeting Score (Tier 2)

    func scoreAndSave(for id: Meeting.ID, allowsAccountability: Bool) async {
        guard let sourceIndex = index(for: id) else { return }
        let meeting = meetings[sourceIndex]
        guard allowsAccountability else {
            if meeting.score != nil {
                var updated = meeting
                updated.score = nil
                replaceMeeting(updated, at: sourceIndex, effects: [])
            }
            return
        }

        let nextScore = await meetingScoreWorker.score(
            for: meeting,
            allowsAccountability: allowsAccountability
        )
        guard !Task.isCancelled,
              let currentIndex = index(for: id),
              meetings[currentIndex] == meeting,
              !Self.sameScoreResult(meeting.score, nextScore)
        else { return }

        var updated = meeting
        updated.score = nextScore
        replaceMeeting(updated, at: currentIndex, effects: [])
    }

    /// `scoredAt` is metadata, not a reason to publish another store revision.
    private static func sameScoreResult(_ lhs: MeetingScore?, _ rhs: MeetingScore?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.clarity == rhs.clarity
                && lhs.decisiveness == rhs.decisiveness
                && lhs.actionability == rhs.actionability
                && lhs.overall == rhs.overall
                && lhs.insight == rhs.insight
        default:
            false
        }
    }

    // MARK: - Action Inbox (Tier 1)

    var pendingActionChecks: [ActionCheck] {
        ActionTracker.pendingChecks(from: meetings)
    }

    func resolveCommitment(commitmentID: Commitment.ID, in meetingID: Meeting.ID, as status: CommitmentStatus) {
        updateCommitmentStatus(status, commitmentID: commitmentID, for: meetingID)
    }

    /// Convenience for the Home action-items inbox: mark the first open or
    /// at-risk commitment in a meeting as fulfilled. Returns true if a
    /// commitment was resolved.
    @discardableResult
    func resolveFirstOpenCommitment(in meetingID: Meeting.ID) -> Bool {
        guard let meeting = meeting(withID: meetingID) else { return false }
        guard meeting.allowsAccountabilityExtraction else { return false }
        guard let commitment = meeting.commitments.first(where: { $0.status == .open || $0.status == .atRisk }) else {
            return false
        }
        updateCommitmentStatus(.fulfilled, commitmentID: commitment.id, for: meetingID)
        return true
    }

    // MARK: - People Intelligence (Tier 2)

    func personIntelligence(for name: String) -> PersonIntelligence {
        PeopleEngine.intelligence(for: name, in: meetings)
    }

    // MARK: - Product Intelligence

    func intelligenceReport(for meeting: Meeting) -> MeetingIntelligenceReport {
        if let cached = _intelligenceReportCache[meeting.id] {
            return cached
        }

        let report = MeetingIntelligenceEngine.report(for: meeting)
        if _intelligenceReportCache.count >= 16 {
            _intelligenceReportCache.removeAll(keepingCapacity: true)
        }
        _intelligenceReportCache[meeting.id] = report
        return report
    }

    private func cacheAnalysis(_ bundle: MeetingAnalysisBundle, for meetingID: Meeting.ID) {
        if _intelligenceReportCache.count >= 16 {
            _intelligenceReportCache.removeAll(keepingCapacity: true)
        }
        if _signalsCache.count >= 32 {
            _signalsCache.removeAll(keepingCapacity: true)
        }
        if _purposeCache.count >= 32 {
            _purposeCache.removeAll(keepingCapacity: true)
            _evidenceNoteLinesCache.removeAll(keepingCapacity: true)
            _sourceReferencesByClaimCache.removeAll(keepingCapacity: true)
            _sensitiveFlagsCache.removeAll(keepingCapacity: true)
        }
        _intelligenceReportCache[meetingID] = bundle.report
        _signalsCache[meetingID] = bundle.signals
        _purposeCache[meetingID] = bundle.purpose
        _evidenceNoteLinesCache[meetingID] = bundle.evidenceNoteLines
        _sourceReferencesByClaimCache[meetingID] = bundle.sourceReferencesByClaim
        _sensitiveFlagsCache[meetingID] = bundle.sensitiveFlags
    }

    /// Calculates the expensive first-open report away from the UI actor and
    /// publishes it only if the meeting source is still current.
    func analysisBundle(for sourceMeeting: Meeting) async -> MeetingAnalysisBundle {
        if let report = _intelligenceReportCache[sourceMeeting.id],
           let signals = _signalsCache[sourceMeeting.id],
           let purpose = _purposeCache[sourceMeeting.id],
           let evidenceNoteLines = _evidenceNoteLinesCache[sourceMeeting.id],
           let sourceReferencesByClaim = _sourceReferencesByClaimCache[sourceMeeting.id],
           let sensitiveFlags = _sensitiveFlagsCache[sourceMeeting.id] {
            return MeetingAnalysisBundle(
                purpose: purpose,
                report: report,
                signals: signals,
                evidenceNoteLines: evidenceNoteLines,
                sourceReferencesByClaim: sourceReferencesByClaim,
                sensitiveFlags: sensitiveFlags
            )
        }

        let bundle = await analysisWorker.analyze(sourceMeeting)
        if let current = meeting(withID: sourceMeeting.id), current == sourceMeeting {
            cacheAnalysis(bundle, for: sourceMeeting.id)
        }
        return bundle
    }

    func speakerSegments(for meetingID: Meeting.ID) -> [SpeakerSegment] {
        guard let meeting = meeting(withID: meetingID) else { return [] }
        return intelligenceReport(for: meeting).speakerSegments
    }

    func renameSpeaker(_ currentName: String, to newName: String, for meetingID: Meeting.ID) {
        let cleanedCurrent = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedCurrent.isEmpty,
              !cleanedNew.isEmpty,
              cleanedCurrent.caseInsensitiveCompare(cleanedNew) != .orderedSame,
              let index = index(for: meetingID)
        else { return }

        var meeting = meetings[index]
        for lineIndex in meeting.transcript.indices
        where meeting.transcript[lineIndex].speaker.caseInsensitiveCompare(cleanedCurrent) == .orderedSame {
            meeting.transcript[lineIndex].speaker = cleanedNew
        }

        meeting.attendees = meeting.attendees.map {
            $0.caseInsensitiveCompare(cleanedCurrent) == .orderedSame ? cleanedNew : $0
        }
        if !meeting.attendees.contains(where: { $0.caseInsensitiveCompare(cleanedNew) == .orderedSame }) {
            meeting.attendees.append(cleanedNew)
        }
        meeting.attendees = Array(Set(meeting.attendees)).sorted()
        reconcileSpeakerSeparationConfidence(in: &meeting)
        invalidateGeneratedIntelligence(in: &meeting)
        meeting.stage = "Speaker labels reviewed"
        publishSemanticMutation(meeting, at: index)
    }

    func reassignSpeaker(
        for lineID: TranscriptLine.ID,
        to newName: String,
        in meetingID: Meeting.ID
    ) {
        let cleanedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty,
              let meetingIndex = index(for: meetingID),
              let lineIndex = meetings[meetingIndex].transcript.firstIndex(where: { $0.id == lineID }),
              meetings[meetingIndex].transcript[lineIndex].speaker
                .caseInsensitiveCompare(cleanedName) != .orderedSame
        else { return }

        var meeting = meetings[meetingIndex]
        meeting.transcript[lineIndex].speaker = cleanedName
        if !meeting.attendees.contains(where: {
            $0.caseInsensitiveCompare(cleanedName) == .orderedSame
        }) {
            meeting.attendees.append(cleanedName)
            meeting.attendees.sort()
        }
        reconcileSpeakerSeparationConfidence(in: &meeting)
        invalidateGeneratedIntelligence(in: &meeting)
        meeting.stage = "Transcript speaker corrected"
        publishSemanticMutation(meeting, at: meetingIndex)
    }

    // MARK: - Storage, Backup, and Privacy Controls

    func storageSnapshot() async -> StorageSnapshot {
        let recordings = meetings.flatMap { meeting in
            meeting.audioRecordings.map { recording in
                StorageRecordingDescriptor(
                    meetingID: meeting.id,
                    recordingID: recording.id,
                    meetingTitle: meeting.title,
                    recordingTitle: recording.title,
                    fileName: recording.fileName,
                    createdAt: recording.createdAt,
                    durationSeconds: recording.durationSeconds
                )
            }
        }

        return await StorageSnapshotService.shared.makeSnapshot(
            notesCount: meetings.count,
            recordings: recordings,
            databaseURL: saveURL
        )
    }

    enum BackupError: LocalizedError {
        case unreadable
        case newerVersion(Int)
        case tooLarge
        case invalidContents(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file isn't a Scribeflow backup, or it's damaged."
            case .newerVersion(let version):
                return "This backup (v\(version)) was made by a newer version of Scribeflow. Update the app, then restore."
            case .tooLarge:
                return "This backup is too large to restore safely on this device."
            case .invalidContents(let message):
                return "This backup cannot be restored safely: \(message)"
            }
        }
    }

    func makeBackup(includeAudio: Bool) async throws -> ScribeflowBackupPayload {
        let snapshot = meetings
        return try await BackupArchiveService.shared.makeBackupPayload(
            meetings: snapshot,
            schemaVersion: Self.currentSchemaVersion,
            includeAudio: includeAudio
        )
    }

    func automaticBackups() async throws -> [AutomaticBackupSnapshot] {
        try await BackupArchiveService.shared.automaticBackups()
    }

    func makeAutomaticBackupNow() async throws -> AutomaticBackupSnapshot {
        let snapshot = meetings
        guard let backup = try await BackupArchiveService.shared.saveAutomaticBackup(
            meetings: snapshot,
            schemaVersion: Self.currentSchemaVersion,
            force: true
        ) else {
            throw BackupArchiveError.noData
        }
        return backup
    }

    func automaticBackupData(for snapshot: AutomaticBackupSnapshot) async throws -> Data {
        try await BackupArchiveService.shared.data(for: snapshot)
    }

    func restorePreparedBackup(_ preparedRestore: PreparedBackupRestore) async throws {
        // Commit the current in-memory state first. The persistence writer then
        // preserves it as the rollback file when the restored library is saved.
        await flushPersistence()
        guard !lastSaveFailed else {
            throw BackupError.invalidContents("the current library could not be protected before restore")
        }

        // Stop a finishing transcription job before the recordings directory
        // is swapped. If staging fails, the queue is resumed against the
        // untouched current library.
        await MeetingProcessingCoordinator.shared.pauseForLibraryReplacement()
        do {
            try await BackupArchiveService.shared.installRecordingFiles(from: preparedRestore)
        } catch {
            MeetingProcessingCoordinator.shared.resumeAfterLibraryReplacement(using: self)
            throw error
        }

        // Nothing from the replaced library should finish into the restored
        // one after the atomic audio swap.
        await MeetingProcessingCoordinator.shared.discardAll()
        aiProcessingTasks.values.forEach { $0.cancel() }
        aiProcessingTasks.removeAll()
        aiProcessingRunIDs.removeAll()
        aiProcessingIDs.removeAll()
        regenerationTasks.values.forEach { $0.cancel() }
        regenerationTasks.removeAll()
        regenerationRunIDs.removeAll()
        regenerationDerivedRunIDs.removeAll()
        derivedProcessingIDs.removeAll()
        derivedMigrationTask?.cancel()
        derivedMigrationTask = nil
        derivedMigrationRunID = nil
        derivedMigrationPendingIDs.removeAll()
        commitmentSupersessionTask?.cancel()
        commitmentSupersessionTask = nil
        commitmentSupersessionRunID = nil
        retentionTask?.cancel()
        retentionTask = nil
        retentionRecalculationTask?.cancel()
        retentionRecalculationTask = nil

        // Capture any completion that landed while audio was staged so the
        // rollback file represents the latest pre-restore library.
        await flushPersistence()
        let currentMeetings = meetings
        for meeting in currentMeetings {
            cancelReminders(for: meeting)
        }

        await SpotlightIndex.removeAllAndWait()
        let package = preparedRestore.package
        forceIndexRebuildAfterMutation = true
        let restoredAudioFileNames = Set(package.audioFiles.map(\.fileName))
        meetings = package.meetings.map { restored in
            var normalized = Self.normalizedMeeting(restored)
            normalized.audioRecordings.removeAll { !restoredAudioFileNames.contains($0.fileName) }
            normalized.commitments = normalized.commitments.map { commitment in
                var restoredCommitment = commitment
                restoredCommitment.reminderID = nil
                restoredCommitment.reminderFireDate = nil
                restoredCommitment.reminderScheduledAt = nil
                return restoredCommitment
            }
            return normalized
        }

        let rowsNeedingMigration = meetings
            .filter(Self.needsDerivedDataRefresh)
            .map(\.id)
        await flushPersistence()
        scheduleDerivedDataMigration(for: rowsNeedingMigration)
    }

    func deleteAllUserData() async {
        await MeetingProcessingCoordinator.shared.discardAll()
        aiProcessingTasks.values.forEach { $0.cancel() }
        aiProcessingTasks.removeAll()
        aiProcessingRunIDs.removeAll()
        aiProcessingIDs.removeAll()
        for meeting in meetings {
            cancelReminders(for: meeting)
        }
        saveTask?.cancel()
        regenerationTasks.values.forEach { $0.cancel() }
        regenerationTasks.removeAll()
        regenerationRunIDs.removeAll()
        regenerationDerivedRunIDs.removeAll()
        derivedProcessingIDs.removeAll()
        derivedMigrationTask?.cancel()
        derivedMigrationTask = nil
        derivedMigrationRunID = nil
        derivedMigrationPendingIDs.removeAll()
        commitmentSupersessionTask?.cancel()
        commitmentSupersessionTask = nil
        commitmentSupersessionRunID = nil
        RecordingFileStore.deleteAllFiles()
        forceIndexRebuildAfterMutation = true
        meetings = []
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: saveURL)
        try? FileManager.default.removeItem(at: backupURL)

        let folder = saveURL.deletingLastPathComponent()
        if let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.lastPathComponent.hasPrefix("meetings.corrupt-") {
                try? FileManager.default.removeItem(at: file)
            }
        }

        await SpotlightIndex.removeAllAndWait()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        WidgetSharedStore.clear()
        WebhookStore.shared.clear()
        AnalyticsLog.shared.clear()
        await TranscriptionRetryQueue.shared.clear()
        await BackupArchiveService.shared.deleteAllAutomaticBackups()
        await DiagnosticsArchive.shared.clear()

        let defaults = UserDefaults.standard
        [
            "scribeflow.currentUserEmail",
            "scribeflow.investorDemoMode",
            "scribeflow.demoModePreparedAt",
            "scribeflow.localAccounts.v1",
            "scribeflow.wantsBiometric",
            "scribeflow.bioAsked",
            TranscriptionProviderFactory.remoteTranscriptionConsentKey
        ].forEach(defaults.removeObject(forKey:))
    }

    @discardableResult
    func addSampleData() -> Int {
        let existingKeys = Set(meetings.map { Self.sampleIdentityKey(for: $0) })
        let samples = Meeting.seed
            .map(Self.normalizedMeeting)
            .filter { !existingKeys.contains(Self.sampleIdentityKey(for: $0)) }

        guard !samples.isEmpty else { return 0 }
        meetings.insert(contentsOf: samples, at: 0)
        scheduleSupersededCommitmentRefresh()
        let sampleIDs = samples.map(\.id)
        scheduleDerivedDataMigration(
            for: sampleIDs,
            preservingAuthoredCommitmentsFor: Set(sampleIDs)
        )
        return samples.count
    }

    func replaceWithSampleData() {
        aiProcessingTasks.values.forEach { $0.cancel() }
        aiProcessingTasks.removeAll()
        aiProcessingRunIDs.removeAll()
        aiProcessingIDs.removeAll()
        regenerationTasks.values.forEach { $0.cancel() }
        regenerationTasks.removeAll()
        regenerationRunIDs.removeAll()
        regenerationDerivedRunIDs.removeAll()
        derivedProcessingIDs.removeAll()
        derivedMigrationTask?.cancel()
        derivedMigrationTask = nil
        derivedMigrationRunID = nil
        derivedMigrationPendingIDs.removeAll()
        commitmentSupersessionTask?.cancel()
        commitmentSupersessionTask = nil
        commitmentSupersessionRunID = nil
        RecordingFileStore.deleteAllFiles()
        SpotlightIndex.removeAll()
        let samples = Meeting.seed.map(Self.normalizedMeeting)
        forceIndexRebuildAfterMutation = true
        meetings = samples
        scheduleSupersededCommitmentRefresh()
        let sampleIDs = samples.map(\.id)
        scheduleDerivedDataMigration(
            for: sampleIDs,
            preservingAuthoredCommitmentsFor: Set(sampleIDs)
        )
    }

    @discardableResult
    func cleanupRecordings(_ action: StorageCleanupAction) -> Int {
        switch action {
        case .largeRecordings(let minimumBytes):
            return deleteRecordings { recording in
                RecordingFileStore.fileSize(at: RecordingFileStore.url(for: recording.fileName)) >= minimumBytes
            }
        case .olderRecordings(let days):
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
            return deleteRecordings { recording in
                recording.createdAt < cutoff
            }
        case .allRecordings:
            return deleteRecordings { _ in true }
        }
    }

    var allPeople: [String] {
        PeopleEngine.allPeople(from: meetings)
    }

    // MARK: - Share Note (Tier 1)

    func richShareText(for id: Meeting.ID) -> String {
        guard let meeting = meeting(withID: id) else { return "" }
        let summary = meeting.summary(for: meeting.selectedTemplate)
        var lines: [String] = []
        lines.append("📋 \(meeting.title)")
        lines.append("\(meeting.when.formatted(date: .complete, time: .shortened))")
        lines.append("")
        lines.append(summary.title)
        for section in summary.sections {
            lines.append("")
            lines.append("• \(section.title)")
            lines.append(contentsOf: section.bullets.map { "  · \($0)" })
        }
        let openActions = meeting.allowsAccountabilityExtraction
            ? meeting.commitments.filter { $0.status == .open }
            : []
        if !openActions.isEmpty {
            lines.append("")
            lines.append("Action Items:")
            lines.append(contentsOf: openActions.prefix(5).map { "  ☐ \($0.statement) [\($0.owner)]" })
        }
        lines.append("")
        lines.append("—")
        lines.append("Sent from Scribeflow")
        return lines.joined(separator: "\n")
    }

    func deleteMeeting(_ id: Meeting.ID) {
        MeetingProcessingCoordinator.shared.discard(id)
        SpotlightIndex.remove(meetingID: id)
        aiProcessingTasks[id]?.cancel()
        aiProcessingTasks[id] = nil
        aiProcessingRunIDs[id] = nil
        aiProcessingIDs.remove(id)
        regenerationTasks[id]?.cancel()
        regenerationTasks[id] = nil
        regenerationRunIDs[id] = nil
        regenerationDerivedRunIDs[id] = nil
        derivedMigrationPendingIDs.remove(id)
        derivedProcessingIDs.remove(id)
        if let meeting = meeting(withID: id) {
            cancelReminders(for: meeting)
            for recording in meeting.audioRecordings {
                RecordingFileStore.deleteFile(named: recording.fileName)
            }
        }
        meetings.removeAll { $0.id == id }
    }

    /// Removes the meeting from the visible array but defers deletion of audio
    /// files to `finalizeDelete(_:)`. Returns the snapshot + original index so
    /// the caller can offer Undo and put it back in place.
    func softDeleteMeeting(_ id: Meeting.ID) -> (Meeting, Int)? {
        guard let idx = index(for: id) else { return nil }
        MeetingProcessingCoordinator.shared.suspend(id)
        SpotlightIndex.remove(meetingID: id)
        aiProcessingTasks[id]?.cancel()
        aiProcessingTasks[id] = nil
        aiProcessingRunIDs[id] = nil
        aiProcessingIDs.remove(id)
        regenerationTasks[id]?.cancel()
        regenerationTasks[id] = nil
        regenerationRunIDs[id] = nil
        regenerationDerivedRunIDs[id] = nil
        derivedMigrationPendingIDs.remove(id)
        derivedProcessingIDs.remove(id)
        let snapshot = meetings[idx]
        meetings.remove(at: idx)
        return (snapshot, idx)
    }

    /// Re-inserts a soft-deleted meeting at its prior index (clamped if the
    /// array shifted in the meantime).
    func restoreMeeting(_ meeting: Meeting, at index: Int) {
        let clamped = min(max(index, 0), meetings.count)
        meetings.insert(meeting, at: clamped)
        scheduleRegeneration(for: meeting.id, delayMilliseconds: 80)
        MeetingProcessingCoordinator.shared.resume(meeting.id, using: self)
    }

    /// Permanently removes the on-disk audio files for a soft-deleted meeting.
    /// Called after the Undo window elapses.
    func finalizeDelete(_ meeting: Meeting) {
        MeetingProcessingCoordinator.shared.discard(meeting.id)
        regenerationTasks[meeting.id]?.cancel()
        regenerationTasks[meeting.id] = nil
        regenerationRunIDs[meeting.id] = nil
        regenerationDerivedRunIDs[meeting.id] = nil
        derivedMigrationPendingIDs.remove(meeting.id)
        derivedProcessingIDs.remove(meeting.id)
        cancelReminders(for: meeting)
        for recording in meeting.audioRecordings {
            RecordingFileStore.deleteFile(named: recording.fileName)
        }
    }

    func duplicateMeeting(_ id: Meeting.ID) -> Meeting.ID? {
        guard let meeting = meeting(withID: id) else { return nil }
        var duplicate = meeting
        duplicate.id = UUID()
        duplicate.when = .now
        duplicate.status = .ready
        duplicate.stage = "Duplicated for follow-up"
        duplicate.isPinned = false
        duplicate.audioRecordings = []
        duplicate.calendarEventID = nil
        duplicate.calendarStartDate = nil
        duplicate.calendarEndDate = nil
        duplicate.summaries = []
        duplicate.evidenceItems = []
        duplicate.derivedDataVersion = 0
        duplicate.commitments = duplicate.commitments.map { commitment in
            var copied = commitment
            copied.id = UUID()
            copied.status = .open
            copied.reminderID = nil
            copied.reminderFireDate = nil
            copied.reminderScheduledAt = nil
            copied.sourceReferences = []
            return copied
        }
        duplicate.selectedPromptID = duplicate.prompts.first?.id
        meetings.insert(duplicate, at: 0)
        scheduleRegeneration(for: duplicate.id, delayMilliseconds: 80)
        return duplicate.id
    }

    private func cancelReminders(for meeting: Meeting) {
        for commitment in meeting.commitments where commitment.hasReminder {
            ReminderScheduler.cancel(meetingID: meeting.id, commitmentID: commitment.id)
        }
    }

    func exportText(for id: Meeting.ID, format: MeetingExportFormat) -> String? {
        guard let meeting = meeting(withID: id) else { return nil }
        return safeSharePreview(
            for: meeting,
            format: format,
            includeInferred: format != .clientRecap,
            includePrivateNotes: format == .internalBrief,
            includeTranscript: false
        )
    }

    func safeSharePreview(
        for meetingID: Meeting.ID,
        format: MeetingExportFormat,
        includeInferred: Bool,
        includePrivateNotes: Bool,
        includeTranscript: Bool
    ) -> String? {
        guard let meeting = meeting(withID: meetingID) else { return nil }
        return safeSharePreview(
            for: meeting,
            format: format,
            includeInferred: includeInferred,
            includePrivateNotes: includePrivateNotes,
            includeTranscript: includeTranscript
        )
    }

    func shareReviewFlags(
        for meetingID: Meeting.ID,
        includeInferred: Bool,
        includePrivateNotes: Bool,
        includeTranscript: Bool
    ) -> [String] {
        guard let meeting = meeting(withID: meetingID) else { return [] }
        var flags = meeting.sensitiveFlags.map { "Contains \($0.title.lowercased())" }

        if includeInferred, meeting.evidenceItems.contains(where: { $0.level == .inferred }) {
            flags.append("Includes inferred bullets")
        }
        if includePrivateNotes, meeting.meetingMode == .privateNotes {
            flags.append("Includes private-note context")
        }
        if includeTranscript, meeting.transcript.isEmpty == false {
            flags.append("Includes transcript snippets")
        }
        if meeting.consentState == .privateCapture && meeting.meetingMode != .privateNotes {
            flags.append("Disclosure state may not match sharing mode")
        }

        return flags
    }

    func markdownExport(for id: Meeting.ID) -> String? {
        exportText(for: id, format: .internalBrief)
    }

    func answerMeetingPrompt(for id: Meeting.ID, prompt: String) async -> String {
        await groundedAnswerMeetingPrompt(for: id, prompt: prompt).text
    }

    func groundedAnswerMeetingPrompt(for id: Meeting.ID, prompt: String) async -> WorkspaceAnswer {
        guard let meeting = meeting(withID: id) else {
            return WorkspaceAnswer(text: "Meeting not found.", citations: [])
        }
        guard !Task.isCancelled else { return WorkspaceAnswer(text: "", citations: []) }

        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            return WorkspaceAnswer(
                text: "Ask about the decisions, follow-ups, open questions, or important context in this capture.",
                citations: []
            )
        }
        let retrievalQuery = meetingRetrievalQuery(for: normalizedPrompt, meeting: meeting)
        let sources = await Task.detached(priority: .userInitiated) {
            LocalRAG.diverseSources(
                for: meeting,
                query: retrievalQuery,
                limit: 12
            )
        }.value
        guard !Task.isCancelled else { return WorkspaceAnswer(text: "", citations: []) }
        guard !sources.isEmpty else {
            return WorkspaceAnswer(
                text: "There isn’t enough original note or transcript evidence to answer that yet.",
                citations: []
            )
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch AppleIntelligenceNoteTransformer.availability() {
            case .available:
                do {
                    return try await AppleIntelligenceWorkspaceAssistant.answer(
                        sources: sources,
                        prompt: normalizedPrompt,
                        modelSelection: .deep
                    )
                } catch {
                    break
                }
            default:
                break
            }
        }
        #endif

        return groundedFallbackAnswer(sources: sources)
    }

    private func meetingRetrievalQuery(for prompt: String, meeting: Meeting) -> String {
        let lower = prompt.lowercased()
        var terms = [prompt, meeting.title, meeting.objective]
        if lower.contains("action") || lower.contains("follow") || lower.contains("next") {
            terms.append("action owner due deadline will follow up next step")
        }
        if lower.contains("decision") || lower.contains("agree") {
            terms.append("decision decided agreed approved confirmed")
        }
        if lower.contains("risk") || lower.contains("blocker") {
            terms.append("risk blocker concern dependency unresolved")
        }
        if lower.contains("recap") || lower.contains("summary")
            || lower.contains("slack") || lower.contains("catch") {
            terms.append("important context outcome decision action question")
        }
        return terms.joined(separator: " ")
    }

    func answerAcrossMeetings(
        prompt: String,
        includeTranscripts: Bool,
        workspaceFilter: String? = nil,
        modelSelection: ChatModelSelection = .auto
    ) async -> String {
        await groundedAnswerAcrossMeetings(
            prompt: prompt,
            includeTranscripts: includeTranscripts,
            workspaceFilter: workspaceFilter,
            modelSelection: modelSelection
        ).text
    }

    func groundedAnswerAcrossMeetings(
        prompt: String,
        includeTranscripts: Bool,
        workspaceFilter: String? = nil,
        modelSelection: ChatModelSelection = .auto
    ) async -> WorkspaceAnswer {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedPrompt.isEmpty else {
            return WorkspaceAnswer(
                text: "Ask about decisions, follow-ups, blockers, or what changed across your recent meetings.",
                citations: []
            )
        }

        let scopedPool = recentMeetings.filter { meeting in
            guard let workspaceFilter, !workspaceFilter.isEmpty else { return true }
            return meeting.workspace.caseInsensitiveCompare(workspaceFilter) == .orderedSame
        }
        let scopedMeetings = Array(scopedPool.prefix(includeTranscripts ? 25 : 40))

        guard !scopedMeetings.isEmpty else {
            if let workspaceFilter, !workspaceFilter.isEmpty {
                return WorkspaceAnswer(
                    text: "There aren’t any saved meetings in \(workspaceFilter) yet.",
                    citations: []
                )
            }
            return WorkspaceAnswer(
                text: "There aren’t any saved meetings yet, so there’s nothing to search across.",
                citations: []
            )
        }

        let sources = await recallSources(
            for: normalizedPrompt,
            scopedMeetingIDs: Set(scopedMeetings.map(\.id)),
            includeTranscripts: includeTranscripts,
            limit: modelSelection == .deep ? 10 : 7
        )

        guard !sources.isEmpty else {
            return WorkspaceAnswer(
                text: "I couldn’t find a source in your saved notes that supports an answer to that yet.",
                citations: []
            )
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch AppleIntelligenceNoteTransformer.availability() {
            case .available:
                do {
                    return try await AppleIntelligenceWorkspaceAssistant.answer(
                        sources: sources,
                        prompt: normalizedPrompt,
                        modelSelection: modelSelection
                    )
                } catch {
                    break
                }
            default:
                break
            }
        }
        #endif

        return groundedFallbackAnswer(sources: sources)
    }

    private func recallSources(
        for query: String,
        scopedMeetingIDs: Set<Meeting.ID>,
        includeTranscripts: Bool,
        limit: Int
    ) async -> [RAGResult] {
        let expectedRevision = revision
        let index: LocalRAG.Index
        if let cached = _recallIndex, _recallIndexRevision == expectedRevision {
            index = cached
        } else {
            let snapshot = meetings
            index = await Task.detached(priority: .userInitiated) {
                LocalRAG.makeIndex(from: snapshot)
            }.value
            if revision == expectedRevision {
                _recallIndex = index
                _recallIndexRevision = expectedRevision
            }
        }

        return await Task.detached(priority: .userInitiated) {
            LocalRAG.search(
                query,
                in: index,
                limit: limit,
                allowedMeetingIDs: scopedMeetingIDs,
                includeTranscripts: includeTranscripts
            )
        }.value
    }

    private func groundedFallbackAnswer(sources: [RAGResult]) -> WorkspaceAnswer {
        let usedSources = Array(sources.prefix(4))
        let bullets = usedSources.map { source in
            "- \(source.snippet) [source: \(source.sourceID)]"
        }
        return WorkspaceAnswer(
            text: (["Here are the closest source-backed matches:"] + bullets).joined(separator: "\n"),
            citations: usedSources
        )
    }

    func workspaceFolders() -> [WorkspaceFolder] {
        let grouped = Dictionary(grouping: recentMeetings, by: \.workspace)
        return grouped.compactMap { workspace, meetings in
            guard let latest = meetings.max(by: { $0.when < $1.when }) else { return nil }
            return WorkspaceFolder(
                name: workspace,
                description: latest.objective,
                meetingCount: meetings.count,
                latestMeetingDate: latest.when
            )
        }
        .sorted { lhs, rhs in
            if lhs.latestMeetingDate == rhs.latestMeetingDate {
                return lhs.name < rhs.name
            }
            return lhs.latestMeetingDate > rhs.latestMeetingDate
        }
    }

    func smartCollections() -> [SmartCollectionCard] {
        _ = meetings // register observation dependency
        if let cached = _smartCollectionsCache { return cached }
        let computed = SmartCollectionKind.allCases.map { kind in
            SmartCollectionCard(kind: kind, count: meetings(matching: kind).count)
        }
        _smartCollectionsCache = computed
        return computed
    }

    func meetings(matching collection: SmartCollectionKind) -> [Meeting] {
        switch collection {
        case .all:
            return recentMeetings
        case .followUp:
            return recentMeetings.filter { $0.status != .shared && $0.status != .processing }
        case .calls:
            return recentMeetings.filter(\.isCallMeeting)
        case .pinned:
            return recentMeetings.filter(\.isPinned)
        case .shared:
            return recentMeetings.filter { $0.status == .shared }
        }
    }

    func tags(for meeting: Meeting) -> [String] {
        workspaceTags(for: meeting).prefix(4).map(\.capitalized)
    }

    func meetings(in folder: WorkspaceFolder) -> [Meeting] {
        recentMeetings
            .filter { $0.workspace.caseInsensitiveCompare(folder.name) == .orderedSame }
            .sorted(by: Meeting.sortDescending)
    }

    func deleteTranscriptLine(for meetingID: Meeting.ID, lineID: TranscriptLine.ID) {
        guard let index = index(for: meetingID) else { return }
        var meeting = meetings[index]
        let oldCount = meeting.transcript.count
        meeting.transcript.removeAll { $0.id == lineID }

        guard meeting.transcript.count != oldCount else { return }

        meeting.stage = "Transcript edited for privacy"
        reconcileSpeakerSeparationConfidence(in: &meeting)
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(meeting, at: index)
    }

    func addMeeting(
        id: Meeting.ID = UUID(),
        title: String,
        workspace: String,
        attendees: [String],
        objective: String,
        notes: String,
        authoredNotes: String? = nil,
        notesAreGenerated: Bool = false,
        moments: [String] = [],
        transcript: [TranscriptLine] = [],
        when: Date = .now,
        status: MeetingStatus = .ready,
        stage: String = "Captured from iPhone notes",
        durationMinutes: Int = 25,
        meetingMode: MeetingMode = .privateNotes,
        consentState: ConsentState = .privateCapture,
        retentionPolicy: RetentionPolicy = .keepUntilDeleted,
        audioRecordings: [AudioRecordingAttachment] = [],
        calendarEventID: String? = nil,
        calendarStartDate: Date? = nil,
        calendarEndDate: Date? = nil,
        selectedTemplate: NoteTemplate = .general,
        shouldScheduleAIProcessing: Bool = true,
        shouldScheduleDerivedProcessing: Bool = true
    ) -> Meeting.ID {
        let normalizedAttendees = attendees.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var meeting = Meeting(
            id: id,
            title: title,
            workspace: workspace,
            when: when,
            durationMinutes: durationMinutes,
            attendees: normalizedAttendees.isEmpty ? ["You"] : normalizedAttendees,
            status: status,
            stage: stage,
            objective: objective,
            rawNotes: notes,
            authoredNotes: authoredNotes,
            notesAreGenerated: notesAreGenerated,
            transcript: transcript,
            summaries: [],
            prompts: Self.defaultPrompts(),
            destinations: [],
            selectedTemplate: selectedTemplate,
            selectedPromptID: nil,
            isPinned: false,
            consentState: consentState,
            meetingMode: meetingMode,
            retentionPolicy: retentionPolicy,
            transcriptVisibilityEnabled: transcript.isEmpty == false,
            audioRecordings: audioRecordings,
            calendarEventID: calendarEventID,
            calendarStartDate: calendarStartDate,
            calendarEndDate: calendarEndDate
        )
        meeting.selectedPromptID = meeting.prompts.first?.id
        meetings.insert(meeting, at: 0)
        let newID = meeting.id
        if status != .processing, shouldScheduleDerivedProcessing {
            scheduleRegeneration(
                for: newID,
                delayMilliseconds: 120,
                shouldScheduleAIProcessing: shouldScheduleAIProcessing
            )
        } else if status != .processing, shouldScheduleAIProcessing {
            scheduleAIProcessing(for: newID)
        }
        return meeting.id
    }

    func livePolishedPreview(
        title: String,
        objective: String,
        notes: String,
        transcriptParagraphs: [String]
    ) -> [String] {
        let cleanedTranscript = transcriptParagraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedNotes.isEmpty || !cleanedTranscript.isEmpty else {
            return []
        }

        let seedNotes: String
        if cleanedNotes.isEmpty {
            seedNotes = cleanedTranscript
                .prefix(3)
                .map { "- \($0)" }
                .joined(separator: "\n")
        } else {
            seedNotes = cleanedNotes
        }

        let polished = enhancedLiveNotes(notes: seedNotes, transcriptParagraphs: cleanedTranscript)
        return polished
            .components(separatedBy: .newlines)
            .map {
                $0
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "- ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    func addMeetingWithTransformation(
        title: String,
        workspace: String,
        attendees: [String],
        objective: String,
        notes: String,
        moments: [String] = [],
        transcript: [TranscriptLine] = [],
        status: MeetingStatus = .ready,
        stage: String = "Captured from iPhone notes",
        durationMinutes: Int = 25,
        meetingMode: MeetingMode = .privateNotes,
        consentState: ConsentState = .privateCapture,
        retentionPolicy: RetentionPolicy = .keepUntilDeleted,
        audioRecordings: [AudioRecordingAttachment] = []
    ) async -> Meeting.ID {
        let meetingID = addMeeting(
            title: title,
            workspace: workspace,
            attendees: attendees,
            objective: objective,
            notes: notes,
            moments: moments,
            transcript: transcript,
            status: status,
            stage: stage,
            durationMinutes: durationMinutes,
            meetingMode: meetingMode,
            consentState: consentState,
            retentionPolicy: retentionPolicy,
            audioRecordings: audioRecordings
        )

        _ = await rewriteMeetingNotes(for: meetingID)
        appendMoments(to: meetingID, moments: moments)
        return meetingID
    }

    func addLiveMeeting(
        title: String,
        workspace: String,
        attendees: [String],
        objective: String,
        notes: String,
        moments: [String] = [],
        transcriptParagraphs: [String],
        transcriptionSegments: [TranscriptionSegment] = [],
        meetingMode: MeetingMode = .privateNotes,
        consentState: ConsentState = .privateCapture,
        retentionPolicy: RetentionPolicy = .keepUntilDeleted,
        calendarEventID: String? = nil,
        calendarStartDate: Date? = nil,
        calendarEndDate: Date? = nil
    ) async -> Meeting.ID {
        let enhancedNotes = enhancedLiveNotes(notes: notes, transcriptParagraphs: transcriptParagraphs)
        let normalizedSegments = SpeakerIdentityResolver.normalizedSegments(transcriptionSegments)
        let transcriptLines = normalizedSegments.isEmpty
            ? transcriptParagraphs.map {
                TranscriptLine(speaker: "Meeting", role: "Live capture", text: $0)
            }
            : normalizedSegments.map {
                TranscriptLine(speaker: $0.speaker, role: "On-device capture", text: $0.text)
            }

        let meetingID = addMeeting(
            title: title,
            workspace: workspace,
            attendees: attendees,
            objective: objective,
            notes: enhancedNotes,
            authoredNotes: notes,
            notesAreGenerated: true,
            moments: moments,
            transcript: transcriptLines,
            status: .ready,
            stage: "Captured live on iPhone",
            meetingMode: meetingMode,
            consentState: consentState,
            retentionPolicy: retentionPolicy,
            calendarEventID: calendarEventID,
            calendarStartDate: calendarStartDate,
            calendarEndDate: calendarEndDate
        )

        appendMoments(to: meetingID, moments: moments)
        return meetingID
    }

    func addPendingLiveMeeting(
        id: Meeting.ID = UUID(),
        title: String,
        workspace: String,
        attendees: [String],
        objective: String,
        notes: String,
        moments: [String] = [],
        transcriptParagraphs: [String],
        transcriptionSegments: [TranscriptionSegment] = [],
        when: Date = .now,
        durationMinutes: Int,
        selectedTemplate: NoteTemplate,
        meetingMode: MeetingMode,
        consentState: ConsentState,
        retentionPolicy: RetentionPolicy,
        calendarEventID: String? = nil,
        calendarStartDate: Date? = nil,
        calendarEndDate: Date? = nil
    ) -> (id: Meeting.ID, pendingNotes: String) {
        let normalizedSegments = SpeakerIdentityResolver.normalizedSegments(transcriptionSegments)
        let transcriptLines = normalizedSegments.isEmpty
            ? transcriptParagraphs.map {
                TranscriptLine(speaker: "Meeting", role: "Live capture", text: $0)
            }
            : normalizedSegments.map {
                TranscriptLine(speaker: $0.speaker, role: "Live capture", text: $0.text)
            }
        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackNotes = transcriptParagraphs
            .prefix(4)
            .map { "- \($0)" }
            .joined(separator: "\n")
        let baseNotes = cleanedNotes.isEmpty
            ? (fallbackNotes.isEmpty ? "Recording saved. The transcript is being refined." : fallbackNotes)
            : cleanedNotes
        let pendingNotes = mergedNotesWithMoments(baseNotes, moments: moments)

        let meetingID = addMeeting(
            id: id,
            title: title,
            workspace: workspace,
            attendees: attendees,
            objective: objective,
            notes: pendingNotes,
            authoredNotes: mergedNotesWithMoments(cleanedNotes, moments: moments),
            notesAreGenerated: cleanedNotes.isEmpty,
            transcript: transcriptLines,
            when: when,
            status: .processing,
            stage: "Refining transcript and separating speakers",
            durationMinutes: max(1, durationMinutes),
            meetingMode: meetingMode,
            consentState: consentState,
            retentionPolicy: retentionPolicy,
            calendarEventID: calendarEventID,
            calendarStartDate: calendarStartDate,
            calendarEndDate: calendarEndDate,
            selectedTemplate: selectedTemplate,
            shouldScheduleAIProcessing: false
        )
        return (meetingID, pendingNotes)
    }

    @discardableResult
    func restorePendingLiveMeeting(
        id: Meeting.ID,
        recovery: PendingMeetingRecoveryPayload,
        capturedNotes: String,
        pendingNotes: String,
        moments: [String]
    ) -> Bool {
        if meeting(withID: id) != nil { return true }

        _ = addPendingLiveMeeting(
            id: id,
            title: recovery.title,
            workspace: recovery.workspace,
            attendees: recovery.attendees,
            objective: recovery.objective,
            notes: capturedNotes,
            moments: moments,
            transcriptParagraphs: recovery.transcriptParagraphs,
            when: recovery.capturedAt,
            durationMinutes: recovery.durationMinutes,
            selectedTemplate: recovery.selectedTemplate,
            meetingMode: recovery.meetingMode,
            consentState: recovery.consentState,
            retentionPolicy: recovery.retentionPolicy,
            calendarEventID: recovery.calendarEventID,
            calendarStartDate: recovery.calendarStartDate,
            calendarEndDate: recovery.calendarEndDate
        )
        if let index = index(for: id),
           !pendingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var meeting = meetings[index]
            meeting.rawNotes = pendingNotes
            meeting.notesAreGenerated = true
            replaceMeeting(meeting, at: index, effects: .semanticContent)
        }
        return true
    }

    func updateMeetingProcessingStage(_ stage: String, for id: Meeting.ID) {
        guard let index = index(for: id),
              meetings[index].status == .processing,
              meetings[index].stage != stage
        else { return }
        var meeting = meetings[index]
        meeting.stage = stage
        replaceMeeting(meeting, at: index, effects: .presentation)
    }

    func completePendingLiveMeeting(
        id: Meeting.ID,
        result: TranscriptionResult,
        capturedNotes: String,
        pendingNotes: String,
        moments: [String]
    ) async -> Bool {
        guard let index = index(for: id) else { return false }
        var meeting = meetings[index]

        let normalizedSegments = SpeakerIdentityResolver.normalizedSegments(result.segments)
        let transcriptLines: [TranscriptLine]
        if normalizedSegments.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            transcriptLines = text.isEmpty
                ? meeting.transcript
                : [TranscriptLine(speaker: "Meeting", role: result.provider.title, text: text)]
        } else {
            transcriptLines = normalizedSegments.map {
                TranscriptLine(speaker: $0.speaker, role: result.provider.title, text: $0.text)
            }
        }

        let transcriptParagraphs = transcriptLines.map(\.text)
        let currentNotes = meeting.rawNotes
        let userEditedWhileProcessing = currentNotes != pendingNotes
        let noteSource = userEditedWhileProcessing ? currentNotes : capturedNotes
        var refinedNotes = enhancedLiveNotes(
            notes: noteSource,
            transcriptParagraphs: transcriptParagraphs
        )
        if !userEditedWhileProcessing {
            refinedNotes = mergedNotesWithMoments(refinedNotes, moments: moments)
        }

        meeting.transcript = transcriptLines
        meeting.transcriptVisibilityEnabled = !transcriptLines.isEmpty
        let hasSeparatedSpeakers = result.diarizationAvailable
            && result.distinctSpeakerCount > 1
        meeting.speakerSeparationConfidence = hasSeparatedSpeakers
            ? result.effectiveSpeakerSeparationConfidence
            : .unverified
        if !noteSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meeting.authoredNotes = userEditedWhileProcessing
                ? noteSource
                : mergedNotesWithMoments(noteSource, moments: moments)
        }
        meeting.rawNotes = refinedNotes
        meeting.notesAreGenerated = true
        meeting.stage = "Organizing the final meeting notes"
        invalidateGeneratedIntelligence(in: &meeting)
        replaceMeeting(meeting, at: index, effects: .semanticContent)

        _ = await rewriteMeetingNotes(for: id)
        guard let finalIndex = self.index(for: id) else { return false }

        let speakerCount = result.diarizationAvailable ? result.distinctSpeakerCount : 0
        var finalMeeting = meetings[finalIndex]
        finalMeeting.status = .ready
        if speakerCount > 1 {
            let qualifier = result.effectiveSpeakerSeparationConfidence == .strong
                ? "voice patterns"
                : "likely speakers"
            finalMeeting.stage = "Enhanced transcript ready · \(speakerCount) \(qualifier)"
        } else {
            finalMeeting.stage = "Enhanced transcript ready"
        }
        replaceMeeting(finalMeeting, at: finalIndex, effects: .retention)
        scheduleRegeneration(for: id, delayMilliseconds: 80)
        return true
    }

    func finishPendingMeetingWithLiveTranscript(_ id: Meeting.ID, message: String) {
        guard let index = index(for: id) else { return }
        var meeting = meetings[index]
        meeting.status = .ready
        meeting.stage = message
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(
            meeting,
            at: index,
            effects: .semanticContentAndRetention
        )
    }

    func updatePendingLiveTranscript(_ id: Meeting.ID, transcript: String) {
        guard let index = index(for: id),
              meetings[index].status == .processing
        else { return }
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        var meeting = meetings[index]
        let nextTranscript = transcriptLines(
            from: cleaned,
            speaker: "Meeting",
            role: "Live capture"
        )
        let transcriptIsUnchanged = meeting.transcript.count == nextTranscript.count
            && zip(meeting.transcript, nextTranscript).allSatisfy { current, next in
                current.speaker == next.speaker
                    && current.role == next.role
                    && current.text == next.text
            }
        guard !transcriptIsUnchanged || !meeting.transcriptVisibilityEnabled else { return }
        meeting.transcript = transcriptLinesPreservingIdentity(
            nextTranscript,
            previous: meeting.transcript
        )
        meeting.transcriptVisibilityEnabled = true
        invalidateGeneratedIntelligence(in: &meeting)
        replaceMeeting(meeting, at: index, effects: .semanticContent)
    }

    @discardableResult
    func finishPendingMeetingPreservingAudio(
        _ id: Meeting.ID,
        recordingURL: URL,
        recovery: PendingMeetingRecoveryPayload?,
        message: String
    ) -> Bool {
        guard let index = index(for: id) else { return false }
        var meeting = meetings[index]
        let fileName = RecordingFileStore.fileName(for: recordingURL)
        if !meeting.audioRecordings.contains(where: { $0.fileName == fileName }) {
            meeting.audioRecordings.append(AudioRecordingAttachment(
                title: "\(meeting.title) recording",
                createdAt: recovery?.capturedAt ?? meeting.when,
                durationSeconds: recovery?.durationSeconds
                    ?? max(1, (recovery?.durationMinutes ?? meeting.durationMinutes) * 60),
                fileName: fileName,
                transcript: recovery?.liveTranscript
                    ?? meeting.transcript.map(\.text).joined(separator: " "),
                linkedNote: meeting.trustedSourceNotes,
                source: .noteAttachment,
                fileSizeBytes: RecordingFileStore.fileSize(at: recordingURL)
            ))
        }
        meeting.status = .ready
        meeting.stage = message
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(
            meeting,
            at: index,
            effects: .semanticContentAndRetention
        )
        return true
    }

    func addVoiceRecording(
        title: String,
        workspace: String,
        notes: String,
        recording: AudioRecordingAttachment
    ) async -> Meeting.ID {
        let transcriptLines = transcriptLines(
            from: recording,
            fallbackSpeaker: "Voice note",
            fallbackRole: recording.source.title
        )
        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackNotes = recording.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawNotes = cleanedNotes.isEmpty
            ? (fallbackNotes.isEmpty ? "- Voice note recorded. Add notes after review." : fallbackNotes)
            : cleanedNotes

        let meetingID = addMeeting(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Voice note" : title,
            workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Voice Notes" : workspace,
            attendees: ["You"],
            objective: "Capture a voice note with audio, transcript, and linked notes.",
            notes: rawNotes,
            transcript: transcriptLines,
            status: .ready,
            stage: "Recorded voice note",
            durationMinutes: recording.durationMinutes,
            meetingMode: .privateNotes,
            consentState: .privateCapture,
            retentionPolicy: recording.hasTranscript ? .transcript7Days : .keepUntilDeleted,
            audioRecordings: [recording]
        )

        Task { @MainActor [weak self] in
            _ = await self?.rewriteMeetingNotes(for: meetingID)
        }
        return meetingID
    }

    func attachVoiceRecording(
        _ recording: AudioRecordingAttachment,
        to meetingID: Meeting.ID,
        appendTranscriptToNotes: Bool
    ) {
        guard let index = index(for: meetingID) else { return }
        var meeting = meetings[index]
        if !meeting.audioRecordings.contains(where: { $0.id == recording.id }) {
            meeting.audioRecordings.append(recording)
        }

        let newTranscript = transcriptLines(
            from: recording,
            fallbackSpeaker: "Voice note",
            fallbackRole: recording.source.title
        )
        if !newTranscript.isEmpty {
            let existingFingerprints = Set(meeting.transcript.map { normalizedFingerprint($0.text) })
            let filtered = newTranscript.filter { !existingFingerprints.contains(normalizedFingerprint($0.text)) }
            meeting.transcript.append(contentsOf: filtered)
            meeting.transcriptVisibilityEnabled = true
            if recording.diarizationAvailable,
               Set(newTranscript.map {
                   SpeakerIdentityResolver.canonicalKey(for: $0.speaker)
               }).filter({ !$0.isEmpty }).count > 1,
               meeting.speakerSeparationConfidence != .strong {
                meeting.speakerSeparationConfidence = .tentative
            }
        }

        if appendTranscriptToNotes {
            let noteParts = [
                recording.linkedNote.trimmingCharacters(in: .whitespacesAndNewlines),
                recording.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            let addendum = noteParts.first(where: { !$0.isEmpty }) ?? ""
            if !addendum.isEmpty {
                if meeting.originalCaptureNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    meeting.originalCaptureNotes = addendum
                } else {
                    meeting.originalCaptureNotes += "\n\nVoice note: \(addendum)"
                }
                if meeting.authoredNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    meeting.authoredNotes = addendum
                } else {
                    meeting.authoredNotes += "\n\nVoice note: \(addendum)"
                }
                if meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    meeting.rawNotes = addendum
                } else {
                    meeting.rawNotes += "\n\nVoice note: \(addendum)"
                }
            }
        }

        let totalRecordingSeconds = meeting.audioRecordings.reduce(0) { $0 + $1.durationSeconds }
        meeting.durationMinutes = max(meeting.durationMinutes, Int(ceil(Double(totalRecordingSeconds) / 60.0)))
        meeting.stage = "Voice recording attached"
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(
            meeting,
            at: index,
            effects: .semanticContentAndRetention
        )
    }

    func updateRecordingTitle(_ title: String, recordingID: AudioRecordingAttachment.ID, in meetingID: Meeting.ID) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let meetingIndex = index(for: meetingID),
              let recordingIndex = meetings[meetingIndex].audioRecordings.firstIndex(where: { $0.id == recordingID })
        else { return }

        guard meetings[meetingIndex].audioRecordings[recordingIndex].title != cleaned else { return }
        var meeting = meetings[meetingIndex]
        meeting.audioRecordings[recordingIndex].title = cleaned
        replaceMeeting(meeting, at: meetingIndex, effects: .presentation)
    }

    func deleteRecording(_ recordingID: AudioRecordingAttachment.ID, from meetingID: Meeting.ID) {
        guard let meetingIndex = index(for: meetingID),
              let recording = meetings[meetingIndex].audioRecordings.first(where: { $0.id == recordingID })
        else { return }

        var meeting = meetings[meetingIndex]
        meeting.audioRecordings.removeAll { $0.id == recordingID }
        RecordingFileStore.deleteFile(named: recording.fileName)
        meeting.stage = meeting.audioRecordings.isEmpty
            ? "Audio removed after review"
            : "Voice recording removed"
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(
            meeting,
            at: meetingIndex,
            effects: .semanticContentAndRetention
        )
    }

    private func deleteRecordings(where shouldDelete: (AudioRecordingAttachment) -> Bool) -> Int {
        var updatedMeetings = meetings
        var deletedCount = 0
        var changedMeetingIDs: [Meeting.ID] = []

        for index in updatedMeetings.indices {
            let removed = updatedMeetings[index].audioRecordings.filter(shouldDelete)
            guard !removed.isEmpty else { continue }

            for recording in removed {
                RecordingFileStore.deleteFile(named: recording.fileName)
            }

            let removedIDs = Set(removed.map(\.id))
            updatedMeetings[index].audioRecordings.removeAll { removedIDs.contains($0.id) }
            updatedMeetings[index].stage = updatedMeetings[index].audioRecordings.isEmpty
                ? "Audio files cleaned up"
                : "Some audio files cleaned up"
            invalidateGeneratedIntelligence(in: &updatedMeetings[index])
            changedMeetingIDs.append(updatedMeetings[index].id)
            deletedCount += removed.count
        }

        guard deletedCount > 0 else { return 0 }

        replaceMeetings(updatedMeetings)
        scheduleDerivedDataMigration(
            for: changedMeetingIDs,
            forceRefresh: true
        )
        return deletedCount
    }

    func audioURL(for recording: AudioRecordingAttachment) -> URL {
        RecordingFileStore.url(for: recording.fileName)
    }

    @discardableResult
    func applyRecoveredTranscript(
        _ result: TranscriptionResult,
        recordingID: AudioRecordingAttachment.ID,
        meetingID: Meeting.ID
    ) -> Bool {
        guard let meetingIndex = index(for: meetingID),
              let recordingIndex = meetings[meetingIndex].audioRecordings.firstIndex(where: { $0.id == recordingID })
        else { return false }

        let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        var meeting = meetings[meetingIndex]
        let previousRecording = meeting.audioRecordings[recordingIndex]
        let previousRecordingFingerprints = Set(
            transcriptLines(
                from: previousRecording,
                fallbackSpeaker: "Voice note",
                fallbackRole: previousRecording.source.title
            ).map { normalizedFingerprint($0.text) }
        )
        meeting.audioRecordings[recordingIndex].transcript = cleaned
        meeting.audioRecordings[recordingIndex].transcriptionSegments =
            SpeakerIdentityResolver.normalizedSegments(result.segments)
        meeting.audioRecordings[recordingIndex].transcriptionProvider = result.provider
        meeting.audioRecordings[recordingIndex].diarizationAvailable = result.diarizationAvailable

        let recoveredLines: [TranscriptLine]
        if result.segments.isEmpty {
            recoveredLines = transcriptLines(
                from: cleaned,
                speaker: "Voice note",
                role: result.provider.title
            ).map { line in
                var sourced = line
                sourced.sourceRecordingID = recordingID
                return sourced
            }
        } else {
            recoveredLines = SpeakerIdentityResolver.normalizedSegments(result.segments).compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptLine(
                    speaker: segment.speaker,
                    role: result.provider.title,
                    text: text,
                    sourceRecordingID: recordingID
                )
            }
        }

        meeting.transcript.removeAll { line in
            line.sourceRecordingID == recordingID
                || previousRecordingFingerprints.contains(normalizedFingerprint(line.text))
        }
        let existing = Set(meeting.transcript.map { normalizedFingerprint($0.text) })
        meeting.transcript.append(contentsOf: recoveredLines.filter {
            !existing.contains(normalizedFingerprint($0.text))
        })
        meeting.transcriptVisibilityEnabled = true
        let hasSeparatedSpeakers = result.diarizationAvailable
            && result.distinctSpeakerCount > 1
        meeting.speakerSeparationConfidence = hasSeparatedSpeakers
            ? result.effectiveSpeakerSeparationConfidence
            : .unverified
        meeting.retentionPolicy = .transcript7Days
        meeting.retentionPolicyUpdatedAt = .now
        meeting.status = .ready
        meeting.stage = result.usedFallback
            ? "Transcript recovered locally"
            : "Transcript recovered"
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(
            meeting,
            at: meetingIndex,
            effects: .semanticContentAndRetention
        )
        return true
    }

    func rewriteMeetingNotes(for id: Meeting.ID, style: NoteRewriteStyle = .concise) async -> String {
        guard let index = index(for: id) else {
            return "Meeting not found."
        }

        let meeting = meetings[index]
        let preservedMoments = extractedBookmarkMoments(from: meeting.rawNotes)
        let outcome = await polishNotes(
            title: meeting.title,
            objective: meeting.objective,
            notes: meeting.rawNotes,
            transcriptParagraphs: meeting.transcript.map { "\($0.speaker): \($0.text)" },
            style: style,
            purpose: meeting.purpose.kind
        )

        guard let currentIndex = self.index(for: id) else {
            return "Meeting was removed before note polishing finished."
        }
        let current = meetings[currentIndex]
        guard current.rawNotes == meeting.rawNotes,
              current.transcript == meeting.transcript,
              current.title == meeting.title,
              current.objective == meeting.objective
        else {
            return "Kept your newer edits instead of replacing them."
        }

        switch outcome {
        case let .appleIntelligence(rewrittenNotes, message):
            var updated = current
            if !updated.notesAreGenerated {
                updated.authoredNotes = updated.rawNotes
            }
            updated.rawNotes = mergedNotesWithMoments(rewrittenNotes, moments: preservedMoments)
            updated.notesAreGenerated = true
            updated.stage = "Apple Intelligence polished notes"
            publishSemanticMutation(updated, at: currentIndex)
            return message
        case let .heuristic(rewrittenNotes, message):
            let cleanedRewrite = rewrittenNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedRewrite.isEmpty || !current.transcript.isEmpty else {
                return message
            }
            var updated = current
            if !cleanedRewrite.isEmpty {
                if !updated.notesAreGenerated {
                    updated.authoredNotes = updated.rawNotes
                }
                updated.rawNotes = mergedNotesWithMoments(rewrittenNotes, moments: preservedMoments)
                updated.notesAreGenerated = true
            }
            if !updated.transcript.isEmpty {
                updated.stage = "Auto-polished from transcript"
            }
            publishSemanticMutation(updated, at: currentIndex)
            return message
        case let .unavailable(message):
            return message
        }
    }

    /// Process a meeting's notes with the on-device language model into a clean,
    /// typo-corrected, structured brief, and store it. The brief's read sites
    /// (signals, commitments, summaries) prefer it; if the model is unavailable
    /// or fails, nothing changes and the heuristic engine stays in charge.
    /// Meetings the model is currently processing — drives the "Processing…"
    /// indicator in the UI.
    private(set) var aiProcessingIDs: Set<Meeting.ID> = []
    private(set) var derivedProcessingIDs: Set<Meeting.ID> = []

    func isProcessingAI(_ id: Meeting.ID) -> Bool { aiProcessingIDs.contains(id) }
    func isPreparingDerivedData(_ id: Meeting.ID) -> Bool {
        derivedProcessingIDs.contains(id)
    }

    private func updateDerivedProcessingState(for id: Meeting.ID) {
        let isPreparing = regenerationDerivedRunIDs[id] != nil
            || derivedMigrationPendingIDs.contains(id)
        if isPreparing {
            guard !derivedProcessingIDs.contains(id) else { return }
            derivedProcessingIDs.insert(id)
        } else {
            guard derivedProcessingIDs.contains(id) else { return }
            derivedProcessingIDs.remove(id)
        }
    }

    private func updateDerivedProcessingStates(for ids: Set<Meeting.ID>) {
        guard !ids.isEmpty else { return }
        var updated = derivedProcessingIDs
        for id in ids {
            let isPreparing = regenerationDerivedRunIDs[id] != nil
                || derivedMigrationPendingIDs.contains(id)
            if isPreparing {
                updated.insert(id)
            } else {
                updated.remove(id)
            }
        }
        guard updated != derivedProcessingIDs else { return }
        derivedProcessingIDs = updated
    }

    private func scheduleAIProcessing(for id: Meeting.ID) {
        aiProcessingTasks[id]?.cancel()
        aiProcessingTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.processWithAI(for: id)
            guard !Task.isCancelled else { return }
            self.aiProcessingTasks[id] = nil
        }
    }

    func processWithAI(for id: Meeting.ID) async {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = AppleIntelligenceBriefExtractor.availability() else { return }
            guard let meeting = meeting(withID: id) else { return }
            let runID = UUID()
            aiProcessingRunIDs[id] = runID
            aiProcessingIDs.insert(id)
            defer {
                if aiProcessingRunIDs[id] == runID {
                    aiProcessingRunIDs[id] = nil
                    aiProcessingIDs.remove(id)
                }
            }
            do {
                let result = try await AppleIntelligenceBriefExtractor.extract(meeting: meeting)
                try Task.checkCancellation()
                guard aiProcessingRunIDs[id] == runID else { return }
                guard let index = index(for: id) else { return }
                let current = meetings[index]
                guard current.title == meeting.title,
                      current.objective == meeting.objective,
                      current.rawNotes == meeting.rawNotes,
                      current.transcript == meeting.transcript,
                      current.contextMode == meeting.contextMode,
                      current.purposeOverride == meeting.purposeOverride,
                      current.meetingMode == meeting.meetingMode,
                      current.consentState == meeting.consentState
                else {
                    // The model answered an older source snapshot. A newer
                    // scheduled run owns the current note, so never publish
                    // stale intelligence over fresh user edits.
                    return
                }

                var brief = result.brief
                let inferredPurpose = brief.capturePurpose
                    ?? MeetingPurposeClassifier.standard.classify(meeting).kind
                if !inferredPurpose.allowsMeetingSignals {
                    brief.decisions = []
                    brief.risks = []
                }
                if !inferredPurpose.allowsAccountabilityExtraction { brief.actions = [] }
                // Store real content OR an explicit "doesn't make sense" verdict;
                // an empty-but-sensible result adds nothing over the heuristic.
                guard !brief.isEmpty || !brief.makesSense else { return }
                brief = briefPreservingSourceReferenceIdentity(
                    brief,
                    previous: current.aiBrief
                )

                var updated = current
                updated.aiBrief = brief
                // Auto-pick the lens when the user hasn't locked one (i.e. still
                // General) — so the badge and future re-tailoring match the meeting.
                if updated.contextMode == .general,
                   let detected = MeetingContextMode(rawValue: result.detectedType),
                   detected != .general {
                    updated.contextMode = detected
                }
                updated.score = nil
                publishSemanticMutation(
                    updated,
                    at: index,
                    shouldScheduleAIProcessing: false
                )
            } catch {
                // Heuristic stays in charge.
            }
        }
        #endif
    }

    /// "Maya — send the deck (by Friday)" from an AI action item.
    func aiActionSentence(_ a: AIActionItem) -> String {
        let core = a.task.hasSuffix(".") ? String(a.task.dropLast()) : a.task
        let due = a.due.isEmpty ? "" : " (by \(a.due))"
        if !a.owner.isEmpty, a.owner != "Owner not named" {
            let lowered = core.prefix(1).lowercased() + core.dropFirst()
            return "\(a.owner) — \(lowered)\(due)"
        }
        return "\(core)\(due)"
    }

    private func save() {
        saveTask?.cancel()
        let debounceMilliseconds: Int
        switch meetings.count {
        case 200...:
            debounceMilliseconds = 650
        case 60...:
            debounceMilliseconds = 400
        default:
            debounceMilliseconds = 250
        }
        saveTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.meetings
            await self.persist(snapshot)
        }
    }

    /// Commits the latest snapshot immediately when iOS moves the app out of
    /// the foreground. This closes the debounce window without doing JSON work
    /// on the main actor.
    func flushPersistence() async {
        saveTask?.cancel()
        saveTask = nil
        await persist(meetings)
    }

    private func persist(_ snapshot: [Meeting]) async {
        do {
            let didWrite = try await persistenceWriter.saveMeetings(
                snapshot,
                to: saveURL,
                recoveryURL: backupURL
            )
            let defaults = UserDefaults.standard
            let preferenceKey = "scribeflow.automaticBackupsEnabled"
            let automaticBackupsEnabled = defaults.object(forKey: preferenceKey) == nil
                ? true
                : defaults.bool(forKey: preferenceKey)
            if didWrite, automaticBackupsEnabled {
                _ = try? await BackupArchiveService.shared.saveAutomaticBackup(
                    meetings: snapshot,
                    schemaVersion: Self.currentSchemaVersion
                )
            }
            lastSaveFailed = false
        } catch {
            storeLog.error("Failed to persist meetings: \(error.localizedDescription, privacy: .public)")
            lastSaveFailed = true
        }
    }

    private func refreshSummariesIfNeeded(
        at index: Int,
        applySupersededCommitments shouldApplySupersededCommitments: Bool = true,
        preserveAuthoredCommitments: Bool = false,
        analysis: MeetingAnalysisBundle? = nil
    ) {
        guard meetings.indices.contains(index) else { return }
        let previous = meetings[index]
        var meeting = meetings[index]
        refreshDerivedData(
            in: &meeting,
            preserveAuthoredCommitments: preserveAuthoredCommitments,
            analysis: analysis
        )
        if meeting != previous {
            replaceMeeting(meeting, at: index, effects: .semanticContent)
            if let analysis {
                cacheAnalysis(analysis, for: meeting.id)
            }
        }
        if shouldApplySupersededCommitments {
            scheduleSupersededCommitmentRefresh()
        }
    }

    private func invalidateGeneratedIntelligence(in meeting: inout Meeting) {
        meeting.aiBrief = nil
        meeting.score = nil
    }

    private func reconcileSpeakerSeparationConfidence(in meeting: inout Meeting) {
        let distinctSpeakers = Set(meeting.transcript.map {
            SpeakerIdentityResolver.canonicalKey(for: $0.speaker)
        }).filter { !$0.isEmpty }.count
        if distinctSpeakers < 2 {
            meeting.speakerSeparationConfidence = .unverified
        }
    }

    private func refreshDerivedData(
        in meeting: inout Meeting,
        preserveAuthoredCommitments: Bool = false,
        analysis: MeetingAnalysisBundle? = nil
    ) {
        let purpose = analysis?.purpose ?? meeting.purpose
        if !purpose.allowsAccountabilityExtraction {
            for commitment in meeting.commitments where commitment.reminderID != nil {
                ReminderScheduler.cancel(meetingID: meeting.id, commitmentID: commitment.id)
            }
        }
        let previousSummaries = meeting.summaries
        let previousEvidenceItems = meeting.evidenceItems
        meeting.summaries = summariesPreservingIdentity(
            generatedSummaries(for: meeting, analysis: analysis),
            previous: previousSummaries
        )
        meeting.evidenceItems = evidenceItemsPreservingIdentity(
            generatedEvidenceItems(for: meeting, analysis: analysis),
            previous: previousEvidenceItems
        )
        // Regeneration must never erase a user's done/skipped state, owner, or
        // edited due date. Seed data keeps its authored copy and gains proof.
        if preserveAuthoredCommitments && !meeting.commitments.isEmpty {
            meeting.commitments = commitmentsAddingSourceProof(
                in: meeting,
                analysis: analysis
            )
        } else {
            meeting.commitments = generatedCommitmentsPreservingUserState(
                for: meeting,
                analysis: analysis
            )
        }
        meeting.sensitiveFlags = analysis?.sensitiveFlags
            ?? SensitiveContentDetector.flags(for: meeting)
        meeting.derivedDataVersion = Self.currentDerivedDataVersion
    }

    private func summariesPreservingIdentity(
        _ generated: [TemplateSummary],
        previous: [TemplateSummary]
    ) -> [TemplateSummary] {
        generated.map { generatedSummary in
            guard let priorSummary = previous.first(where: {
                $0.template == generatedSummary.template
            }) else {
                return generatedSummary
            }

            var revised = generatedSummary
            revised.id = priorSummary.id
            var availableSections = priorSummary.summary.sections
            revised.summary.sections = generatedSummary.summary.sections.map { generatedSection in
                guard let matchIndex = availableSections.firstIndex(where: {
                    $0.title.caseInsensitiveCompare(generatedSection.title) == .orderedSame
                }) else {
                    return generatedSection
                }
                var section = generatedSection
                section.id = availableSections.remove(at: matchIndex).id
                return section
            }
            return revised
        }
    }

    private func evidenceItemsPreservingIdentity(
        _ generated: [EvidenceItem],
        previous: [EvidenceItem]
    ) -> [EvidenceItem] {
        var availableItems = previous
        return generated.map { generatedItem in
            let fingerprint = normalizedFingerprint(generatedItem.text)
            guard let matchIndex = availableItems.firstIndex(where: {
                $0.level == generatedItem.level
                    && normalizedFingerprint($0.text) == fingerprint
            }) else {
                return generatedItem
            }

            let priorItem = availableItems.remove(at: matchIndex)
            var revised = generatedItem
            revised.id = priorItem.id
            revised.sourceReferences = sourceReferencesPreservingIdentity(
                generatedItem.sourceReferences,
                previous: priorItem.sourceReferences
            )
            return revised
        }
    }

    private func sourceReferencesPreservingIdentity(
        _ generated: [SourceReference],
        previous: [SourceReference]
    ) -> [SourceReference] {
        var availableReferences = previous
        return generated.map { generatedReference in
            guard let matchIndex = availableReferences.firstIndex(where: {
                sameSourceIdentity($0, generatedReference)
            }) else {
                return generatedReference
            }

            var revised = generatedReference
            revised.id = availableReferences.remove(at: matchIndex).id
            return revised
        }
    }

    private func briefPreservingSourceReferenceIdentity(
        _ generated: AIBriefData,
        previous: AIBriefData?
    ) -> AIBriefData {
        guard let previous else { return generated }
        var revised = generated
        var availableContributions = previous.speakerContributions
        revised.speakerContributions = generated.speakerContributions.map { contribution in
            let speakerKey = SpeakerIdentityResolver.canonicalKey(for: contribution.speaker)
            let contributionKey = normalizedFingerprint(contribution.contribution)
            guard let matchIndex = availableContributions.firstIndex(where: {
                SpeakerIdentityResolver.canonicalKey(for: $0.speaker) == speakerKey
                    && normalizedFingerprint($0.contribution) == contributionKey
            }) else {
                return contribution
            }

            let priorContribution = availableContributions.remove(at: matchIndex)
            var updated = contribution
            updated.sourceReferences = sourceReferencesPreservingIdentity(
                contribution.sourceReferences,
                previous: priorContribution.sourceReferences
            )
            return updated
        }
        return revised
    }

    private func sameSourceIdentity(
        _ lhs: SourceReference,
        _ rhs: SourceReference
    ) -> Bool {
        guard lhs.meetingID == rhs.meetingID, lhs.kind == rhs.kind else { return false }

        if lhs.transcriptLineID != nil || rhs.transcriptLineID != nil {
            return lhs.transcriptLineID == rhs.transcriptLineID
        }
        if lhs.lineIndex != nil || rhs.lineIndex != nil {
            return lhs.lineIndex == rhs.lineIndex
                && normalizedFingerprint(lhs.snippet) == normalizedFingerprint(rhs.snippet)
        }
        return normalizedFingerprint(lhs.snippet) == normalizedFingerprint(rhs.snippet)
            && SpeakerIdentityResolver.canonicalKey(for: lhs.speaker ?? "")
                == SpeakerIdentityResolver.canonicalKey(for: rhs.speaker ?? "")
    }

    private static func completeSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }

    private func generatedSummaries(
        for meeting: Meeting,
        analysis: MeetingAnalysisBundle? = nil
    ) -> [TemplateSummary] {
        // Nonsense verdict → a clarify summary, not fabricated structure.
        if let brief = meeting.aiBrief, !brief.makesSense {
            let clarify = MeetingSummary(
                eyebrow: "Needs input",
                title: "This does not make sense. Please clarify.",
                sections: [SummarySection(title: "Try this", bullets: [
                    "Add a little more context about what happened, what you are thinking, or what you want to remember."
                ])]
            )
            return NoteTemplate.allCases.map { TemplateSummary(template: $0, summary: clarify) }
        }

        let noteLines = evidenceNoteLines(for: meeting, analysis: analysis)
            .map(\.1)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•\t")) }
            .filter { !$0.isEmpty }
        let purpose = analysis?.purpose ?? meeting.purpose

        // Prefer the model's structured brief; otherwise fall back to the
        // heuristic. Only ever label something a "decision" or "next step" if it
        // really is one — never mislabel note lines or prefill a placeholder.
        let allowsMeetingSignals = purpose.allowsMeetingSignals
        let allowsAccountability = purpose.allowsAccountabilityExtraction
        let decisions: [String]
        let nextSteps: [String]
        let keyPoints: [String]
        if let brief = meeting.aiBrief, !brief.isEmpty {
            decisions = allowsMeetingSignals ? brief.decisions : []
            nextSteps = allowsAccountability ? brief.actions.map(aiActionSentence) : []
            keyPoints = brief.whatMatters.isEmpty ? brief.keyPoints : brief.whatMatters
        } else if let analysis {
            decisions = allowsMeetingSignals ? analysis.report.decisions : []
            nextSteps = allowsAccountability
                ? analysis.report.structuredActionItems.map(MeetingIntelligenceEngine.commitmentSentence)
                : []
            keyPoints = analysis.report.suggestedSummary
        } else {
            decisions = allowsMeetingSignals ? MeetingIntelligenceEngine.decisions(for: meeting, limit: 3) : []
            nextSteps = allowsAccountability
                ? MeetingIntelligenceEngine.structuredActions(for: meeting, limit: 4)
                    .map(MeetingIntelligenceEngine.commitmentSentence)
                : []
            keyPoints = MeetingIntelligenceEngine.keyPoints(for: meeting, limit: 5)
        }

        if !allowsMeetingSignals {
            var purposeSections: [SummarySection] = []
            if !keyPoints.isEmpty {
                purposeSections.append(SummarySection(
                    title: purpose.kind.insightTitle,
                    bullets: keyPoints
                ))
            }
            if let brief = meeting.aiBrief {
                purposeSections.append(contentsOf: brief.sections.prefix(4).map {
                    SummarySection(title: $0.heading, bullets: $0.items)
                })
                if !brief.openQuestions.isEmpty {
                    purposeSections.append(SummarySection(
                        title: "Questions to keep",
                        bullets: brief.openQuestions
                    ))
                }
            }
            if purposeSections.isEmpty, !noteLines.isEmpty {
                purposeSections.append(SummarySection(title: "Notes", bullets: Array(noteLines.prefix(5))))
            }

            let modelSummary = meeting.aiBrief?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let purposeTitle: String
            if !modelSummary.isEmpty {
                purposeTitle = modelSummary
            } else if let topic = purpose.topic {
                purposeTitle = "This capture is about \(topic.lowercased())."
            } else {
                purposeTitle = "Your \(purpose.displayTitle.lowercased()), organized clearly."
            }
            let summary = MeetingSummary(
                eyebrow: purpose.displayTitle,
                title: purposeTitle,
                sections: purposeSections
            )
            return NoteTemplate.allCases.map { TemplateSummary(template: $0, summary: summary) }
        }

        func sections(_ decisionsTitle: String, _ stepsTitle: String, _ pointsTitle: String) -> [SummarySection] {
            var out: [SummarySection] = []
            if !decisions.isEmpty { out.append(SummarySection(title: decisionsTitle, bullets: decisions)) }
            if !nextSteps.isEmpty { out.append(SummarySection(title: stepsTitle, bullets: nextSteps)) }
            if !keyPoints.isEmpty { out.append(SummarySection(title: pointsTitle, bullets: keyPoints)) }
            // Last resort only for content-free input (symbols/numbers): echo the
            // note rather than invent structure.
            if out.isEmpty, !noteLines.isEmpty {
                out.append(SummarySection(title: "Notes", bullets: Array(noteLines.prefix(5))))
            }
            return out
        }

        let modelSummary = meeting.aiBrief?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let objective = meeting.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingTitle = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !modelSummary.isEmpty
            ? modelSummary
            : (!objective.isEmpty
                ? Self.completeSentence(objective)
                : (meetingTitle.isEmpty
                    ? "Captured and ready to review."
                    : "Summary of \(meetingTitle)."))

        return [
            TemplateSummary(template: .general, summary: MeetingSummary(
                eyebrow: "Auto draft", title: title,
                sections: sections("Decisions", "Next steps", "Key points"))),
            TemplateSummary(template: .discovery, summary: MeetingSummary(
                eyebrow: "Auto draft", title: title,
                sections: sections("Decisions", "Next steps", "Key points"))),
            TemplateSummary(template: .exec, summary: MeetingSummary(
                eyebrow: "Exec view", title: "Quick readout for \(meeting.workspace).",
                sections: sections("What was decided", "Owns the follow-through", "Context"))),
            TemplateSummary(template: .manager, summary: MeetingSummary(
                eyebrow: "Coach angle", title: "Turn this capture into coaching and accountability.",
                sections: sections("Decisions to reinforce", "Hold owners to", "Observed"))),
            TemplateSummary(template: .standup, summary: MeetingSummary(
                eyebrow: "Standup", title: "Progress, blockers, and next ownership.",
                sections: sections("Decisions", "Owners and next steps", "Progress and blockers"))),
            TemplateSummary(template: .interview, summary: MeetingSummary(
                eyebrow: "Interview", title: "Evidence and decision context from this interview.",
                sections: sections("Decision signals", "Follow-up", "Observed evidence"))),
            TemplateSummary(template: .brainstorm, summary: MeetingSummary(
                eyebrow: "Brainstorm", title: "Themes and ideas worth carrying forward.",
                sections: sections("Ideas selected", "Experiments and next moves", "Themes"))),
        ]
    }

    private func enhancedLiveNotes(notes: String, transcriptParagraphs: [String]) -> String {
        let manualLines = notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let transcriptCandidates = transcriptParagraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 24 }

        var merged: [String] = []
        var seen: Set<String> = []
        var usedTranscriptFingerprints: Set<String> = []

        for line in manualLines {
            let context = bestTranscriptContext(for: line, in: transcriptCandidates)
            let enhanced = formatEnhancedMeetingLine(from: line, context: context)
            let fingerprint = normalizedFingerprint(enhanced)

            guard !fingerprint.isEmpty, !seen.contains(fingerprint) else { continue }
            seen.insert(fingerprint)
            merged.append("- \(enhanced)")

            if let context {
                usedTranscriptFingerprints.insert(normalizedFingerprint(context))
            }
        }

        let rankedCandidates = rankTranscriptHighlights(transcriptCandidates)

        for line in rankedCandidates {
            let transcriptFingerprint = normalizedFingerprint(line)

            guard !usedTranscriptFingerprints.contains(transcriptFingerprint) else { continue }

            let enhanced = formatEnhancedMeetingLine(from: line, context: nil)
            let fingerprint = normalizedFingerprint(enhanced)

            guard !fingerprint.isEmpty, !seen.contains(fingerprint) else { continue }
            seen.insert(fingerprint)
            merged.append("- \(enhanced)")
        }

        if merged.isEmpty {
            return """
            - Meeting captured live on iPhone and saved without enough transcript detail to enhance yet.
            - Add a little more context next time and Scribeflow will turn the conversation into stronger notes automatically.
            """
        }

        return merged.prefix(6).joined(separator: "\n")
    }

    private func enhancedPersonalNotes(notes: String, transcriptParagraphs: [String]) -> String {
        let noteLines = notes
            .split(whereSeparator: \.isNewline)
            .map { polishedFragment(from: String($0)) }
            .filter { !$0.isEmpty }
        let transcriptLines = transcriptParagraphs
            .map(polishedFragment)
            .filter { $0.count > 12 }

        var seen: Set<String> = []
        let ranked = noteLines + rankTranscriptHighlights(transcriptLines)
        let unique = ranked.compactMap { line -> String? in
            let body = sentenceBody(line)
            let fingerprint = normalizedFingerprint(body)
            guard !body.isEmpty, seen.insert(fingerprint).inserted else { return nil }
            return capitalizedSentence(body).hasSuffix(".")
                ? capitalizedSentence(body)
                : "\(capitalizedSentence(body))."
        }

        return unique.prefix(6).map { "- \($0)" }.joined(separator: "\n")
    }

    private func rankTranscriptHighlights(_ paragraphs: [String]) -> [String] {
        let weightedTerms = SignalWeights.terms

        return paragraphs
            .map { paragraph -> (String, Int) in
                let lower = paragraph.lowercased()
                var score = max(1, paragraph.count / 60)

                for (term, weight) in weightedTerms where lower.contains(term) {
                    score += weight
                }

                if paragraph.rangeOfCharacter(from: .decimalDigits) != nil {
                    score += 1
                }

                return (paragraph, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.count < rhs.0.count
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
    }

    private func bestTranscriptContext(for line: String, in paragraphs: [String]) -> String? {
        let noteTokens = significantTokens(in: line)

        guard !noteTokens.isEmpty else { return nil }

        return paragraphs
            .compactMap { paragraph -> (String, Int)? in
                let paragraphTokens = significantTokens(in: paragraph)
                let overlap = noteTokens.intersection(paragraphTokens).count

                guard overlap > 0 else { return nil }

                let score = overlap * 4 + min(paragraph.count / 50, 3)
                return (paragraph, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.count < rhs.0.count
                }
                return lhs.1 > rhs.1
            }
            .first?.0
    }

    private func formatEnhancedMeetingLine(from line: String, context: String?) -> String {
        let cleaned = polishedFragment(from: line)
        let lower = cleaned.lowercased()
        let base = sentenceBody(cleaned)

        guard !base.isEmpty else { return "" }

        let leadIn: String?

        if MeetingIntelligenceEngine.decision(from: cleaned) != nil {
            leadIn = "Decision"
        } else if MeetingIntelligenceEngine.actionItem(from: cleaned) != nil {
            leadIn = "Next step"
        } else if MeetingIntelligenceEngine.hasAffirmedRiskSignal(in: cleaned) {
            leadIn = "Risk"
        } else if lower.contains("budget") || lower.contains("price") {
            leadIn = "Budget"
        } else if lower.contains("timeline") || lower.contains("quarter") || lower.contains("launch") {
            leadIn = "Timing"
        } else {
            leadIn = nil
        }

        var sentence = leadIn.map { "\($0): \(base)" } ?? capitalizedSentence(base)

        if let context,
           let contextClause = contextualClause(from: context, comparedTo: cleaned)
        {
            sentence += ", and the transcript clarified that \(contextClause)"
        }

        return sentence.hasSuffix(".") ? sentence : "\(sentence)."
    }

    private func contextualClause(from context: String, comparedTo line: String) -> String? {
        let cleanedContext = sentenceBody(polishedFragment(from: context))
        let contextFingerprint = normalizedFingerprint(cleanedContext)
        let lineFingerprint = normalizedFingerprint(line)

        guard !cleanedContext.isEmpty, contextFingerprint != lineFingerprint else { return nil }

        let contextTokens = significantTokens(in: cleanedContext)
        let lineTokens = significantTokens(in: line)
        let uniqueContextTokens = contextTokens.subtracting(lineTokens)

        guard uniqueContextTokens.count >= 2 || cleanedContext.count > line.count + 16 else { return nil }

        return lowercasedSentence(cleanedContext)
    }

    private func polishedFragment(from line: String) -> String {
        line
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "•", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sentenceBody(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return "" }

        let components = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)

        if components.count == 2,
           components[0].count < 14
        {
            return String(components[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }

        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func significantTokens(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "about", "after", "again", "also", "around", "been", "being", "but", "from", "have",
            "into", "just", "more", "that", "than", "their", "them", "then", "they", "this",
            "what", "when", "with", "will", "would", "could", "should", "there", "here", "were",
            "your", "ours", "ourselves", "meeting", "notes"
        ]

        return Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }

    private func capitalizedSentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func lowercasedSentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private func normalizedFingerprint(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func firstMeaningfulLine(in notes: String) -> String? {
        notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func mergedNotesWithMoments(_ notes: String, moments: [String]) -> String {
        guard !moments.isEmpty else { return notes }

        let momentLines = moments.map { "- Bookmark: \($0)" }.joined(separator: "\n")
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedNotes.isEmpty else { return momentLines }
        return trimmedNotes + "\n" + momentLines
    }

    private func extractedBookmarkMoments(from notes: String) -> [String] {
        notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.lowercased().contains("bookmark:") }
            .map {
                $0
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "Bookmark:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private func appendMoments(to id: Meeting.ID, moments: [String]) {
        guard !moments.isEmpty else { return }
        guard let index = index(for: id) else { return }

        var meeting = meetings[index]
        meeting.originalCaptureNotes = mergedNotesWithMoments(
            meeting.originalCaptureNotes,
            moments: moments
        )
        meeting.authoredNotes = mergedNotesWithMoments(meeting.authoredNotes, moments: moments)
        meeting.rawNotes = mergedNotesWithMoments(meeting.rawNotes, moments: moments)
        invalidateGeneratedIntelligence(in: &meeting)
        publishSemanticMutation(meeting, at: index)
    }

    private func generatedEvidenceItems(
        for meeting: Meeting,
        analysis: MeetingAnalysisBundle? = nil
    ) -> [EvidenceItem] {
        let noteLines = evidenceNoteLines(for: meeting, analysis: analysis)

        return noteLines.map { index, line in
            let polishedLine = polishedSignalLine(line)
            let lower = line.lowercased()
            let level: EvidenceLevel

            if lower.contains("bookmark:") || lower.contains("personal note") {
                level = .personalNote
            } else {
                // This row is the user's saved note itself. Transcript overlap
                // can add corroboration, but is not required to prove the note
                // exists in Scribeflow's source record.
                level = .verified
            }

            return EvidenceItem(
                text: polishedLine,
                level: level,
                supportingSnippets: [],
                sourceReferences: [
                    SourceReference(
                        meetingID: meeting.id,
                        meetingTitle: meeting.title,
                        kind: .note,
                        snippet: polishedLine,
                        lineIndex: index,
                        matchStrength: .exact
                    )
                ]
            )
        }
        .filter {
            !$0.text.isEmpty
                && !meeting.dismissedEvidenceFingerprints.contains(
                    normalizedFingerprint($0.text)
                )
        }
    }

    private func evidenceNoteLines(
        for meeting: Meeting,
        analysis: MeetingAnalysisBundle?
    ) -> [(Int, String)] {
        if let analysis {
            return analysis.evidenceNoteLines.map { ($0.index, $0.text) }
        }
        return boundedEvidenceNoteLines(from: meeting.trustedSourceNotes)
    }

    /// A long pasted document can contain thousands of lines. Evidence remains
    /// useful when it is reviewable, so keep the opening, ending, signal-heavy,
    /// and evenly distributed lines instead of creating an enormous UI model.
    private func boundedEvidenceNoteLines(
        from notes: String,
        limit: Int = 120
    ) -> [(Int, String)] {
        let allLines = noteLinesWithIndex(from: notes)
        guard allLines.count > limit else { return allLines }

        var selectedIndices = Set<Int>()
        selectedIndices.reserveCapacity(limit)

        for entry in allLines.prefix(30) {
            selectedIndices.insert(entry.0)
        }
        for entry in allLines.suffix(20) {
            selectedIndices.insert(entry.0)
        }

        let signalTerms = [
            "decision", "decided", "agreed", "action", "owner", "will", "need to",
            "risk", "blocked", "concern", "question", "follow up", "due", "deadline"
        ]
        for (index, line) in allLines where selectedIndices.count < limit {
            let lower = line.lowercased()
            if line.contains("?") || signalTerms.contains(where: lower.contains) {
                selectedIndices.insert(index)
            }
        }

        if selectedIndices.count < limit {
            let remainingSlots = limit - selectedIndices.count
            let stride = max(1, allLines.count / max(1, remainingSlots))
            var offset = stride / 2
            while selectedIndices.count < limit, offset < allLines.count {
                selectedIndices.insert(allLines[offset].0)
                offset += stride
            }
        }

        return allLines.filter { selectedIndices.contains($0.0) }
    }

    private func generatedCommitments(
        for meeting: Meeting,
        analysis: MeetingAnalysisBundle? = nil
    ) -> [Commitment] {
        // Nonsense verdict → no commitments invented from gibberish.
        if let brief = meeting.aiBrief, !brief.makesSense { return [] }
        // Personal captures are notes, not accountability records. Keep them
        // searchable and summarizable without turning casual writing into Tasks.
        let purpose = analysis?.purpose ?? meeting.purpose
        guard purpose.allowsAccountabilityExtraction else { return [] }
        // Prefer the model's action items when it has processed this meeting.
        if let brief = meeting.aiBrief, !brief.actions.isEmpty {
            let generated = brief.actions.map { a in
                let lower = a.task.lowercased()
                let status: CommitmentStatus = (lower.contains("risk") || lower.contains("block")
                    || lower.contains("stuck") || lower.contains("at risk")) ? .atRisk : .open
                return Commitment(
                    statement: a.task,
                    owner: a.owner.isEmpty ? "Owner not named" : a.owner,
                    sourceSpeaker: "AI",
                    dueHint: a.due.isEmpty ? nil : a.due,
                    status: status,
                    priority: a.priority.isEmpty ? nil : a.priority,
                    rationale: a.why.isEmpty ? nil : a.why,
                    sourceReferences: prefetchedSourceReferences(
                        for: a.task,
                        in: meeting,
                        analysis: analysis
                    )
                )
            }
            return deduplicatedCommitments(generated)
        }
        // Single source of truth: the same text-aware extractor that powers the
        // intelligence report, so persisted commitments match what the user
        // reads — real owners (You / Team / named), due hints, and de-noised
        // action lines instead of any line containing "will" or "by".
        let structuredActions = analysis?.report.structuredActionItems
            ?? MeetingIntelligenceEngine.structuredActions(for: meeting, limit: 6)
        let generated = structuredActions.map { action in
            let lower = action.text.lowercased()
            let status: CommitmentStatus = (lower.contains("risk")
                || lower.contains("block")
                || lower.contains("stuck")
                || lower.contains("overdue")
                || lower.contains("at risk")) ? .atRisk : .open
            return Commitment(
                statement: action.text,
                owner: action.owner,
                sourceSpeaker: action.sourceSpeaker,
                dueHint: action.dueHint,
                status: status,
                sourceReferences: prefetchedSourceReferences(
                    for: action.text,
                    in: meeting,
                    analysis: analysis
                )
            )
        }
        return deduplicatedCommitments(generated)
    }

    private func prefetchedSourceReferences(
        for text: String,
        in meeting: Meeting,
        analysis: MeetingAnalysisBundle?
    ) -> [SourceReference] {
        let key = normalizedFingerprint(text)
        if let references = analysis?.sourceReferencesByClaim[key] {
            return references
        }
        return sourceReferences(for: text, in: meeting)
    }

    private func deduplicatedCommitments(_ commitments: [Commitment]) -> [Commitment] {
        var accepted: [(commitment: Commitment, tokens: Set<String>)] = []
        for commitment in commitments {
            let tokens = significantTokens(in: commitment.statement)
            guard !tokens.isEmpty else { continue }
            if let index = accepted.firstIndex(where: { candidate in
                let ownersCompatible = candidate.commitment.owner == "Owner not named"
                    || commitment.owner == "Owner not named"
                    || candidate.commitment.owner.caseInsensitiveCompare(commitment.owner) == .orderedSame
                let overlap = Double(candidate.tokens.intersection(tokens).count)
                let union = Double(candidate.tokens.union(tokens).count)
                return ownersCompatible && union > 0 && overlap / union >= 0.72
            }) {
                var merged = accepted[index].commitment
                if merged.owner == "Owner not named" { merged.owner = commitment.owner }
                if merged.dueHint == nil { merged.dueHint = commitment.dueHint }
                if merged.priority == nil { merged.priority = commitment.priority }
                if merged.rationale == nil { merged.rationale = commitment.rationale }
                for reference in commitment.sourceReferences where !merged.sourceReferences.contains(where: {
                    $0.kind == reference.kind
                        && $0.transcriptLineID == reference.transcriptLineID
                        && $0.lineIndex == reference.lineIndex
                        && $0.snippet == reference.snippet
                }) {
                    merged.sourceReferences.append(reference)
                }
                if commitment.statement.count > merged.statement.count {
                    merged.statement = commitment.statement
                }
                accepted[index] = (merged, significantTokens(in: merged.statement))
            } else {
                accepted.append((commitment, tokens))
            }
        }
        return accepted.map { $0.commitment }
    }

    private func generatedCommitmentsPreservingUserState(
        for meeting: Meeting,
        analysis: MeetingAnalysisBundle? = nil
    ) -> [Commitment] {
        let previousByFingerprint = Dictionary(
            meeting.commitments.compactMap { commitment -> (String, Commitment)? in
                let fingerprint = normalizedFingerprint(commitment.statement)
                guard !fingerprint.isEmpty else { return nil }
                return (fingerprint, commitment)
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        return generatedCommitments(for: meeting, analysis: analysis).map { generated in
            let fingerprint = normalizedFingerprint(generated.statement)
            guard let previous = previousByFingerprint[fingerprint] else { return generated }

            var preserved = generated
            preserved.id = previous.id
            preserved.status = previous.status
            preserved.owner = previous.owner.isEmpty || previous.owner == "Owner not named"
                ? generated.owner
                : previous.owner
            preserved.dueDateOverride = previous.dueDateOverride
            preserved.dueHint = previous.dueDateOverride == nil
                ? (previous.dueHint ?? generated.dueHint)
                : previous.dueHint
            preserved.priority = previous.priority ?? generated.priority
            preserved.rationale = previous.rationale ?? generated.rationale
            preserved.reminderID = previous.reminderID
            preserved.reminderFireDate = previous.reminderFireDate
            preserved.reminderScheduledAt = previous.reminderScheduledAt
            let generatedReferences = generated.sourceReferences.isEmpty
                ? previous.sourceReferences
                : generated.sourceReferences
            preserved.sourceReferences = sourceReferencesPreservingIdentity(
                generatedReferences,
                previous: previous.sourceReferences
            )
            return preserved
        }
    }

    private func commitmentsAddingSourceProof(
        in meeting: Meeting,
        analysis: MeetingAnalysisBundle?
    ) -> [Commitment] {
        meeting.commitments.map { commitment in
            guard commitment.sourceReferences.isEmpty else { return commitment }
            var enriched = commitment
            enriched.sourceReferences = prefetchedSourceReferences(
                for: commitment.statement,
                in: meeting,
                analysis: analysis
            )
            return enriched
        }
    }

    private func transcriptLines(from transcript: String, speaker: String, role: String) -> [TranscriptLine] {
        SpeakerTranscriptParser.lines(from: transcript, defaultSpeaker: speaker, defaultRole: role)
    }

    private func transcriptLinesPreservingIdentity(
        _ generated: [TranscriptLine],
        previous: [TranscriptLine]
    ) -> [TranscriptLine] {
        var availableLines = previous
        return generated.map { generatedLine in
            guard let matchIndex = availableLines.firstIndex(where: {
                $0.sourceRecordingID == generatedLine.sourceRecordingID
                    && SpeakerIdentityResolver.canonicalKey(for: $0.speaker)
                        == SpeakerIdentityResolver.canonicalKey(for: generatedLine.speaker)
                    && $0.role == generatedLine.role
                    && normalizedFingerprint($0.text) == normalizedFingerprint(generatedLine.text)
            }) else {
                return generatedLine
            }

            var revised = generatedLine
            revised.id = availableLines.remove(at: matchIndex).id
            return revised
        }
    }

    private func transcriptLines(
        from recording: AudioRecordingAttachment,
        fallbackSpeaker: String,
        fallbackRole: String
    ) -> [TranscriptLine] {
        let segments = SpeakerIdentityResolver.normalizedSegments(recording.transcriptionSegments)
        if !segments.isEmpty {
            let role = recording.transcriptionProvider?.title ?? fallbackRole
            return segments.map {
                TranscriptLine(
                    speaker: $0.speaker,
                    role: role,
                    text: $0.text,
                    sourceRecordingID: recording.id
                )
            }
        }
        return transcriptLines(
            from: recording.transcript,
            speaker: fallbackSpeaker,
            role: fallbackRole
        ).map { line in
            var sourced = line
            sourced.sourceRecordingID = recording.id
            return sourced
        }
    }

    private func scheduleSupersededCommitmentRefresh() {
        commitmentSupersessionTask?.cancel()
        let runID = UUID()
        let expectedRevision = revision
        commitmentSupersessionRunID = runID
        let candidates = meetings.flatMap { meeting in
            meeting.commitments.map { commitment in
                CommitmentSupersessionCandidate(
                    meetingID: meeting.id,
                    meetingDate: meeting.when,
                    commitmentID: commitment.id,
                    statement: commitment.statement,
                    isOpen: commitment.status == .open
                )
            }
        }
        let worker = commitmentSupersessionWorker

        commitmentSupersessionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let supersededIDs = await worker.supersededCommitmentIDs(from: candidates)
            guard !Task.isCancelled,
                  let self,
                  self.commitmentSupersessionRunID == runID
            else { return }
            self.commitmentSupersessionTask = nil
            self.commitmentSupersessionRunID = nil
            guard self.revision == expectedRevision else { return }
            self.applySupersededCommitmentIDs(supersededIDs)
        }
    }

    private func applySupersededCommitmentIDs(
        _ supersededIDs: [Meeting.ID: Set<Commitment.ID>]
    ) {
        guard !supersededIDs.isEmpty else { return }
        var updatedMeetings = meetings
        var changed = false

        for (meetingID, commitmentIDs) in supersededIDs {
            guard let meetingIndex = indexByID[meetingID],
                  updatedMeetings.indices.contains(meetingIndex),
                  updatedMeetings[meetingIndex].id == meetingID
            else { continue }
            for commitmentIndex in updatedMeetings[meetingIndex].commitments.indices {
                guard commitmentIDs.contains(
                    updatedMeetings[meetingIndex].commitments[commitmentIndex].id
                ) else { continue }
                if updatedMeetings[meetingIndex].commitments[commitmentIndex].status == .open {
                    updatedMeetings[meetingIndex].commitments[commitmentIndex].status = .superseded
                    changed = true
                }
            }
        }

        if changed {
            replaceMeetings(updatedMeetings, effects: .commitments)
        }
    }

    private func safeSharePreview(
        for meeting: Meeting,
        format: MeetingExportFormat,
        includeInferred: Bool,
        includePrivateNotes: Bool,
        includeTranscript: Bool
    ) -> String {
        let visibleEvidence = meeting.evidenceItems.filter {
            includeInferred || $0.level != .inferred
        }

        let includeEvidenceLabels = format != .clientRecap
        let noteLines = visibleEvidence
            .filter { !$0.text.isEmpty }
            .map { item in
                var line = "- \(item.text)"
                if includeEvidenceLabels {
                    line += " [\(item.level.title)]"
                    if includeTranscript, let source = item.supportingSnippets.first {
                        line += " [source: \(source)]"
                    }
                }
                return line
            }
        let notesBlock = noteLines.isEmpty
            ? "- No safe bullets available yet."
            : noteLines.prefix(format == .execUpdate ? 4 : 6).joined(separator: "\n")

        let commitmentsBlock = meeting.allowsAccountabilityExtraction
            ? meeting.commitments
                .filter { $0.status != .superseded || format != .clientRecap }
                .prefix(4)
                .map { "- \($0.formattedLine)" }
                .joined(separator: "\n")
            : ""
        let emptyCommitmentsLine = meeting.allowsAccountabilityExtraction
            ? "- No commitments captured."
            : "- Personal note. No meeting tasks were extracted."
        let emptyNextStepsLine = meeting.allowsAccountabilityExtraction
            ? "- We'll confirm the next step in writing."
            : "- Personal note. No client next steps were extracted."
        let emptyFollowThroughLine = meeting.allowsAccountabilityExtraction
            ? "- No executive follow-through captured yet."
            : "- Personal note. No meeting follow-through was extracted."
        let emptyActionItemsLine = meeting.allowsAccountabilityExtraction
            ? "- No action items captured."
            : "- Personal note. No action items were extracted."

        let transcriptBlock = includeTranscript
            ? meeting.transcript.prefix(3).map { "- \($0.speaker): \($0.text)" }.joined(separator: "\n")
            : ""

        let privateNoteFooter = includePrivateNotes
            ? "\nInternal flags: \(meeting.sensitiveFlags.map(\.title).joined(separator: ", "))"
            : ""

        switch format {
        case .internalBrief:
            return """
            \(meeting.title)

            Objective: \(meeting.objective)
            Consent: \(meeting.consentState.title)

            What happened:
            \(notesBlock)

            Commitments:
            \(commitmentsBlock.isEmpty ? emptyCommitmentsLine : commitmentsBlock)\(privateNoteFooter)
            \(transcriptBlock.isEmpty ? "" : "\nTranscript context:\n\(transcriptBlock)")
            """
        case .clientRecap:
            return """
            Subject: \(meeting.title) recap

            Hi team,

            Thanks again for the conversation. Here’s the clean recap:

            \(notesBlock)

            Next steps:
            \(commitmentsBlock.isEmpty ? emptyNextStepsLine : commitmentsBlock)

            Best,
            """
        case .execUpdate:
            return """
            \(meeting.title) — exec update

            \(meeting.summary(for: .exec).title)

            Decisions and signals:
            \(notesBlock)

            Follow-through:
            \(commitmentsBlock.isEmpty ? emptyFollowThroughLine : commitmentsBlock)
            """
        case .markdown:
            let dateLine = ISO8601DateFormatter().string(from: meeting.when)
            let attendeesLine = meeting.attendees.isEmpty ? "" : "**Attendees:** \(meeting.attendees.joined(separator: ", "))\n"
            let transcriptSection = includeTranscript && !meeting.transcript.isEmpty
                ? "\n## Transcript\n\n" + meeting.transcript.map { "**\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
                : ""
            return """
            # \(meeting.title)

            \(attendeesLine)**Date:** \(dateLine)
            **Objective:** \(meeting.objective)

            ## Notes

            \(notesBlock)

            ## Action items

            \(commitmentsBlock.isEmpty ? emptyActionItemsLine : commitmentsBlock)\(transcriptSection)
            """
        }
    }

    private func sourceProof(
        references: [SourceReference],
        meeting: Meeting,
        fallbackDetail: String
    ) -> SourceProof {
        SourceProof(
            confidence: sourceConfidence(for: references),
            sourceMeetingTitle: meeting.title,
            references: references,
            fallbackDetail: fallbackDetail
        )
    }

    private func sourceConfidence(for references: [SourceReference]) -> SourceProofConfidence {
        if references.contains(where: { $0.matchStrength == .exact }) {
            return .confirmed
        }
        if references.contains(where: { $0.matchStrength == .partial }) {
            return .likely
        }
        if references.contains(where: { $0.matchStrength == .contextual }) {
            return .inferred
        }
        // Older saved references have no strength metadata. Preserve their
        // usefulness without silently upgrading them to confirmed.
        if !references.isEmpty { return .likely }
        return .needsReview
    }

    private func sourceReferences(for text: String, in meeting: Meeting) -> [SourceReference] {
        let noteReferences = matchingNoteReferences(for: text, in: meeting)
        if !noteReferences.isEmpty {
            return noteReferences
        }

        let transcriptReferences = matchingTranscriptReferences(for: text, in: meeting)
        if !transcriptReferences.isEmpty {
            return transcriptReferences
        }

        let audioReferences = matchingAudioReferences(for: text, in: meeting)
        if !audioReferences.isEmpty {
            return audioReferences
        }

        if let calendarReference = calendarReference(for: text, in: meeting) {
            return [calendarReference]
        }

        return []
    }

    private func bestEvidenceMatch(for text: String, in meeting: Meeting) -> EvidenceItem? {
        meeting.evidenceItems.first { sourceTextMatches(text, $0.text) }
    }

    private func matchingTranscriptReferences(for text: String, in meeting: Meeting) -> [SourceReference] {
        var references: [SourceReference] = []
        references.reserveCapacity(2)
        for (index, line) in meeting.transcript.enumerated() {
            guard let matchStrength = sourceTextMatchStrength(text, line.text) else { continue }
            references.append(SourceReference(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                kind: .transcript,
                snippet: line.text,
                speaker: line.speaker,
                transcriptLineID: line.id,
                lineIndex: index,
                matchStrength: matchStrength
            ))
            if references.count == 2 { break }
        }
        return references
    }

    private func matchingAudioReferences(for text: String, in meeting: Meeting) -> [SourceReference] {
        for recording in meeting.audioRecordings {
            let paragraphs = [recording.linkedNote, recording.transcript]
                .flatMap { $0.components(separatedBy: .newlines) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for (index, paragraph) in paragraphs.enumerated() {
                guard let matchStrength = sourceTextMatchStrength(text, paragraph) else { continue }
                return [SourceReference(
                    meetingID: meeting.id,
                    meetingTitle: meeting.title,
                    kind: .audioTranscript,
                    snippet: paragraph,
                    speaker: recording.title,
                    lineIndex: index,
                    matchStrength: matchStrength
                )]
            }
        }
        return []
    }

    private func matchingNoteReferences(for text: String, in meeting: Meeting) -> [SourceReference] {
        for (index, line) in noteLinesWithIndex(from: meeting.trustedSourceNotes) {
            guard let matchStrength = sourceTextMatchStrength(text, line) else { continue }
            return [SourceReference(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                kind: .note,
                snippet: polishedSignalLine(line),
                lineIndex: index,
                matchStrength: matchStrength
            )]
        }
        return []
    }

    private func calendarReference(for text: String, in meeting: Meeting) -> SourceReference? {
        guard meeting.calendarEventID != nil else { return nil }
        let calendarText = "\(meeting.title) \(meeting.attendees.joined(separator: " ")) \(meeting.objective)"
        guard let matchStrength = sourceTextMatchStrength(text, calendarText) else { return nil }

        let end = meeting.calendarEndDate.map { " - \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return SourceReference(
            meetingID: meeting.id,
            meetingTitle: meeting.title,
            kind: .calendar,
            snippet: "\(meeting.when.formatted(date: .abbreviated, time: .shortened))\(end)",
            matchStrength: matchStrength == .exact ? .exact : .contextual
        )
    }

    private func noteLinesWithIndex(from notes: String) -> [(Int, String)] {
        notes
            .components(separatedBy: .newlines)
            .enumerated()
            .map { ($0.offset, $0.element.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
    }

    private func sourceTextMatches(_ claim: String, _ source: String) -> Bool {
        sourceTextMatchStrength(claim, source) != nil
    }

    private func sourceTextMatchStrength(_ claim: String, _ source: String) -> SourceMatchStrength? {
        ClaimEvidenceValidator.matchStrength(claim: claim, source: source)
    }

    private func polishedSignalLine(_ line: String) -> String {
        let cleaned = polishedFragment(from: line)
            .replacingOccurrences(of: "Bookmark:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "" }

        let sentence = capitalizedSentence(sentenceBody(cleaned))
        guard !sentence.isEmpty else { return "" }
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }

    private func workspaceTags(for meeting: Meeting) -> [String] {
        if let cached = _workspaceTagsCache[meeting.id] {
            return cached
        }

        let tags = [
            "pricing", "security", "launch", "timeline", "mobile", "integration", "rollout",
            "budget", "hiring", "design", "privacy", "follow-up", "risk", "support", "adoption"
        ]
        var matches = Set<String>()

        func inspect(_ source: String) {
            guard matches.count < tags.count, !source.isEmpty else { return }
            let normalized = source.lowercased()
            for tag in tags where !matches.contains(tag) && normalized.contains(tag) {
                matches.insert(tag)
            }
        }

        inspect(meeting.objective)
        inspect(meeting.trustedSourceNotes)
        for line in meeting.transcript where matches.count < tags.count {
            inspect(line.text)
        }

        let result = tags.filter(matches.contains)
        if _workspaceTagsCache.count >= 64 {
            _workspaceTagsCache.removeAll(keepingCapacity: true)
        }
        _workspaceTagsCache[meeting.id] = result
        return result
    }

    private func topWorkspaceThemes(limit: Int) -> [String] {
        let tags = recentMeetings.prefix(10).flatMap(workspaceTags(for:))
        let ranked = Dictionary(grouping: tags, by: { $0 })
            .mapValues(\.count)
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)

        return ranked.map { $0.key }
    }


    nonisolated private static func normalizedMeeting(_ meeting: Meeting) -> Meeting {
        var normalized = meeting

        let existingPromptTitles = Set(normalized.prompts.map { $0.prompt.lowercased() })
        for prompt in defaultPrompts() where !existingPromptTitles.contains(prompt.prompt.lowercased()) {
            normalized.prompts.append(prompt)
        }

        if normalized.selectedPromptID == nil {
            normalized.selectedPromptID = normalized.prompts.first?.id
        }

        let staleLiveThreshold = Date.now.addingTimeInterval(-14_400)

        if normalized.status == .live, normalized.when < staleLiveThreshold {
            normalized.status = .ready

            if normalized.stage.lowercased().contains("capturing") {
                normalized.stage = "Captured and ready to review"
            }
        }

        normalized.transcriptVisibilityEnabled = normalized.transcriptVisibilityEnabled && !normalized.transcript.isEmpty

        return normalized
    }

    private static func sampleIdentityKey(for meeting: Meeting) -> String {
        "\(meeting.title.lowercased())|\(meeting.workspace.lowercased())|\(meeting.calendarEventID ?? "")"
    }

    nonisolated private static func defaultPrompts() -> [AIResponse] {
        [
            AIResponse(prompt: "Write follow-up", answer: "Draft a crisp follow-up that confirms the main outcome, decisions, and next step."),
            AIResponse(prompt: "List action items", answer: "Turn the notes into clear owners, actions, and follow-up deadlines."),
            AIResponse(prompt: "Slack update", answer: "Summarize the meeting for a team Slack update in a concise, confident tone."),
            AIResponse(prompt: "Risks and blockers", answer: "Call out the biggest risks, open questions, and blockers from this meeting."),
            AIResponse(prompt: "Decision memo", answer: "Condense the meeting into the core decision, why it matters, and what happens next."),
            AIResponse(prompt: "Customer themes", answer: "Extract recurring needs, pain points, and product signals from the conversation."),
            AIResponse(prompt: "Catch-up summary", answer: "Write a short catch-up for someone who joined the meeting late."),
        ]
    }

    private func polishNotes(
        title: String,
        objective: String,
        notes: String,
        transcriptParagraphs: [String],
        style: NoteRewriteStyle,
        purpose: CapturePurposeKind
    ) async -> NotePolishOutcome {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch AppleIntelligenceNoteTransformer.availability() {
            case .available:
                do {
                    let rewritten = try await AppleIntelligenceNoteTransformer.transformNotes(
                        title: title,
                        objective: objective,
                        notes: notes,
                        transcriptParagraphs: transcriptParagraphs,
                        style: style,
                        purpose: purpose
                    )

                    if !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .appleIntelligence(rewritten, "Polished with Apple Intelligence in \(style.title.lowercased()) style.")
                    }
                } catch {
                    break
                }
            case .unavailable(.deviceNotEligible):
                break
            case .unavailable(.appleIntelligenceNotEnabled):
                break
            case .unavailable(.modelNotReady):
                break
            @unknown default:
                break
            }
        }
        #endif

        if !transcriptParagraphs.isEmpty {
            let rewritten = purpose.isPersonalCapture
                ? enhancedPersonalNotes(notes: notes, transcriptParagraphs: transcriptParagraphs)
                : enhancedLiveNotes(notes: notes, transcriptParagraphs: transcriptParagraphs)
            return .heuristic(rewritten, "Saved with transcript-based note enhancement in \(style.title.lowercased()) style.")
        }

        return .unavailable("Apple Intelligence isn’t available on this device yet, so the original note was kept.")
    }
}

private enum NotePolishOutcome {
    case appleIntelligence(String, String)
    case heuristic(String, String)
    case unavailable(String)
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum AppleIntelligenceNoteTransformer {
    static func availability() -> SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static func transformNotes(
        title: String,
        objective: String,
        notes: String,
        transcriptParagraphs: [String],
        style: NoteRewriteStyle,
        purpose: CapturePurposeKind
    ) async throws -> String {
        let styleInstruction: String
        switch style {
        case .concise:
            styleInstruction = "Keep the bullets crisp and compact."
        case .detailed:
            styleInstruction = "Add a little more situational detail while staying clean and readable."
        case .executive:
            styleInstruction = purpose.allowsMeetingSignals
                ? "Write for an executive reader, emphasizing supported business impact and outcomes."
                : "Lead with the main point and remove secondary detail without making the note sound corporate."
        case .actionFocused:
            styleInstruction = purpose.allowsAccountabilityExtraction
                ? "Emphasize explicitly supported owners, commitments, and follow-through."
                : "Emphasize only intentions the speaker explicitly stated, without creating tasks, owners, or deadlines."
        }

        let purposeInstruction = purpose.allowsMeetingSignals
            ? "This is a structured professional capture. Prioritize confirmed outcomes, context, owners, and next steps only when supported."
            : "This is a \(purpose.title.lowercased()). Organize its ideas and facts naturally without turning them into meeting decisions, risks, owners, or tasks."
        let session = LanguageModelSession(instructions: """
        You are an expert notes editor.
        Rewrite rough notes into polished, professional notes that remain faithful to the capture.
        Return only 4 to 6 concise bullet points.
        Each bullet must be one sentence, specific, and useful.
        \(purposeInstruction)
        Use the person's rough notes as the anchor and use transcript context to fill in detail.
        \(styleInstruction)
        Do not add headings.
        Do not invent facts that aren't supported by the notes or transcript.
        Preserve negation, names, numbers, dates, prices, and ownership exactly. If
        the transcript is ambiguous, keep the uncertainty instead of guessing.
        """)

        let transcriptContext = representativeContext(
            from: transcriptParagraphs,
            limit: 24,
            purpose: purpose
        )
            .joined(separator: "\n")

        let prompt = """
        Capture title: \(title)
        Objective: \(objective)

        Rough notes:
        \(notes.isEmpty ? "No rough notes were captured." : notes)

        Transcript context:
        \(transcriptContext.isEmpty ? "No transcript context was captured." : transcriptContext)

        Rewrite this into polished, purpose-appropriate notes now.
        Return only bullet points.
        """

        let response = try await session.respond(to: prompt)
        return normalizeBullets(response.content)
    }

    private static func representativeContext(
        from lines: [String],
        limit: Int,
        purpose: CapturePurposeKind
    ) -> [String] {
        guard lines.count > limit, limit > 1 else { return lines }

        let cues: [String]
        switch purpose {
        case .meeting, .call:
            cues = [
                "decided", "decision", "will", "owner", "deadline", "due",
                "next step", "risk", "blocker", "question", "agreed", "need"
            ]
        case .appointment:
            cues = ["important", "instruction", "follow up", "symptom", "treatment", "question", "remember"]
        case .learning:
            cues = ["means", "because", "example", "important", "learned", "question", "concept"]
        case .reflection, .idea, .personalPlan, .conversation, .personalNote:
            cues = ["i feel", "i think", "i realized", "idea", "important", "remember", "because", "want", "plan"]
        }
        var selected: Set<Int> = [0, lines.count - 1]

        let signalIndices = lines.indices.sorted { left, right in
            let leftText = lines[left].lowercased()
            let rightText = lines[right].lowercased()
            let leftScore = cues.reduce(0) { $0 + (leftText.contains($1) ? 1 : 0) }
            let rightScore = cues.reduce(0) { $0 + (rightText.contains($1) ? 1 : 0) }
            if leftScore == rightScore { return left < right }
            return leftScore > rightScore
        }
        for index in signalIndices where selected.count < max(2, limit / 2) {
            selected.insert(index)
        }

        let spacing = Double(lines.count - 1) / Double(limit - 1)
        for slot in 0..<limit where selected.count < limit {
            selected.insert(Int((Double(slot) * spacing).rounded()))
        }

        for index in lines.indices where selected.count < limit {
            selected.insert(index)
        }
        return selected.sorted().prefix(limit).map { lines[$0] }
    }

    private static func normalizeBullets(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "- ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let normalized = lines.map { line in
            let sentence = line.hasSuffix(".") ? line : "\(line)."
            return "- \(sentence)"
        }

        return normalized.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedActionItem {
    @Guide(description: "The task as a short imperative phrase, e.g. 'Send the deck'. Fix any spelling.")
    var task: String
    @Guide(description: "Who owns it: a person's name, 'You', or 'Team'. Empty string if unclear.")
    var owner: String
    @Guide(description: "Due date if stated, e.g. 'Friday' or 'next week'. Empty string if none.")
    var due: String
    @Guide(description: "Priority based on urgency and impact stated in the notes: 'high', 'medium', or 'low'. Do not inflate.")
    var priority: String
    @Guide(description: "One short clause on why this matters / the consequence, only if the notes support it. Empty otherwise.")
    var why: String
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedEnhancedNote {
    @Guide(description: "The user's original note point, kept VERBATIM — do not reword, summarize, or fix it.")
    var anchor: String
    @Guide(description: "One concise sentence expanding that point with context from the notes or transcript. Empty string if there is nothing to add.")
    var detail: String
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedSection {
    @Guide(description: "A section heading specific to the meeting type, e.g. 'Done', 'In progress', 'Budget', 'Stakeholders', 'Looking ahead', 'Customer needs'.")
    var heading: String
    @Guide(description: "Concise bullets under this heading. Fix spelling.")
    var items: [String]
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedSpeakerContribution {
    @Guide(description: "The speaker label exactly as it appears in the numbered transcript.")
    var speaker: String
    @Guide(description: "One plain-language sentence describing this person's most important contribution, position, question, or commitment. Do not infer personality or emotion.")
    var contribution: String
    @Guide(description: "The 1-based numbered transcript line that directly supports the contribution. Use 0 only when there is no valid source, in which case the item will be discarded.")
    var sourceLineNumber: Int
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedBrief {
    @Guide(description: "true if the input is real, meaningful notes (even if rough or misspelled); false if it is random, unclear, or meaningless gibberish like 'asdf 123 jkl'.")
    var makesSense: Bool
    @Guide(description: "Classify the actual content as exactly one of: personalNote, reflection, idea, personalPlan, conversation, appointment, learning, meeting, or call. Use meeting/call only for structured professional collaboration, never just because the UI title says meeting.")
    var capturePurpose: String
    @Guide(description: "A concrete 2 to 6 word topic describing what the capture is about. Base it on the content, not the template. Empty only when the input does not make sense.")
    var captureTopic: String
    @Guide(description: "Classify the subject area as exactly one of: Personal, Work, Health, Education, Legal, Finance, or General.")
    var captureDomain: String
    @Guide(description: "Confidence in the capture-purpose classification: high, medium, or low.")
    var purposeConfidence: String
    @Guide(description: "Specific points that are genuinely ambiguous and need the user to clarify. Do NOT guess these. Empty when everything is clear.")
    var needsClarification: [String]
    @Guide(description: "A one or two sentence plain-language summary tailored to the detected capture purpose. Never call it a meeting unless capturePurpose is meeting or call.")
    var summary: String
    @Guide(description: "Decisions that were actually made. Empty for proposals, pending choices, or explicit statements that no decision was made.")
    var decisions: [String]
    @Guide(description: "Explicit action items or commitments only, each with an owner and due date when stated. A negated commitment such as 'will not' or 'does not need to' is not an action.")
    var actions: [GeneratedActionItem]
    @Guide(description: "Unresolved questions that still need an answer. Empty if none.")
    var openQuestions: [String]
    @Guide(description: "Other substantive discussion points that are not decisions or actions.")
    var keyPoints: [String]
    @Guide(description: "Affirmed risks, blockers, or concerns raised. Empty for statements such as 'no risk', 'not blocked', or neutral mentions of security, budget, or timeline.")
    var risks: [String]
    @Guide(description: "Up to four short points the note owner most needs to understand, ranked for the stated objective and brief focus. Do not repeat the summary or invent recommendations.")
    var whatMatters: [String]
    @Guide(description: "At most one important, source-backed contribution per reliably labeled speaker. Empty when the transcript has fewer than two distinct speaker labels.")
    var speakerContributions: [GeneratedSpeakerContribution]
    @Guide(description: "For each point the user wrote, the original text as the anchor plus added context. Keep the user's structure and order.")
    var enhancedNotes: [GeneratedEnhancedNote]
    @Guide(description: "Purpose-specific sections that do not duplicate other fields. Examples: reflection: Realizations / Patterns; idea: Core idea / Possibilities; appointment: Guidance / Instructions; learning: Concepts / Examples; work meeting: Done / In progress or Customer needs. Use natural headings for the actual content.")
    var sections: [GeneratedSection]
    @Guide(description: "Choose an optional domain lens: general, coaching, sales, legal, medical, founder, or product. Use general when none fits; this does not determine capturePurpose.")
    var detectedType: String
}

/// Turns rough, possibly misspelled notes into a clean, professional structured
/// brief using the on-device model — real comprehension, not keyword matching.
@available(iOS 26.0, *)
private enum AppleIntelligenceBriefExtractor {
    static func availability() -> SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static func extract(meeting: Meeting) async throws -> (brief: AIBriefData, detectedType: String) {
        let session = LanguageModelSession(instructions: """
        You are an expert capture-understanding editor inside a private notes app.
        First determine what the words are actually about, then turn rough notes
        and transcripts into the most useful brief for that purpose. Follow these
        rules strictly:

        1. NEVER invent anything. Use only what the input (and transcript) supports.
        2. If the input is random, unclear, or meaningless gibberish, set
           makesSense=false and leave every other field empty. Do not manufacture
           meaning from nonsense.
        3. Preserve important details, but rank them instead of repeating them.
        4. Use short sentences, familiar words, and one idea per bullet.
        5. Classify capturePurpose from the content itself. Titles, templates,
           workspaces, and UI labels are weak hints and may be wrong.
        6. Tailor the structure to capturePurpose:
           - reflection: realizations, themes, and details worth remembering.
           - idea: core concept, possibilities, constraints, and questions.
           - personalPlan: priorities and personal planning details in sections.
           - conversation: topics, viewpoints, and memorable details.
           - appointment: facts, guidance, instructions, and questions to remember.
           - learning: concepts, explanations, examples, and takeaways.
           - meeting/call: decisions, actions, owners, risks, and follow-through.
           - personalNote: clear facts and useful context without work structure.
        7. For every purpose except meeting or call, decisions, actions, and risks
           MUST be empty. Put supported information in keyPoints, whatMatters, or
           purpose-specific sections instead. Never manufacture accountability.
        8. Put each piece of information in one place. Do not repeat a point across
           summary, keyPoints, whatMatters, and sections.
        9. Language: simple, natural, and appropriate for the content. Do not make
           personal speech sound corporate.
        10. Remove repetition, but keep every important meaning.
        11. The summary is the bottom line. whatMatters is the smallest ranked set
           of facts the owner needs to understand the note in seconds.
        12. If a point is genuinely unclear, put it in needsClarification — do not
           guess it.
        13. Correct spelling and grammar. Write tasks as short imperative phrases.
            If a category has nothing, return it empty.
        14. Never merge speakers. For speakerContributions, use only the supplied
            speaker label and cite one numbered transcript line that directly
            supports the sentence. If labels are not distinct, return none.
        15. An appointment may contain important instructions, and a personal plan
            may contain intended steps. Keep those in descriptive sections; do not
            turn them into work tasks, owners, risks, or commitments.
        16. Treat speech recognition as fallible evidence. Preserve negation and the
            exact meaning of names, numbers, dates, prices, quantities, and owners.
            Never silently resolve an uncertain word into a stronger claim.
        17. "Not decided" is not a decision, "will not" is not an action item, and
            "no risk" is not a risk. Keep negative instructions as constraints only
            when the words explicitly support them.
        18. When speakers conflict, wording is incomplete, or a critical proper noun
            or number is unclear, use needsClarification instead of guessing.

        For enhancedNotes, treat the user's own bullet points as the skeleton:
        keep each one VERBATIM as the anchor (in their order) and add a short
        'detail' that fleshes it out from the transcript or surrounding notes.
        Never reword the anchor. Leave detail empty when there is nothing to add.
        """)

        let transcriptEvidence = selectedTranscriptEvidence(from: meeting.transcript, limit: 40)
        let evidenceLineIndices = Set(transcriptEvidence.map { $0.0 })
        let transcriptContext = transcriptEvidence.map { lineIndex, line in
            let lineNumber = lineIndex + 1
            let speaker = SpeakerIdentityResolver.normalizedDisplayName(line.speaker)
            let role = line.role.trimmingCharacters(in: .whitespacesAndNewlines)
            let roleLabel = role.isEmpty ? "" : " (\(role))"
            return "\(lineNumber). [\(speaker)\(roleLabel)]: \(bounded(line.text, maxCharacters: 260))"
        }.joined(separator: "\n")
        let detectedSpeakers = Set(meeting.transcript.map {
            SpeakerIdentityResolver.canonicalKey(for: $0.speaker)
        }).filter { !$0.isEmpty }.count
        let notes = bounded(
            meeting.trustedSourceNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            maxCharacters: 3_600
        )
        let prompt = """
        Capture title: \(meeting.title.isEmpty ? "(untitled)" : meeting.title)
        User objective: \(meeting.objective.isEmpty ? "Understand and organize the capture." : meeting.objective)
        User-confirmed purpose: \(meeting.purposeOverride?.title ?? "Automatic — infer from the evidence")
        Distinct transcript labels: \(detectedSpeakers)

        Notes (may contain typos and shorthand):
        \(notes.isEmpty ? "(none)" : notes)

        Numbered transcript evidence:
        \(transcriptContext.isEmpty ? "(none)" : transcriptContext)

        Infer the real purpose, topic, and domain from this evidence, then produce
        the purpose-appropriate structured brief for the note owner.
        """

        let response = try await session.respond(to: prompt, generating: GeneratedBrief.self)
        let g = response.content
        let clean: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let detected = clean(g.detectedType).lowercased()
        let fallbackPurpose = MeetingPurposeClassifier.standard.classify(meeting).kind
        let modelPurpose = CapturePurposeKind(modelValue: clean(g.capturePurpose))
        let capturePurpose: CapturePurposeKind
        if let purposeOverride = meeting.purposeOverride {
            capturePurpose = purposeOverride
        } else if let modelPurpose,
                  !modelPurpose.allowsMeetingSignals || fallbackPurpose.allowsMeetingSignals {
            capturePurpose = modelPurpose
        } else {
            capturePurpose = fallbackPurpose
        }
        let allowsMeetingSignals = capturePurpose.allowsMeetingSignals
        let allowsAccountability = capturePurpose.allowsAccountabilityExtraction
        let authoredNoteLines = meeting.trustedSourceNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let transcriptEvidenceLines = meeting.transcript.map { line in
            let speaker = SpeakerIdentityResolver.normalizedDisplayName(line.speaker)
            return speaker.isEmpty ? line.text : "\(speaker): \(line.text)"
        }
        let directEvidenceLines = authoredNoteLines + transcriptEvidenceLines
        let fallbackContextLines = [meeting.objective, meeting.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sourceEvidenceLines = directEvidenceLines.isEmpty ? fallbackContextLines : directEvidenceLines
        let supportedDecisionCount = sourceEvidenceLines.reduce(0) { count, line in
            count + (MeetingIntelligenceEngine.decision(from: line) == nil ? 0 : 1)
        }
        let supportedActionCount = sourceEvidenceLines.reduce(0) { count, line in
            count + (MeetingIntelligenceEngine.actionItem(from: line) == nil ? 0 : 1)
        }
        let supportedRiskCount = sourceEvidenceLines.reduce(0) { count, line in
            count + (MeetingIntelligenceEngine.hasAffirmedRiskSignal(in: line) ? 1 : 0)
        }

        // Nonsense input → a clear verdict, nothing manufactured (rule 2).
        guard g.makesSense else {
            return (AIBriefData(makesSense: false), detected)
        }

        var seenSpeakers: Set<String> = []
        let speakerContributions = g.speakerContributions.compactMap { item -> AISpeakerContribution? in
            let contribution = clean(item.contribution)
            let lineIndex = item.sourceLineNumber - 1
            guard detectedSpeakers > 1,
                  !contribution.isEmpty,
                  meeting.transcript.indices.contains(lineIndex),
                  evidenceLineIndices.contains(lineIndex)
            else { return nil }

            let sourceLine = meeting.transcript[lineIndex]
            let speaker = SpeakerIdentityResolver.normalizedDisplayName(sourceLine.speaker)
            let key = SpeakerIdentityResolver.canonicalKey(for: speaker)
            let generatedSpeaker = clean(item.speaker)
            guard !generatedSpeaker.isEmpty else { return nil }
            let generatedSpeakerKey = SpeakerIdentityResolver.canonicalKey(for: generatedSpeaker)
            guard generatedSpeakerKey == key else { return nil }
            guard seenSpeakers.insert(key).inserted else { return nil }
            guard let contributionStrength = ClaimEvidenceValidator.matchStrength(
                claim: contribution,
                source: "\(speaker): \(sourceLine.text)"
            ) else { return nil }

            return AISpeakerContribution(
                speaker: speaker,
                contribution: contribution,
                sourceReferences: [SourceReference(
                    meetingID: meeting.id,
                    meetingTitle: meeting.title,
                    kind: .transcript,
                    snippet: sourceLine.text,
                    speaker: speaker,
                    transcriptLineID: sourceLine.id,
                    lineIndex: lineIndex,
                    matchStrength: contributionStrength
                )]
            )
        }

        let generatedActions = deduplicatedActions(
            g.actions
                .compactMap { generated -> AIActionItem? in
                    let task = clean(generated.task)
                    guard !task.isEmpty,
                          let supportingLine = ClaimEvidenceValidator.bestSupportingSource(
                            for: task,
                            sources: sourceEvidenceLines
                          )
                    else { return nil }
                    let owner = supportedActionMetadata(
                        clean(generated.owner),
                        sourceLines: [supportingLine],
                        allowsGenericValues: true
                    )
                    let due = supportedActionMetadata(
                        clean(generated.due),
                        sourceLines: [supportingLine],
                        allowsGenericValues: false
                    )
                    let why = clean(generated.why)
                    return AIActionItem(
                        task: task,
                        owner: owner,
                        due: due,
                        priority: clean(generated.priority).lowercased(),
                        why: isGrounded(why, in: sourceEvidenceLines) ? why : ""
                    )
                }
        )
        let actions = supportedActionCount == 0
            ? []
            : Array(generatedActions.prefix(max(1, supportedActionCount * 2)))
        let decisions = supportedDecisionCount == 0
            ? []
            : Array(groundedStrings(g.decisions.map(clean), in: sourceEvidenceLines).prefix(max(1, supportedDecisionCount * 2)))
        let risks = supportedRiskCount == 0
            ? []
            : Array(groundedStrings(g.risks.map(clean), in: sourceEvidenceLines).prefix(max(1, supportedRiskCount * 2)))
        let generatedSummary = clean(g.summary)
        let trustedSummary: String
        if isGrounded(generatedSummary, in: sourceEvidenceLines) {
            trustedSummary = generatedSummary
        } else {
            let objective = meeting.objective.trimmingCharacters(in: .whitespacesAndNewlines)
            trustedSummary = objective.isEmpty ? (sourceEvidenceLines.first ?? "") : objective
        }

        let generatedTopic = clean(g.captureTopic)
        let trustedTopic = isGrounded(generatedTopic, in: sourceEvidenceLines)
            ? generatedTopic
            : clean(meeting.title)
        let brief = AIBriefData(
            capturePurpose: capturePurpose,
            captureTopic: trustedTopic,
            captureDomain: normalizedDomain(clean(g.captureDomain), for: capturePurpose),
            purposeConfidence: normalizedPurposeConfidence(clean(g.purposeConfidence)),
            summary: trustedSummary,
            decisions: allowsMeetingSignals ? decisions : [],
            actions: allowsAccountability ? actions : [],
            openQuestions: groundedStrings(g.openQuestions.map(clean), in: sourceEvidenceLines),
            keyPoints: groundedStrings(g.keyPoints.map(clean), in: sourceEvidenceLines),
            risks: allowsMeetingSignals ? risks : [],
            whatMatters: Array(groundedStrings(g.whatMatters.map(clean), in: sourceEvidenceLines).prefix(4)),
            speakerContributions: Array(speakerContributions.prefix(6)),
            enhancedNotes: g.enhancedNotes
                .compactMap { generated -> EnhancedNoteData? in
                    let generatedAnchor = clean(generated.anchor)
                    guard let anchor = authoredNoteLines.first(where: {
                        ClaimEvidenceValidator.isExact(generatedAnchor, source: $0)
                    }) else { return nil }
                    let detail = clean(generated.detail)
                    return EnhancedNoteData(
                        anchor: anchor,
                        detail: isGrounded(detail, in: sourceEvidenceLines) ? detail : ""
                    )
                },
            sections: purposeAppropriateSections(
                g.sections,
                purpose: capturePurpose,
                sourceLines: sourceEvidenceLines,
                clean: clean
            ),
            makesSense: true,
            needsClarification: groundedStrings(g.needsClarification.map(clean), in: sourceEvidenceLines)
        )
        return (brief, detected)
    }

    private static func normalizedDomain(
        _ value: String,
        for purpose: CapturePurposeKind
    ) -> String {
        let allowed = ["personal", "work", "health", "education", "legal", "finance", "general"]
        let normalized = value.lowercased()
        if let match = allowed.first(where: { normalized == $0 }) {
            return match.capitalized
        }
        if purpose == .learning { return "Education" }
        return purpose.allowsMeetingSignals ? "Work" : "Personal"
    }

    private static func normalizedPurposeConfidence(_ value: String) -> String {
        switch value.lowercased() {
        case "high", "verified", "certain": return "high"
        case "medium", "strong", "likely": return "medium"
        default: return "low"
        }
    }

    private static func purposeAppropriateSections(
        _ sections: [GeneratedSection],
        purpose: CapturePurposeKind,
        sourceLines: [String],
        clean: (String) -> String
    ) -> [AIBriefSection] {
        let forbiddenPersonalHeadings = [
            "action", "commitment", "decision", "deliverable", "owner", "risk", "blocker"
        ]

        return sections.compactMap { section in
            let heading = clean(section.heading)
            let lowerHeading = heading.lowercased()
            guard !heading.isEmpty else { return nil }
            if !purpose.allowsMeetingSignals,
               forbiddenPersonalHeadings.contains(where: lowerHeading.contains) {
                return nil
            }

            let items = groundedStrings(section.items.map(clean), in: sourceLines)
            guard !items.isEmpty else { return nil }
            return AIBriefSection(heading: heading, items: items)
        }
    }

    private static func deduplicatedStrings(_ values: [String]) -> [String] {
        var accepted: [(text: String, tokens: Set<String>)] = []
        for value in values {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = semanticTokens(in: text)
            guard !text.isEmpty, !tokens.isEmpty else { continue }
            guard !accepted.contains(where: {
                $0.text.caseInsensitiveCompare(text) == .orderedSame
                    || semanticSimilarity($0.tokens, tokens) >= 0.76
            }) else { continue }
            accepted.append((text, tokens))
        }
        return accepted.map { $0.text }
    }

    private static func groundedStrings(_ values: [String], in sourceLines: [String]) -> [String] {
        deduplicatedStrings(values).filter { isGrounded($0, in: sourceLines) }
    }

    private static func isGrounded(_ value: String, in sourceLines: [String]) -> Bool {
        ClaimEvidenceValidator.supports(claim: value, sources: sourceLines)
    }

    private static func supportedActionMetadata(
        _ value: String,
        sourceLines: [String],
        allowsGenericValues: Bool
    ) -> String {
        guard !value.isEmpty else { return "" }
        if allowsGenericValues,
           ["you", "team", "we", "i"].contains(value.lowercased()) {
            return value.lowercased() == "i" ? "You" : value
        }
        return sourceLines.contains(where: { $0.localizedCaseInsensitiveContains(value) }) ? value : ""
    }

    private static func deduplicatedActions(_ values: [AIActionItem]) -> [AIActionItem] {
        var accepted: [(action: AIActionItem, tokens: Set<String>)] = []
        for value in values {
            let tokens = semanticTokens(in: value.task)
            guard !tokens.isEmpty else { continue }
            if let index = accepted.firstIndex(where: { candidate in
                let ownersCompatible = candidate.action.owner.isEmpty
                    || value.owner.isEmpty
                    || candidate.action.owner.caseInsensitiveCompare(value.owner) == .orderedSame
                return ownersCompatible && semanticSimilarity(candidate.tokens, tokens) >= 0.72
            }) {
                var merged = accepted[index].action
                if merged.owner.isEmpty { merged.owner = value.owner }
                if merged.due.isEmpty { merged.due = value.due }
                if merged.priority.isEmpty { merged.priority = value.priority }
                if merged.why.isEmpty { merged.why = value.why }
                if value.task.count > merged.task.count { merged.task = value.task }
                accepted[index] = (merged, semanticTokens(in: merged.task))
            } else {
                accepted.append((value, tokens))
            }
        }
        return accepted.map { $0.action }
    }

    private static func semanticTokens(in text: String) -> Set<String> {
        let ignored = Set([
            "the", "and", "for", "with", "from", "that", "this", "then", "will",
            "should", "could", "would", "please", "need", "needs", "task", "action"
        ])
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !ignored.contains($0) }
        return Set(tokens)
    }

    private static func semanticSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private static func selectedTranscriptEvidence(
        from lines: [TranscriptLine],
        limit: Int
    ) -> [(Int, TranscriptLine)] {
        guard limit > 1 else { return lines.first.map { [(0, $0)] } ?? [] }
        guard lines.count > limit else {
            return lines.enumerated().map { ($0.offset, $0.element) }
        }

        var selectedIndices: Set<Int> = []
        var representedSpeakers: Set<String> = []
        for (index, line) in lines.enumerated() {
            let key = SpeakerIdentityResolver.canonicalKey(for: line.speaker)
            if representedSpeakers.insert(key).inserted {
                selectedIndices.insert(index)
            }
            if selectedIndices.count == limit { break }
        }

        let cues = [
            "decided", "decision", "will", "owner", "deadline", "due",
            "next step", "risk", "blocker", "question", "agreed", "need"
        ]
        let signalIndices = lines.indices.sorted { left, right in
            let leftText = lines[left].text.lowercased()
            let rightText = lines[right].text.lowercased()
            let leftScore = cues.reduce(0) { $0 + (leftText.contains($1) ? 1 : 0) }
            let rightScore = cues.reduce(0) { $0 + (rightText.contains($1) ? 1 : 0) }
            if leftScore == rightScore { return left < right }
            return leftScore > rightScore
        }
        for index in signalIndices where selectedIndices.count < max(2, limit / 2) {
            selectedIndices.insert(index)
        }

        let spacing = Double(lines.count - 1) / Double(limit - 1)
        for slot in 0..<limit where selectedIndices.count < limit {
            selectedIndices.insert(Int((Double(slot) * spacing).rounded()))
        }

        for index in lines.indices.reversed() where selectedIndices.count < limit {
            selectedIndices.insert(index)
        }

        return selectedIndices.sorted().prefix(limit).map { ($0, lines[$0]) }
    }

    private static func bounded(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let half = maxCharacters / 2
        return "\(text.prefix(half))\n[earlier/later context omitted]\n\(text.suffix(half))"
    }
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedGroundedWorkspaceBullet {
    @Guide(description: "One concise claim that directly answers the user's question using only the supplied source excerpts.")
    var text: String
    @Guide(description: "One or more exact source IDs from the supplied evidence, such as S1 or S3. Never create an ID.")
    var sourceIDs: [String]
}

@available(iOS 26.0, *)
@Generable
private struct GeneratedGroundedWorkspaceAnswer {
    @Guide(description: "A concise ordered set of non-duplicated, source-supported answer bullets. Return an empty array when the evidence cannot answer the question.")
    var bullets: [GeneratedGroundedWorkspaceBullet]
}

@available(iOS 26.0, *)
private enum WorkspaceGroundingError: Error {
    case noSupportedClaims
}

@available(iOS 26.0, *)
private enum AppleIntelligenceWorkspaceAssistant {
    static func answer(
        sources: [RAGResult],
        prompt: String,
        modelSelection: ChatModelSelection
    ) async throws -> WorkspaceAnswer {
        let styleInstruction: String
        switch modelSelection {
        case .auto:
            styleInstruction = "Default to concise answers, but expand only when the task requires cross-meeting analysis."
        case .fast:
            styleInstruction = "Keep the answer short and execution-focused."
        case .deep:
            styleInstruction = "Provide deeper cross-meeting analysis and tradeoffs while staying concise."
        }

        let session = LanguageModelSession(instructions: """
        You are a precise workspace meeting assistant inside a professional note-taking app.
        Answer using only the source excerpts provided.
        Be concise, structured, and practical.
        Surface patterns, decisions, action items, blockers, and useful prep notes when relevant.
        Every answer bullet must cite one or more exact source IDs supplied with the excerpts.
        Omit any claim that the excerpts do not directly support.
        Do not treat a generated summary or prior answer as evidence.
        \(styleInstruction)
        Do not invent facts, source IDs, owners, dates, decisions, or causal relationships.
        """)

        let context = sources.map { source in
            """
            \(source.sourceID)
            Meeting: \(source.meetingTitle)
            Source: \(source.sourceLabel)
            Excerpt: \(source.snippet)
            """
        }.joined(separator: "\n\n---\n\n")

        let request = """
        Allowed evidence:
        \(context)

        User question:
        \(prompt)
        """

        let response = try await session.respond(
            to: request,
            generating: GeneratedGroundedWorkspaceAnswer.self
        )
        let allowedIDs = Set(sources.map(\.sourceID))
        var usedIDs: Set<String> = []
        var seenClaims: [Set<String>] = []
        let maximumBullets = modelSelection == .deep ? 8 : 5
        var rendered: [String] = []

        for bullet in response.content.bullets {
            guard rendered.count < maximumBullets else { break }
            let text = bullet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceIDs = bullet.sourceIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { allowedIDs.contains($0) }
            guard !text.isEmpty, !sourceIDs.isEmpty else { continue }
            let citedSnippets = sources
                .filter { sourceIDs.contains($0.sourceID) }
                .map(\.snippet)
            guard ClaimEvidenceValidator.supports(claim: text, sources: citedSnippets) else {
                continue
            }

            let tokens = semanticTokens(in: text)
            guard !tokens.isEmpty else { continue }
            guard !seenClaims.contains(where: { semanticSimilarity(tokens, $0) >= 0.78 }) else {
                continue
            }
            seenClaims.append(tokens)
            usedIDs.formUnion(sourceIDs)
            rendered.append("- \(text) [source: \(sourceIDs.joined(separator: ", "))]")
        }

        guard !rendered.isEmpty else { throw WorkspaceGroundingError.noSupportedClaims }
        let usedSources = sources.filter { usedIDs.contains($0.sourceID) }
        guard !usedSources.isEmpty else { throw WorkspaceGroundingError.noSupportedClaims }
        return WorkspaceAnswer(text: rendered.joined(separator: "\n"), citations: usedSources)
    }

    private static func semanticTokens(in text: String) -> Set<String> {
        Set(LocalRAG.tokenize(text))
    }

    private static func semanticSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }
}
#endif
