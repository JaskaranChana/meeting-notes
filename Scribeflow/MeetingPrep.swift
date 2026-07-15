import Foundation
import SwiftUI

enum EventPrepMatchStrength: String, Hashable {
    case strong
    case related
    case newContext

    var title: String {
        switch self {
        case .strong: "Strong history match"
        case .related: "Related history"
        case .newContext: "New context"
        }
    }

    var systemImage: String {
        switch self {
        case .strong: "checkmark.seal.fill"
        case .related: "link.circle.fill"
        case .newContext: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .strong: AppPalette.success
        case .related: AppPalette.accent
        case .newContext: AppPalette.gold
        }
    }
}

enum EventPrepPointKind: String, Hashable {
    case commitment
    case decision
    case question
    case risk

    var systemImage: String {
        switch self {
        case .commitment: AppSymbols.action
        case .decision: AppSymbols.decision
        case .question: "questionmark.bubble.fill"
        case .risk: AppSymbols.risk
        }
    }

    var tint: Color {
        switch self {
        case .commitment: AppPalette.coral
        case .decision: AppPalette.success
        case .question: AppPalette.accent
        case .risk: AppPalette.gold
        }
    }
}

struct EventPrepSource: Identifiable, Hashable {
    let id: Meeting.ID
    let title: String
    let date: Date
    let matchReason: String
}

struct EventPrepPoint: Identifiable, Hashable {
    let id: String
    let text: String
    let kind: EventPrepPointKind
    let source: EventPrepSource?
    let evidenceLabel: String
}

struct EventPrepBrief: Hashable {
    let headline: String
    let contextLine: String
    let strength: EventPrepMatchStrength
    let carryForward: [EventPrepPoint]
    let questions: [EventPrepPoint]
    let relatedMeetings: [EventPrepSource]

    var hasHistory: Bool { !relatedMeetings.isEmpty }
}

/// Immutable sheet input. Building the relationship graph happens once when
/// the user asks for prep, rather than every time SwiftUI reevaluates a sheet.
struct EventPrepPresentation: Identifiable {
    var id: String { event.id }
    let event: CalendarEventSnapshot
    let brief: EventPrepBrief
    let hasPreparedNote: Bool
}

extension CalendarEventSnapshot {
    init?(preparedMeeting meeting: Meeting) {
        guard let calendarEventID = meeting.calendarEventID else { return nil }
        let startDate = meeting.calendarStartDate ?? meeting.when
        let endDate = meeting.calendarEndDate
            ?? startDate.addingTimeInterval(TimeInterval(max(15, meeting.durationMinutes) * 60))
        let context = "\(meeting.workspace) \(meeting.objective)".lowercased()
        let isVideoCall = meeting.isCallMeeting
            || ["zoom", "google meet", "microsoft teams", "facetime"].contains(where: context.contains)

        self.init(
            id: calendarEventID,
            title: meeting.title,
            startDate: startDate,
            endDate: endDate,
            location: nil,
            notes: meeting.objective,
            attendees: meeting.attendees,
            isVideoCall: isVideoCall
        )
    }
}

/// Shared identity rules for calendar attendees, saved attendees, and corrected
/// transcript speakers. Generic diarization labels never become people records.
enum MeetingIdentityResolver {
    private static let ignoredNames: Set<String> = [
        "ai", "host", "me", "meeting", "participant", "unknown", "you"
    ]
    private static let honorifics: Set<String> = ["dr", "miss", "mr", "mrs", "ms", "prof"]

    static func people(in meeting: Meeting) -> [String] {
        let transcriptNames = meeting.transcript.map(\.speaker)
        return deduplicated(meeting.attendees + transcriptNames)
    }

    static func deduplicated(_ names: [String]) -> [String] {
        var result: [String] = []
        for candidate in names where isUsableName(candidate) {
            if let index = result.firstIndex(where: { likelySamePerson($0, candidate) }) {
                if preferredDisplayName(candidate, over: result[index]) {
                    result[index] = cleanedDisplayName(candidate)
                }
            } else {
                result.append(cleanedDisplayName(candidate))
            }
        }
        return result
    }

    static func likelySamePerson(_ lhs: String, _ rhs: String) -> Bool {
        let left = nameTokens(lhs)
        let right = nameTokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }

