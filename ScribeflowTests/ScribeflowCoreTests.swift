import Foundation
import Testing
@testable import Scribeflow

struct ScribeflowCoreTests {
    @Test
    func audioRecordingDurationLabelIsStable() {
        let recording = AudioRecordingAttachment(
            title: "Follow-up note",
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 125,
            fileName: "voice.m4a",
            transcript: "Next step is clear.",
            linkedNote: "Remember to send the recap.",
            source: .voiceNote,
            fileSizeBytes: 1024
        )

        #expect(recording.durationLabel == "02:05")
        #expect(recording.durationMinutes == 3)
        #expect(recording.hasTranscript)
    }

    @Test
    func recordingFileStoreCreatesProtectedRecordingLocation() throws {
        let id = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let url = try RecordingFileStore.makeRecordingURL(id: id)

        #expect(url.lastPathComponent == "11111111-1111-1111-1111-111111111111.m4a")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Recordings")
    }

    @Test
    func complianceCopyDoesNotPromiseRestrictedCallRecording() {
        #expect(RecordingCompliance.restrictedCallRecordingNotice.contains("cannot record cellular"))
        #expect(RecordingCompliance.restrictedCallRecordingNotice.contains("App Store-safe"))
        #expect(RecordingCompliance.providerCallRequirement.contains("app-owned VoIP"))
    }

    @Test
    func librarySearchShowsRecordingTranscriptContext() throws {
        let recording = AudioRecordingAttachment(
            title: "Launch audio",
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 74,
            fileName: "launch.m4a",
            transcript: "The roadmap launch decision moved to Friday after legal review.",
            linkedNote: "Follow up with design.",
            source: .voiceNote,
            fileSizeBytes: 4096
        )
        let meeting = Meeting(
            title: "Weekly sync",
            workspace: "Voice Notes",
            when: Date(timeIntervalSince1970: 0),
            durationMinutes: 2,
            attendees: ["Ari"],
            status: .ready,
            stage: "Recorded voice note",
            objective: "Capture launch notes.",
            rawNotes: "",
            transcript: [],
            summaries: [],
            prompts: [],
            destinations: [],
            selectedTemplate: .exec,
            selectedPromptID: nil,
            isPinned: false,
            audioRecordings: [recording]
        )

        let match = try #require(LibrarySearchMatcher.match(in: meeting, query: "launch decision"))

        #expect(match.label == "Recording transcript")
        #expect(match.snippet.contains("launch decision"))
    }

    @Test
    func speakerParserSplitsNamedTranscriptLines() {
        let lines = SpeakerTranscriptParser.lines(
            from: """
            Maya: We agreed to ship the beta next Friday.
            Arjun: I will send the launch checklist by tomorrow.
            """,
            defaultSpeaker: "Voice note",
            defaultRole: "Speaker"
        )

        #expect(lines.count == 2)
        #expect(lines[0].speaker == "Maya")
        #expect(lines[1].speaker == "Arjun")
    }

    @Test
    func intelligenceReportExtractsProductSignals() {
        let meeting = Meeting(
            title: "Launch sync",
            workspace: "Product",
            when: Date(timeIntervalSince1970: 0),
            durationMinutes: 18,
            attendees: ["Maya", "Arjun"],
            status: .ready,
            stage: "Recorded voice note",
            objective: "Finalize beta launch.",
            rawNotes: """
            Decision: beta launch moves to Friday.
            Arjun will send the checklist by tomorrow.
            Clarify whether legal has approved the consent copy.
            """,
            transcript: SpeakerTranscriptParser.lines(
                from: "Maya: We agreed Friday is safer. Arjun: I will send the checklist by tomorrow.",
                defaultSpeaker: "Voice note",
                defaultRole: "Speaker"
            ),
            summaries: [],
            prompts: [],
            destinations: [],
            selectedTemplate: .exec,
            selectedPromptID: nil,
            isPinned: false
        )

        let report = MeetingIntelligenceEngine.report(for: meeting)

        #expect(report.decisions.contains { $0.localizedCaseInsensitiveContains("Friday") })
        #expect(report.actionItems.contains { $0.localizedCaseInsensitiveContains("checklist") })
        #expect(report.openQuestions.contains { $0.localizedCaseInsensitiveContains("legal") })
        #expect(report.speakerSegments.count == 2)
        #expect(report.structuredActionItems.contains { $0.owner == "Arjun" && $0.dueHint == "tomorrow" })
        #expect(report.mode == .localHeuristic)
    }

