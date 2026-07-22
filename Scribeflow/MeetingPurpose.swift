import Foundation

enum CapturePurposeKind: String, Codable, CaseIterable, Hashable {
    case personalNote
    case reflection
    case idea
    case personalPlan
    case conversation
    case appointment
    case learning
    case meeting
    case call

    var title: String {
        switch self {
        case .personalNote: "Personal note"
        case .reflection: "Reflection"
        case .idea: "Idea"
        case .personalPlan: "Plan"
        case .conversation: "Conversation"
        case .appointment: "Appointment"
        case .learning: "Class or learning"
        case .meeting: "Meeting"
        case .call: "Call"
        }
    }

    var insightTitle: String {
        switch self {
        case .personalNote: "Key notes"
        case .reflection: "Reflections"
        case .idea: "Core ideas"
        case .personalPlan: "Plan"
        case .conversation: "Conversation highlights"
        case .appointment: "Important guidance"
        case .learning: "Takeaways"
        case .meeting, .call: "What matters"
        }
    }

    var intelligenceTitle: String {
        switch self {
        case .meeting, .call: "Meeting intelligence"
        default: "Capture understanding"
        }
    }

    var systemImage: String {
        switch self {
        case .personalNote: "note.text"
        case .reflection: "brain.head.profile"
        case .idea: "lightbulb.fill"
        case .personalPlan: "list.bullet.clipboard"
        case .conversation: "person.2.wave.2"
        case .appointment: "calendar.badge.clock"
        case .learning: "book.closed.fill"
        case .meeting: "person.3.fill"
        case .call: "phone.fill"
        }
    }

    var isPersonalCapture: Bool {
        !allowsMeetingSignals
    }

    var allowsMeetingSignals: Bool {
        self == .meeting || self == .call
    }

    var allowsAccountabilityExtraction: Bool {
        allowsMeetingSignals
    }

    init?(modelValue: String) {
        let normalized = modelValue
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()

        switch normalized {
        case "personalnote", "note", "solo", "voice", "voicenote": self = .personalNote
        case "reflection", "personalreflection", "journal", "journaling": self = .reflection
        case "idea", "ideacapture", "brainstorm", "brainstorming": self = .idea
        case "personalplan", "personalplanning", "plan", "planning", "reminder": self = .personalPlan
        case "conversation", "casualconversation", "discussion": self = .conversation
        case "appointment", "consultation", "consult": self = .appointment
        case "learning", "learningnotes", "lecture", "class", "study": self = .learning
        case "meeting", "workmeeting", "professionalmeeting": self = .meeting
        case "call", "structuredcall", "workcall", "professionalcall": self = .call
        default: return nil
        }
    }
}

enum CapturePurposeConfidence: String, Codable, Hashable {
    case verified
    case strong
    case conservative

    init(modelValue: String) {
        switch modelValue.lowercased() {
        case "high", "verified", "certain": self = .verified
        case "medium", "strong", "likely": self = .strong
        default: self = .conservative
        }
    }
}

enum CapturePurposeEvidence: String, Codable, Hashable {
    case userOverride
    case aiUnderstanding
    case contentAnalysis
    case structuredWorkLanguage
    case personalLanguage
    case multipleSpeakers
    case calendarEvent
    case disclosedMode
    case externalAttendees
    case callRecording
    case meetingLabel
    case personalWorkspace
    case personalTitle
    case soloVoiceNote
    case privateCapture
}

struct CapturePurpose: Hashable {
    let kind: CapturePurposeKind
    let confidence: CapturePurposeConfidence
    let evidence: [CapturePurposeEvidence]
    let topic: String?
    let domain: String?

    init(
        kind: CapturePurposeKind,
        confidence: CapturePurposeConfidence,
        evidence: [CapturePurposeEvidence],
        topic: String? = nil,
        domain: String? = nil
    ) {
        self.kind = kind
        self.confidence = confidence
        self.evidence = evidence
        self.topic = Self.cleanLabel(topic)
        self.domain = Self.cleanLabel(domain)
    }

    var isPersonalCapture: Bool {
        kind.isPersonalCapture
    }

    var allowsMeetingSignals: Bool {
        kind.allowsMeetingSignals
    }

