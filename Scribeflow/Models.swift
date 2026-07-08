import Foundation

enum MeetingStatus: String, Codable, CaseIterable, Identifiable {
    case live
    case ready
    case shared

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live:
            "Live"
        case .ready:
            "Ready"
        case .shared:
            "Shared"
        }
    }
}

enum NoteTemplate: String, Codable, CaseIterable, Identifiable {
    case discovery
    case exec
    case manager
    case standup
    case interview
    case brainstorm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discovery:
            "Discovery"
        case .exec:
            "Exec"
        case .manager:
            "1:1 Coach"
        case .standup:
            "Standup"
        case .interview:
            "Interview"
        case .brainstorm:
            "Brainstorm"
        }
    }

    var description: String {
        switch self {
        case .discovery:
            "Pulls out buyer pain, signals, and next steps."
        case .exec:
            "Summarizes the meeting for fast leadership review."
        case .manager:
            "Frames the conversation as coaching and follow-through."
        case .standup:
            "Pulls blockers, progress, and ownership from a daily or weekly sync."
        case .interview:
            "Captures candidate signals, fit indicators, and hiring decision rationale."
        case .brainstorm:
            "Organizes ideas, themes, and next moves from a working session."
        }
    }
}

// MARK: - Meeting Context Mode (Tier 2: Adaptive Modes)

enum MeetingContextMode: String, Codable, CaseIterable, Identifiable {
    case general
    case coaching
    case sales
    case legal
    case medical
    case founder
    case product

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:  "General"
        case .coaching: "Coach"
        case .sales:    "Sales"
        case .legal:    "Legal"
        case .medical:  "Medical"
        case .founder:  "Founder"
        case .product:  "Product"
        }
    }

    var systemImage: String {
        switch self {
        case .general:  "doc.text.fill"
        case .coaching: "figure.mind.and.body"
        case .sales:    "chart.line.uptrend.xyaxis"
        case .legal:    "building.columns.fill"
        case .medical:  "cross.circle.fill"
        case .founder:  "lightbulb.fill"
        case .product:  "cpu.fill"
        }
    }

    var description: String {
        switch self {
        case .general:  "Balanced capture for any meeting."
        case .coaching: "Goals, blockers, and growth signals."
        case .sales:    "Pain, objections, and next steps."
        case .legal:    "Facts, risks, and exact language."
        case .medical:  "Symptoms, plans, and follow-ups."
        case .founder:  "Decisions, priorities, investor signals."
        case .product:  "Specs, dependencies, ship criteria."
        }
    }

    var aiHint: String {
        switch self {
        case .general:
            "Summarize with key decisions, action items, and important context."
        case .coaching:
            "Focus on goals, personal growth signals, blockers, and accountability. Note every commitment made."
        case .sales:
            "Extract buyer pain points, objections raised, signals of intent, and agreed next steps."
        case .legal:
            "Capture exact language around commitments, risks, liabilities, conditions, and deadlines."
        case .medical:
            "Summarize symptoms discussed, diagnoses mentioned, treatment plans, and follow-up instructions."
        case .founder:
            "Focus on strategic decisions, investor concerns, product priorities, and key metrics."
        case .product:
            "Extract feature specs, technical dependencies, acceptance criteria, and ship dates."
        }
    }
}

// MARK: - Meeting Score (Tier 2: Meeting Score Card)

struct MeetingScore: Codable, Hashable {
    var clarity: Int
    var decisiveness: Int
    var actionability: Int
    var overall: Int
    var insight: String
    var scoredAt: Date
}

// MARK: - Action Check (Tier 1: Post-Meeting Accountability Loop)

enum ActionCheckStatus: String, Codable, CaseIterable {
    case pending
    case done
    case skipped
}

struct ActionCheck: Codable, Identifiable {
    var id = UUID()
    var meetingID: Meeting.ID
    var meetingTitle: String
    var text: String
    var owner: String
    var meetingDate: Date
    var status: ActionCheckStatus
    var resolvedAt: Date?
}

// MARK: - Voice Memo (Tier 3: Quick Voice Capture)

struct VoiceMemo: Codable, Identifiable {
    var id = UUID()
    var createdAt: Date
    var durationSeconds: Int
    var transcript: String
    var title: String
}

// MARK: - People Intelligence (Tier 2: People Intelligence Cards)

struct PersonIntelligence: Identifiable {
    var id: String { name }
    var name: String
    var meetings: [Meeting]
    var openCommitments: [Commitment]
    var topTopics: [String]
    var lastMeetingDate: Date?
    var daysSinceLastMeeting: Int?

    var totalMeetings: Int { meetings.count }
}

enum NoteRewriteStyle: String, CaseIterable, Identifiable {
    case concise
    case detailed
    case executive
    case actionFocused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .concise:
            "Concise"
        case .detailed:
            "Detailed"
        case .executive:
            "Executive"
        case .actionFocused:
            "Action"
        }
    }

    var helperText: String {
        switch self {
        case .concise:
            "Short, crisp bullets for fast review."
        case .detailed:
            "Richer context that still reads cleanly."
        case .executive:
            "Higher-level summary for leadership updates."
        case .actionFocused:
            "Pushes ownership, next steps, and follow-through."
        }
    }
}

enum MeetingExportFormat: String, CaseIterable, Identifiable {
    case internalBrief
    case clientRecap
    case execUpdate
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .internalBrief:
            "Internal brief"
        case .clientRecap:
            "Client recap"
        case .execUpdate:
            "Exec update"
        case .markdown:
            "Markdown"
        }
    }
}

struct SummarySection: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var bullets: [String]
}

struct MeetingSummary: Codable, Hashable {
    var eyebrow: String
    var title: String
    var sections: [SummarySection]
}

struct TemplateSummary: Codable, Hashable, Identifiable {
    var id = UUID()
    var template: NoteTemplate
    var summary: MeetingSummary
}

struct TranscriptLine: Codable, Hashable, Identifiable {
    var id = UUID()
    var speaker: String
    var role: String
    var text: String
}

struct AIResponse: Codable, Hashable, Identifiable {
    var id = UUID()
    var prompt: String
    var answer: String
}

struct WorkspaceFolder: Hashable, Identifiable {
    var id: String { name }
    var name: String
    var description: String
    var meetingCount: Int
    var latestMeetingDate: Date
}

enum WorkspaceRecipe: String, CaseIterable, Identifiable {
    case prepMe
    case decisions
    case actions
    case themes
    case brief

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prepMe:
            "Prep me"
        case .decisions:
            "Decisions"
        case .actions:
            "Action items"
        case .themes:
            "Themes"
        case .brief:
            "Write brief"
        }
    }

    var prompt: String {
        switch self {
        case .prepMe:
            "Prepare me for my next conversation using these meetings. Give top context, unresolved risks, and what I should ask next."
        case .decisions:
            "List the clearest decisions across these meetings with source references."
        case .actions:
            "Extract concrete action items with likely owner and next step."
        case .themes:
            "Spot recurring themes and patterns across these meetings."
        case .brief:
            "Write a concise status brief I can send to my team."
        }
    }
}

enum ChatModelSelection: String, CaseIterable, Identifiable {
    case auto
    case fast
    case deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            "Auto"
        case .fast:
            "Fast"
        case .deep:
            "Deep"
        }
    }

    var helperText: String {
        switch self {
        case .auto:
            "Auto switches style based on context."
        case .fast:
            "Fast is tuned for quick, concise answers."
        case .deep:
            "Deep spends more room on cross-meeting analysis."
        }
    }
}

