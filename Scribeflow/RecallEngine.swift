import Foundation

// MARK: - Action Tracker (Tier 1: Post-Meeting Accountability Loop)

enum ActionTracker {

    static func pendingChecks(from meetings: [Meeting]) -> [ActionCheck] {
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        return meetings
            .filter { $0.when <= cutoff }
            .filter { $0.allowsAccountabilityExtraction }
            .flatMap { meeting -> [ActionCheck] in
                meeting.commitments
                    .filter { $0.status == .open || $0.status == .atRisk }
                    .map { commitment in
                        ActionCheck(
                            meetingID: meeting.id,
                            meetingTitle: meeting.title,
                            text: commitment.statement,
                            owner: commitment.owner.isEmpty ? "You" : commitment.owner,
                            meetingDate: meeting.when,
                            status: .pending
                        )
                    }
            }
            .sorted { $0.meetingDate < $1.meetingDate }
    }

    static func completionRate(checks: [ActionCheck]) -> Double {
        guard !checks.isEmpty else { return 1.0 }
        let resolved = checks.filter { $0.status == .done || $0.status == .skipped }.count
        return Double(resolved) / Double(checks.count)
    }

    static func overdueMeetings(from meetings: [Meeting]) -> [Meeting] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return meetings.filter {
            $0.when <= cutoff &&
            $0.status != .shared &&
            $0.allowsAccountabilityExtraction &&
            $0.commitments.contains { $0.status == .open }
        }
    }
}

// MARK: - People Intelligence Engine (Tier 2)

enum PeopleEngine {

    private static let stopWords: Set<String> = [
        "the","a","an","and","or","but","in","on","at","to","for","of","with","is",
        "was","are","were","be","been","have","has","had","this","that","we","i","you",
        "he","she","it","they","our","your","call","meeting","sync","review","update",
        "check","discuss","follow","weekly","monthly","daily","about","from","into",
        "will","can","would","could","should","next","last","first","also","before",
        "after","team","work","time","just","over","then","when","what","which"
    ]

    static func intelligence(for name: String, in meetings: [Meeting]) -> PersonIntelligence {
        let personMeetings = meetings.filter { meeting in
            MeetingIdentityResolver.people(in: meeting).contains {
                MeetingIdentityResolver.likelySamePerson(name, $0)
            }
        }.sorted { $0.when > $1.when }

        let open = personMeetings
            .filter { $0.allowsAccountabilityExtraction }
            .flatMap(\.commitments)
            .filter { $0.status == .open || $0.status == .atRisk }

        var wordFreq: [String: Int] = [:]
        for meeting in personMeetings {
            let source = "\(meeting.title) \(meeting.objective) \(meeting.rawNotes)".lowercased()
            let words = source
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 5 && !stopWords.contains($0) }
            for word in words { wordFreq[word, default: 0] += 1 }
        }
        let topTopics = wordFreq
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { String($0.key.prefix(1)).uppercased() + $0.key.dropFirst() }

        let lastDate = personMeetings.first?.when
        let daysSince = lastDate.map {
            Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0
        }

        return PersonIntelligence(
            name: name,
            meetings: personMeetings,
            openCommitments: open,
            topTopics: Array(topTopics),
            lastMeetingDate: lastDate,
            daysSinceLastMeeting: daysSince
        )
    }

    static func allPeople(from meetings: [Meeting]) -> [String] {
        MeetingIdentityResolver
            .deduplicated(meetings.flatMap { MeetingIdentityResolver.people(in: $0) })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Meeting Score Engine (Tier 2)

enum MeetingScorer {

    static func score(for meeting: Meeting) -> MeetingScore {
        score(
            for: meeting,
            allowsAccountability: meeting.allowsAccountabilityExtraction
        )
    }

    static func score(for meeting: Meeting, allowsAccountability: Bool) -> MeetingScore {
        var clarity = 50
        var decisiveness = 50
        var actionability = 50

        let noteLength = meeting.rawNotes.count
        if noteLength > 200 { clarity += 20 }
        if noteLength > 500 { clarity += 10 }
        if !meeting.objective.isEmpty { clarity += 10 }
        if meeting.transcript.count > 5 { clarity += 10 }

        let scoredCommitments = allowsAccountability ? meeting.commitments : []
        let decisions = scoredCommitments.filter { $0.status != .superseded }.count
        decisiveness += min(decisions * 10, 30)
        if meeting.summaries.count > 1 { decisiveness += 10 }

        let actions = scoredCommitments.filter { $0.status == .open || $0.status == .fulfilled }.count
        actionability += min(actions * 8, 32)
        if !meeting.attendees.isEmpty { actionability += 8 }
        let ownedActions = scoredCommitments.filter { !$0.owner.isEmpty }.count
        actionability += min(ownedActions * 5, 10)

        clarity = min(clarity, 100)
        decisiveness = min(decisiveness, 100)
        actionability = min(actionability, 100)
        let overall = (clarity + decisiveness + actionability) / 3

        let insight = scoreInsight(clarity: clarity, decisiveness: decisiveness, actionability: actionability, overall: overall)

        return MeetingScore(
            clarity: clarity,
            decisiveness: decisiveness,
            actionability: actionability,
            overall: overall,
            insight: insight,
            scoredAt: Date()
        )
    }

    private static func scoreInsight(clarity: Int, decisiveness: Int, actionability: Int, overall: Int) -> String {
        let lowest = [("clarity", clarity), ("decisiveness", decisiveness), ("actionability", actionability)]
            .min(by: { $0.1 < $1.1 })?.0 ?? "clarity"

        if overall >= 85 {
            return "High-signal meeting. Decisions were clear and actions are owned."
        } else if overall >= 70 {
            return "Solid meeting. A bit more \(lowest) would make it more actionable."
        } else if overall >= 55 {
            return "Average capture. Focus on improving \(lowest) next time."
        } else {
            return "Light notes. Add more context or commitments to get more value."
        }
    }
}
