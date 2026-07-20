import Foundation

enum RecordingCompliance {
    static let restrictedCallRecordingNotice = "Scribeflow cannot record cellular, FaceTime, WhatsApp, or audio from other apps. iOS does not provide an App Store-safe API for that."

    static let providerCallRequirement = "Two-sided call recording requires a supported calling service and participant consent."

    static let providerSetupRequired = "Call recording is unavailable in this build. You can still record a voice note or type notes during a call."

    static let localAudioStorage = "Voice notes are stored in the app container with iOS file protection and are excluded from device backups. Delete a note or recording to remove its local audio file."

    static let speechRecognition = "Transcription prefers on-device recognition. If Apple Speech fallback is enabled and local recognition is unavailable, Apple may process speech under its service terms."

    static let releasePrivacySummary = "Scribeflow does not track users or sell data. Scribeflow remote transcription is opt-in; Apple Speech fallback is controlled separately below."
}