enum SmartCollectionKind: String, CaseIterable, Identifiable {
    case all
    case followUp
    case calls
    case pinned
    case shared

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .followUp:
            "Follow-up"
        case .calls:
            "Calls"
        case .pinned:
            "Pinned"
        case .shared:
            "Shared"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "rectangle.stack.fill"
        case .followUp:
            "checklist"
        case .calls:
            "phone.fill"
        case .pinned:
            "pin.fill"
        case .shared:
            "square.and.arrow.up.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .all:
            "Everything in one place"
        case .followUp:
            "Needs a next move"
        case .calls:
            "Phone and FaceTime notes"
        case .pinned:
            "Your most important notes"
        case .shared:
            "Already sent out"
        }
    }
}

struct SmartCollectionCard: Identifiable, Hashable {
    var id: SmartCollectionKind { kind }
    var kind: SmartCollectionKind
    var count: Int
}

struct WorkspaceSignal: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var detail: String
    var systemImage: String
}

enum OpenLoopKind: String, Hashable, CaseIterable, Identifiable {
    case action
    case risk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .action:
            "Action"
        case .risk:
            "Risk"
        }
    }

    var systemImage: String {
        switch self {
        case .action:
            "checkmark.circle.fill"
        case .risk:
            "exclamationmark.triangle.fill"
        }
    }
}

enum SignalWeights {
    static let terms: [(String, Int)] = [
        ("need", 5), ("needs", 5), ("must", 5), ("decision", 5),
        ("next", 5), ("follow up", 5),
        ("timeline", 4), ("budget", 4), ("risk", 4), ("security", 4),
        ("priority", 4), ("problem", 4), ("issue", 4),
        ("launch", 3), ("mobile", 3), ("integration", 3), ("owner", 3),
    ]
}

struct MeetingSignals: Hashable {
    var decisions: [String]
    var actions: [String]
    var risks: [String]
    var questions: [String] = []
}

struct OpenLoop: Identifiable, Hashable {
    var id = UUID()
    var meetingID: Meeting.ID
    var meetingTitle: String
    var workspace: String
    var kind: OpenLoopKind
    var text: String
}

struct PrepBrief: Hashable {
    var headline: String
    var bullets: [String]
    var questions: [String]
}

enum MeetingMode: String, Codable, CaseIterable, Identifiable {
    case privateNotes
    case internalShared
    case clientSafeRecap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privateNotes:
            "Private notes"
        case .internalShared:
            "Internal shared note"
        case .clientSafeRecap:
            "Client-safe recap"
        }
    }

    var helperText: String {
        switch self {
        case .privateNotes:
            "Best for rough thinking, personal notes, and internal context."
        case .internalShared:
            "Best for team-visible notes with fuller transcript context."
        case .clientSafeRecap:
            "Best for polished external recap with safer defaults."
        }
    }
}

enum ConsentState: String, Codable, CaseIterable, Identifiable {
    case privateCapture
    case disclosedInternal
    case disclosedExternal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privateCapture:
            "Private"
        case .disclosedInternal:
            "Disclosed internally"
        case .disclosedExternal:
            "Disclosed to external participants"
        }
    }
}

enum RetentionPolicy: String, Codable, CaseIterable, Identifiable {
    case notesOnly
    case transcript24Hours
    case transcript7Days
    case keepUntilDeleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notesOnly:
            "Notes only"
        case .transcript24Hours:
            "Transcript for 24 hours"
        case .transcript7Days:
            "Transcript for 7 days"
        case .keepUntilDeleted:
            "Keep until deleted"
        }
    }
}

enum EvidenceLevel: String, Codable, CaseIterable, Identifiable {
    case verified
    case inferred
    case personalNote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verified:
            "Verified"
        case .inferred:
            "Inferred"
        case .personalNote:
            "Personal note"
        }
    }
}

enum EvidenceFilter: String, CaseIterable, Identifiable {
    case all
    case verifiedOnly
    case hideInferred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .verifiedOnly:
            "Verified only"
        case .hideInferred:
            "Hide inferred"
        }
    }
}

struct EvidenceItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var level: EvidenceLevel
    var supportingSnippets: [String]

    var confidenceLabel: String {
        switch level {
        case .verified:
            "High confidence"
        case .inferred:
            "Needs review"
        case .personalNote:
            "Personal note"
        }
    }
}

enum CommitmentStatus: String, Codable, CaseIterable, Identifiable {
    case open
    case atRisk
    case fulfilled
    case superseded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open:
            "Open"
        case .atRisk:
            "At risk"
        case .fulfilled:
            "Fulfilled"
        case .superseded:
            "Skipped"
        }
    }
}

struct Commitment: Codable, Hashable, Identifiable {
    var id = UUID()
    var statement: String
    var owner: String
    var sourceSpeaker: String
    var dueHint: String?
    var dueDateOverride: Date? = nil
    var status: CommitmentStatus
    /// Model-assigned priority ("high" / "medium" / "low") — drives ranking and
    /// the urgency flag. Optional so old data and the heuristic path stay valid.
    var priority: String? = nil
    /// One line on why this matters, so a task isn't just a verb with no stakes.
    var rationale: String? = nil
}

enum SensitiveFlag: String, Codable, CaseIterable, Identifiable {
    case names
    case pricing
    case roadmap
    case security
    case internalOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .names:
            "Names"
        case .pricing:
            "Pricing"
        case .roadmap:
            "Roadmap"
        case .security:
            "Security / legal"
        case .internalOnly:
            "Internal only"
        }
    }
}

/// A meeting brief produced by the on-device language model — structured,
/// typo-corrected, and comprehension-based (vs. the keyword heuristic). Stored
/// on the meeting so the synchronous UI can read it; nil when the model wasn't
/// available, in which case the heuristic engine is used instead.
struct AIBriefData: Codable, Hashable {
    var summary: String = ""
    var decisions: [String] = []
    var actions: [AIActionItem] = []
    var openQuestions: [String] = []
    var keyPoints: [String] = []
    var risks: [String] = []
    /// Granola-style: each note the user wrote, expanded with AI context while
    /// keeping their words as the anchor.
    var enhancedNotes: [EnhancedNoteData] = []
    /// Sections specific to the meeting type that aren't already a decision,
    /// action, question, or risk — e.g. standup Done/In progress, sales
    /// Budget/Stakeholders, 1:1 Looking ahead. Empty for a general meeting.
    var sections: [AIBriefSection] = []
    /// False when the input is random/meaningless — the app then says so instead
    /// of fabricating structure. True for real (even if rough) notes.
    var makesSense: Bool = true
    /// Genuinely unclear points the user should clarify — surfaced, never guessed.
    var needsClarification: [String] = []

    var isEmpty: Bool {
        summary.isEmpty && decisions.isEmpty && actions.isEmpty
            && openQuestions.isEmpty && keyPoints.isEmpty && risks.isEmpty
            && enhancedNotes.isEmpty && sections.isEmpty && needsClarification.isEmpty
    }
}

/// A model-chosen, meeting-type-specific section (heading + bullets).
struct AIBriefSection: Codable, Hashable {
    var heading: String
    var items: [String] = []
}

struct AIActionItem: Codable, Hashable {
    var task: String
    var owner: String = ""
    var due: String = ""
    var priority: String = ""   // high / medium / low
    var why: String = ""        // why it matters
}

