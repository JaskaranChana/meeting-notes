import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct StorageRecordingItem: Identifiable, Hashable {
    var id: String { "\(meetingID.uuidString)-\(recordingID.uuidString)" }
    let meetingID: Meeting.ID
    let recordingID: AudioRecordingAttachment.ID
    let meetingTitle: String
    let recordingTitle: String
    let fileName: String
    let createdAt: Date
    let durationSeconds: Int
    let sizeBytes: Int

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    var durationLabel: String {
        String(format: "%02d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
}

struct StorageSnapshot: Equatable {
    let notesCount: Int
    let recordingsCount: Int
    let audioBytes: Int
    let databaseBytes: Int
    let recordings: [StorageRecordingItem]

    var totalBytes: Int { audioBytes + databaseBytes }
    var audioFraction: Double { totalBytes > 0 ? Double(audioBytes) / Double(totalBytes) : 0 }
    var audioSizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(audioBytes), countStyle: .file) }
    var databaseSizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(databaseBytes), countStyle: .file) }
    var totalSizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file) }

    func recordingsLargerThan(bytes: Int) -> [StorageRecordingItem] {
        recordings.filter { $0.sizeBytes >= bytes }
    }

    func recordingsOlderThan(days: Int, now: Date = .now) -> [StorageRecordingItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return recordings.filter { $0.createdAt < cutoff }
    }
}

enum StorageCleanupAction: Hashable, Identifiable {
    case largeRecordings(minimumBytes: Int)
    case olderRecordings(days: Int)
    case allRecordings

    var id: String {
        switch self {
        case .largeRecordings(let minimumBytes):
            "large-\(minimumBytes)"
        case .olderRecordings(let days):
            "older-\(days)"
        case .allRecordings:
            "all-recordings"
        }
    }

    var title: String {
        switch self {
        case .largeRecordings(let minimumBytes):
            "Delete audio over \(ByteCountFormatter.string(fromByteCount: Int64(minimumBytes), countStyle: .file))?"
        case .olderRecordings(let days):
            "Delete audio older than \(days) days?"
        case .allRecordings:
            "Delete all local audio?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .largeRecordings:
            "Transcripts and notes stay in the app, but matching audio files will be removed from this device."
        case .olderRecordings:
            "This keeps notes and transcripts while removing older audio files from local storage."
        case .allRecordings:
            "This removes every local recording file and leaves notes/transcripts behind."
        }
    }
}

struct ScribeflowBackupAudioFile: Codable {
    var fileName: String
    var data: Data
}

struct ScribeflowBackupPackage: Codable {
    var schemaVersion: Int
    var exportedAt: Date
    var meetings: [Meeting]
    var audioFiles: [ScribeflowBackupAudioFile]
}

struct ScribeflowBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum LocalAccountSyncStatus {
    static let title = "Local-only account"
    static let subtitle = "No account or cloud sync backend is configured yet."
    static let backendRequirement = "To ship cross-device sync, Scribeflow needs authentication, encrypted cloud storage, conflict resolution, and account deletion on the server."
}
