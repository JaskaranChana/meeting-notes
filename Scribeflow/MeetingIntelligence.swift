import Foundation
import Security

struct SpeakerSegment: Identifiable, Equatable {
    var id: String { speaker }
    let speaker: String
    let role: String
    let lineCount: Int
    let wordCount: Int
    let talkShare: Double
    let sample: String
}

enum SpeakerDetectionMethod: String, Equatable {
    case diarized
    case partiallyDiarized
    case labeledTranscript
    case mixedTrack
    case singleTrack
    case none
}

struct SpeakerDetectionSummary: Equatable {
    let detectedCount: Int
    let expectedCount: Int
    let method: SpeakerDetectionMethod
    let title: String
    let detail: String

    var badge: String {
        switch method {
        case .diarized: "Diarized"
        case .partiallyDiarized: "Mixed sources"
        case .labeledTranscript: "Labeled"
        case .mixedTrack: "Mixed audio"
        case .singleTrack: "Single track"
        case .none: "No audio"
        }
    }
}

enum SpeakerIdentityResolver {
    private static let genericPrefixes = ["speaker", "spk", "person", "participant", "voice"]
    private static let unknownLabels: Set<String> = [
        "", "unknown", "unidentified", "none", "null", "n/a", "na"
    ]

    static func normalizedDisplayName(_ rawValue: String) -> String {
        let cleaned = rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()

        guard !unknownLabels.contains(lower) else { return "Speaker 1" }
        if lower.allSatisfy(\.isNumber), let value = Int(lower) {
            return "Speaker \(value + 1)"
        }

        let parts = lower.split(separator: " ").map(String.init)
        if let prefix = parts.first,
           genericPrefixes.contains(prefix) {
            guard parts.count > 1 else { return "Speaker 1" }
            let token = parts[1]
            if let value = Int(token) {
                let isZeroBased = value == 0 || token.hasPrefix("0")
                return "Speaker \(isZeroBased ? value + 1 : value)"
            }
            if token.count == 1,
               let scalar = token.uppercased().unicodeScalars.first,
               (65...90).contains(Int(scalar.value)) {
                return "Speaker \(Int(scalar.value) - 64)"
            }
        }

        return cleaned
    }

    static func canonicalKey(for rawValue: String) -> String {
        normalizedDisplayName(rawValue)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    static func normalizedSegments(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var normalized = segment
            normalized.speaker = normalizedDisplayName(segment.speaker)
            normalized.text = text
            return normalized
        }
    }
}

struct ExtractedActionItem: Identifiable, Equatable {
    var id: String { "\(text)-\(owner)-\(dueHint ?? "")-\(sourceSpeaker)" }
    let text: String
    let owner: String
    let dueHint: String?
    let sourceSpeaker: String
}

enum MeetingIntelligenceMode: String, Equatable {
    case localHeuristic
    case backendReady

    var title: String {
        switch self {
        case .localHeuristic:
            "Local intelligence"
        case .backendReady:
            "Production transcription"
        }
    }

    var detail: String {
        switch self {
        case .localHeuristic:
            "Runs on saved notes and transcripts without uploading data."
        case .backendReady:
            "Uses the configured transcription service while note intelligence remains source-backed."
        }
    }
}

struct MeetingIntelligenceReport: Equatable {
    let headline: String
    let suggestedSummary: [String]
    let decisions: [String]
    let actionItems: [String]
    let structuredActionItems: [ExtractedActionItem]
    let openQuestions: [String]
    let followUps: [String]
    let speakerSegments: [SpeakerSegment]
    let speakerDetection: SpeakerDetectionSummary
    let confidenceLabel: String
    let mode: MeetingIntelligenceMode
    let speakerDetectionNote: String
}

enum SpeakerTranscriptParser {
    private static let structuralLabels: Set<String> = [
        "action", "action item", "actions", "agenda", "blocker", "blockers",
        "concern", "concerns", "context", "decision", "decisions", "done",
        "due", "goal", "idea", "ideas", "in progress", "key point",
        "next step", "note", "notes", "objective", "open question", "owner",
        "progress", "question", "risk", "risks", "summary", "takeaway",
        "takeaways", "task", "tasks", "todo"
    ]

    static func lines(from transcript: String, defaultSpeaker: String, defaultRole: String) -> [TranscriptLine] {
        let rawLines = transcript
            .components(separatedBy: .newlines)
            .flatMap(splitLongParagraph)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let parsed = rawLines.flatMap { line -> [TranscriptLine] in
            if let speakerLine = parseSpeakerLine(line, defaultRole: defaultRole) {
                return [speakerLine]
            }

            return splitSentences(line).map {
                TranscriptLine(
                    speaker: SpeakerIdentityResolver.normalizedDisplayName(defaultSpeaker),
                    role: defaultRole,
                    text: $0
                )
            }
        }

        return Array(parsed.prefix(60))
    }