    var allowsAccountabilityExtraction: Bool {
        kind.allowsAccountabilityExtraction
    }

    var displayTitle: String {
        kind.title
    }

    private static func cleanLabel(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty
        else { return nil }
        return String(cleaned.prefix(64))
    }
}

struct MeetingPurposeClassifier {
    static let standard = MeetingPurposeClassifier()

    func classify(_ meeting: Meeting) -> CapturePurpose {
        if let override = meeting.purposeOverride {
            let contentPurpose = classifyContent(in: meeting)
            let domain: String
            if override.allowsMeetingSignals {
                domain = "Work"
            } else if override == .learning {
                domain = "Education"
            } else if override == .appointment,
                      let inferredDomain = meeting.aiBrief?.captureDomain,
                      !inferredDomain.isEmpty {
                domain = inferredDomain
            } else {
                domain = "Personal"
            }
            return CapturePurpose(
                kind: override,
                confidence: .verified,
                evidence: [.userOverride],
                topic: meeting.aiBrief?.captureTopic ?? contentPurpose.topic,
                domain: domain
            )
        }

        if let brief = meeting.aiBrief,
           brief.makesSense,
           let detectedPurpose = brief.capturePurpose {
            let contentPurpose = classifyContent(in: meeting)
            let resolvedPurpose: CapturePurposeKind
            let trimmedTopic = brief.captureTopic.trimmingCharacters(in: .whitespacesAndNewlines)
            if detectedPurpose.allowsMeetingSignals,
               !contentPurpose.allowsMeetingSignals {
                resolvedPurpose = contentPurpose.kind
            } else {
                resolvedPurpose = detectedPurpose
            }
            return CapturePurpose(
                kind: resolvedPurpose,
                confidence: resolvedPurpose == detectedPurpose
                    ? CapturePurposeConfidence(modelValue: brief.purposeConfidence)
                    : contentPurpose.confidence,
                evidence: resolvedPurpose == detectedPurpose
                    ? [.aiUnderstanding, .contentAnalysis]
                    : contentPurpose.evidence,
                topic: trimmedTopic.isEmpty ? contentPurpose.topic : trimmedTopic,
                domain: resolvedPurpose == detectedPurpose
                    ? brief.captureDomain
                    : contentPurpose.domain
            )
        }

        return classifyContent(in: meeting)
    }

    private func classifyContent(in meeting: Meeting) -> CapturePurpose {
        let transcriptParagraphs = representativeTranscriptParagraphs(meeting.transcript)
        let recordingParagraphs = meeting.audioRecordings.flatMap { recording -> [String] in
            var sources = sampledTextFragments(recording.linkedNote)
            if meeting.transcript.isEmpty {
                sources.append(contentsOf: sampledTextFragments(recording.transcript))
            }
            return sources
        }
        return classifyCapture(
            title: meeting.title,
            workspace: meeting.workspace,
            objective: meeting.objective,
            attendees: meeting.attendees,
            notes: meeting.trustedSourceNotes,
            transcriptParagraphs: transcriptParagraphs + recordingParagraphs,
            distinctSpeakerCount: distinctSpeakerCount(in: meeting),
            hasCalendarContext: hasCalendarContext(meeting),
            isCallRecording: meeting.audioRecordings.contains { $0.source == .compliantCall },
            meetingMode: meeting.meetingMode,
            consentState: meeting.consentState,
            isSoloVoiceNote: !meeting.audioRecordings.isEmpty
                && meeting.audioRecordings.allSatisfy { $0.source == .voiceNote }
        )
    }

