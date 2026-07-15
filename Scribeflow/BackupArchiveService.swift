import Foundation

struct AutomaticBackupSnapshot: Identifiable, Hashable, Sendable {
    var id: String { fileName }
    let fileName: String
    let createdAt: Date
    let meetingsCount: Int
    let byteCount: Int

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var detail: String {
        "\(meetingsCount) note\(meetingsCount == 1 ? "" : "s") - \(sizeLabel)"
    }
}

enum BackupArchiveError: LocalizedError {
    case noData
    case missingAudio(String)
    case invalidSnapshot

    var errorDescription: String? {
        switch self {
        case .noData:
            "There is no Scribeflow data to back up yet."
        case .missingAudio(let fileName):
            "The full backup could not include \(fileName). Use Notes only or remove the missing recording."
        case .invalidSnapshot:
            "That automatic backup is unavailable or damaged."
        }
    }
}

actor BackupArchiveService {
    static let shared = BackupArchiveService()

    private let maximumAutomaticBackups = 7
    private let minimumAutomaticBackupInterval: TimeInterval = 6 * 60 * 60
    private var cachedLatestAutomaticBackupAt: Date?
    private var hasLoadedAutomaticBackupMetadata = false

    func makeBackupData(
        meetings: [Meeting],
        schemaVersion: Int,
        includeAudio: Bool,
        exportedAt: Date = .now
    ) throws -> Data {
        let audioFiles: [ScribeflowBackupAudioFile]
        if includeAudio {
            let fileNames = Set(meetings.flatMap { $0.audioRecordings.map(\.fileName) })
            audioFiles = try fileNames.sorted().map { fileName in
                let url = RecordingFileStore.url(for: fileName)
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    throw BackupArchiveError.missingAudio(fileName)
                }
                return ScribeflowBackupAudioFile(fileName: fileName, data: data)
            }
        } else {
            audioFiles = []
        }

        let package = ScribeflowBackupPackage(
            schemaVersion: schemaVersion,
            exportedAt: exportedAt,
            meetings: meetings,
            audioFiles: audioFiles
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(package)
    }

    @discardableResult
    func saveAutomaticBackup(
        meetings: [Meeting],
        schemaVersion: Int,
        force: Bool = false,
        now: Date = .now
    ) throws -> AutomaticBackupSnapshot? {
        guard !meetings.isEmpty else { return nil }
        try ensureDirectory()

        if !force {
            if !hasLoadedAutomaticBackupMetadata {
                _ = try automaticBackups()
            }
            if let latest = cachedLatestAutomaticBackupAt,
               now.timeIntervalSince(latest) < minimumAutomaticBackupInterval {
                return nil
            }
        }

        let data = try makeBackupData(
            meetings: meetings,
            schemaVersion: schemaVersion,
            includeAudio: false,
            exportedAt: now
        )
        let fileName = "scribeflow-auto-\(Self.fileTimestamp.string(from: now)).json"
        let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )

        try pruneAutomaticBackups()
        cachedLatestAutomaticBackupAt = now
        hasLoadedAutomaticBackupMetadata = true
        return AutomaticBackupSnapshot(
            fileName: fileName,
            createdAt: now,
            meetingsCount: meetings.count,
            byteCount: data.count
        )
    }

    func automaticBackups() throws -> [AutomaticBackupSnapshot] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshots: [AutomaticBackupSnapshot] = urls.compactMap { url -> AutomaticBackupSnapshot? in
            guard url.pathExtension.lowercased() == "json",
                  url.lastPathComponent.hasPrefix("scribeflow-auto-"),
                  let data = try? Data(contentsOf: url),
                  let package = try? decoder.decode(ScribeflowBackupPackage.self, from: data)
            else { return nil }

            return AutomaticBackupSnapshot(
                fileName: url.lastPathComponent,
                createdAt: package.exportedAt,
                meetingsCount: package.meetings.count,
                byteCount: data.count
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
        cachedLatestAutomaticBackupAt = snapshots.first?.createdAt
        hasLoadedAutomaticBackupMetadata = true
        return snapshots
    }

    func data(for snapshot: AutomaticBackupSnapshot) throws -> Data {
        guard Self.isSafeFileName(snapshot.fileName) else {
            throw BackupArchiveError.invalidSnapshot
        }
        let url = directoryURL.appendingPathComponent(snapshot.fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw BackupArchiveError.invalidSnapshot
        }
        return data
    }

    func deleteAllAutomaticBackups() {
        try? FileManager.default.removeItem(at: directoryURL)
        cachedLatestAutomaticBackupAt = nil
        hasLoadedAutomaticBackupMetadata = true
    }

    private func pruneAutomaticBackups() throws {
        let backups = try automaticBackups()
        for backup in backups.dropFirst(maximumAutomaticBackups) {
            let url = directoryURL.appendingPathComponent(backup.fileName, isDirectory: false)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private var directoryURL: URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseDirectory
            .appendingPathComponent("Scribeflow", isDirectory: true)
            .appendingPathComponent("Automatic Backups", isDirectory: true)
    }

    private static func isSafeFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && URL(fileURLWithPath: fileName).lastPathComponent == fileName
            && fileName.hasPrefix("scribeflow-auto-")
            && fileName.hasSuffix(".json")
    }

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }()
}