    private static func parseSpeakerLine(_ line: String, defaultRole: String) -> TranscriptLine? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }

        let speaker = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard speaker.count >= 2, speaker.count <= 32, body.count > 4 else { return nil }
        guard speaker.rangeOfCharacter(from: .letters) != nil else { return nil }
        guard !structuralLabels.contains(speaker.lowercased()) else { return nil }

        return TranscriptLine(
            speaker: SpeakerIdentityResolver.normalizedDisplayName(speaker),
            role: defaultRole,
            text: body
        )
    }

    private static func splitLongParagraph(_ paragraph: String) -> [String] {
        if paragraph.contains(":") {
            return paragraph
                .replacingOccurrences(
                    of: #"(?<=[.!?])\s+(?=[A-Z][A-Za-z .'-]{1,31}:)"#,
                    with: "\n",
                    options: .regularExpression
                )
                .components(separatedBy: .newlines)
        }
        return splitSentences(paragraph)
    }

    private static func splitSentences(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 4 }
    }
}

enum MeetingIntelligenceEngine {
    static func report(for meeting: Meeting) -> MeetingIntelligenceReport {
        let source = sourceLines(for: meeting)
        let corpus = source.map(\.text)
        let allowsMeetingSignals = meeting.allowsMeetingSignalExtraction
        let decisions = allowsMeetingSignals
            ? extract(from: corpus, keywords: decisionCues, limit: 4, transform: distilledDecision)
            : []
        let structuredActions = meeting.allowsAccountabilityExtraction
            ? extractStructuredActions(from: source, attendees: meeting.attendees, limit: 5)
            : []
        // One definition of "an action": the strict, distilled structured set.
        let actions = structuredActions.map(\.text)
        let questions = extractQuestions(from: corpus, limit: 4)
        let followUps = meeting.allowsAccountabilityExtraction
            ? followUps(from: actions, structuredActions: structuredActions, questions: questions, decisions: decisions)
            : []
        let summary = summary(from: meeting, corpus: corpus, decisions: decisions, structuredActions: structuredActions)
        let speakers = speakerSegments(for: meeting)
        let speakerDetection = speakerDetectionSummary(for: meeting, speakers: speakers)
        let usedBackend = meeting.audioRecordings.contains { $0.transcriptionProvider == .backend }

        return MeetingIntelligenceReport(
            headline: headline(for: meeting, decisions: decisions, actions: actions, questions: questions),
            suggestedSummary: summary,
            decisions: decisions,
            actionItems: actions,
            structuredActionItems: structuredActions,
            openQuestions: questions,
            followUps: followUps,
            speakerSegments: speakers,
            speakerDetection: speakerDetection,
            confidenceLabel: confidenceLabel(corpusCount: corpus.count, speakerCount: speakers.count),
            mode: usedBackend ? .backendReady : .localHeuristic,
            speakerDetectionNote: speakerDetection.detail
        )
    }

    /// Text-derived action items (with owner/due/source) for a meeting — the
    /// single source of truth so persisted commitments match the live read.
    static func structuredActions(for meeting: Meeting, limit: Int = 6) -> [ExtractedActionItem] {
        guard meeting.allowsAccountabilityExtraction else { return [] }
        return extractStructuredActions(from: sourceLines(for: meeting), attendees: meeting.attendees, limit: limit)
    }

    /// Decisions detected in a meeting's notes/transcript.
    static func decisions(for meeting: Meeting, limit: Int = 4) -> [String] {
        guard meeting.allowsMeetingSignalExtraction else { return [] }
        return extract(from: sourceLines(for: meeting).map(\.text), keywords: decisionCues, limit: limit, transform: distilledDecision)
    }

    /// Open/unresolved questions raised in the notes or transcript — the
    /// "what still needs an answer" every meeting template surfaces. Lines that
    /// are really action items ("need to clarify X") are excluded so they show
    /// once, under Actions, instead of in both places.
    static func openQuestions(for meeting: Meeting, limit: Int = 4) -> [String] {
        let lines = sourceLines(for: meeting).map(\.text).filter {
            !meeting.allowsAccountabilityExtraction || !looksActionable($0)
        }
        return extractQuestions(from: lines, limit: limit)
    }

    /// Whether a raw line is a commitment/task — used to keep action lines from
    /// also surfacing as "risks" just because they share a keyword.
    static func isActionableLine(_ line: String) -> Bool {
        looksActionable(line)
    }

