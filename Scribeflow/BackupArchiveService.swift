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
    case embeddedAudioTooLarge(Int64)
    case invalidSnapshot

    var errorDescription: String? {
        switch self {
        case .noData:
            "There is no Scribeflow data to back up yet."
        case .missingAudio(let fileName):
            "The full backup could not include \(fileName). Use Notes only or remove the missing recording."
        case .embeddedAudioTooLarge(let byteCount):
            "The recordings total \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)), which is too large for a single backup file. Export Notes only and share recordings separately."
        case .invalidSnapshot:
            "That automatic backup is unavailable or damaged."
        }
    }
}

actor BackupArchiveService {
    static let shared = BackupArchiveService()

    /// The legacy JSON package embeds audio as Base64, which temporarily needs
    /// substantially more memory than the source files. Keep this bounded until
    /// a streaming archive format replaces it.
    private let maximumEmbeddedAudioBytes: Int64 = 64 * 1_024 * 1_024
    private let maximumRestoreBytes = 128 * 1_024 * 1_024
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
        try makeBackupPayload(
            meetings: meetings,
            schemaVersion: schemaVersion,
            includeAudio: includeAudio,
            exportedAt: exportedAt
        ).data
    }

    func makeBackupPayload(
        meetings: [Meeting],
        schemaVersion: Int,
        includeAudio: Bool,
        exportedAt: Date = .now
    ) throws -> ScribeflowBackupPayload {
        let audioFiles: [ScribeflowBackupAudioFile]
        if includeAudio {
            let fileNames = Set(meetings.flatMap { $0.audioRecordings.map(\.fileName) })
            let sources = try fileNames.sorted().map { fileName -> (String, URL, Int64) in
                let url = RecordingFileStore.url(for: fileName)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      let fileSize = values.fileSize,
                      fileSize > 0 else {
                    throw BackupArchiveError.missingAudio(fileName)
                }
                return (fileName, url, Int64(fileSize))
            }
            let totalAudioBytes = sources.reduce(Int64(0)) { $0 + $1.2 }
            guard totalAudioBytes <= maximumEmbeddedAudioBytes else {
                throw BackupArchiveError.embeddedAudioTooLarge(totalAudioBytes)
            }
            audioFiles = try sources.map { fileName, url, _ in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
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
        return ScribeflowBackupPayload(
            data: try encoder.encode(package),
            preview: ScribeflowBackupPreview(
                schemaVersion: schemaVersion,
                exportedAt: exportedAt,
                meetingsCount: meetings.count,
                audioFilesCount: audioFiles.count
            )
        )
    }

    func prepareRestore(
        from data: Data,
        supportedSchemaVersion: Int
    ) throws -> PreparedBackupRestore {
        PreparedBackupRestore(
            package: try decodedBackupPackage(
                from: data,
                supportedSchemaVersion: supportedSchemaVersion
            )
        )
    }

    func prepareRestore(
        from url: URL,
        supportedSchemaVersion: Int
    ) throws -> PreparedBackupRestore {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumRestoreBytes {
            throw MeetingStore.BackupError.tooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try prepareRestore(
            from: data,
            supportedSchemaVersion: supportedSchemaVersion
        )
    }

    func installRecordingFiles(from preparedRestore: PreparedBackupRestore) throws {
        try replaceRecordingFiles(with: preparedRestore.package.audioFiles)
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

    private func decodedBackupPackage(
        from data: Data,
        supportedSchemaVersion: Int
    ) throws -> ScribeflowBackupPackage {
        guard data.count <= maximumRestoreBytes else {
            throw MeetingStore.BackupError.tooLarge
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package: ScribeflowBackupPackage
        do {
            package = try decoder.decode(ScribeflowBackupPackage.self, from: data)
        } catch {
            throw MeetingStore.BackupError.unreadable
        }

        guard package.schemaVersion <= supportedSchemaVersion else {
            throw MeetingStore.BackupError.newerVersion(package.schemaVersion)
        }
        guard package.schemaVersion > 0 else {
            throw MeetingStore.BackupError.invalidContents("invalid schema version")
        }
        guard Set(package.meetings.map(\.id)).count == package.meetings.count else {
            throw MeetingStore.BackupError.invalidContents("duplicate note identifiers")
        }

        let audioFileNames = package.audioFiles.map(\.fileName)
        guard Set(audioFileNames).count == audioFileNames.count else {
            throw MeetingStore.BackupError.invalidContents("duplicate audio files")
        }
        guard audioFileNames.allSatisfy(Self.isSafeBackupAudioFileName) else {
            throw MeetingStore.BackupError.invalidContents("unsafe audio file name")
        }
        let embeddedAudioBytes = package.audioFiles.reduce(Int64(0)) {
            $0 + Int64($1.data.count)
        }
        guard embeddedAudioBytes <= maximumEmbeddedAudioBytes else {
            throw MeetingStore.BackupError.tooLarge
        }
        return package
    }

    private func replaceRecordingFiles(with audioFiles: [ScribeflowBackupAudioFile]) throws {
        let fileManager = FileManager.default
        let destination = RecordingFileStore.directoryURL
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(
            "Recordings.restore-\(UUID().uuidString)",
            isDirectory: true
        )
        let rollback = parent.appendingPathComponent(
            "Recordings.rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            for audioFile in audioFiles {
                let url = staging.appendingPathComponent(audioFile.fileName, isDirectory: false)
                try audioFile.data.write(to: url, options: [.atomic])
                RecordingFileStore.protectFile(at: url)
            }

            let hadExistingDirectory = fileManager.fileExists(atPath: destination.path)
            if hadExistingDirectory {
                try fileManager.moveItem(at: destination, to: rollback)
            }

            do {
                try fileManager.moveItem(at: staging, to: destination)
                try? fileManager.removeItem(at: rollback)
                try RecordingFileStore.ensureDirectory()
            } catch {
                try? fileManager.removeItem(at: destination)
                if hadExistingDirectory {
                    try? fileManager.moveItem(at: rollback, to: destination)
                }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
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

    private static func isSafeBackupAudioFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && URL(fileURLWithPath: fileName).lastPathComponent == fileName
            && !fileName.contains("..")
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