    @Test
    func productCapabilityStatusDoesNotClaimCloudSync() {
        let snapshot = StorageSnapshot(
            notesCount: 2,
            recordingsCount: 1,
            audioBytes: 5_000_000,
            databaseBytes: 120_000,
            recordings: []
        )

        let statuses = LocalOnlyAccountSyncService().currentStatus(storage: snapshot)
        let cloudSync = statuses.first { $0.id == "cloud-sync" }
        let manualBackup = statuses.first { $0.id == "manual-backup" }

        #expect(cloudSync?.state == .needsBackend)
        #expect(manualBackup?.state == .available)
    }

    @Test
    func storageSnapshotFiltersLargeAndOldRecordings() throws {
        let oldDate = try #require(Calendar.current.date(byAdding: .day, value: -45, to: Date(timeIntervalSince1970: 100_000)))
        let small = StorageRecordingItem(
            meetingID: UUID(),
            recordingID: UUID(),
            meetingTitle: "Small",
            recordingTitle: "Small audio",
            fileName: "small.m4a",
            createdAt: Date(timeIntervalSince1970: 100_000),
            durationSeconds: 10,
            sizeBytes: 1_000
        )
        let largeOld = StorageRecordingItem(
            meetingID: UUID(),
            recordingID: UUID(),
            meetingTitle: "Large",
            recordingTitle: "Large audio",
            fileName: "large.m4a",
            createdAt: oldDate,
            durationSeconds: 300,
            sizeBytes: 50_000_000
        )
        let snapshot = StorageSnapshot(
            notesCount: 1,
            recordingsCount: 2,
            audioBytes: 50_001_000,
            databaseBytes: 10_000,
            recordings: [small, largeOld]
        )

        #expect(snapshot.recordingsLargerThan(bytes: 25_000_000).map(\.fileName) == ["large.m4a"])
        #expect(snapshot.recordingsOlderThan(days: 30, now: Date(timeIntervalSince1970: 100_000)).map(\.fileName) == ["large.m4a"])
    }

    @Test
    func authValidationCatchesBadEmailAndWeakPassword() {
        let empty = AuthCredentialsValidator.validate(email: "", password: "")
        let invalid = AuthCredentialsValidator.validate(email: "not-an-email", password: "password")
        let strong = AuthCredentialsValidator.validate(email: "user@example.com", password: "Secure123")

        #expect(empty.emailError == "Add your email to continue.")
        #expect(empty.passwordError == "Add your password to continue.")
        #expect(invalid.emailError == "Use a valid email with an @ and domain.")
        #expect(invalid.passwordError == "Add one uppercase letter.")
        #expect(strong.canSubmit)
    }

    @Test
    func localAuthServiceIssuesTokenWithoutPersistingPassword() async throws {
        let service = LocalDevelopmentAuthService()
        let session = try await service.signup(email: "User@Example.com", password: "Secure123")

        #expect(session.email == "user@example.com")
        #expect(session.accessToken.isEmpty == false)
        #expect(session.accessToken.contains("Secure123") == false)
        #expect(!session.isExpired)
    }

    // MARK: - Today "Next move" heuristic

    private func makeMeeting(
        title: String,
        when: Date = .now,
        status: MeetingStatus = .ready,
        rawNotes: String = "",
        summaries: [TemplateSummary] = [],
        transcript: [TranscriptLine] = [],
        commitments: [Commitment] = []
    ) -> Meeting {
        Meeting(
            title: title,
            workspace: "Meetings",
            when: when,
            durationMinutes: 30,
            attendees: ["You"],
            status: status,
            stage: "",
            objective: "Test objective",
            rawNotes: rawNotes,
            transcript: transcript,
            summaries: summaries,
            prompts: [],
            destinations: [],
            selectedTemplate: .discovery,
            selectedPromptID: nil,
            isPinned: false,
            commitments: commitments
        )
    }

    @Test
    func nextMoveIsNilWhenLibraryIsEmpty() {
        let snapshot = TodaySnapshot(meetings: [])
        #expect(snapshot.nextMove == nil)
    }