    /// Substantive discussion points distilled from the notes/transcript — the
    /// lines that carry meeting content but aren't decisions, actions, or
    /// questions (those are surfaced separately). Cleaned, deduped, ranked by
    /// signal. Empty for content-free input, so nothing is invented.
    static func keyPoints(for meeting: Meeting, limit: Int = 5) -> [String] {
        let source = sourceLines(for: meeting)
        let focusTokens = focusTokens(for: meeting)
        var seen: Set<String> = []
        var scored: [(text: String, score: Int)] = []
        for line in source {
            let raw = line.text
            let lower = raw.lowercased()
            // Skip what's already surfaced elsewhere.
            if meeting.allowsAccountabilityExtraction, looksActionable(raw) { continue }
            if meeting.allowsMeetingSignalExtraction,
               decisionCues.contains(where: lower.contains) { continue }
            if raw.contains("?") { continue }

            let point = polished(raw)
            guard !point.isEmpty, hasSubstance(point) else { continue }
            let key = fingerprint(point)
            guard seen.insert(key).inserted else { continue }
            scored.append((point, focusedScore(raw, focusTokens: focusTokens)))
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.text)
    }

    /// True when a line carries real words — at least two letter-runs of 3+
    /// characters — so symbol/number noise ("12345 !!!") isn't a "key point".
    private static func hasSubstance(_ text: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 }.count >= 2
    }

    /// Distilled action text for a single line, or nil if it isn't a real action.
    /// Used by the live copilot, which classifies spoken paragraphs one at a time.
    static func actionItem(from line: String) -> String? {
        guard looksActionable(line) else { return nil }
        let text = distilledAction(line)
        return isTaskLike(text) ? text : nil
    }

    /// Distilled decision text for a single line, or nil if it isn't a decision.
    static func decision(from line: String) -> String? {
        let lower = line.lowercased()
        guard decisionCues.contains(where: lower.contains) else { return nil }
        let text = distilledDecision(line)
        return text.count >= 3 ? text : nil
    }

    private struct IntelligenceSourceLine {
        let text: String
        let speaker: String?
    }

    private static func sourceLines(for meeting: Meeting) -> [IntelligenceSourceLine] {
        let noteLines = meeting.rawNotes
            .components(separatedBy: .newlines)
            .map(cleanLine)
            .filter { !$0.isEmpty }
            .map { IntelligenceSourceLine(text: $0, speaker: nil) }
        let transcriptLines = meeting.transcript.map {
            IntelligenceSourceLine(text: "\($0.speaker): \($0.text)", speaker: $0.speaker)
        }
        let recordingLines = meeting.audioRecordings.flatMap { recording in
            [recording.linkedNote, recording.transcript]
                .flatMap { $0.components(separatedBy: .newlines) }
                .map(cleanLine)
                .filter { !$0.isEmpty }
                .map { IntelligenceSourceLine(text: $0, speaker: recording.source.title) }
        }
        return noteLines + transcriptLines + recordingLines
    }

    private static func extract(
        from corpus: [String],
        keywords: [String],
        limit: Int,
        transform: (String) -> String = polished
    ) -> [String] {
        var seen: Set<String> = []
        var results: [String] = []

        for line in corpus {
            let lower = line.lowercased()
            guard keywords.contains(where: lower.contains) else { continue }
            let distilled = transform(line)
            let key = fingerprint(distilled)
            guard !distilled.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(distilled)
        }

        return Array(results.prefix(limit))
    }

    private static func extractQuestions(from corpus: [String], limit: Int) -> [String] {
        var seen: Set<String> = []
        var results: [String] = []

        for line in corpus {
            let lower = line.lowercased()
            let looksLikeQuestion = line.contains("?")
                || lower.contains("clarify")
                || lower.contains("question")
                || lower.contains("open item")
                || lower.contains("need to know")
                || lower.contains("not sure")
            guard looksLikeQuestion else { continue }
            // Skip rhetorical meeting-closers — they aren't open questions.
            guard !isClosingQuestion(lower) else { continue }

            var polished = polished(line)
            if !polished.hasSuffix("?"), lower.contains("clarify") || lower.contains("question") {
                polished = polished.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "?"
            }

            let key = fingerprint(polished)
            guard !polished.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(polished)
        }

        return Array(results.prefix(limit))
    }

    /// Cues that signal a decision was made.
    static let decisionCues = [
        "decided", "decision", "we agreed", "agreed to", "approved",
        "greenlit", "go with", "going with", "go ahead with", "locked in",
        "final call", "chose", "settled on", "moving forward with", "we will go"
    ]

    /// A line is a real action only if it carries a commitment signal: an owner
    /// marker ("owner: Dana"), a commitment preamble ("I'll", "we need to",
    /// "Maya will", "action item:"), or an imperative opening ("Send the deck").
    /// Lines that merely mention a cue word — "the security review is mandatory",
    /// "the launch went well" — are statements, not tasks, and are excluded.
    private static func looksActionable(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard !lower.hasSuffix("?") else { return false }
        if explicitOwner(in: line) != nil { return true }
        if leadingNamedOwner(in: line) != nil { return true }
        let body = strippedSpeaker(cleanLine(line))
        if earliestPreambleEnd(in: body, preambles: actionPreambles) != nil { return true }
        return opensWithImperative(body)
    }

    /// Base-form verbs that, when a line opens with one, signal an imperative task.
    private static let imperativeVerbs: Set<String> = [
        "send", "share", "schedule", "book", "review", "prepare", "draft", "assign",
        "deliver", "set", "follow", "circle", "reach", "create", "update", "fix",
        "ship", "email", "call", "confirm", "sync", "finalize", "write", "build",
        "test", "add", "remove", "check", "plan", "organize", "define", "document",
        "publish", "deploy", "migrate", "audit", "validate", "investigate", "loop",
        "pull", "push", "merge", "file", "submit", "approve", "compile", "collect"
    ]

    /// Linking verbs that turn a verb-first line into a *statement* about a thing
    /// ("Review is mandatory") rather than an instruction ("Review the deck").
    private static let linkingVerbs: Set<String> = ["is", "are", "was", "were", "has", "have", "will", "would"]

    private static func opensWithImperative(_ text: String) -> Bool {
        let words = text.split(separator: " ").map { $0.lowercased() }
        guard let first = words.first else { return false }
        let firstClean = first.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard imperativeVerbs.contains(firstClean) else { return false }
        if words.count >= 2, linkingVerbs.contains(words[1]) { return false }
        return true
    }

    /// Verbs that describe a state or feeling, not a thing to do. A distilled
    /// item opening with one isn't a task — "it has to feel lightweight" should
    /// not become the action "Feel lightweight."
    private static let nonActionOpeners: Set<String> = [
        "feel", "feels", "be", "is", "are", "was", "were", "seem", "seems",
        "look", "looks", "sound", "sounds", "become", "becomes", "stay", "stays",
        "remain", "remains", "want", "wants", "like", "likes", "love", "loves",
        "know", "knows", "think", "thinks", "hope", "hopes", "believe", "prefer",
        "matter", "matters", "exist", "depend", "depends", "tolerate"
    ]

    /// Final gate on a distilled action: long enough, and not a stative phrase.
    private static func isTaskLike(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard let first = words.first, text.count >= 3 else { return false }
        let firstClean = first.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        return !nonActionOpeners.contains(firstClean)
    }

    private static func extractStructuredActions(
        from source: [IntelligenceSourceLine],
        attendees: [String],
        limit: Int
    ) -> [ExtractedActionItem] {
        var seen: Set<String> = []
        var results: [ExtractedActionItem] = []

        for line in source {
            guard looksActionable(line.text) else { continue }

            let text = distilledAction(line.text)
            // Reject distillations that collapsed to a stative phrase ("Feel
            // lightweight") — they read as tasks but aren't.
            guard isTaskLike(text) else { continue }
            let key = fingerprint(text)
            guard !text.isEmpty, !seen.contains(key) else { continue }

            seen.insert(key)
            results.append(
                ExtractedActionItem(
                    text: text,
                    owner: ownerHint(in: line.text, attendees: attendees),
                    dueHint: dueHint(in: line.text),
                    sourceSpeaker: line.speaker ?? speakerPrefix(in: line.text) ?? "Meeting"
                )
            )

            if results.count == limit { break }
        }

        return results
    }

    private static func followUps(
        from actions: [String],
        structuredActions: [ExtractedActionItem],
        questions: [String],
        decisions: [String]
    ) -> [String] {
        var followUps: [String] = []
        if let action = structuredActions.first {
            let owner = action.owner == "Owner not named" ? "an owner" : action.owner
            let timing = action.dueHint.map { " by \($0)" } ?? ""
            followUps.append("Confirm \(owner)\(timing) for: \(lowerFirst(action.text))")
        } else if let action = actions.first {
            followUps.append("Confirm owner and timing for: \(lowerFirst(action))")
        }
        if let question = questions.first {
            followUps.append("Resolve open question: \(lowerFirst(question))")
        }
        if let decision = decisions.first {
            followUps.append("Send recap around the decision: \(lowerFirst(decision))")
        }
        if followUps.isEmpty {
            followUps.append("Add one explicit next step before sharing this note.")
        }
        return Array(followUps.prefix(3))
    }

    private static func summary(
        from meeting: Meeting,
        corpus: [String],
        decisions: [String],
        structuredActions: [ExtractedActionItem]
    ) -> [String] {
        var bullets: [String] = []
        var used: Set<String> = []

        if meeting.allowsMeetingSignalExtraction {
            // Lead with the outcome and the next move. These are the two facts a
            // reader most often needs when reopening a meeting note.
            if let decision = decisions.first {
                bullets.append("Outcome: \(lowerFirst(decision))")
                used.insert(fingerprint(decision))
            }
            if let action = structuredActions.first {
                bullets.append("Next move: \(commitmentSentence(action))")
                used.insert(fingerprint(action.text))
            }
        }

        // Fill with lines that match the objective, chosen note template, and
        // meeting lens before falling back to generic signal strength.
        let focusTokens = focusTokens(for: meeting)
        let ranked = corpus
            .filter { $0.count > 18 }
            .sorted { focusedScore($0, focusTokens: focusTokens) > focusedScore($1, focusTokens: focusTokens) }

        for line in ranked {
            let clause = polished(line)
            let key = fingerprint(clause)
            guard !clause.isEmpty, !used.contains(key) else { continue }
            used.insert(key)
            bullets.append(meeting.isPersonalCapture ? clause : "What matters: \(lowerFirst(clause))")
            if bullets.count == 4 { break }
        }

        if bullets.isEmpty {
            bullets.append(meeting.objective.isEmpty ? "Capture more detail to generate a stronger brief." : meeting.objective)
        }
        return bullets
    }

    /// "Maya — send the deck (by Friday)" — owner + task + due, only when known.
    static func commitmentSentence(_ action: ExtractedActionItem) -> String {
        let core = action.text.hasSuffix(".") ? String(action.text.dropLast()) : action.text
        let due = action.dueHint.map { " (by \(displayDue($0)))" } ?? ""
        if action.owner != "Owner not named", !action.owner.isEmpty {
            return "\(action.owner) — \(lowerFirst(core))\(due)"
        }
        return "\(core)\(due)"
    }

    /// Capitalize/expand a raw due marker for display (model keeps the raw form).
    static func displayDue(_ hint: String) -> String {
        switch hint.lowercased() {
        case "eow": return "end of week"
        case "eod": return "end of day"
        case "q1", "q2", "q3", "q4": return hint.uppercased()
        case "today", "tomorrow", "this week", "next week", "end of week", "month":
            return hint
        default:
            return hint.prefix(1).uppercased() + hint.dropFirst()
        }
    }

    private static func speakerSegments(for meeting: Meeting) -> [SpeakerSegment] {
        let grouped = Dictionary(grouping: meeting.transcript) {
            SpeakerIdentityResolver.canonicalKey(for: $0.speaker)
        }
        let totalWords = max(1, meeting.transcript.reduce(0) { partial, line in
            partial + line.text.split(whereSeparator: \.isWhitespace).count
        })
        return grouped
            .compactMap { _, lines -> SpeakerSegment? in
                guard let first = lines.first else { return nil }
                let speaker = SpeakerIdentityResolver.normalizedDisplayName(first.speaker)
                let wordCount = lines.reduce(0) { partial, line in
                    partial + line.text.split(whereSeparator: \.isWhitespace).count
                }
                let sample = lines.max { lhs, rhs in
                    score(lhs.text) < score(rhs.text)
                }?.text ?? first.text
                return SpeakerSegment(
                    speaker: speaker,
                    role: first.role.isEmpty ? "Speaker" : first.role,
                    lineCount: lines.count,
                    wordCount: wordCount,
                    talkShare: Double(wordCount) / Double(totalWords),
                    sample: sample
                )
            }
            .sorted { lhs, rhs in
                if lhs.lineCount == rhs.lineCount { return lhs.speaker < rhs.speaker }
                return lhs.lineCount > rhs.lineCount
            }
    }

    private static func headline(
        for meeting: Meeting,
        decisions: [String],
        actions: [String],
        questions: [String]
    ) -> String {
        if !meeting.allowsMeetingSignalExtraction {
            let modelSummary = meeting.aiBrief?.summary
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !modelSummary.isEmpty { return modelSummary }
            if let topic = meeting.purpose.topic {
                return "\(meeting.purpose.displayTitle): \(lowerFirst(topic))"
            }
            return "Organized as \(meeting.purpose.displayTitle.lowercased())."
        }
        if let decision = decisions.first {
            return "Decision captured: \(lowerFirst(decision))"
        }
        if let action = actions.first {
            return "Follow-through needed: \(lowerFirst(action))"
        }
        if let question = questions.first {
            return "Open question: \(lowerFirst(question))"
        }
        return meeting.objective.isEmpty ? "Ready for review." : meeting.objective
    }

    private static func confidenceLabel(corpusCount: Int, speakerCount: Int) -> String {
        if corpusCount >= 10 && speakerCount > 1 { return "Strong local read" }
        if corpusCount >= 5 { return "Good local read" }
        return "Needs more context"
    }

    private static func speakerDetectionSummary(
        for meeting: Meeting,
        speakers: [SpeakerSegment]
    ) -> SpeakerDetectionSummary {
        let expectedPeople = Set(meeting.attendees.compactMap { attendee -> String? in
            let cleaned = attendee.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return cleaned.lowercased()
        }).count
        let detected = speakers.count
        let speakerKeys = Set(speakers.map { SpeakerIdentityResolver.canonicalKey(for: $0.speaker) })
        let diarizedSpeakerKeys = Set(
            meeting.audioRecordings
                .filter { $0.diarizationAvailable }
                .flatMap { $0.transcriptionSegments }
                .map { SpeakerIdentityResolver.canonicalKey(for: $0.speaker) }
                .filter { !$0.isEmpty }
        )

        if detected == 0 {
            return SpeakerDetectionSummary(
                detectedCount: 0,
                expectedCount: expectedPeople,
                method: .none,
                title: "No voices identified",
                detail: expectedPeople > 0
                    ? "\(expectedPeople) people are listed, but there is no speaker-labeled transcript yet."
                    : "Add a transcript to identify and review speakers."
            )
        }

        if !diarizedSpeakerKeys.isEmpty, diarizedSpeakerKeys == speakerKeys {
            return SpeakerDetectionSummary(
                detectedCount: detected,
                expectedCount: expectedPeople,
                method: .diarized,
                title: "\(detected) voice\(detected == 1 ? "" : "s") separated",
                detail: "The transcription provider separated the audio by voice. Review names before sharing."
            )
        }

        if !diarizedSpeakerKeys.isEmpty {
            return SpeakerDetectionSummary(
                detectedCount: detected,
                expectedCount: expectedPeople,
                method: .partiallyDiarized,
                title: "\(detected) labels · \(diarizedSpeakerKeys.count) diarized",
                detail: "Some voices came from provider diarization and others came from saved transcript labels. Review the combined speaker list before sharing."
            )
        }

        if detected > 1 {
            return SpeakerDetectionSummary(
                detectedCount: detected,
                expectedCount: expectedPeople,
                method: .labeledTranscript,
                title: "\(detected) labeled speakers",
                detail: "Counted from transcript labels and any names you corrected. The app did not infer identities from voiceprints."
            )
        }

        if expectedPeople > 1 {
            return SpeakerDetectionSummary(
                detectedCount: detected,
                expectedCount: expectedPeople,
                method: .mixedTrack,
                title: "1 mixed speaker track",
                detail: "\(expectedPeople) people are listed, but this transcript has one shared label. Enable a diarization-capable provider or split labels manually."
            )
        }

        return SpeakerDetectionSummary(
            detectedCount: 0,
            expectedCount: expectedPeople,
            method: .singleTrack,
            title: "Speaker separation not available",
            detail: "The transcript has one shared label, not a confirmed person count. Run on-device speaker analysis or label turns during review."
        )
    }

    private static func focusTokens(for meeting: Meeting) -> Set<String> {
        let focusText = [
            meeting.objective,
            meeting.contextMode.aiHint,
            meeting.selectedTemplate.description
        ].joined(separator: " ")
        return Set(
            focusText.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 }
        )
    }

    private static func focusedScore(_ line: String, focusTokens: Set<String>) -> Int {
        let lower = line.lowercased()
        let matches = focusTokens.reduce(0) { $0 + (lower.contains($1) ? 2 : 0) }
        return score(line) + min(matches, 10)
    }

    private static func score(_ line: String) -> Int {
        let lower = line.lowercased()
        let weighted = [
            "decision": 6, "agreed": 6, "next": 5, "owner": 5, "follow": 5,
            "risk": 4, "question": 4, "timeline": 4, "launch": 3, "budget": 3
        ]
        return weighted.reduce(max(1, line.count / 70)) { score, item in
            lower.contains(item.key) ? score + item.value : score
        }
    }

    private static func polished(_ line: String) -> String {
        let cleaned = cleanLine(line)
        let parts = cleaned.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let body = parts.count == 2 && parts[0].count <= 32 ? String(parts[1]) : cleaned
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let first = trimmed.prefix(1).uppercased() + String(trimmed.dropFirst())
        return first.hasSuffix(".") || first.hasSuffix("?") ? String(first) : "\(first)."
    }

    private static func cleanLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "•", with: "")
            .replacingOccurrences(of: "- ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }

    // MARK: - Distillation
    //
    // Raw spoken/typed lines are conversational: "so yeah I think I'll probably
    // send the deck over by Friday." A useful action item is the imperative core:
    // "Send the deck over by Friday." We cut the commitment preamble, drop leading
    // filler, and keep the first clause — owner and due are captured separately.

    /// Preambles that introduce a commitment. We keep the verb that follows.
    private static let actionPreambles: [String] = [
        "i am going to", "i'm going to", "we are going to", "we're going to",
        "is going to", "are going to", "going to", "gonna",
        "i need to", "we need to", "you need to", "they need to", "need to", "needs to", "needed to",
        "i have to", "we have to", "have to", "has to", "had to",
        "i want to", "we want to", "want to",
        "i should", "we should", "you should", "should",
        "i'll", "we'll", "you'll", "they'll", "he'll", "she'll",
        "i will", "we will", "you will", "they will", "he will", "she will", "will",
        "let's", "let me",
        "action items:", "action item:", "action:", "to-do:", "to do:", "todo:",
        "next steps:", "next step:", "follow up on", "follow up with", "follow-up on",
        "follow up", "follow-up", "circle back on", "circle back",
        "responsible for", "in charge of", "must"
    ]

    /// Preambles that introduce a decision. We keep the outcome that follows.
    private static let decisionPreambles: [String] = [
        "we have decided to", "we've decided to", "we decided to", "i decided to",
        "decided to", "we agreed to", "we agreed that", "we agreed", "agreed to", "agreed that",
        "we are going with", "we're going with", "going with", "go ahead with", "go with",
        "we will go with", "we'll go with", "moving forward with",
        "we settled on", "settled on", "we chose to", "chose to", "we chose",
        "approved", "greenlit", "locked in on", "locked in",
        "final call:", "decision:"
    ]

    /// Single-word discourse filler stripped from the front of a distilled item.
    private static let leadingFillers: Set<String> = [
        "so", "um", "uh", "okay", "ok", "well", "yeah", "yep", "right", "now",
        "basically", "actually", "literally", "honestly", "just", "really",
        "maybe", "probably", "like", "then", "and", "but", "also"
    ]

    /// Multi-word filler phrases stripped from the front (checked before words).
    private static let leadingFillerPhrases: [String] = [
        "i think", "i guess", "i mean", "you know", "kind of", "sort of", "let's see"
    ]

    private static func distilledAction(_ raw: String) -> String {
        distill(raw, preambles: actionPreambles, stripOwnerMarker: true)
    }

    private static func distilledDecision(_ raw: String) -> String {
        distill(raw, preambles: decisionPreambles, stripOwnerMarker: false)
    }

    private static func distill(_ raw: String, preambles: [String], stripOwnerMarker: Bool) -> String {
        var text = strippedSpeaker(cleanLine(raw))

        if stripOwnerMarker {
            // "owner: Dana — confirm the seat count" → "confirm the seat count".
            text = text.replacingOccurrences(
                of: #"(?i)^\s*owner\b\s*[:\-–]\s*[A-Za-z][A-Za-z '.]{0,30}?\s*[—–-]\s*"#,
                with: "",
                options: .regularExpression
            )
            // "Maya to book …" / "Dana will send …" → drop the leading name and
            // connector, keeping the verb (the name is captured as owner).
            text = text.replacingOccurrences(
                of: #"^[A-Z][a-z]{1,20}\s+(?:will|to|should|owns|leads|takes|is going to)\s+"#,
                with: "",
                options: .regularExpression
            )
        }

        if let end = earliestPreambleEnd(in: text, preambles: preambles) {
            text = String(text[end...])
        }

        text = strippedLeadingFiller(text)
        text = firstClause(text)
        // The due date is captured separately (dueHint) and shown as its own
        // chip, so drop a trailing "by Friday" / "next week" from the task text.
        if stripOwnerMarker { text = strippedTrailingDue(text) }

        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—.").union(.whitespacesAndNewlines))
        // If distilling over-trimmed (e.g. a name-only "Sam will."), keep the
        // original polished line rather than emit something meaningless.
        guard trimmed.count >= 3 else { return polished(raw) }

        let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        if capitalized.hasSuffix(".") || capitalized.hasSuffix("?") || capitalized.hasSuffix("!") {
            return String(capitalized)
        }
        return "\(capitalized)."
    }

    /// Drop a transcript "Speaker: …" prefix, keeping just the spoken text.
    private static func strippedSpeaker(_ line: String) -> String {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].count <= 32,
              parts[0].rangeOfCharacter(from: .decimalDigits) == nil else { return line }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    /// Index just past the earliest word-bounded preamble match, if any.
    private static func earliestPreambleEnd(in text: String, preambles: [String]) -> String.Index? {
        var best: Range<String.Index>?
        for preamble in preambles {
            var searchStart = text.startIndex
            while let range = text.range(of: preamble, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                let beforeOK = range.lowerBound == text.startIndex
                    || !text[text.index(before: range.lowerBound)].isLetter
                // Colon-terminated cues ("action item:") don't need a word boundary after.
                let afterOK = preamble.hasSuffix(":")
                    || range.upperBound == text.endIndex
                    || !text[range.upperBound].isLetter
                if beforeOK, afterOK {
                    if best == nil || range.lowerBound < best!.lowerBound { best = range }
                    break
                }
                searchStart = range.upperBound
                if searchStart >= text.endIndex { break }
            }
        }
        return best?.upperBound
    }

    private static func strippedLeadingFiller(_ text: String) -> String {
        var working = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—.").union(.whitespacesAndNewlines))
        var changed = true
        while changed {
            changed = false
            for phrase in leadingFillerPhrases where working.lowercased().hasPrefix(phrase + " ") {
                working = String(working.dropFirst(phrase.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
            }
            let firstWord = working.prefix { $0.isLetter || $0 == "'" }.lowercased()
            if !firstWord.isEmpty, leadingFillers.contains(firstWord) {
                working = String(working.dropFirst(firstWord.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
            }
        }
        return working
    }

    /// Remove a trailing due phrase ("by Friday", "next week") from a task,
    /// since the due is surfaced separately as its own chip.
    private static func strippedTrailingDue(_ text: String) -> String {
        let patterns = [
            #"(?i)\s+by\s+(today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|eod|eow|end of day|end of week|end of the week|q[1-4]|next week|this week)\s*$"#,
            #"(?i)\s+(this week|next week|end of week|end of the week|end of day)\s*$"#,
            #"(?i)\s+(today|tomorrow|tonight)\s*$"#
        ]
        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    /// Keep only the first sentence/clause so a rambling line stays a single item.
    private static func firstClause(_ text: String) -> String {
        if let idx = text.firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" }) {
            let head = text[..<idx]
            if head.trimmingCharacters(in: .whitespaces).count >= 8 { return String(head) }
        }
        if text.count > 140, let cut = text.prefix(140).lastIndex(of: " ") {
            return String(text[..<cut]) + "…"
        }
        return text
    }

    private static func isClosingQuestion(_ lower: String) -> Bool {
        let closers = [
            "any questions", "questions?", "anything else", "make sense",
            "sound good", "does that work", "are we good", "all good"
        ]
        return closers.contains { lower.contains($0) } && lower.count < 40
    }

    private static func ownerHint(in line: String, attendees: [String]) -> String {
        let lower = line.lowercased()

        // Explicit "owner: Name" / "owner - Name".
        if let owner = explicitOwner(in: line) {
            return owner
        }

        // Named attendee mentioned in the line.
        for attendee in attendees where lower.contains(attendee.lowercased()) {
            return attendee
        }

        // First person → the user; "we" → the team.
        if lower.contains("i'll") || lower.contains("i will") || lower.contains("i'm going to")
            || lower.contains("i need to") || lower.contains("my action") || lower.hasPrefix("i ") {
            return "You"
        }
        if lower.contains("we'll") || lower.contains("we will") || lower.contains("we need to")
            || lower.contains("our team") || lower.hasPrefix("we ") {
            return "Team"
        }

        // "Name will / Name to <verb> / Name owns".
        if let named = leadingNamedOwner(in: line) {
            return named
        }

        // Transcript "Speaker: …" prefix.
        if let speaker = speakerPrefix(in: line) {
            return speaker
        }
        return "Owner not named"
    }

    /// Pulls the name from an explicit "owner: Name" / "owner - Name" marker.
    private static func explicitOwner(in line: String) -> String? {
        guard let range = line.range(of: #"(?i)\bowner\b\s*[:\-–]\s*"#, options: .regularExpression) else { return nil }
        let tail = line[range.upperBound...]
        let name = tail.prefix { $0.isLetter || $0 == " " || $0 == "'" }
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .prefix(2)
            .joined(separator: " ")
        return name.count >= 2 ? name : nil
    }

    /// "Maya will send …" / "Leo to review …" / "Sam owns …" → the leading name.
    private static func leadingNamedOwner(in line: String) -> String? {
        let cleaned = cleanLine(line)
        guard let match = cleaned.range(
            of: #"^([A-Z][a-z]{1,20})\s+(will|to|should|owns|is going to|takes|leads)\b"#,
            options: .regularExpression
        ) else { return nil }
        let name = cleaned[match].split(separator: " ").first.map(String.init) ?? ""
        return name.count >= 2 ? name : nil
    }

    private static func dueHint(in line: String) -> String? {
        let lower = line.lowercased()
        let markers = [
            "today", "tomorrow", "friday", "monday", "tuesday", "wednesday",
            "thursday", "this week", "next week", "end of week", "eow",
            "q1", "q2", "q3", "q4", "month"
        ]
        return markers.first(where: lower.contains)
    }

    private static func speakerPrefix(in line: String) -> String? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let speaker = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard speaker.count >= 2, speaker.count <= 32 else { return nil }
        return speaker
    }

    private static func fingerprint(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}
