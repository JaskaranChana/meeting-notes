import Foundation

enum AudioRecordingSource: String, Codable, CaseIterable, Identifiable {
    case voiceNote
    case noteAttachment
    case compliantCall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voiceNote:
            "Voice note"
        case .noteAttachment:
            "Note attachment"
        case .compliantCall:
            "Provider call"
        }
    }

    var systemImage: String {
        switch self {
        case .voiceNote:
            "waveform.badge.mic"
        case .noteAttachment:
            "paperclip"
        case .compliantCall:
            "phone.badge.waveform"
        }
    }
}

struct AudioRecordingAttachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var durationSeconds: Int
    var fileName: String
    var transcript: String
    var linkedNote: String
    var source: AudioRecordingSource
    var fileSizeBytes: Int

    var durationLabel: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var durationMinutes: Int {
        max(1, Int(ceil(Double(durationSeconds) / 60.0)))
    }

    var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum LibraryTypeFilter: String, CaseIterable, Identifiable {
    case all
    case voice
    case calls
    case live
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .voice:
            "Voice"
        case .calls:
            "Calls"
        case .live:
            "Live"
        case .notes:
            "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "tray.full.fill"
        case .voice:
            "waveform"
        case .calls:
            "phone.fill"
        case .live:
            "dot.radiowaves.left.and.right"
        case .notes:
            "doc.text.fill"
        }
    }
}

enum LibraryDateFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case sevenDays
    case thirtyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "Any time"
        case .today:
            "Today"
        case .sevenDays:
            "7 days"
        case .thirtyDays:
            "30 days"
        }
    }
}

enum LibrarySortMode: String, CaseIterable, Identifiable {
    case newest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest:
            "Newest"
        case .title:
            "Title"
        }
    }
}

enum RecordingFileStore {
    static let directoryName = "Recordings"

    static var directoryURL: URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseDirectory
            .appendingPathComponent("Scribeflow", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = directoryURL
        try? mutableURL.setResourceValues(resourceValues)
    }

    static func makeRecordingURL(id: UUID = UUID()) throws -> URL {
        try ensureDirectory()
        return directoryURL.appendingPathComponent("\(id.uuidString).m4a", isDirectory: false)
    }

    static func url(for fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    static func fileName(for url: URL) -> String {
        url.lastPathComponent
    }

    static func protectFile(at url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    static func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    static func deleteFile(named fileName: String) {
        let url = url(for: fileName)
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAllFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