    @Test
    func nextMovePrioritizesAtRiskCommitment() {
        let atRisk = Commitment(
            statement: "Ship the API contract",
            owner: "Owner not named",
            sourceSpeaker: "",
            dueHint: nil,
            status: .atRisk
        )
        let meeting = makeMeeting(
            title: "Platform sync",
            summaries: [],
            commitments: [atRisk]
        )

        let snapshot = TodaySnapshot(meetings: [meeting])
        #expect(snapshot.nextMove?.kind == .resolveRisk)
        #expect(snapshot.nextMove?.meetingID == meeting.id)
    }

    @Test
    func nextMoveSuggestsSummaryForUnsummarizedNote() {
        let meeting = makeMeeting(
            title: "Customer interview",
            rawNotes: "They want faster onboarding and clearer pricing tiers across plans.",
            summaries: [] // no summary yet, no commitments → summarize wins
        )

        let snapshot = TodaySnapshot(meetings: [meeting])
        #expect(snapshot.nextMove?.kind == .summarize)
        #expect(snapshot.nextMove?.meetingID == meeting.id)
    }

    // MARK: - Persistence recovery ladder

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMeetings(_ meetings: [Meeting], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meetings).write(to: url)
    }

    private func quarantineExists(in dir: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.contains { $0.hasPrefix("meetings.corrupt-") }
    }

    @Test @MainActor
    func loadReadsGoodMainWithoutRecovering() throws {
        let dir = try makeTempDir()
        let main = dir.appendingPathComponent("meetings.json")
        let backup = dir.appendingPathComponent("meetings.backup.json")
        try writeMeetings([makeMeeting(title: "Kickoff")], to: main)

        let outcome = MeetingStore.loadMeetings(mainURL: main, backupURL: backup)
        #expect(outcome.meetings.count == 1)
        #expect(!outcome.loadFailed)
        #expect(!outcome.recoveredFromBackup)
        #expect(!quarantineExists(in: dir))
    }

    @Test @MainActor
    func loadRecoversFromBackupAndQuarantinesCorruptMain() throws {
        let dir = try makeTempDir()
        let main = dir.appendingPathComponent("meetings.json")
        let backup = dir.appendingPathComponent("meetings.backup.json")
        try Data("not valid json {".utf8).write(to: main)
        try writeMeetings([makeMeeting(title: "Recovered")], to: backup)

        let outcome = MeetingStore.loadMeetings(mainURL: main, backupURL: backup)
        #expect(outcome.meetings.count == 1)
        #expect(outcome.recoveredFromBackup)
        #expect(!outcome.loadFailed)
        // Corrupt main is preserved (quarantined), not deleted.
        #expect(quarantineExists(in: dir))
        #expect(!FileManager.default.fileExists(atPath: main.path))
    }

    @Test @MainActor
    func loadFlagsFailureAndQuarantinesWhenNoBackup() throws {
        let dir = try makeTempDir()
        let main = dir.appendingPathComponent("meetings.json")
        let backup = dir.appendingPathComponent("meetings.backup.json")
        try Data("corrupt".utf8).write(to: main)

        let outcome = MeetingStore.loadMeetings(mainURL: main, backupURL: backup)
        #expect(outcome.meetings.isEmpty)
        #expect(outcome.loadFailed)
        #expect(!outcome.recoveredFromBackup)
        // The unreadable bytes survive for manual rescue.
        #expect(quarantineExists(in: dir))
    }

    @Test @MainActor
    func loadFallsBackToBackupWhenMainMissing() throws {
        let dir = try makeTempDir()
        let main = dir.appendingPathComponent("meetings.json")
        let backup = dir.appendingPathComponent("meetings.backup.json")
        try writeMeetings([makeMeeting(title: "From backup")], to: backup)

        let outcome = MeetingStore.loadMeetings(mainURL: main, backupURL: backup)
        #expect(outcome.meetings.count == 1)
        #expect(outcome.recoveredFromBackup)
        #expect(!outcome.loadFailed)
    }
}

// MARK: - Live Meeting Copilot

struct MeetingCopilotTests {
    private func meeting(
        title: String,
        attendees: [String],
        commitments: [Commitment]
    ) -> Meeting {
        var m = Meeting.seed[0]
        m.title = title
        m.attendees = attendees
        m.commitments = commitments
        return m
    }

