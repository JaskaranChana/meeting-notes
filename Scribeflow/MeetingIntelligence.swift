import Foundation
import Security

struct SpeakerSegment: Identifiable, Equatable {
    var id: String { speaker }
    let speaker: String
    let role: String
    let lineCount: Int
    let sample: String
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
            "Backend-ready"
        }
    }

    var detail: String {
        switch self {
        case .localHeuristic:
            "Runs on saved notes and transcripts without uploading data."
        case .backendReady:
            "Use the service interface when a production AI backend is configured."
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
    let confidenceLabel: String
    let mode: MeetingIntelligenceMode
    let speakerDetectionNote: String
}

enum SpeakerTranscriptParser {
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
                TranscriptLine(speaker: defaultSpeaker, role: defaultRole, text: $0)
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
        guard speaker.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }

        return TranscriptLine(speaker: speaker, role: defaultRole, text: body)
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
        let decisions = extract(from: corpus, keywords: decisionCues, limit: 4)
        let actions = extract(from: corpus, keywords: actionCues, limit: 5)
        let structuredActions = extractStructuredActions(from: source, attendees: meeting.attendees, limit: 5)
        let questions = extractQuestions(from: corpus, limit: 4)
        let followUps = followUps(from: actions, structuredActions: structuredActions, questions: questions, decisions: decisions)
        let summary = summary(from: meeting, corpus: corpus, decisions: decisions, actions: actions)
        let speakers = speakerSegments(for: meeting)

        return MeetingIntelligenceReport(
            headline: headline(for: meeting, decisions: decisions, actions: actions, questions: questions),
            suggestedSummary: summary,
            decisions: decisions,
            actionItems: actions,
            structuredActionItems: structuredActions,
            openQuestions: questions,
            followUps: followUps,
            speakerSegments: speakers,
            confidenceLabel: confidenceLabel(corpusCount: corpus.count, speakerCount: speakers.count),
            mode: .localHeuristic,
            speakerDetectionNote: speakerDetectionNote(for: speakers)
        )
    }

    /// Text-derived action items (with owner/due/source) for a meeting — the
    /// single source of truth so persisted commitments match the live read.
    static func structuredActions(for meeting: Meeting, limit: Int = 6) -> [ExtractedActionItem] {
        extractStructuredActions(from: sourceLines(for: meeting), attendees: meeting.attendees, limit: limit)
    }

    /// Decisions detected in a meeting's notes/transcript.
    static func decisions(for meeting: Meeting, limit: Int = 4) -> [String] {
        extract(from: sourceLines(for: meeting).map(\.text), keywords: decisionCues, limit: limit)
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

    private static func extract(from corpus: [String], keywords: [String], limit: Int) -> [String] {
        var seen: Set<String> = []
        var results: [String] = []

        for line in corpus {
            let lower = line.lowercased()
            guard keywords.contains(where: lower.contains) else { continue }
            let polished = polished(line)
            let key = fingerprint(polished)
            guard !polished.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(polished)
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

    /// Cues that signal a commitment/action. Specific enough to avoid the
    /// "everything with 'will' becomes a task" noise of the old filter.
    static let actionCues = [
        "i'll", "i will", "we'll", "we will", "need to", "needs to",
        "going to", "follow up", "follow-up", "next step", "action item",
        "to-do", "todo", "send", "share", "schedule", "book", "review",
        "prepare", "draft", "assign", "owner", "deadline", "deliver",
        "circle back", "set up", "reach out", "by friday", "by monday",
        "by tuesday", "by wednesday", "by thursday", "by tomorrow", "by eod",
        "must ", "responsible for"
    ]

    /// Cues that signal a decision was made.
    static let decisionCues = [
        "decided", "decision", "we agreed", "agreed to", "approved",
        "greenlit", "go with", "going with", "go ahead with", "locked in",
        "final call", "chose", "settled on", "moving forward with", "we will go"
    ]

    private static func looksActionable(_ lower: String) -> Bool {
        guard !lower.hasSuffix("?") else { return false }
        return actionCues.contains(where: lower.contains)
    }

    private static func extractStructuredActions(
        from source: [IntelligenceSourceLine],
        attendees: [String],
        limit: Int
    ) -> [ExtractedActionItem] {
        var seen: Set<String> = []
        var results: [ExtractedActionItem] = []

        for line in source {
            guard looksActionable(line.text.lowercased()) else { continue }

            let text = polished(line.text)
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
        actions: [String]
    ) -> [String] {
        var bullets: [String] = []
        if let decision = decisions.first {
            bullets.append("Decision signal: \(decision)")
        }
        if let action = actions.first {
            bullets.append("Next-step signal: \(action)")
        }

        let ranked = corpus
            .filter { $0.count > 18 }
            .sorted { score($0) > score($1) }
            .map(polished)

        for line in ranked where !bullets.contains(line) {
            bullets.append(line)
            if bullets.count == 4 { break }
        }

        if bullets.isEmpty {
            bullets.append(meeting.objective.isEmpty ? "Capture more detail to generate a stronger brief." : meeting.objective)
        }
        return bullets
    }

    private static func speakerSegments(for meeting: Meeting) -> [SpeakerSegment] {
        let grouped = Dictionary(grouping: meeting.transcript, by: \.speaker)
        return grouped
            .map { speaker, lines in
                SpeakerSegment(
                    speaker: speaker,
                    role: lines.first?.role ?? "Speaker",
                    lineCount: lines.count,
                    sample: lines.first?.text ?? ""
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

    private static func speakerDetectionNote(for speakers: [SpeakerSegment]) -> String {
        if speakers.count > 1 {
            return "Speaker labels came from transcript text and user-corrected labels. Acoustic diarization still needs a production transcription provider."
        }

        return "Only one speaker label is available. Rename or merge labels manually, or connect a diarization-capable transcription backend."
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