/// A user note kept verbatim (`anchor`) plus the context the model added
/// around it (`detail`) — rendered as your words + AI detail, visually distinct.
struct EnhancedNoteData: Codable, Hashable {
    var anchor: String
    var detail: String = ""
}

struct Meeting: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var workspace: String
    var when: Date
    var durationMinutes: Int
    var attendees: [String]
    var status: MeetingStatus
    var stage: String
    var objective: String
    var rawNotes: String
    var transcript: [TranscriptLine]
    var summaries: [TemplateSummary]
    var prompts: [AIResponse]
    var destinations: [String]
    var selectedTemplate: NoteTemplate
    var selectedPromptID: AIResponse.ID?
    var isPinned: Bool
    var consentState: ConsentState = .privateCapture
    var meetingMode: MeetingMode = .privateNotes
    var retentionPolicy: RetentionPolicy = .keepUntilDeleted
    var evidenceItems: [EvidenceItem] = []
    var commitments: [Commitment] = []
    var sensitiveFlags: [SensitiveFlag] = []
    var transcriptVisibilityEnabled: Bool = true
    var contextMode: MeetingContextMode = .general
    var score: MeetingScore? = nil
    var audioRecordings: [AudioRecordingAttachment] = []
    var aiBrief: AIBriefData? = nil
    var calendarEventID: String? = nil
    var calendarStartDate: Date? = nil
    var calendarEndDate: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case workspace
        case when
        case durationMinutes
        case attendees
        case status
        case stage
        case objective
        case rawNotes
        case transcript
        case summaries
        case prompts
        case destinations
        case selectedTemplate
        case selectedPromptID
        case isPinned
        case consentState
        case meetingMode
        case retentionPolicy
        case evidenceItems
        case commitments
        case sensitiveFlags
        case transcriptVisibilityEnabled
        case contextMode
        case score
        case audioRecordings
        case aiBrief
        case calendarEventID
        case calendarStartDate
        case calendarEndDate
    }

    init(
        id: UUID = UUID(),
        title: String,
        workspace: String,
        when: Date,
        durationMinutes: Int,
        attendees: [String],
        status: MeetingStatus,
        stage: String,
        objective: String,
        rawNotes: String,
        transcript: [TranscriptLine],
        summaries: [TemplateSummary],
        prompts: [AIResponse],
        destinations: [String],
        selectedTemplate: NoteTemplate,
        selectedPromptID: AIResponse.ID?,
        isPinned: Bool,
        consentState: ConsentState = .privateCapture,
        meetingMode: MeetingMode = .privateNotes,
        retentionPolicy: RetentionPolicy = .keepUntilDeleted,
        evidenceItems: [EvidenceItem] = [],
        commitments: [Commitment] = [],
        sensitiveFlags: [SensitiveFlag] = [],
        transcriptVisibilityEnabled: Bool = true,
        contextMode: MeetingContextMode = .general,
        score: MeetingScore? = nil,
        audioRecordings: [AudioRecordingAttachment] = [],
        aiBrief: AIBriefData? = nil,
        calendarEventID: String? = nil,
        calendarStartDate: Date? = nil,
        calendarEndDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.workspace = workspace
        self.when = when
        self.durationMinutes = durationMinutes
        self.attendees = attendees
        self.status = status
        self.stage = stage
        self.objective = objective
        self.rawNotes = rawNotes
        self.transcript = transcript
        self.summaries = summaries
        self.prompts = prompts
        self.destinations = destinations
        self.selectedTemplate = selectedTemplate
        self.selectedPromptID = selectedPromptID
        self.isPinned = isPinned
        self.consentState = consentState
        self.meetingMode = meetingMode
        self.retentionPolicy = retentionPolicy
        self.evidenceItems = evidenceItems
        self.commitments = commitments
        self.sensitiveFlags = sensitiveFlags
        self.transcriptVisibilityEnabled = transcriptVisibilityEnabled
        self.contextMode = contextMode
        self.score = score
        self.audioRecordings = audioRecordings
        self.aiBrief = aiBrief
        self.calendarEventID = calendarEventID
        self.calendarStartDate = calendarStartDate
        self.calendarEndDate = calendarEndDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        workspace = try container.decode(String.self, forKey: .workspace)
        when = try container.decode(Date.self, forKey: .when)
        durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)
        attendees = try container.decode([String].self, forKey: .attendees)
        status = try container.decode(MeetingStatus.self, forKey: .status)
        stage = try container.decode(String.self, forKey: .stage)
        objective = try container.decode(String.self, forKey: .objective)
        rawNotes = try container.decode(String.self, forKey: .rawNotes)
        transcript = try container.decode([TranscriptLine].self, forKey: .transcript)
        summaries = try container.decode([TemplateSummary].self, forKey: .summaries)
        prompts = try container.decode([AIResponse].self, forKey: .prompts)
        destinations = try container.decode([String].self, forKey: .destinations)
        selectedTemplate = try container.decode(NoteTemplate.self, forKey: .selectedTemplate)
        selectedPromptID = try container.decodeIfPresent(AIResponse.ID.self, forKey: .selectedPromptID)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        consentState = try container.decodeIfPresent(ConsentState.self, forKey: .consentState) ?? .privateCapture
        meetingMode = try container.decodeIfPresent(MeetingMode.self, forKey: .meetingMode) ?? .privateNotes
        retentionPolicy = try container.decodeIfPresent(RetentionPolicy.self, forKey: .retentionPolicy) ?? .keepUntilDeleted
        evidenceItems = try container.decodeIfPresent([EvidenceItem].self, forKey: .evidenceItems) ?? []
        commitments = try container.decodeIfPresent([Commitment].self, forKey: .commitments) ?? []
        sensitiveFlags = try container.decodeIfPresent([SensitiveFlag].self, forKey: .sensitiveFlags) ?? []
        transcriptVisibilityEnabled = try container.decodeIfPresent(Bool.self, forKey: .transcriptVisibilityEnabled) ?? true
        contextMode = try container.decodeIfPresent(MeetingContextMode.self, forKey: .contextMode) ?? .general
        score = try container.decodeIfPresent(MeetingScore.self, forKey: .score)
        audioRecordings = try container.decodeIfPresent([AudioRecordingAttachment].self, forKey: .audioRecordings) ?? []
        // Tolerate schema drift in the AI brief: if an older/newer shape can't
        // decode, drop it (the heuristic takes over and it regenerates) rather
        // than failing the whole meeting load.
        aiBrief = (try? container.decodeIfPresent(AIBriefData.self, forKey: .aiBrief)) ?? nil
        calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
        calendarStartDate = try container.decodeIfPresent(Date.self, forKey: .calendarStartDate)
        calendarEndDate = try container.decodeIfPresent(Date.self, forKey: .calendarEndDate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(when, forKey: .when)
        try container.encode(durationMinutes, forKey: .durationMinutes)
        try container.encode(attendees, forKey: .attendees)
        try container.encode(status, forKey: .status)
        try container.encode(stage, forKey: .stage)
        try container.encode(objective, forKey: .objective)
        try container.encode(rawNotes, forKey: .rawNotes)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(summaries, forKey: .summaries)
        try container.encode(prompts, forKey: .prompts)
        try container.encode(destinations, forKey: .destinations)
        try container.encode(selectedTemplate, forKey: .selectedTemplate)
        try container.encodeIfPresent(selectedPromptID, forKey: .selectedPromptID)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(consentState, forKey: .consentState)
        try container.encode(meetingMode, forKey: .meetingMode)
        try container.encode(retentionPolicy, forKey: .retentionPolicy)
        try container.encode(evidenceItems, forKey: .evidenceItems)
        try container.encode(commitments, forKey: .commitments)
        try container.encode(sensitiveFlags, forKey: .sensitiveFlags)
        try container.encode(transcriptVisibilityEnabled, forKey: .transcriptVisibilityEnabled)
        try container.encode(contextMode, forKey: .contextMode)
        try container.encodeIfPresent(score, forKey: .score)
        try container.encode(audioRecordings, forKey: .audioRecordings)
        try container.encodeIfPresent(aiBrief, forKey: .aiBrief)
        try container.encodeIfPresent(calendarEventID, forKey: .calendarEventID)
        try container.encodeIfPresent(calendarStartDate, forKey: .calendarStartDate)
        try container.encodeIfPresent(calendarEndDate, forKey: .calendarEndDate)
    }
}