    @Test
    func relatedMeetingsMatchOnSharedAttendee() {
        let a = meeting(title: "QBR", attendees: ["Alice", "Bob"], commitments: [])
        let b = meeting(title: "Standup", attendees: ["Carol"], commitments: [])
        let related = MeetingCopilot.relatedMeetings(attendees: ["alice"], in: [a, b])
        #expect(related.count == 1)
        #expect(related.first?.title == "QBR")
    }

    @Test
    func rememberSurfacesOpenPromisesFromRelatedMeetings() {
        let m = meeting(
            title: "Meridian",
            attendees: ["Dana"],
            commitments: [
                Commitment(statement: "Send security doc", owner: "You", sourceSpeaker: "You", dueHint: nil, status: .open),
                Commitment(statement: "Confirm seats", owner: "Dana", sourceSpeaker: "Dana", dueHint: "Friday", status: .atRisk),
                Commitment(statement: "Already shipped", owner: "Dana", sourceSpeaker: "Dana", dueHint: nil, status: .fulfilled)
            ]
        )
        let signals = MeetingCopilot.remember(attendees: ["Dana"], in: [m])
        // Fulfilled item excluded; the two open/at-risk surface.
        #expect(signals.count == 2)
        #expect(signals.contains { $0.text == "Send security doc" && $0.detail?.contains("You owe") == true })
        #expect(signals.contains { $0.text == "Confirm seats" && $0.detail?.contains("Dana") == true })
    }

    @Test
    func askThemOnlyTurnsTheirPromisesIntoQuestions() {
        let m = meeting(
            title: "Meridian",
            attendees: ["Dana"],
            commitments: [
                Commitment(statement: "Send security doc", owner: "You", sourceSpeaker: "You", dueHint: nil, status: .open),
                Commitment(statement: "Confirm seat count", owner: "Dana", sourceSpeaker: "Dana", dueHint: nil, status: .open)
            ]
        )
        let signals = MeetingCopilot.askThem(attendees: ["Dana"], in: [m])
        #expect(signals.count == 1)
        #expect(signals.first?.text.contains("Confirm seat count") == true)
        #expect(signals.first?.kind == .ask)
    }

    @Test
    func detectClassifiesDecisionsAndActions() {
        let paragraphs = [
            "Some neutral chit chat about the weather today",
            "We decided to ship the pilot in Q3 across all teams",
            "I'll send the MSA over before end of day tomorrow"
        ]
        let signals = MeetingCopilot.detect(paragraphs: paragraphs)
        // Text is distilled and sentence-cased ("Ship the pilot"), so match
        // case-insensitively.
        #expect(signals.contains { $0.kind == .decision && $0.text.localizedCaseInsensitiveContains("ship the pilot") })
        #expect(signals.contains { $0.kind == .action && $0.text.localizedCaseInsensitiveContains("send the MSA") })
        // Neutral chatter is not surfaced.
        #expect(!signals.contains { $0.text.localizedCaseInsensitiveContains("weather") })
    }

    @Test
    func noAttendeesYieldsNoMemoryRecall() {
        let m = meeting(
            title: "Meridian",
            attendees: ["Dana"],
            commitments: [
                Commitment(statement: "Send doc", owner: "You", sourceSpeaker: "You", dueHint: nil, status: .open)
            ]
        )
        #expect(MeetingCopilot.remember(attendees: [], in: [m]).isEmpty)
        #expect(MeetingCopilot.askThem(attendees: [], in: [m]).isEmpty)
    }
}

// MARK: - Note → intelligence extraction

struct MeetingExtractionTests {
    private func meeting(notes: String, attendees: [String] = []) -> Meeting {
        var m = Meeting.seed[0]
        m.rawNotes = notes
        m.attendees = attendees
        m.transcript = []
        m.commitments = []
        return m
    }

    @Test
    func firstPersonActionOwnedByYouWithDue() throws {
        let m = meeting(notes: "- I'll send the pricing deck by Friday")
        let actions = MeetingIntelligenceEngine.structuredActions(for: m)
        let action = try #require(actions.first { $0.text.localizedCaseInsensitiveContains("pricing deck") })
        #expect(action.owner == "You")
        #expect(action.dueHint == "friday")
    }

    @Test
    func namedOwnerIsExtracted() throws {
        let m = meeting(notes: "- Maya will review the contract", attendees: ["Maya"])
        let action = try #require(MeetingIntelligenceEngine.structuredActions(for: m).first)
        #expect(action.owner == "Maya")
    }