    func classifyCapture(
        title: String,
        workspace: String,
        objective: String,
        attendees: [String],
        notes: String,
        transcriptParagraphs: [String],
        distinctSpeakerCount: Int = 0,
        hasCalendarContext: Bool = false,
        isCallRecording: Bool = false,
        meetingMode: MeetingMode = .privateNotes,
        consentState: ConsentState = .privateCapture,
        isSoloVoiceNote: Bool = false
    ) -> CapturePurpose {
        let noteFragments = sampledTextFragments(notes)
        let representativeTranscript = representativeParagraphs(transcriptParagraphs)
        let content = normalizedText((noteFragments + representativeTranscript).joined(separator: " "))
        let metadata = normalizedText([title, workspace, objective].joined(separator: " "))
        let semanticText = [content, metadata].filter { !$0.isEmpty }.joined(separator: " ")
        let explicitTopicText = normalizedText([objective, title].joined(separator: " "))
        let topicText = explicitTopicText.isEmpty ? content : explicitTopicText
        let externalAttendeeCount = attendees.filter { !isSelfLabel($0) }.count
        let hasMultiplePeople = distinctSpeakerCount > 1 || externalAttendeeCount > 0
        let hasExplicitMeetingLabel = hasMeetingLabel(
            title: title,
            workspace: workspace,
            objective: objective
        )
        let hasTrustedMeetingContext = hasVerifiedMeetingContext(
            hasCalendarContext: hasCalendarContext,
            externalAttendeeCount: externalAttendeeCount,
            meetingMode: meetingMode,
            consentState: consentState
        )

        let appointmentScore = score(appointmentCues, in: semanticText)
        let learningScore = score(learningCues, in: semanticText)
        let reflectionScore = score(reflectionCues, in: semanticText)
        let ideaScore = score(ideaCues, in: semanticText)
        let planningScore = score(planningCues, in: semanticText)
        let relationshipScore = score(relationshipCues, in: semanticText)
        let workScore = score(workCues, in: semanticText)
        let structuredScore = score(structuredMeetingCues, in: semanticText)

        var evidence: [CapturePurposeEvidence] = []
        if !content.isEmpty { evidence.append(.contentAnalysis) }
        if hasMultiplePeople { evidence.append(.multipleSpeakers) }
        if workScore + structuredScore >= 4 { evidence.append(.structuredWorkLanguage) }
        if max(reflectionScore, ideaScore, planningScore, relationshipScore) >= 3 {
            evidence.append(.personalLanguage)
        }
        if hasCalendarContext { evidence.append(.calendarEvent) }
        if meetingMode != .privateNotes || consentState != .privateCapture { evidence.append(.disclosedMode) }
        if externalAttendeeCount > 0 { evidence.append(.externalAttendees) }
        if isCallRecording { evidence.append(.callRecording) }
        if hasExplicitMeetingLabel { evidence.append(.meetingLabel) }
        evidence.append(contentsOf: personalEvidence(
            title: title,
            workspace: workspace,
            objective: objective,
            isSoloVoiceNote: isSoloVoiceNote,
            meetingMode: meetingMode,
            consentState: consentState
        ))
        evidence = deduplicated(evidence)

        let kind: CapturePurposeKind
        let winningScore: Int

        if appointmentScore >= 4 {
            kind = .appointment
            winningScore = appointmentScore
        } else if learningScore >= 4 {
            kind = .learning
            winningScore = learningScore
        } else if hasMultiplePeople,
                  relationshipScore >= 2 || (workScore + structuredScore < 4 && !content.isEmpty) {
            kind = .conversation
            winningScore = max(relationshipScore, 3)
        } else if !hasMultiplePeople, reflectionScore >= 4 {
            kind = .reflection
            winningScore = reflectionScore
        } else if ideaScore >= 4, workScore < 4 {
            kind = .idea
            winningScore = ideaScore
        } else if !hasMultiplePeople, planningScore >= 4, workScore < 4 {
            kind = .personalPlan
            winningScore = planningScore
        } else if workScore + structuredScore >= (hasMultiplePeople ? 4 : 5),
                  hasMultiplePeople
                    || hasTrustedMeetingContext
                    || hasExplicitMeetingLabel
                    || structuredScore >= 3 {
            kind = isCallRecording || hasCallLabel(title: title, workspace: workspace) ? .call : .meeting
            winningScore = workScore + structuredScore
        } else if hasTrustedMeetingContext,
                  content.isEmpty || structuredScore > 0 || workScore > 1 {
            kind = isCallRecording || hasCallLabel(title: title, workspace: workspace) ? .call : .meeting
            winningScore = 4
        } else if hasMultiplePeople {
            kind = .conversation
            winningScore = 3
        } else if ideaScore >= max(reflectionScore, planningScore), ideaScore >= 2 {
            kind = .idea
            winningScore = ideaScore
        } else if reflectionScore >= planningScore, reflectionScore >= 2 {
            kind = .reflection
            winningScore = reflectionScore
        } else if planningScore >= 2 {
            kind = .personalPlan
            winningScore = planningScore
        } else {
            kind = .personalNote
            winningScore = content.isEmpty ? 1 : 2
        }

        return CapturePurpose(
            kind: kind,
            confidence: confidence(for: winningScore, evidence: evidence),
            evidence: evidence.isEmpty ? [.privateCapture] : evidence,
            topic: heuristicTopic(from: topicText),
            domain: domain(for: kind, content: semanticText)
        )
    }

