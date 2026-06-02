import Foundation

enum RecordingCompliance {
    static let restrictedCallRecordingNotice = "Scribeflow cannot record cellular, FaceTime, WhatsApp, or audio from other apps. iOS does not provide an App Store-safe API for that."

    static let providerCallRequirement = "Two-sided call recording requires an app-owned VoIP or telephony provider flow with participant consent, server-side recording, and backend transcription."

    static let providerSetupRequired = "Provider calling is disabled until a compliant backend is configured. The app can still capture voice notes and notes you type during a call."

    static let localAudioStorage = "Voice notes are stored in the app container with iOS file protection and are excluded from device backups. Delete a note or recording to remove its local audio file."

    static let speechRecognition = "Transcription uses Apple's Speech framework when permission is granted. Availability and accuracy depend on language, device, and system conditions."

    static let releasePrivacySummary = "Scribeflow does not track users or sell data. Current voice-note audio and transcripts stay on device unless you explicitly export or share them."
}