extension Meeting {
    /// Returns the currently selected AI response. Falls back to the first
    /// prompt, then a placeholder if `prompts` is empty (previously crashed
    /// with `prompts[0]` on out-of-bounds access).
    var selectedPrompt: AIResponse {
        prompts.first(where: { $0.id == selectedPromptID })
            ?? prompts.first
            ?? AIResponse(prompt: "", answer: "")
    }

    func summary(for template: NoteTemplate) -> MeetingSummary {
        summaries.first(where: { $0.template == template })?.summary
        ?? summaries.first?.summary
        ?? MeetingSummary(
            eyebrow: "AI view",
            title: "No summary available yet.",
            sections: []
        )
    }
}

extension Meeting {
    var isCallMeeting: Bool {
        workspace.localizedCaseInsensitiveContains("call")
            || workspace.localizedCaseInsensitiveContains("phone")
            || title.lowercased().contains("call")
            || audioRecordings.contains { $0.source == .compliantCall }
    }

    static func sortDescending(_ lhs: Meeting, _ rhs: Meeting) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return lhs.when > rhs.when
    }
}

extension Commitment {
    var formattedLine: String {
        var parts = [statement]
        if owner != "Owner not named" { parts.append("Owner: \(owner)") }
        if let dueHint { parts.append("Timing: \(dueHint)") }
        if status != .open { parts.append(status.title) }
        return parts.joined(separator: " — ")
    }
}

