import Foundation

enum CapturePurposeKind: String, Hashable {
    case personalNote
    case meeting
    case call

    var allowsMeetingSignals: Bool {
        self != .personalNote
    }

    var allowsAccountabilityExtraction: Bool {
        allowsMeetingSignals
    }
}

enum CapturePurposeConfidence: String, Hashable {
    case verified
    case strong
    case conservative
}

enum CapturePurposeEvidence: String, Hashable {
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

    var isPersonalCapture: Bool {
        kind == .personalNote
    }

    var allowsMeetingSignals: Bool {
        kind.allowsMeetingSignals
    }

    var allowsAccountabilityExtraction: Bool {
        kind.allowsAccountabilityExtraction
    }
}

struct MeetingPurposeClassifier {
    static let standard = MeetingPurposeClassifier()

    func classify(_ meeting: Meeting) -> CapturePurpose {
        let meetingEvidence = meetingEvidence(for: meeting)
        if !meetingEvidence.isEmpty {
            return CapturePurpose(
                kind: meetingKind(for: meeting),
                confidence: meetingEvidence.contains(.calendarEvent) || meetingEvidence.contains(.externalAttendees) ? .verified : .strong,
                evidence: meetingEvidence
            )
        }

        let personalEvidence = personalEvidence(for: meeting)
        if !personalEvidence.isEmpty {
            return CapturePurpose(
                kind: .personalNote,
                confidence: personalEvidence.contains(.soloVoiceNote) ? .verified : .strong,
                evidence: personalEvidence
            )
        }

        // Accuracy bias: ambiguous private captures stay personal until the
        // user adds meeting proof. Better to omit a task than invent one.
        return CapturePurpose(
            kind: .personalNote,
            confidence: .conservative,
            evidence: [.privateCapture]
        )
    }

    private func meetingKind(for meeting: Meeting) -> CapturePurposeKind {
        hasCallSignal(meeting) ? .call : .meeting
    }

    private func meetingEvidence(for meeting: Meeting) -> [CapturePurposeEvidence] {
        var evidence: [CapturePurposeEvidence] = []
        if hasCalendarContext(meeting) { evidence.append(.calendarEvent) }
        if meeting.meetingMode != .privateNotes || meeting.consentState != .privateCapture {
            evidence.append(.disclosedMode)
        }
        if hasExternalAttendees(meeting) { evidence.append(.externalAttendees) }
        if meeting.audioRecordings.contains(where: { $0.source == .compliantCall }) {
            evidence.append(.callRecording)
        }
        if hasMeetingLabel(meeting) { evidence.append(.meetingLabel) }
        return evidence
    }

    private func personalEvidence(for meeting: Meeting) -> [CapturePurposeEvidence] {
        var evidence: [CapturePurposeEvidence] = []
        let workspaceText = meeting.workspace.lowercased()
        let titleText = meeting.title.lowercased()
        let objectiveText = meeting.objective.lowercased()
        let stageText = meeting.stage.lowercased()

        if workspaceText.contains("personal")
            || workspaceText.contains("voice notes")
            || workspaceText.contains("journal") {
            evidence.append(.personalWorkspace)
        }
        if titleText.contains("voice note")
            || titleText.contains("quick note")
            || titleText.contains("personal")
            || objectiveText.contains("voice note")
            || stageText.contains("voice note") {
            evidence.append(.personalTitle)
        }
        if !meeting.audioRecordings.isEmpty,
           meeting.audioRecordings.allSatisfy({ $0.source == .voiceNote }) {
            evidence.append(.soloVoiceNote)
        }
        if meeting.meetingMode == .privateNotes && meeting.consentState == .privateCapture {
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

    private func hasExternalAttendees(_ meeting: Meeting) -> Bool {
        meeting.attendees.contains { attendee in
            let name = attendee.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !name.isEmpty && !["you", "me", "myself", "i", "self"].contains(name)
        }
    }

    private func hasCallSignal(_ meeting: Meeting) -> Bool {
        let workspaceText = meeting.workspace.lowercased()
        let titleText = meeting.title.lowercased()
        return workspaceText.contains("call")
            || workspaceText.contains("phone")
            || titleText.contains("call")
            || meeting.audioRecordings.contains { $0.source == .compliantCall }
    }

    private func hasMeetingLabel(_ meeting: Meeting) -> Bool {
        let workspaceText = meeting.workspace.lowercased()
        let titleText = meeting.title.lowercased()
        let objectiveText = meeting.objective.lowercased()
        return workspaceText.contains("meeting")
            || workspaceText.contains("call")
            || workspaceText.contains("client")
            || workspaceText.contains("customer")
            || workspaceText.contains("sales")
            || titleText.contains("meeting")
            || titleText.contains("call")
            || titleText.contains("sync")
            || titleText.contains("standup")
            || titleText.contains("interview")
            || titleText.contains("workshop")
            || objectiveText.contains("meeting")
    }
}