    private func distinctSpeakerCount(in meeting: Meeting) -> Int {
        var speakers: Set<String> = []
        for line in meeting.transcript {
            let speaker = line.speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !speaker.isEmpty else { continue }
            speakers.insert(speaker)
            if speakers.count == 2 { return 2 }
        }
        return speakers.count
    }

    private func representativeTranscriptParagraphs(
        _ lines: [TranscriptLine],
        limit: Int = 80
    ) -> [String] {
        representativeIndices(count: lines.count, limit: limit).map {
            boundedParagraph(lines[$0].text)
        }
    }

    private func representativeParagraphs(
        _ paragraphs: [String],
        limit: Int = 80
    ) -> [String] {
        representativeIndices(count: paragraphs.count, limit: limit).map {
            boundedParagraph(paragraphs[$0])
        }
    }

    private func representativeIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }

        let edgeCount = min(20, limit / 3)
        var selected = Set(0..<edgeCount)
        selected.formUnion((count - edgeCount)..<count)
        let remaining = limit - selected.count
        guard remaining > 0 else { return selected.sorted() }

        let step = Double(count - 1) / Double(remaining + 1)
        for position in 1...remaining {
            selected.insert(min(count - 1, Int((Double(position) * step).rounded())))
        }
        return selected.sorted().prefix(limit).map { $0 }
    }

    private func sampledTextFragments(
        _ text: String,
        fragmentLength: Int = 320,
        limit: Int = 12
    ) -> [String] {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard source.length > 0 else { return [] }
        guard source.length > fragmentLength else { return [source as String] }

        let maximumStart = source.length - fragmentLength
        let fragmentCount = min(limit, max(2, Int(ceil(Double(source.length) / Double(fragmentLength)))))
        var fragments: [String] = []
        fragments.reserveCapacity(fragmentCount)

        for position in 0..<fragmentCount {
            let progress = fragmentCount == 1
                ? 0
                : Double(position) / Double(fragmentCount - 1)
            let start = min(maximumStart, Int((Double(maximumStart) * progress).rounded()))
            fragments.append(
                source.substring(with: NSRange(location: start, length: fragmentLength))
            )
        }
        return fragments
    }

    private func boundedParagraph(_ text: String, maximumLength: Int = 320) -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard source.length > maximumLength else { return source as String }
        let edgeLength = maximumLength / 2
        return source.substring(to: edgeLength)
            + " "
            + source.substring(from: source.length - edgeLength)
    }

    private func confidence(
        for score: Int,
        evidence: [CapturePurposeEvidence]
    ) -> CapturePurposeConfidence {
        if score >= 7 || evidence.contains(.calendarEvent) && evidence.contains(.structuredWorkLanguage) {
            return .verified
        }
        if score >= 4 { return .strong }
        return .conservative
    }

    private func personalEvidence(
        title: String,
        workspace: String,
        objective: String,
        isSoloVoiceNote: Bool,
        meetingMode: MeetingMode,
        consentState: ConsentState
    ) -> [CapturePurposeEvidence] {
        var evidence: [CapturePurposeEvidence] = []
        let workspaceText = workspace.lowercased()
        let titleText = title.lowercased()
        let objectiveText = objective.lowercased()

        if workspaceText.contains("personal")
            || workspaceText.contains("voice notes")
            || workspaceText.contains("journal") {
            evidence.append(.personalWorkspace)
        }
        if titleText.contains("voice note")
            || titleText.contains("quick note")
            || titleText.contains("personal")
            || titleText.contains("journal")
            || objectiveText.contains("voice note") {
            evidence.append(.personalTitle)
        }
        if isSoloVoiceNote { evidence.append(.soloVoiceNote) }
        if meetingMode == .privateNotes && consentState == .privateCapture {
            evidence.append(.privateCapture)
        }
        return evidence
    }

    private func hasCalendarContext(_ meeting: Meeting) -> Bool {
        if let eventID = meeting.calendarEventID,
           !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return meeting.calendarStartDate != nil || meeting.calendarEndDate != nil
    }

    private func hasVerifiedMeetingContext(
        hasCalendarContext: Bool,
        externalAttendeeCount: Int,
        meetingMode: MeetingMode,
        consentState: ConsentState
    ) -> Bool {
        hasCalendarContext
            || externalAttendeeCount > 0
            || meetingMode != .privateNotes
            || consentState != .privateCapture
    }

    private func hasMeetingLabel(title: String, workspace: String, objective: String) -> Bool {
        let titleText = normalizedText(title)
        let workspaceText = normalizedText(workspace)
        let objectiveText = normalizedText(objective)
        let genericTitles: Set<String> = ["meeting", "live meeting", "new capture", "untitled capture"]

        let titleHasSignal = !genericTitles.contains(titleText) && containsAny(
            ["meeting", "sync", "standup", "interview", "workshop", "review", "qbr"],
            in: titleText
        )
        return titleHasSignal
            || containsAny(["meetings", "client", "customer", "sales"], in: workspaceText)
            || containsAny(["meeting agenda", "meeting objective"], in: objectiveText)
    }

    private func hasCallLabel(title: String, workspace: String) -> Bool {
        containsAny(["call", "phone", "facetime"], in: normalizedText(title + " " + workspace))
    }

    private func isSelfLabel(_ attendee: String) -> Bool {
        let value = attendee.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || ["you", "me", "myself", "i", "self"].contains(value)
    }

    private func score(_ cues: [(String, Int)], in text: String) -> Int {
        cues.reduce(0) { result, cue in
            result + (containsCue(cue.0, in: text) ? cue.1 : 0)
        }
    }

    private func containsAny(_ cues: [String], in text: String) -> Bool {
        cues.contains { containsCue($0, in: text) }
    }

    private func containsCue(_ cue: String, in text: String) -> Bool {
        let normalizedCue = normalizedText(cue)
        guard !normalizedCue.isEmpty else { return false }
        return " \(text) ".contains(" \(normalizedCue) ")
    }

    private func normalizedText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func heuristicTopic(from content: String) -> String? {
        guard !content.isEmpty else { return nil }
        let ignored: Set<String> = [
            "about", "after", "again", "also", "because", "been", "before", "being",
            "could", "did", "does", "doing", "from", "going", "have", "having", "into",
            "just", "like", "make", "maybe", "more", "need", "really", "said", "some",
            "something", "that", "their", "them", "then", "there", "these", "they", "thing",
            "think", "this", "those", "today", "very", "want", "what", "when", "where",
            "which", "will", "with", "would", "your", "youre",
            "action", "actions", "attendee", "attendees", "calendar", "capture",
            "decision", "decisions", "meeting", "notes", "owner", "owners", "prep",
            "review", "risk", "risks", "speaker", "speakers", "summary", "transcript"
        ]
        let words = content.split(separator: " ").map(String.init).filter {
            $0.count >= 4 && !ignored.contains($0)
        }
        guard !words.isEmpty else { return nil }

        var counts: [String: (count: Int, firstIndex: Int)] = [:]
        for (index, word) in words.enumerated() {
            let existing = counts[word] ?? (0, index)
            counts[word] = (existing.count + 1, existing.firstIndex)
        }
        let selected = counts.sorted { left, right in
            if left.value.count == right.value.count {
                return left.value.firstIndex < right.value.firstIndex
            }
            return left.value.count > right.value.count
        }
        .prefix(3)
        .map(\.key)

        guard !selected.isEmpty else { return nil }
        let topic = selected.joined(separator: " ")
        return topic.prefix(1).uppercased() + topic.dropFirst()
    }

    private func domain(for kind: CapturePurposeKind, content: String) -> String {
        if score(healthCues, in: content) >= 2 { return "Health" }
        if score(legalCues, in: content) >= 2 { return "Legal" }
        if score(financeCues, in: content) >= 2 { return "Finance" }
        if kind == .learning { return "Education" }
        if kind.allowsMeetingSignals { return "Work" }
        return "Personal"
    }

    private func deduplicated(_ evidence: [CapturePurposeEvidence]) -> [CapturePurposeEvidence] {
        var seen: Set<CapturePurposeEvidence> = []
        return evidence.filter { seen.insert($0).inserted }
    }

    private let reflectionCues: [(String, Int)] = [
        ("i feel", 3), ("i felt", 3), ("i realized", 3), ("i noticed", 2),
        ("i have been thinking", 3), ("ive been thinking", 3), ("my thoughts", 3),
        ("journal", 4), ("grateful", 3), ("reflection", 4), ("personally", 2)
    ]

    private let ideaCues: [(String, Int)] = [
        ("idea", 3), ("what if", 3), ("imagine", 2), ("concept", 3),
        ("brainstorm", 4), ("possibility", 2), ("could create", 2), ("could build", 2)
    ]

    private let planningCues: [(String, Int)] = [
        ("remember to", 4), ("personal plan", 4), ("my plan", 3), ("i need to", 2),
        ("i want to", 2), ("this weekend", 2), ("tomorrow i", 2), ("to do", 3),
        ("shopping list", 4), ("packing list", 4)
    ]

    private let relationshipCues: [(String, Int)] = [
        ("family", 2), ("friend", 2), ("partner", 2), ("husband", 2), ("wife", 2),
        ("mom", 2), ("mother", 2), ("dad", 2), ("father", 2), ("dinner", 1),
        ("vacation", 2), ("home", 1), ("weekend", 1)
    ]

    private let appointmentCues: [(String, Int)] = [
        ("appointment", 3), ("doctor", 4), ("dentist", 4), ("therapist", 4),
        ("lawyer", 4), ("physician", 4), ("symptom", 3), ("symptoms", 3),
        ("medication", 3), ("prescription", 3), ("diagnosis", 3), ("treatment", 3),
        ("consultation", 3)
    ]

    private let learningCues: [(String, Int)] = [
        ("lecture", 4), ("lesson", 3), ("class", 3), ("course", 3), ("study", 2),
        ("chapter", 3), ("professor", 4), ("teacher", 3), ("definition", 2),
        ("i learned", 3), ("key concept", 3)
    ]

    private let workCues: [(String, Int)] = [
        ("client", 3), ("customer", 3), ("project", 2), ("roadmap", 3),
        ("sprint", 3), ("stakeholder", 3), ("deliverable", 3), ("deadline", 2),
        ("launch", 2), ("quarter", 2), ("revenue", 3), ("pipeline", 3),
        ("product", 2), ("engineering", 2), ("sales", 3), ("manager", 2),
        ("team", 1), ("budget", 2), ("proposal", 2), ("contract", 2)
    ]

    private let structuredMeetingCues: [(String, Int)] = [
        ("we agreed", 3), ("we decided", 3), ("action item", 3), ("next step", 2),
        ("meeting agenda", 3), ("follow up", 1), ("owner", 2), ("due date", 2),
        ("blocker", 2), ("status update", 2)
    ]

    private let healthCues: [(String, Int)] = [
        ("doctor", 3), ("symptom", 2), ("symptoms", 2), ("medication", 2),
        ("prescription", 2), ("diagnosis", 2), ("treatment", 2), ("health", 2)
    ]

    private let legalCues: [(String, Int)] = [
        ("lawyer", 3), ("legal", 2), ("court", 3), ("attorney", 3),
        ("agreement", 1), ("liability", 2), ("claim", 2)
    ]

    private let financeCues: [(String, Int)] = [
        ("bank", 2), ("mortgage", 3), ("investment", 2), ("tax", 2),
        ("budget", 1), ("debt", 2), ("loan", 2), ("finance", 2)
    ]
}
