import AVFoundation
import Foundation

enum AudioPCMBufferCopy {
    static func make(from source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        destination.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData
            else { continue }
            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return destination
    }
}

struct ImportedAudioFile: Sendable {
    let recordingID: UUID
    let fileName: String
    let fileSizeBytes: Int
    let durationSeconds: Int
}

enum AudioImportError: LocalizedError {
    case emptyFile
    case unsupportedFormat
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            "The selected audio file is empty."
        case .unsupportedFormat:
            "Choose an M4A, MP3, WAV, AIFF, CAF, MP4, or MOV audio file."
        case .insufficientStorage:
            "There is not enough free space to import this audio safely."
        }
    }
}

actor AudioImportService {
    static let shared = AudioImportService()

    private let supportedExtensions: Set<String> = [
        "m4a", "mp3", "wav", "wave", "aif", "aiff", "caf", "mp4", "mov"
    ]

    func importFile(from sourceURL: URL) async throws -> ImportedAudioFile {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values.fileSize ?? 0
        guard fileSize > 0 else { throw AudioImportError.emptyFile }

        let pathExtension = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(pathExtension) else {
            throw AudioImportError.unsupportedFormat
        }

        try RecordingFileStore.ensureDirectory()
        let available = try? RecordingFileStore.directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        let requiredBytes = Int64(fileSize) + 64 * 1_024 * 1_024
        if let available, available < requiredBytes {
            throw AudioImportError.insufficientStorage
        }

        let recordingID = UUID()
        let destination = try RecordingFileStore.makeRecordingURL(
            id: recordingID,
            pathExtension: pathExtension
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            RecordingFileStore.protectFile(at: destination)

            let asset = AVURLAsset(url: destination)
            let duration = try? await asset.load(.duration)
            let seconds = duration.map { CMTimeGetSeconds($0) } ?? 0
            return ImportedAudioFile(
                recordingID: recordingID,
                fileName: RecordingFileStore.fileName(for: destination),
                fileSizeBytes: RecordingFileStore.fileSize(at: destination),
                durationSeconds: seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

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
    var transcriptionSegments: [TranscriptionSegment]
    var transcriptionProvider: TranscriptionProviderKind?
    var diarizationAvailable: Bool

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        durationSeconds: Int,
        fileName: String,
        transcript: String,
        linkedNote: String,
        source: AudioRecordingSource,
        fileSizeBytes: Int,
        transcriptionSegments: [TranscriptionSegment] = [],
        transcriptionProvider: TranscriptionProviderKind? = nil,
        diarizationAvailable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.fileName = fileName
        self.transcript = transcript
        self.linkedNote = linkedNote
        self.source = source
        self.fileSizeBytes = fileSizeBytes
        self.transcriptionSegments = transcriptionSegments
        self.transcriptionProvider = transcriptionProvider
        self.diarizationAvailable = diarizationAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case durationSeconds
        case fileName
        case transcript
        case linkedNote
        case source
        case fileSizeBytes
        case transcriptionSegments
        case transcriptionProvider
        case diarizationAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
        fileName = try container.decode(String.self, forKey: .fileName)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        linkedNote = try container.decodeIfPresent(String.self, forKey: .linkedNote) ?? ""
        source = try container.decode(AudioRecordingSource.self, forKey: .source)
        fileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .fileSizeBytes) ?? 0
        transcriptionSegments = try container.decodeIfPresent(
            [TranscriptionSegment].self,
            forKey: .transcriptionSegments
        ) ?? []
        transcriptionProvider = try container.decodeIfPresent(
            TranscriptionProviderKind.self,
            forKey: .transcriptionProvider
        )
        diarizationAvailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .diarizationAvailable
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(linkedNote, forKey: .linkedNote)
        try container.encode(source, forKey: .source)
        try container.encode(fileSizeBytes, forKey: .fileSizeBytes)
        try container.encode(transcriptionSegments, forKey: .transcriptionSegments)
        try container.encodeIfPresent(transcriptionProvider, forKey: .transcriptionProvider)
        try container.encode(diarizationAvailable, forKey: .diarizationAvailable)
    }

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

    var detectedSpeakerCount: Int {
        Set(transcriptionSegments.map { SpeakerIdentityResolver.canonicalKey(for: $0.speaker) })
            .filter { !$0.isEmpty }
            .count
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

    static func makeRecordingURL(
        id: UUID = UUID(),
        pathExtension: String = "m4a"
    ) throws -> URL {
        try ensureDirectory()
        let safeExtension = pathExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return directoryURL
            .appendingPathComponent(id.uuidString, isDirectory: false)
            .appendingPathExtension(safeExtension.isEmpty ? "m4a" : safeExtension)
    }

    static func adoptFile(at sourceURL: URL) throws -> URL {
        try ensureDirectory()
        let pathExtension = sourceURL.pathExtension.isEmpty ? "caf" : sourceURL.pathExtension
        let destination = directoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destination)
        } catch {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        protectFile(at: destination)
        return destination
    }

    static func url(for fileName: String) -> URL {
        directoryURL.appendingPathComponent(
            URL(fileURLWithPath: fileName).lastPathComponent,
            isDirectory: false
        )
    }

    static func fileName(for url: URL) -> String {
        url.lastPathComponent
    }

    static func protectFile(at url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
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