    @Test
    func explicitOwnerMarkerIsParsed() throws {
        let m = meeting(notes: "- owner: Dana — confirm the seat count")
        let action = try #require(MeetingIntelligenceEngine.structuredActions(for: m).first)
        #expect(action.owner == "Dana")
    }

    @Test
    func weCommitmentIsOwnedByTeam() throws {
        let m = meeting(notes: "- We need to ship the SSO fix")
        let action = try #require(MeetingIntelligenceEngine.structuredActions(for: m).first)
        #expect(action.owner == "Team")
    }

    @Test
    func decisionsExtractedAndNotMistakenForActions() {
        let m = meeting(notes: "We decided to ship the pilot in Q3")
        #expect(MeetingIntelligenceEngine.decisions(for: m).contains { $0.localizedCaseInsensitiveContains("ship the pilot") })
        #expect(!MeetingIntelligenceEngine.structuredActions(for: m).contains { $0.text.localizedCaseInsensitiveContains("ship the pilot") })
    }

    @Test
    func chatterAndQuestionsAreNotActions() {
        let m = meeting(notes: "It was a nice chat about the weather today\nShould we launch next month?")
        #expect(MeetingIntelligenceEngine.structuredActions(for: m).isEmpty)
    }

    // MARK: Distillation — raw conversational lines become crisp items

    @Test
    func actionIsDistilledToImperativeCore() throws {
        let m = meeting(notes: "- so yeah I think I'll probably send the pricing deck over by Friday")
        let action = try #require(MeetingIntelligenceEngine.structuredActions(for: m).first)
        #expect(action.text.hasPrefix("Send"))
        #expect(action.text.localizedCaseInsensitiveContains("pricing deck"))
        // Filler and the commitment preamble are stripped out.
        #expect(!action.text.localizedCaseInsensitiveContains("i'll"))
        #expect(!action.text.localizedCaseInsensitiveContains("probably"))
        #expect(!action.text.localizedCaseInsensitiveContains("i think"))
        #expect(action.owner == "You")
        #expect(action.dueHint == "friday")
    }

    @Test
    func statementMentioningCueWordIsNotAnAction() {
        // "review" is a cue word, but this line is a policy statement, not a task.
        let m = meeting(notes: "Security review is mandatory before rollout\nThe launch went well")
        let actions = MeetingIntelligenceEngine.structuredActions(for: m)
        #expect(!actions.contains { $0.text.localizedCaseInsensitiveContains("mandatory") })
        #expect(!actions.contains { $0.text.localizedCaseInsensitiveContains("launch went") })
    }

    @Test
    func garbageNoteProducesNothingMeaningful() {
        // Typed junk must not be turned into actions or decisions.
        let m = meeting(notes: "asdf asdf qwerty zxcvbn\nlorem ipsum dolor sit\n12345 !!! ????")
        #expect(MeetingIntelligenceEngine.structuredActions(for: m).isEmpty)
        #expect(MeetingIntelligenceEngine.decisions(for: m).isEmpty)
    }

    @Test
    func imperativeLineIsAnAction() throws {
        let m = meeting(notes: "- Review the contract and send the redlines")
        let action = try #require(MeetingIntelligenceEngine.structuredActions(for: m).first)
        #expect(action.text.hasPrefix("Review"))
    }

    @Test
    func stativeRequirementIsNotAnAction() {
        // "has to feel lightweight" is a requirement on a thing, not a task.
        let m = meeting(notes: "If we switch, it has to feel lightweight")
        let actions = MeetingIntelligenceEngine.structuredActions(for: m)
        #expect(!actions.contains { $0.text.localizedCaseInsensitiveContains("lightweight") })
    }

    @Test
    func seedAllFoundDoesNotProduceStatementActions() throws {
        let allFound = try #require(Meeting.seed.first { $0.title == "Intro call: AllFound" })
        let texts = MeetingIntelligenceEngine.structuredActions(for: allFound).map(\.text)
        #expect(!texts.contains { $0.localizedCaseInsensitiveContains("mandatory") })
        #expect(!texts.contains { $0.localizedCaseInsensitiveContains("as long as") })
        #expect(!texts.contains { $0.localizedCaseInsensitiveContains("lightweight") })
    }

