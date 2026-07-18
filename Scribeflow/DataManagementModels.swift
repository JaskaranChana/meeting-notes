import Foundation
import CloudKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct StorageRecordingItem: Identifiable, Hashable, Sendable {
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

struct StorageSnapshot: Equatable, Sendable {
    let notesCount: Int
    let recordingsCount: Int
    let audioBytes: Int
    let databaseBytes: Int
    let recordings: [StorageRecordingItem]

    static let empty = StorageSnapshot(
        notesCount: 0,
        recordingsCount: 0,
        audioBytes: 0,
        databaseBytes: 0,
        recordings: []
    )

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

struct StorageRecordingDescriptor: Sendable {
    let meetingID: Meeting.ID
    let recordingID: AudioRecordingAttachment.ID
    let meetingTitle: String
    let recordingTitle: String
    let fileName: String
    let createdAt: Date
    let durationSeconds: Int
}

actor StorageSnapshotService {
    static let shared = StorageSnapshotService()

    func makeSnapshot(
        notesCount: Int,
        recordings descriptors: [StorageRecordingDescriptor],
        databaseURL: URL
    ) -> StorageSnapshot {
        let recordings = descriptors.map { descriptor in
            StorageRecordingItem(
                meetingID: descriptor.meetingID,
                recordingID: descriptor.recordingID,
                meetingTitle: descriptor.meetingTitle,
                recordingTitle: descriptor.recordingTitle,
                fileName: descriptor.fileName,
                createdAt: descriptor.createdAt,
                durationSeconds: descriptor.durationSeconds,
                sizeBytes: RecordingFileStore.fileSize(
                    at: RecordingFileStore.url(for: descriptor.fileName)
                )
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
        let audioBytes = recordings.reduce(0) { $0 + $1.sizeBytes }
        let databaseBytes = RecordingFileStore.fileSize(at: databaseURL)

        return StorageSnapshot(
            notesCount: notesCount,
            recordingsCount: recordings.count,
            audioBytes: audioBytes,
            databaseBytes: databaseBytes,
            recordings: recordings
        )
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

struct ScribeflowBackupAudioFile: Codable, Sendable {
    var fileName: String
    var data: Data
}

struct ScribeflowBackupPackage: Codable {
    var schemaVersion: Int
    var exportedAt: Date
    var meetings: [Meeting]
    var audioFiles: [ScribeflowBackupAudioFile]
}

struct ScribeflowBackupPreview: Hashable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let meetingsCount: Int
    let audioFilesCount: Int

    var includesAudio: Bool {
        audioFilesCount > 0
    }

    var exportedAtLabel: String {
        exportedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var summary: String {
        "\(meetingsCount) note\(meetingsCount == 1 ? "" : "s")"
            + " and \(audioFilesCount) audio file\(audioFilesCount == 1 ? "" : "s")"
    }
}

struct ScribeflowBackupPayload: Sendable {
    let data: Data
    let preview: ScribeflowBackupPreview
}

/// Decoded on the backup actor and then transferred once to the main actor for
/// an atomic library replacement. No code mutates the package concurrently.
struct PreparedBackupRestore: @unchecked Sendable {
    let package: ScribeflowBackupPackage

    var preview: ScribeflowBackupPreview {
        ScribeflowBackupPreview(
            schemaVersion: package.schemaVersion,
            exportedAt: package.exportedAt,
            meetingsCount: package.meetings.count,
            audioFilesCount: package.audioFiles.count
        )
    }
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
    static let title = "Local-first account"
    static let subtitle = "Manual exports and private iCloud backup are user-controlled."
    static let backendRequirement = "Private backup includes integrity and conflict protection. Live record-level multi-device sync is a separate future product decision."
}

struct CloudBackupReceipt: Hashable {
    let exportedAt: Date
    let meetingsCount: Int
    let audioFilesCount: Int
    let byteCount: Int
    let includesAudio: Bool
    let contentDigest: String?

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return "\(meetingsCount) note\(meetingsCount == 1 ? "" : "s"), \(audioFilesCount) audio file\(audioFilesCount == 1 ? "" : "s"), \(size)"
    }
}

enum CloudBackupAccountState: Hashable {
    case unknown
    case checking
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unavailable(String)

    init(status: CKAccountStatus) {
        switch status {
        case .available:
            self = .available
        case .noAccount:
            self = .noAccount
        case .restricted:
            self = .restricted
        case .temporarilyUnavailable:
            self = .temporarilyUnavailable
        case .couldNotDetermine:
            self = .unknown
        @unknown default:
            self = .unknown
        }
    }

    var isAvailable: Bool {
        self == .available
    }

    var title: String {
        switch self {
        case .unknown:
            "Not checked"
        case .checking:
            "Checking"
        case .available:
            "iCloud available"
        case .noAccount:
            "Sign in required"
        case .restricted:
            "iCloud restricted"
        case .temporarilyUnavailable:
            "Temporarily unavailable"
        case .unavailable:
            "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            "Check iCloud before saving a cloud backup."
        case .checking:
            "Checking the iCloud account on this device."
        case .available:
            "Ready to save a private backup in the user's iCloud account."
        case .noAccount:
            "The user needs to sign in to iCloud in Settings."
        case .restricted:
            "iCloud is restricted by device policy or parental controls."
        case .temporarilyUnavailable:
            "iCloud is temporarily unavailable. Try again later."
        case .unavailable(let message):
            message
        }
    }
}

enum ScribeflowCloudBackupError: LocalizedError {
    case notConfigured
    case noBackup
    case missingAsset
    case unreadableAsset
    case remoteChanged
    case integrityMismatch

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "iCloud backup needs the CloudKit entitlement and container before it can run on device."
        case .noBackup:
            "No iCloud backup was found for this account."
        case .missingAsset:
            "The iCloud backup record is missing its backup file."
        case .unreadableAsset:
            "The iCloud backup file could not be read on this device."
        case .remoteChanged:
            "A newer or unknown iCloud backup already exists. Restore it before replacing it."
        case .integrityMismatch:
            "The downloaded iCloud backup did not pass its integrity check. The local library was not changed."
        }
    }
}

enum ScribeflowCloudBackupService {
    static let containerIdentifier = "iCloud.ai.scribeflow.app"
    static let enabledInfoKey = "SCRIBEFLOW_CLOUD_BACKUP_ENABLED"

    static var isConfigured: Bool {
        if let raw = ProcessInfo.processInfo.environment[enabledInfoKey] {
            return (raw as NSString).boolValue
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: enabledInfoKey) as? NSNumber {
            return value.boolValue
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: enabledInfoKey) as? String {
            return (value as NSString).boolValue
        }
        return false
    }

    private static let recordType = "ScribeflowBackup"
    private static let recordName = "primary-backup"

    private enum Field {
        static let backupFile = "backupFile"
        static let exportedAt = "exportedAt"
        static let schemaVersion = "schemaVersion"
        static let meetingsCount = "meetingsCount"
        static let audioFilesCount = "audioFilesCount"
        static let byteCount = "byteCount"
        static let includesAudio = "includesAudio"
        static let contentDigest = "contentDigest"
        static let libraryID = "libraryID"
        static let clientVersion = "clientVersion"
    }

    private static let metadataDigestKey = "scribeflow.cloud.lastKnownDigest"
    private static let metadataChangeTagKey = "scribeflow.cloud.lastKnownChangeTag"
    private static let libraryIDKey = "scribeflow.cloud.libraryID"
    private static let io = CloudBackupIO()

    static func accountState() async -> CloudBackupAccountState {
        guard isConfigured else {
            return .unavailable("Enable the CloudKit entitlement and container before using iCloud backup on device.")
        }
        do {
            let status = try await container.accountStatus()
            return CloudBackupAccountState(status: status)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func upload(
        data: Data,
        preview: ScribeflowBackupPreview,
        includesAudio: Bool
    ) async throws -> CloudBackupReceipt {
        guard isConfigured else { throw ScribeflowCloudBackupError.notConfigured }
        let recordID = CKRecord.ID(recordName: recordName)
        let existing = try await existingRecord(id: recordID)
        let digest = await io.digest(for: data)
        try validateUpload(existingRecord: existing, newDigest: digest)
        let record = existing ?? CKRecord(recordType: recordType, recordID: recordID)

        let fileURL = try await io.temporaryBackupFileURL(data: data)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        record[Field.backupFile] = CKAsset(fileURL: fileURL)
        record[Field.exportedAt] = preview.exportedAt as CKRecordValue
        record[Field.schemaVersion] = NSNumber(value: preview.schemaVersion)
        record[Field.meetingsCount] = NSNumber(value: preview.meetingsCount)
        record[Field.audioFilesCount] = NSNumber(value: preview.audioFilesCount)
        record[Field.byteCount] = NSNumber(value: data.count)
        record[Field.includesAudio] = NSNumber(value: includesAudio)
        record[Field.contentDigest] = digest as CKRecordValue
        record[Field.libraryID] = localLibraryID as CKRecordValue
        record[Field.clientVersion] = appVersion as CKRecordValue

        let savedRecord: CKRecord
        do {
            savedRecord = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw ScribeflowCloudBackupError.remoteChanged
        }
        remember(savedRecord, fallbackDigest: digest)
        return receipt(from: savedRecord, fallbackByteCount: data.count)
    }

    static func download() async throws -> (data: Data, receipt: CloudBackupReceipt) {
        guard isConfigured else { throw ScribeflowCloudBackupError.notConfigured }
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await database.record(for: recordID)
        guard let asset = record[Field.backupFile] as? CKAsset else {
            throw ScribeflowCloudBackupError.missingAsset
        }
        guard let fileURL = asset.fileURL else {
            throw ScribeflowCloudBackupError.unreadableAsset
        }
        let data = try await io.data(contentsOf: fileURL)
        let digest = await io.digest(for: data)
        if let expectedDigest = record[Field.contentDigest] as? String,
           expectedDigest != digest {
            throw ScribeflowCloudBackupError.integrityMismatch
        }
        remember(record, fallbackDigest: digest)
        return (data, receipt(from: record, fallbackByteCount: data.count))
    }

    static func deleteBackup() async throws {
        guard isConfigured else { throw ScribeflowCloudBackupError.notConfigured }
        let recordID = CKRecord.ID(recordName: recordName)
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            // Deletion is idempotent: an already-missing backup is success.
        }
        resetLocalMetadata()
    }

    static func resetLocalMetadata() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: metadataDigestKey)
        defaults.removeObject(forKey: metadataChangeTagKey)
        defaults.removeObject(forKey: libraryIDKey)
    }

    private static var container: CKContainer {
        CKContainer(identifier: containerIdentifier)
    }

    private static var database: CKDatabase {
        container.privateCloudDatabase
    }

    private static func existingRecord(id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private static func validateUpload(existingRecord: CKRecord?, newDigest: String) throws {
        guard let existingRecord else { return }
        let remoteDigest = existingRecord[Field.contentDigest] as? String
        if remoteDigest == newDigest { return }

        let lastKnownDigest = UserDefaults.standard.string(forKey: metadataDigestKey)
        guard let remoteDigest, remoteDigest == lastKnownDigest else {
            throw ScribeflowCloudBackupError.remoteChanged
        }
    }

    private static func remember(_ record: CKRecord, fallbackDigest: String) {
        let defaults = UserDefaults.standard
        defaults.set((record[Field.contentDigest] as? String) ?? fallbackDigest, forKey: metadataDigestKey)
        defaults.set(record.recordChangeTag, forKey: metadataChangeTagKey)
    }

    private static var localLibraryID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: libraryIDKey), !existing.isEmpty {
            return existing
        }
        let identifier = UUID().uuidString
        defaults.set(identifier, forKey: libraryIDKey)
        return identifier
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static func receipt(from record: CKRecord, fallbackByteCount: Int) -> CloudBackupReceipt {
        let exportedAt = record[Field.exportedAt] as? Date
            ?? record.modificationDate
            ?? .now
        let meetingsCount = (record[Field.meetingsCount] as? NSNumber)?.intValue ?? 0
        let audioFilesCount = (record[Field.audioFilesCount] as? NSNumber)?.intValue ?? 0
        let byteCount = (record[Field.byteCount] as? NSNumber)?.intValue ?? fallbackByteCount
        let includesAudio = (record[Field.includesAudio] as? NSNumber)?.boolValue ?? (audioFilesCount > 0)
        let contentDigest = record[Field.contentDigest] as? String
        return CloudBackupReceipt(
            exportedAt: exportedAt,
            meetingsCount: meetingsCount,
            audioFilesCount: audioFilesCount,
            byteCount: byteCount,
            includesAudio: includesAudio,
            contentDigest: contentDigest
        )
    }
}

private actor CloudBackupIO {
    func temporaryBackupFileURL(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribeflow-icloud-backup-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic])
        return url
    }

    func data(contentsOf url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func digest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