extension Meeting {
    static let seed: [Meeting] = [
        Meeting(
            title: "Intro call: AllFound",
            workspace: "Pipeline · Expansion",
            when: .now.addingTimeInterval(-900),
            durationMinutes: 31,
            attendees: ["Maya", "Leo", "Priya", "Jon"],
            status: .ready,
            stage: "Captured and ready to review",
            objective: "Understand buying committee, timing, and why Tuesday.ai is failing them.",
            rawNotes: """
            - 100 employees and hiring quickly
            - Current tool is too manual for non-technical teams
            - Security review is mandatory before rollout
            - Wants a mobile-friendly experience for managers on the road
            - Migration decision is a Q2 priority
            - I'll send the mobile workflow examples and permission model by Friday
            - Maya to book the security walkthrough with Jon next week
            """,
            transcript: [
                TranscriptLine(speaker: "Maya", role: "AE", text: "Can you walk me through what pushed this project to the top of the queue right now?"),
                TranscriptLine(speaker: "Priya", role: "Ops lead", text: "Our current workflow depends on too much copy and paste, and managers have basically stopped updating it."),
                TranscriptLine(speaker: "Leo", role: "Founder", text: "If we switch, it has to feel lightweight. People will not tolerate another tool that demands ceremony."),
                TranscriptLine(speaker: "Maya", role: "AE", text: "Got it. So adoption matters as much as the intelligence layer."),
                TranscriptLine(speaker: "Jon", role: "Security", text: "As long as we can understand retention, sharing controls, and permissions, I can fast-track the review."),
            ],
            summaries: [
                TemplateSummary(
                    template: .discovery,
                    summary: MeetingSummary(
                        eyebrow: "Auto draft",
                        title: "AllFound wants a faster, lower-friction system before Q2 planning locks.",
                        sections: [
                            SummarySection(title: "What matters most", bullets: [
                                "Current tool is too manual for non-technical teams.",
                                "Mobile support is a must-have for field managers.",
                                "Security review is required but not expected to block if permissions are clear.",
                            ]),
                            SummarySection(title: "Signals", bullets: [
                                "Buying urgency is real because adoption has already dropped.",
                                "Founder is optimizing for simplicity, not just feature count.",
                                "Budget pressure suggests we should lead with time saved, not premium positioning.",
                            ]),
                            SummarySection(title: "Next moves", bullets: [
                                "Send mobile workflow examples and permission model.",
                                "Frame rollout as a low-ceremony replacement, not a process overhaul.",
                                "Book security plus champion follow-up this week.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .exec,
                    summary: MeetingSummary(
                        eyebrow: "Exec view",
                        title: "Deal momentum is healthy, with adoption risk and security clarity as the two leverage points.",
                        sections: [
                            SummarySection(title: "Snapshot", bullets: [
                                "Prospect has clear dissatisfaction with incumbent workflow.",
                                "Decision target sits in Q2 planning cycle.",
                                "Differentiation should center on simplicity and mobile usability.",
                            ]),
                            SummarySection(title: "Risks", bullets: [
                                "Security review could stall if retention and sharing model are vague.",
                                "Price sensitivity remains in play because the incumbent is seen as expensive.",
                            ]),
                            SummarySection(title: "Recommended action", bullets: [
                                "Package one concise follow-up with mobile proof, security FAQ, and rollout path.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .manager,
                    summary: MeetingSummary(
                        eyebrow: "Coaching angle",
                        title: "Discovery was strong; the best coaching opportunity is tightening follow-up around the champion path.",
                        sections: [
                            SummarySection(title: "Rep strengths", bullets: [
                                "Good urgency probe early in the call.",
                                "Reflected priorities back clearly and earned alignment.",
                            ]),
                            SummarySection(title: "Coach next", bullets: [
                                "Open the follow-up by confirming business pain, then ask for the economic buyer explicitly.",
                            ]),
                        ]
                    )
                ),
            ],
            prompts: [
                AIResponse(prompt: "Write follow-up", answer: "Thanks again for the conversation today. I would send a short recap focused on mobile workflow, low-lift rollout, and the security controls Jon asked about, then propose a 30-minute working session with Priya and security."),
                AIResponse(prompt: "List objections", answer: "The biggest objections are hidden adoption cost, fear of adding process overhead, and uncertainty around retention and permissions."),
                AIResponse(prompt: "What is the budget?", answer: "No explicit number was confirmed. The useful signal is that the incumbent is seen as expensive, so the deal needs a savings story rather than a premium story."),
            ],
            destinations: ["Email all participants", "#user-feedback", "CRM", "Public link"],
            selectedTemplate: .discovery,
            selectedPromptID: nil,
            isPinned: true
        ),
        Meeting(
            title: "Design crit: onboarding",
            workspace: "Product team",
            when: .now.addingTimeInterval(-8_100),
            durationMinutes: 42,
            attendees: ["Rina", "Harsh", "Selena"],
            status: .ready,
            stage: "Auto-structured from notes",
            objective: "Stress-test the first-run activation flow before the beta push.",
            rawNotes: """
            - Empty state still feels too enterprise
            - Team liked the progress preview animation
            - Clarify import options sooner
            - Need a friendlier way to explain privacy and recording
            """,
            transcript: [
                TranscriptLine(speaker: "Rina", role: "Design", text: "The first screen still feels like a setup wizard instead of a welcoming product moment."),
                TranscriptLine(speaker: "Harsh", role: "PM", text: "The motion is doing good work though. People immediately understand that the notes get transformed for them."),
                TranscriptLine(speaker: "Selena", role: "Research", text: "Privacy reassurance should appear before we ask for any audio permissions."),
            ],
            summaries: [
                TemplateSummary(
                    template: .discovery,
                    summary: MeetingSummary(
                        eyebrow: "Design synthesis",
                        title: "The team wants onboarding to feel warmer and more trust-building before permissions appear.",
                        sections: [
                            SummarySection(title: "Takeaways", bullets: [
                                "First screen feels too operational and not enough like a product reveal.",
                                "Motion preview earned strong positive feedback.",
                                "Privacy copy should land earlier.",
                            ]),
                            SummarySection(title: "Suggested revisions", bullets: [
                                "Lead with a sample note transformation before asking for setup choices.",
                                "Pull import options closer to the top of the flow.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .exec,
                    summary: MeetingSummary(
                        eyebrow: "Team update",
                        title: "Beta is on track, but onboarding trust and tone need refinement before launch.",
                        sections: [
                            SummarySection(title: "Progress", bullets: [
                                "Interaction design is landing well.",
                                "Concerns are contained to onboarding tone and permissions framing.",
                            ]),
                            SummarySection(title: "Needed before beta", bullets: [
                                "Rewrite privacy language and simplify the opening state.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .manager,
                    summary: MeetingSummary(
                        eyebrow: "1:1 coach",
                        title: "Collaboration looked healthy; the team challenged the work without slipping into vague feedback.",
                        sections: [
                            SummarySection(title: "Team patterns", bullets: [
                                "Design and research aligned quickly on trust messaging.",
                                "PM kept feedback anchored to launch goals.",
                            ]),
                        ]
                    )
                ),
            ],
            prompts: [
                AIResponse(prompt: "Write summary", answer: "The team agreed onboarding needs to feel more welcoming before it asks for permissions. The strongest concept in the room was the transformation preview, which should become the emotional anchor for the opening sequence."),
                AIResponse(prompt: "List risks", answer: "The main risk is user trust. If privacy explanation lands too late, people may bounce before they understand why the app needs access."),
                AIResponse(prompt: "What is next week's plan?", answer: "Rewrite the opening copy, move privacy reassurance higher, prototype a warmer empty state, and validate whether import options should appear earlier or later."),
            ],
            destinations: ["Project updates", "#meeting-notes", "Public link"],
            selectedTemplate: .discovery,
            selectedPromptID: nil,
            isPinned: false
        ),
        Meeting(
            title: "Staff sync: roadmap tradeoffs",
            workspace: "Leadership",
            when: .now.addingTimeInterval(-86_400),
            durationMinutes: 55,
            attendees: ["Nina", "Owen", "Tariq", "Mika"],
            status: .shared,
            stage: "Shared to leadership channel",
            objective: "Decide what slips if audio search ships in May.",
            rawNotes: """
            - Audio search is still the bet
            - If we ship it in May, the new workspace import slips by 2 weeks
            - Need explicit owner for support plan
            - Team wants an exec summary before Friday
            """,
            transcript: [
                TranscriptLine(speaker: "Nina", role: "CEO", text: "If audio search really changes retention, I am comfortable slipping import as long as we tell customers clearly."),
                TranscriptLine(speaker: "Owen", role: "Engineering", text: "The real cost is support load. We need someone to own messaging and edge cases."),
            ],
            summaries: [
                TemplateSummary(
                    template: .discovery,
                    summary: MeetingSummary(
                        eyebrow: "Roadmap notes",
                        title: "Leadership will trade import timing for audio search if support and comms are owned.",
                        sections: [
                            SummarySection(title: "Decision", bullets: [
                                "Audio search remains the strategic bet.",
                                "Workspace import can slip by roughly two weeks if customer messaging is crisp.",
                            ]),
                            SummarySection(title: "Open item", bullets: [
                                "Assign one owner for support readiness and edge-case triage.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .exec,
                    summary: MeetingSummary(
                        eyebrow: "Exec update",
                        title: "Tentative prioritization favors audio search, pending a support plan.",
                        sections: [
                            SummarySection(title: "Implication", bullets: [
                                "May launch can proceed if import delay is framed as deliberate focus.",
                            ]),
                            SummarySection(title: "Before Friday", bullets: [
                                "Produce an executive summary and assign support ownership.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .manager,
                    summary: MeetingSummary(
                        eyebrow: "Manager view",
                        title: "The team aligned on the bet, but ownership around rollout burden is still fuzzy.",
                        sections: [
                            SummarySection(title: "Leadership dynamic", bullets: [
                                "Decision quality was high because tradeoffs were explicit.",
                                "Risk is not strategy disagreement, it is operational ambiguity.",
                            ]),
                        ]
                    )
                ),
            ],
            prompts: [
                AIResponse(prompt: "Who owns what?", answer: "Nina owns the strategic call, Owen likely owns technical readiness, and there is still a gap around support ownership that needs to be named explicitly."),
                AIResponse(prompt: "Write exec summary", answer: "Proceed with audio search as the headline May investment and accept a short slip in workspace import, provided support readiness and customer messaging are assigned this week."),
            ],
            destinations: ["Leadership brief", "Email all participants"],
            selectedTemplate: .exec,
            selectedPromptID: nil,
            isPinned: true
        ),
        Meeting(
            title: "Team standup: Week 18",
            workspace: "Product team",
            when: .now.addingTimeInterval(-3 * 3600),
            durationMinutes: 18,
            attendees: ["Harsh", "Rina", "Dev", "Selena"],
            status: .ready,
            stage: "Captured and ready to review",
            objective: "Surface blockers and align on sprint priorities before the afternoon push.",
            rawNotes: """
            - Dev: blocked on API contract for notification service
            - Rina: design handoff for onboarding is done
            - Harsh: sprint review prep needs owner
            - Selena: user interviews scheduled for Thursday
            - Blocker: need backend sign-off before notification feature can move to QA
            """,
            transcript: [
                TranscriptLine(speaker: "Harsh", role: "PM", text: "Dev, what is blocking you right now?"),
                TranscriptLine(speaker: "Dev", role: "Engineering", text: "The API contract for the notification service is still not finalized. I cannot start integration until that is locked."),
                TranscriptLine(speaker: "Rina", role: "Design", text: "My side is unblocked. Onboarding handoff is done and in Figma."),
                TranscriptLine(speaker: "Selena", role: "Research", text: "Thursday interviews are confirmed. I need someone to observe one session if possible."),
            ],
            summaries: [
                TemplateSummary(
                    template: .standup,
                    summary: MeetingSummary(
                        eyebrow: "Standup digest",
                        title: "One blocker on notification integration; everything else is moving.",
                        sections: [
                            SummarySection(title: "Blockers", bullets: [
                                "API contract for notification service unsigned, blocking Dev's integration work.",
                                "Backend sign-off required before QA handoff.",
                            ]),
                            SummarySection(title: "Progress", bullets: [
                                "Onboarding design handoff is complete and in Figma.",
                                "User interviews confirmed for Thursday.",
                            ]),
                            SummarySection(title: "Next moves", bullets: [
                                "Assign owner for sprint review prep.",
                                "Get backend to finalize API contract today.",
                                "Identify observer for Thursday's user research session.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .exec,
                    summary: MeetingSummary(
                        eyebrow: "Team update",
                        title: "Sprint is largely unblocked; one API dependency needs resolution today.",
                        sections: [
                            SummarySection(title: "Status", bullets: [
                                "Notification integration blocked pending API contract finalization.",
                                "Design and research are on track and unblocked.",
                            ]),
                            SummarySection(title: "Action needed", bullets: [
                                "Backend team must finalize contract today to protect sprint delivery.",
                            ]),
                        ]
                    )
                ),
            ],
            prompts: [
                AIResponse(prompt: "Who is blocked?", answer: "Dev is blocked on the API contract for the notification service. A backend owner needs to finalize and sign before integration can move to QA."),
                AIResponse(prompt: "Write standup summary", answer: "Week 18: one blocker (API contract, backend owner needed), design handoff done, user interviews Thursday. Next: lock contract today, assign sprint review owner."),
            ],
            destinations: ["#engineering", "#product-updates", "Email all participants"],
            selectedTemplate: .standup,
            selectedPromptID: nil,
            isPinned: false
        ),
        Meeting(
            title: "Candidate screen: Jamie Park",
            workspace: "Hiring · iOS",
            when: .now.addingTimeInterval(-2 * 86400),
            durationMinutes: 45,
            attendees: ["Tariq", "Jamie Park"],
            status: .ready,
            stage: "Captured and ready to review",
            objective: "Assess technical depth, communication, and culture fit for the senior iOS role.",
            rawNotes: """
            - Strong SwiftUI fundamentals, comfortable with async/await
            - Led a complex codebase migration from callbacks to structured concurrency
            - Asked smart questions about team size and release cadence
            - Prefers async communication and deep work blocks
            - Concern: limited CI/CD pipeline experience at scale
            - Overall: strong craft signal, moderate DevOps signal
            """,
            transcript: [
                TranscriptLine(speaker: "Tariq", role: "Hiring manager", text: "Can you walk me through a technical decision you are still proud of?"),
                TranscriptLine(speaker: "Jamie Park", role: "Candidate", text: "We had a callback-heavy codebase and I led the async/await migration. Managing intermediate state while keeping old paths alive was the hardest part."),
                TranscriptLine(speaker: "Tariq", role: "Hiring manager", text: "How do you structure your work week?"),
                TranscriptLine(speaker: "Jamie Park", role: "Candidate", text: "I work best in long uninterrupted blocks. I batch communication into morning and end of day so I do not fragment deep build time."),
            ],
            summaries: [
                TemplateSummary(
                    template: .interview,
                    summary: MeetingSummary(
                        eyebrow: "Interview notes",
                        title: "Strong iOS craft; CI/CD depth is the gap to probe in the technical round.",
                        sections: [
                            SummarySection(title: "Strengths", bullets: [
                                "Deep SwiftUI and structured concurrency fundamentals.",
                                "Led a complex async migration under real production constraints.",
                                "Asks thoughtful, process-aware questions.",
                            ]),
                            SummarySection(title: "Gaps to probe", bullets: [
                                "Limited CI/CD pipeline experience at scale.",
                                "Deep work preference — worth confirming fit with team cadence.",
                            ]),
                            SummarySection(title: "Recommendation", bullets: [
                                "Advance to technical round. Include a CI/CD scenario in the take-home.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .exec,
                    summary: MeetingSummary(
                        eyebrow: "Hiring update",
                        title: "Strong screen; recommend advancing with one targeted probe area.",
                        sections: [
                            SummarySection(title: "Signal", bullets: [
                                "Above-bar iOS craft and clear communication.",
                                "CI/CD gap is real but testable in the technical round.",
                            ]),
                            SummarySection(title: "Next step", bullets: [
                                "Send take-home with CI/CD scenario and schedule technical round.",
                            ]),
                        ]
                    )
                ),
            ],
            prompts: [
                AIResponse(prompt: "Should we advance?", answer: "Yes. Technical depth is above bar and communication is clear. The CI/CD gap is testable. Advance with a take-home that includes a pipeline scenario."),
                AIResponse(prompt: "What are the risks?", answer: "The DevOps gap and preference for low-interrupt work could create friction if the team runs high-cadence standups or frequent pairing. Worth addressing in the offer conversation."),
            ],
            destinations: ["ATS notes", "Hiring team brief", "Email all participants"],
            selectedTemplate: .interview,
            selectedPromptID: nil,
            isPinned: false
        ),
        Meeting(
            title: "Brainstorm: notification strategy",
            workspace: "Product team",
            when: .now.addingTimeInterval(-3 * 86400),
            durationMinutes: 38,
            attendees: ["Rina", "Harsh", "Dev", "Mika"],
            status: .ready,
            stage: "Auto-structured from notes",
            objective: "Generate and pressure-test ideas for a smarter notification layer before feature kickoff.",
            rawNotes: """
            - Push vs digest: users prefer batched digest over individual pings
            - AI-filtered: let the model decide what is worth surfacing
            - Channel flexibility: Slack, email, in-app configurable per workspace
            - Frequency problem: current tools send too much and users mute everything
            - Big idea: quiet mode that surfaces only high-signal items
            - Risk: personalization at scale requires strong signal data early on
            """,
            transcript: [
                TranscriptLine(speaker: "Mika", role: "Product", text: "The real problem is that every tool has trained people to ignore notifications. We need a trust reset."),
                TranscriptLine(speaker: "Dev", role: "Engineering", text: "If we batch by relevance instead of time, we might get better open rates without annoying anyone."),
                TranscriptLine(speaker: "Rina", role: "Design", text: "A quiet mode that only breaks for verified high-signal items could be the differentiator. People would actually trust that ping."),
                TranscriptLine(speaker: "Harsh", role: "PM", text: "Channel flexibility is probably table stakes. The AI filter is the bet that makes us different."),
            ],
            summaries: [
                TemplateSummary(
                    template: .brainstorm,
                    summary: MeetingSummary(
                        eyebrow: "Ideas capture",
                        title: "The team converged on AI-filtered quiet mode as the differentiated bet.",
                        sections: [
                            SummarySection(title: "Strongest ideas", bullets: [
                                "Quiet mode that only breaks silence for AI-verified high-signal events.",
                                "Relevance-based batching instead of time-based digest.",
                                "Configurable channels per workspace as baseline flexibility.",
                            ]),
                            SummarySection(title: "Tensions to resolve", bullets: [
                                "Personalization requires quality signal data — cold-start problem is real.",
                                "Channel flexibility may dilute focus; decide if it is table stakes or a later phase.",
                            ]),
                            SummarySection(title: "Next moves", bullets: [
                                "Write a one-pager on quiet mode and validate with five power users.",
                                "Define signal taxonomy before kickoff.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .exec,
                    summary: MeetingSummary(
                        eyebrow: "Strategy snapshot",
                        title: "Notification strategy has a clear differentiator; cold-start is the primary risk.",
                        sections: [
                            SummarySection(title: "The bet", bullets: [
                                "AI-filtered quiet mode rebuilds trust in a notification channel users have learned to mute.",
                            ]),
                            SummarySection(title: "Risk", bullets: [
                                "Model needs quality signal data early — phased rollout is safer than a hard launch.",
                            ]),
                        ]
                    )
                ),
            ],
            prompts: [
                AIResponse(prompt: "What is the strongest idea?", answer: "Quiet mode with AI filtering. Users have trained themselves to ignore notifications. A system that only breaks silence for things that matter could rebuild trust in the channel entirely."),
                AIResponse(prompt: "What should we prototype first?", answer: "Define the signal taxonomy before writing notification code. The filter quality depends entirely on agreeing what a high-signal event looks like."),
            ],
            destinations: ["Product brief", "#product-team", "Public link"],
            selectedTemplate: .brainstorm,
            selectedPromptID: nil,
            isPinned: false
        ),
        Meeting(
            title: "QBR: Meridian Health",
            workspace: "Pipeline · Enterprise",
            when: .now.addingTimeInterval(-4 * 86400),
            durationMinutes: 62,
            attendees: ["Maya", "Dr. Singh", "Rachel T.", "Owen"],
            status: .shared,
            stage: "Shared to account team",
            objective: "Review Q1 outcomes, confirm renewal intent, and align on Q2 expansion scope.",
            rawNotes: """
            - Q1: 94% of contracted seats active
            - NPS up 18 points since onboarding
            - Top request: SSO and advanced permission controls
            - Renewal confirmed verbally, paperwork pending legal review
            - Expansion: 3 additional departments interested for Q2
            - Security review required before expansion rolls out
            - Decision maker is Dr. Singh, economic buyer is Rachel
            """,
            transcript: [
                TranscriptLine(speaker: "Dr. Singh", role: "Chief Medical Officer", text: "Adoption has exceeded what we planned for. The teams that resisted at first are now our heaviest users."),
                TranscriptLine(speaker: "Rachel T.", role: "VP Operations", text: "We are committed to renewing. I just need legal to sign off on the updated DPA before we countersign."),
                TranscriptLine(speaker: "Maya", role: "AE", text: "What would it take to bring the other three departments in for Q2?"),
                TranscriptLine(speaker: "Dr. Singh", role: "Chief Medical Officer", text: "SSO is the real blocker. Once that is live, I can approve rollout to radiology and cardiology without another security review."),
            ],
            summaries: [
                TemplateSummary(
                    template: .discovery,
                    summary: MeetingSummary(
                        eyebrow: "Account review",
                        title: "Meridian is renewing and expansion is real, gated on SSO and legal.",
                        sections: [
                            SummarySection(title: "Health signals", bullets: [
                                "94% seat activation and NPS up 18 points signal a strong account.",
                                "Early resistors became the highest-usage cohort.",
                            ]),
                            SummarySection(title: "Expansion path", bullets: [
                                "Three departments ready to expand pending SSO availability.",
                                "Dr. Singh can approve radiology and cardiology rollout once SSO ships.",
                                "Rachel is committed; DPA legal review is the only paperwork blocker.",
                            ]),
                            SummarySection(title: "Next moves", bullets: [
                                "Provide SSO timeline and updated DPA to unblock renewal signature.",
                                "Prepare expansion proposal for radiology and cardiology.",
                                "Schedule follow-up with Rachel to confirm legal timeline.",
                            ]),
                        ]
                    )
                ),
                TemplateSummary(
                    template: .exec,
                    summary: MeetingSummary(
                        eyebrow: "Exec update",
                        title: "Meridian renewal is secure; fast SSO delivery unlocks three-department expansion.",
                        sections: [
                            SummarySection(title: "Headline", bullets: [
                                "Renewal confirmed verbally at current contract value.",
                                "Q2 expansion across three departments is in reach if SSO ships on schedule.",
                            ]),
                            SummarySection(title: "Dependencies", bullets: [
                                "SSO is the product gate for expansion approval.",
                                "Legal DPA review is the paperwork gate for renewal close.",
                            ]),
                        ]
                    )
                ),
            ],
            prompts: [
                AIResponse(prompt: "What is the expansion opportunity?", answer: "Three departments ready to expand once SSO ships. Radiology and cardiology are pre-approved by Dr. Singh pending the SSO blocker. This is a meaningful Q2 revenue opportunity gated on product timeline, not sales."),
                AIResponse(prompt: "Write the follow-up email", answer: "Thanks for a productive review. Our next steps: SSO timeline and updated DPA delivered this week. Once legal clears, we will work with Rachel to countersign and kick off the radiology and cardiology expansion. Looking forward to making Q2 a strong chapter for Meridian."),
            ],
            destinations: ["Account brief", "CRM", "Email all participants", "#enterprise-cs"],
            selectedTemplate: .exec,
            selectedPromptID: nil,
            isPinned: true
        ),
        Meeting(
            title: "Calendar prep: Helio launch review",
            workspace: "Meetings",
            when: .now.addingTimeInterval(45 * 60),
            durationMinutes: 45,
            attendees: ["You", "Avery Chen", "Mina Patel", "Jordan Lee"],
            status: .ready,
            stage: "Prepared from calendar",
            objective: """
            Location: Zoom
            Calendar notes: Review launch readiness, assign follow-up owners, and decide whether the client-safe recap can go out today.
            """,
            rawNotes: """
            - Attendees: You, Avery Chen, Mina Patel, Jordan Lee
            - Agenda: launch readiness, open risks, client recap
            - Decisions:
            - Risks:
            - Next steps:
            """,
            transcript: [],
            summaries: [
                TemplateSummary(
                    template: .exec,
                    summary: MeetingSummary(
                        eyebrow: "Calendar prep",
                        title: "Upcoming launch review is ready for capture with attendees and objective prefilled.",
                        sections: [
                            SummarySection(title: "Use this to test", bullets: [
                                "Open this note from Library to see a calendar-started meeting record.",
                                "Use Tasks to schedule a local notification for the follow-up items.",
                                "Compare the objective and attendees with the calendar context stored on the meeting.",
                            ]),
                            SummarySection(title: "Prep prompts", bullets: [
                                "Confirm launch approval criteria.",
                                "Ask who owns client recap edits.",
                                "Capture any risks that should be source-backed before sharing.",
                            ]),
                        ]
                    )
                ),
            ],
            prompts: [
                AIResponse(prompt: "How should I prepare?", answer: "Confirm launch criteria first, then resolve recap ownership and any legal/security risks before the client-safe summary goes out."),
                AIResponse(prompt: "What should I ask?", answer: "Ask Avery whether launch criteria are final, Mina whether the recap can be client-safe today, and Jordan whether any legal language needs review."),
            ],
            destinations: ["Email all participants", "Files export"],
            selectedTemplate: .exec,
            selectedPromptID: nil,
            isPinned: true,
            commitments: [
                Commitment(statement: "Send the client-safe recap after launch review", owner: "You", sourceSpeaker: "Calendar prep", dueHint: "today", status: .open, priority: "high", rationale: "This is the fastest way to test local notification scheduling from Tasks."),
                Commitment(statement: "Confirm legal wording before the recap is shared", owner: "Mina Patel", sourceSpeaker: "Calendar prep", dueHint: "tomorrow", status: .open, priority: "medium", rationale: "Keeps the source-backed accuracy flow visible before external sharing."),
            ],
            calendarEventID: "sample-calendar-helio-launch-review",
            calendarStartDate: .now.addingTimeInterval(45 * 60),
            calendarEndDate: .now.addingTimeInterval(90 * 60)
        ),
        Meeting(
            title: "Captured from calendar: Orion renewal",
            workspace: "Calls",
            when: .now.addingTimeInterval(-30 * 60),
            durationMinutes: 52,
            attendees: ["You", "Noah Rivera", "Elena Brooks", "Samir Shah"],
            status: .ready,
            stage: "Captured from calendar event",
            objective: """
            Location: Google Meet
            Calendar notes: Renewal call with procurement and champion. Confirm next step owner and pricing objection.
            """,
            rawNotes: """
            - Decision: Orion wants a two-year renewal option if pricing protection is included
            - Risk: procurement needs revised terms before Friday
            - Elena asked for the security addendum and uptime summary
            - Noah will confirm whether finance approves the two-year option
            """,
            transcript: [
                TranscriptLine(speaker: "Elena Brooks", role: "Champion", text: "The team wants to renew, but procurement needs revised terms before Friday."),
                TranscriptLine(speaker: "Samir Shah", role: "Procurement", text: "Pricing protection is the main condition for a two-year agreement."),
                TranscriptLine(speaker: "Noah Rivera", role: "Finance", text: "I can confirm finance approval tomorrow if we have the updated option in writing."),
                TranscriptLine(speaker: "You", role: "AE", text: "I will send the security addendum and uptime summary today with the two-year option."),
            ],
            summaries: [
                TemplateSummary(
                    template: .discovery,
                    summary: MeetingSummary(
                        eyebrow: "Calendar capture",
                        title: "Orion is leaning toward renewal, with pricing protection and revised terms as the blockers.",
                        sections: [
                            SummarySection(title: "Confirmed", bullets: [
                                "Renewal interest is real, but procurement needs revised terms before Friday.",
                                "Pricing protection is the condition for a two-year agreement.",
                                "Finance approval can happen tomorrow if the option is sent in writing.",
                            ]),
                            SummarySection(title: "Follow-ups", bullets: [
                                "Send security addendum, uptime summary, and two-year option today.",
                                "Ask Noah to confirm finance approval tomorrow.",
                                "Track procurement terms as at risk until Friday.",
                            ]),
                        ]
                    )
                ),
            ],
            prompts: [
                AIResponse(prompt: "What did Orion ask for?", answer: "Orion asked for revised renewal terms, pricing protection for a two-year agreement, the security addendum, and an uptime summary."),
                AIResponse(prompt: "What do I need to do today?", answer: "Send the security addendum, uptime summary, and two-year renewal option today, then follow up with Noah tomorrow for finance approval."),
            ],
            destinations: ["CRM", "Email all participants", "#enterprise-sales"],
            selectedTemplate: .discovery,
            selectedPromptID: nil,
            isPinned: false,
            commitments: [
                Commitment(statement: "Send the security addendum and uptime summary", owner: "You", sourceSpeaker: "You", dueHint: "today", status: .open, priority: "high", rationale: "Unblocks Orion procurement before Friday."),
                Commitment(statement: "Confirm finance approval for the two-year option", owner: "Noah Rivera", sourceSpeaker: "Noah Rivera", dueHint: "tomorrow", status: .open, priority: "medium", rationale: "Needed before procurement signs off."),
                Commitment(statement: "Review revised renewal terms", owner: "Samir Shah", sourceSpeaker: "Samir Shah", dueHint: "Friday", status: .atRisk, priority: "high", rationale: "Procurement is the renewal gate."),
            ],
            calendarEventID: "sample-calendar-orion-renewal",
            calendarStartDate: .now.addingTimeInterval(-30 * 60),
            calendarEndDate: .now.addingTimeInterval(22 * 60)
        ),

        // MARK: Scenario coverage — explicit commitments to exercise the Daily
        // Plan ranking, Tasks overdue banner, Copilot recall (shared
        // attendees), you-owe vs they-owe, and Ask key-point extraction.
        Meeting(
            title: "Sync: Meridian rollout",
            workspace: "Pipeline · Enterprise",
            when: .now.addingTimeInterval(-3600),
            durationMinutes: 28,
            attendees: ["Maya", "Dr. Singh", "Rachel T."],
            status: .ready,
            stage: "Captured and ready to review",
            objective: "Lock the SSO timeline and clear the DPA blocker before expansion.",
            rawNotes: """
            - We decided to ship the pilot to 12 seats first
            - Risk: legal has not cleared the DPA yet
            - Budget approved at $40k for Q2 expansion
            - SSO is the blocker for radiology and cardiology
            """,
            transcript: [],
            summaries: [],
            prompts: [],
            destinations: [],
            selectedTemplate: .exec,
            selectedPromptID: nil,
            isPinned: true,
            commitments: [
                Commitment(statement: "Send the SSO security whitepaper", owner: "You", sourceSpeaker: "Maya", dueHint: "today", status: .open),
                Commitment(statement: "Confirm the final seat count", owner: "Rachel T.", sourceSpeaker: "Rachel T.", dueHint: "Friday", status: .atRisk),
                Commitment(statement: "Share the rollout timeline for radiology", owner: "Dr. Singh", sourceSpeaker: "Dr. Singh", dueHint: nil, status: .open),
                Commitment(statement: "Deliver the updated DPA to legal", owner: "You", sourceSpeaker: "Maya", dueHint: "tomorrow", status: .open),
            ]
        ),
        Meeting(
            title: "Roadmap sync",
            workspace: "Internal · Product",
            when: .now.addingTimeInterval(-2 * 86400),
            durationMinutes: 45,
            attendees: ["Leo", "Sam", "Priya"],
            status: .ready,
            stage: "Captured and ready to review",
            objective: "Agree Q3 priorities and unblock the hiring plan.",
            rawNotes: """
            - Decision: go with the phased rollout
            - Agreed to push the launch to August
            - Sam owns the hiring approval
            """,
            transcript: [],
            summaries: [],
            prompts: [],
            destinations: [],
            selectedTemplate: .manager,
            selectedPromptID: nil,
            isPinned: false,
            commitments: [
                Commitment(statement: "Draft the Q3 roadmap doc", owner: "You", sourceSpeaker: "Leo", dueHint: "tomorrow", status: .open),
                Commitment(statement: "Approve the hiring plan", owner: "Sam", sourceSpeaker: "Sam", dueHint: nil, status: .open),
                Commitment(statement: "Finalize the OKRs", owner: "You", sourceSpeaker: "Leo", dueHint: nil, status: .fulfilled),
                Commitment(statement: "Retire the old scope draft", owner: "Leo", sourceSpeaker: "Leo", dueHint: nil, status: .superseded),
            ]
        ),
        Meeting(
            title: "Customer call: Northwind",
            workspace: "Pipeline · Expansion",
            when: .now.addingTimeInterval(-9 * 86400),
            durationMinutes: 22,
            attendees: ["Priya", "Wei", "Maya"],
            status: .ready,
            stage: "Captured and ready to review",
            objective: "Respond to procurement and keep the renewal on track.",
            rawNotes: """
            - Blocker: procurement is waiting on our reply
            - Must send the pricing deck before end of day
            - Decision deferred to next week
            """,
            transcript: [],
            summaries: [],
            prompts: [],
            destinations: [],
            selectedTemplate: .discovery,
            selectedPromptID: nil,
            isPinned: false,
            commitments: [
                Commitment(statement: "Reply to procurement", owner: "You", sourceSpeaker: "Wei", dueHint: "eod", status: .atRisk),
                Commitment(statement: "Send the pricing deck", owner: "You", sourceSpeaker: "Maya", dueHint: "today", status: .open),
                Commitment(statement: "Schedule the security review", owner: "Wei", sourceSpeaker: "Wei", dueHint: "next week", status: .open),
            ]
        ),
    ]
}