    @Test
    func abilityPhraseIsNotAnAction() {
        // "as long as we can understand X" expresses ability/condition, not a commitment.
        let m = meeting(notes: "As long as we can understand the permissions, I can fast-track it")
        let actions = MeetingIntelligenceEngine.structuredActions(for: m)
        #expect(!actions.contains { $0.text.localizedCaseInsensitiveContains("understand the permissions") })
    }

    @Test
    func decisionIsDistilledToOutcome() {
        let m = meeting(notes: "Okay so we decided to go with the blue theme")
        let decisions = MeetingIntelligenceEngine.decisions(for: m)
        #expect(decisions.contains { $0.localizedCaseInsensitiveContains("blue theme") })
        #expect(!decisions.contains { $0.localizedCaseInsensitiveContains("decided") })
        #expect(!decisions.contains { $0.localizedCaseInsensitiveContains("okay") })
    }

    @Test
    func namedOwnerIsDroppedFromActionText() throws {
        let m = meeting(notes: "- Maya will review the contract by Monday", attendees: ["Maya"])
        let action = try #require(MeetingIntelligenceEngine.structuredActions(for: m).first)
        #expect(action.owner == "Maya")
        #expect(action.text.hasPrefix("Review"))          // name moved to owner, not text
        #expect(!action.text.localizedCaseInsensitiveContains("will"))
    }

    @Test
    func closingQuestionsAreNotOpenQuestions() {
        let m = meeting(notes: "Great work everyone today.\nAny questions?")
        #expect(MeetingIntelligenceEngine.report(for: m).openQuestions.isEmpty)
    }

    @Test
    func commitmentSentenceReadsAsOwnerTaskDue() {
        let action = ExtractedActionItem(text: "Send the deck.", owner: "Maya", dueHint: "friday", sourceSpeaker: "Maya")
        #expect(MeetingIntelligenceEngine.commitmentSentence(action) == "Maya — send the deck (by Friday)")
    }
}

// MARK: - Real due dates / overdue

struct DueDateTests {
    private let cal = Calendar.current
    private let ref = Date(timeIntervalSince1970: 1_780_000_000) // fixed reference

    @Test
    func tomorrowResolvesToNextDay() throws {
        let due = try #require(DueDateParser.date(from: "tomorrow", capturedAt: ref, calendar: cal))
        let expected = try #require(cal.date(byAdding: .day, value: 1, to: ref))
        #expect(cal.isDate(due, inSameDayAs: expected))
    }

    @Test
    func eodResolvesToSameDay() throws {
        let due = try #require(DueDateParser.date(from: "eod", capturedAt: ref, calendar: cal))
        #expect(cal.isDate(due, inSameDayAs: ref))
    }

    @Test
    func weekdayResolvesToFridayOnOrAfterRef() throws {
        let due = try #require(DueDateParser.date(from: "by Friday", capturedAt: ref, calendar: cal))
        #expect(cal.component(.weekday, from: due) == 6) // Friday
        #expect(due >= cal.startOfDay(for: ref))
        let within7 = try #require(cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: ref)))
        #expect(due <= within7)
    }

    @Test
    func vagueOrMissingHintIsNil() {
        #expect(DueDateParser.date(from: "q3", capturedAt: ref, calendar: cal) == nil)
        #expect(DueDateParser.date(from: nil, capturedAt: ref, calendar: cal) == nil)
    }

    @Test
    func itemFromPastDeadlineIsOverdue() {
        let past = cal.date(byAdding: .day, value: -10, to: Date()) ?? Date()
        let commitment = Commitment(statement: "Send deck", owner: "You", sourceSpeaker: "You", dueHint: "today", status: .open)
        let item = AggregatedActionItem(commitment: commitment, meetingID: UUID(), meetingTitle: "M", workspace: "W", meetingDate: past, isMeetingPinned: false)
        #expect(item.isOverdue)
        #expect(!item.isDueSoon)
    }

    @Test
    func itemDueTomorrowIsDueSoonNotOverdue() {
        let commitment = Commitment(statement: "Reply", owner: "You", sourceSpeaker: "You", dueHint: "tomorrow", status: .open)
        let item = AggregatedActionItem(commitment: commitment, meetingID: UUID(), meetingTitle: "M", workspace: "W", meetingDate: Date(), isMeetingPinned: false)
        #expect(item.isDueSoon)
        #expect(!item.isOverdue)
    }
}