        if left.count == 1, let token = left.first {
            return token.count >= 3 && (right.first == token || right.last == token)
        }
        if right.count == 1, let token = right.first {
            return token.count >= 3 && (left.first == token || left.last == token)
        }
        return left.first == right.first && left.last == right.last
    }

    static func isUsableName(_ raw: String) -> Bool {
        let cleaned = cleanedDisplayName(raw)
        let folded = foldedText(cleaned)
        guard cleaned.count >= 2, cleaned.count <= 80, !ignoredNames.contains(folded) else { return false }
        guard !folded.hasPrefix("speaker "), !folded.hasPrefix("speaker_") else { return false }
        guard !folded.hasPrefix("person "), !folded.hasPrefix("participant ") else { return false }
        return cleaned.unicodeScalars.contains(where: CharacterSet.letters.contains)
    }

    private static func preferredDisplayName(_ candidate: String, over existing: String) -> Bool {
        let candidateTokens = nameTokens(candidate)
        let existingTokens = nameTokens(existing)
        if candidateTokens.count != existingTokens.count {
            return candidateTokens.count > existingTokens.count
        }
        return cleanedDisplayName(candidate).count > cleanedDisplayName(existing).count
    }

    private static func nameTokens(_ raw: String) -> [String] {
        var source = foldedText(raw)
        if let at = source.firstIndex(of: "@") {
            source = String(source[..<at])
        }
        return source
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !honorifics.contains($0) }
    }

    private static func cleanedDisplayName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func foldedText(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum EventPrepEngine {
    private struct Candidate {
        let meeting: Meeting
        let score: Int
        let sharedPeople: [String]
        let sharedTitleTokens: [String]

        var source: EventPrepSource {
            EventPrepSource(
                id: meeting.id,
                title: meeting.title,
                date: meeting.when,
                matchReason: Self.matchReason(people: sharedPeople, titleTokens: sharedTitleTokens)
            )
        }

        private static func matchReason(people: [String], titleTokens: [String]) -> String {
            if !people.isEmpty {
                return "Shared people: \(naturalList(Array(people.prefix(3))))"
            }
            if !titleTokens.isEmpty {
                return "Shared topic: \(naturalList(Array(titleTokens.prefix(3)).map(\.capitalized)))"
            }
            return "Related recent note"
        }
    }

    private static let titleStopWords: Set<String> = [
        "a", "an", "and", "calendar", "call", "check", "daily", "for", "in", "meeting",
        "monthly", "of", "on", "prep", "review", "sync", "the", "to", "update", "weekly", "with"
    ]

    static func make(
        for event: CalendarEventSnapshot,
        meetings: [Meeting],
        excluding excludedMeetingID: Meeting.ID? = nil
    ) -> EventPrepBrief {
        let eventPeople = MeetingIdentityResolver.deduplicated(event.attendees)
            .filter { !MeetingIdentityResolver.likelySamePerson($0, "You") }
        let eventTitleTokens = topicTokens(event.title)
        let eventContextTokens = topicTokens([event.title, event.notes ?? "", event.location ?? ""].joined(separator: " "))

        let candidates = meetings
            .lazy
            .filter { $0.id != excludedMeetingID }
            .filter { !$0.isPersonalCapture && $0.status != .live }
            .filter { $0.when < event.startDate.addingTimeInterval(-60) }
            .prefix(80)
            .compactMap { meeting -> Candidate? in
                let meetingPeople = MeetingIdentityResolver.people(in: meeting)
                let sharedPeople = eventPeople.filter { eventPerson in
                    meetingPeople.contains { MeetingIdentityResolver.likelySamePerson(eventPerson, $0) }
                }

                let meetingTitleTokens = topicTokens(meeting.title)
                let sharedTitle = eventTitleTokens.intersection(meetingTitleTokens).sorted()
                let meetingContext = topicTokens("\(meeting.title) \(meeting.workspace) \(meeting.objective)")
                let sharedContext = eventContextTokens.intersection(meetingContext)

                let hasRelationshipSignal = !sharedPeople.isEmpty
                    || sharedTitle.count >= min(2, max(1, eventTitleTokens.count))
                    || (eventTitleTokens.count == 1 && sharedTitle.count == 1)
                guard hasRelationshipSignal else { return nil }

                var score = sharedPeople.count * 24
                score += sharedTitle.count * 9
                score += min(sharedContext.count, 4) * 3
                if meeting.calendarEventID != nil { score += 2 }
                score += recencyBonus(for: meeting.when, relativeTo: event.startDate)
                guard score >= 12 else { return nil }

                return Candidate(
                    meeting: meeting,
                    score: score,
                    sharedPeople: sharedPeople,
                    sharedTitleTokens: sharedTitle
                )
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.meeting.when > $1.meeting.when
            }

        let selected = Array(candidates.prefix(4))
        let sources = selected.map(\.source)
        let strength: EventPrepMatchStrength
        if let top = selected.first, top.score >= 42 {
            strength = .strong
        } else if selected.isEmpty {
            strength = .newContext
        } else {
            strength = .related
        }

        let carryForward = carryForwardPoints(from: selected)
        let questions = questionPoints(from: selected, event: event)
        let matchedPeople = MeetingIdentityResolver.deduplicated(selected.flatMap(\.sharedPeople))
        let openCount = selected.reduce(into: 0) { count, candidate in
            count += candidate.meeting.commitments.filter { $0.status == .open || $0.status == .atRisk }.count
        }

        return EventPrepBrief(
            headline: headline(for: selected, matchedPeople: matchedPeople),
            contextLine: contextLine(
                sourceCount: sources.count,
                matchedPeople: matchedPeople,
                openCount: openCount,
                latestDate: selected.first?.meeting.when
            ),
            strength: strength,
            carryForward: carryForward,
            questions: questions,
            relatedMeetings: sources
        )
    }

    private static func carryForwardPoints(from candidates: [Candidate]) -> [EventPrepPoint] {
        var points: [EventPrepPoint] = []
        var fingerprints = Set<String>()

        for candidate in candidates {
            let source = candidate.source
            let commitments = candidate.meeting.commitments
                .filter { $0.status == .open || $0.status == .atRisk }
                .sorted { commitmentRank($0) > commitmentRank($1) }

            for commitment in commitments {
                appendPoint(
                    text: commitment.statement,
                    kind: .commitment,
                    source: source,
                    evidenceLabel: commitment.sourceReferences.isEmpty ? "Saved action" : "Transcript-backed",
                    to: &points,
                    fingerprints: &fingerprints
                )
                if points.count == 3 { return points }
            }

            if let decision = decisions(in: candidate.meeting).first {
                appendPoint(
                    text: decision,
                    kind: .decision,
                    source: source,
                    evidenceLabel: "Saved decision",
                    to: &points,
                    fingerprints: &fingerprints
                )
                if points.count == 3 { return points }
            }
        }
        return points
    }

    private static func questionPoints(from candidates: [Candidate], event: CalendarEventSnapshot) -> [EventPrepPoint] {
        var points: [EventPrepPoint] = []
        var fingerprints = Set<String>()

        for candidate in candidates {
            let source = candidate.source
            for question in openQuestions(in: candidate.meeting) {
                appendPoint(
                    text: question,
                    kind: .question,
                    source: source,
                    evidenceLabel: "Open question",
                    to: &points,
                    fingerprints: &fingerprints
                )
                if points.count == 3 { return points }
            }

            for risk in risks(in: candidate.meeting) {
                appendPoint(
                    text: "Has this been resolved: \(trimSentence(risk))?",
                    kind: .risk,
                    source: source,
                    evidenceLabel: "Prior risk",
                    to: &points,
                    fingerprints: &fingerprints
                )
                if points.count == 3 { return points }
            }
        }

        let suggested = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = suggested?.isEmpty == false
            ? "What outcome should be settled from the calendar agenda?"
            : "What must be true by the end of this conversation?"
        appendPoint(
            text: fallback,
            kind: .question,
            source: nil,
            evidenceLabel: "Suggested",
            to: &points,
            fingerprints: &fingerprints
        )
        return Array(points.prefix(3))
    }

    private static func decisions(in meeting: Meeting) -> [String] {
        if let brief = meeting.aiBrief, brief.makesSense, !brief.decisions.isEmpty {
            return brief.decisions
        }
        return MeetingIntelligenceEngine.decisions(for: meeting, limit: 2)
    }

    private static func openQuestions(in meeting: Meeting) -> [String] {
        if let brief = meeting.aiBrief, brief.makesSense, !brief.openQuestions.isEmpty {
            return brief.openQuestions
        }
        return MeetingIntelligenceEngine.openQuestions(for: meeting, limit: 2)
    }

    private static func risks(in meeting: Meeting) -> [String] {
        if let brief = meeting.aiBrief, brief.makesSense, !brief.risks.isEmpty {
            return Array(brief.risks.prefix(2))
        }
        let lines: [String] = meeting.rawNotes
            .split(whereSeparator: \.isNewline)
            .map { line in
                String(line).trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-*•"))
                )
            }
            .filter { line in
                let folded = line.lowercased()
                return folded.hasPrefix("risk:") || folded.hasPrefix("blocker:") || folded.hasPrefix("concern:")
            }
        return Array(lines.prefix(2))
    }

    private static func appendPoint(
        text: String,
        kind: EventPrepPointKind,
        source: EventPrepSource?,
        evidenceLabel: String,
        to points: inout [EventPrepPoint],
        fingerprints: inout Set<String>
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 4 else { return }
        let fingerprint = normalizedFingerprint(cleaned)
        guard fingerprints.insert(fingerprint).inserted else { return }
        let sourceID = source?.id.uuidString ?? "suggested"
        points.append(
            EventPrepPoint(
                id: "\(kind.rawValue)|\(sourceID)|\(fingerprint)",
                text: cleaned,
                kind: kind,
                source: source,
                evidenceLabel: evidenceLabel
            )
        )
    }

    private static func commitmentRank(_ commitment: Commitment) -> Int {
        var rank = commitment.status == .atRisk ? 30 : 10
        switch commitment.priority?.lowercased() {
        case "high": rank += 20
        case "medium": rank += 10
        default: break
        }
        if commitment.dueDateOverride != nil || commitment.dueHint != nil { rank += 4 }
        return rank
    }

    private static func headline(for candidates: [Candidate], matchedPeople: [String]) -> String {
        guard !candidates.isEmpty else { return "First conversation in Scribeflow" }
        if !matchedPeople.isEmpty {
            return "Pick up where you left off with \(naturalList(Array(matchedPeople.prefix(2))))"
        }
        if let topic = candidates.first?.sharedTitleTokens.first {
            return "Continue the \(topic) thread"
        }
        return "Continue from your related notes"
    }

    private static func contextLine(
        sourceCount: Int,
        matchedPeople: [String],
        openCount: Int,
        latestDate: Date?
    ) -> String {
        guard sourceCount > 0 else {
            return "No related meeting history was pulled into this brief."
        }
        var parts = ["\(sourceCount) related note\(sourceCount == 1 ? "" : "s")"]
        if !matchedPeople.isEmpty {
            parts.append("\(matchedPeople.count) familiar person\(matchedPeople.count == 1 ? "" : "s")")
        }
        if openCount > 0 {
            parts.append("\(openCount) open item\(openCount == 1 ? "" : "s")")
        }
        if let latestDate {
            parts.append("latest \(latestDate.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private static func recencyBonus(for meetingDate: Date, relativeTo eventDate: Date) -> Int {
        let days = max(0, Calendar.current.dateComponents([.day], from: meetingDate, to: eventDate).day ?? 0)
        switch days {
        case 0...7: return 8
        case 8...30: return 5
        case 31...90: return 2
        default: return 0
        }
    }

    private static func topicTokens(_ text: String) -> Set<String> {
        Set(
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !titleStopWords.contains($0) }
        )
    }

    private static func normalizedFingerprint(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func trimSentence(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!")))
    }
}

private func naturalList(_ values: [String]) -> String {
    switch values.count {
    case 0: ""
    case 1: values[0]
    case 2: "\(values[0]) and \(values[1])"
    default: "\(values.dropLast().joined(separator: ", ")), and \(values.last ?? "")"
    }
}

struct EventPrepBriefSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsSources = false

    let event: CalendarEventSnapshot
    let brief: EventPrepBrief
    let hasPreparedNote: Bool
    let onOpenNote: () -> Void
    let onRecord: () -> Void
    let onOpenSource: (Meeting.ID) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    eventHeader
                    contextSummary

                    if brief.carryForward.isEmpty {
                        firstConversationState
                    } else {
                        prepSection(title: "Carry forward", points: brief.carryForward)
                    }

                    prepSection(title: "Ask next", points: brief.questions)

                    if !brief.relatedMeetings.isEmpty { sourceDisclosure }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.xl)
                .readingWidth()
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle(event.endDate < .now ? "Event context" : "Before you join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: AppSymbols.close)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(AppRadius.xl)
    }

    private var eventHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            EditorialEyebrow(text: event.startDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            Text(event.title)
                .font(.system(.title, design: .serif).weight(.semibold))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: AppSpacing.sm) {
                Label(eventTime, systemImage: AppSymbols.clock)
                if event.isVideoCall {
                    Label("Video", systemImage: "video.fill")
                } else if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                    Label(location, systemImage: "location.fill")
                        .lineLimit(1)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(AppPalette.secondaryInk)

            if !event.attendees.isEmpty {
                HStack(spacing: AppSpacing.sm) {
                    EditorialAvatarStack(names: event.attendees, size: 26, max: 4)
                    Text(event.attendees.prefix(3).joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .lineLimit(2)
                }
            }
        }
    }

    private var contextSummary: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            IconBadge(systemImage: brief.strength.systemImage, tint: brief.strength.tint, size: .small)
            VStack(alignment: .leading, spacing: 4) {
                EditorialMeta(text: brief.strength.title, tint: brief.strength.tint)
                Text(brief.headline)
                    .font(.headline)
                    .foregroundStyle(AppPalette.ink)
                Text(brief.contextLine)
                    .font(.footnote)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.md)
        .overlay(alignment: .top) { EditorialRule() }
        .overlay(alignment: .bottom) { EditorialRule() }
    }

    private var firstConversationState: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "text.badge.plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppPalette.gold)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text("Start with a clean agenda")
                    .font(.headline)
                    .foregroundStyle(AppPalette.ink)
                Text("Scribeflow found no strong relationship or topic match, so it left prior notes out instead of guessing.")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func prepSection(title: String, points: [EventPrepPoint]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            EditorialSectionHead(title: title)
            ForEach(points) { point in
                prepPointRow(point)
            }
        }
    }

    private func prepPointRow(_ point: EventPrepPoint) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: point.kind.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(point.kind.tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(point.text)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let source = point.source {
                    Button {
                        openSource(source.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text(point.evidenceLabel)
                            Text("·")
                            Text(source.title)
                                .lineLimit(1)
                            Image(systemName: AppSymbols.chevron)
                                .font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open source note \(source.title)")
                } else {
                    EditorialMeta(text: point.evidenceLabel, tint: AppPalette.gold)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.xs)
        .overlay(alignment: .bottom) { EditorialRule() }
    }

    private var sourceDisclosure: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Button {
                HapticEngine.tap(.light)
                withAnimation(.easeOut(duration: 0.16)) {
                    showsSources.toggle()
                }
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(AppPalette.accent)
                    Text("\(brief.relatedMeetings.count) source note\(brief.relatedMeetings.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Spacer(minLength: 8)
                    Image(systemName: showsSources ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsSources {
                ForEach(brief.relatedMeetings) { source in
                    Button {
                        openSource(source.id)
                    } label: {
                        HStack(spacing: AppSpacing.sm) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppPalette.ink)
                                    .lineLimit(2)
                                Text("\(source.matchReason) · \(source.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(AppPalette.secondaryInk)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: AppSymbols.chevron)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppPalette.tertiaryInk)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorialRowStyle())
                }
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .overlay(alignment: .top) { EditorialRule() }
    }

    private var actionBar: some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                perform(onOpenNote)
            } label: {
                Label(hasPreparedNote ? "Open note" : "Create note", systemImage: AppSymbols.note)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AppPalette.ink)

            Button {
                perform(onRecord)
            } label: {
                Label("Record", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.accent)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .adaptiveMaterial(.regularMaterial, solid: AppPalette.cardBackground)
        .overlay(alignment: .top) { EditorialRule() }
    }

    private var eventTime: String {
        "\(event.startDate.formatted(.dateTime.hour().minute()))-\(event.endDate.formatted(.dateTime.hour().minute()))"
    }

    private func openSource(_ id: Meeting.ID) {
        dismiss()
        onOpenSource(id)
    }

    private func perform(_ action: () -> Void) {
        dismiss()
        action()
    }
}
