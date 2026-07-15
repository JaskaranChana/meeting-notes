import Foundation

enum ProductCapabilityState: String, Equatable {
    case available
    case localOnly
    case needsBackend
    case needsEntitlement

    var title: String {
        switch self {
        case .available:
            "Available"
        case .localOnly:
            "Local only"
        case .needsBackend:
            "Backend needed"
        case .needsEntitlement:
            "Entitlement needed"
        }
    }
}

struct ProductCapabilityStatus: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let state: ProductCapabilityState
}

protocol AccountSyncStatusProviding {
    func currentStatus(storage: StorageSnapshot) -> [ProductCapabilityStatus]
}

struct LocalOnlyAccountSyncService: AccountSyncStatusProviding {
    func currentStatus(storage: StorageSnapshot) -> [ProductCapabilityStatus] {
        [
            ProductCapabilityStatus(
                id: "account",
                title: "Account boundary",
                detail: "Device and Apple identity sessions are Keychain-backed. Server features require a backend-issued Scribeflow session.",
                systemImage: "person.crop.circle.badge.checkmark",
                state: .localOnly
            ),
            ProductCapabilityStatus(
                id: "cloud-sync",
                title: "iCloud backup",
                detail: "Conflict-safe private backup is ready. Enable the build flag only after the CloudKit profile and production schema are live.",
                systemImage: "icloud",
                state: .needsEntitlement
            ),
            ProductCapabilityStatus(
                id: "manual-backup",
                title: "Manual backup",
                detail: "JSON export/import is available now. Audio backup size: \(storage.audioSizeLabel).",
                systemImage: "externaldrive.fill",
                state: .available
            ),
            ProductCapabilityStatus(
                id: "ai-summary",
                title: "Meeting intelligence",
                detail: "Purpose-aware local briefs rank what matters, preserve the user's words, and keep claims tied to saved sources.",
                systemImage: "sparkles",
                state: .localOnly
            ),
            ProductCapabilityStatus(
                id: "speaker-detection",
                title: "Speaker detection",
                detail: "Speaker labels are normalized and editable. Automatic speaker separation is preserved with honest detected-versus-listed counts.",
                systemImage: "person.wave.2.fill",
                state: .localOnly
            )
        ]
    }
}

protocol CloudSyncProviding {
    func pushBackup(_ data: Data) async throws -> Date
    func pullLatestBackup() async throws -> Data
}

struct CloudKitBackupProvider: CloudSyncProviding {
    func pushBackup(_ data: Data) async throws -> Date {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(ScribeflowBackupPackage.self, from: data)
        let preview = ScribeflowBackupPreview(
            schemaVersion: package.schemaVersion,
            exportedAt: package.exportedAt,
            meetingsCount: package.meetings.count,
            audioFilesCount: package.audioFiles.count
        )
        return try await ScribeflowCloudBackupService.upload(
            data: data,
            preview: preview,
            includesAudio: !package.audioFiles.isEmpty
        ).exportedAt
    }

    func pullLatestBackup() async throws -> Data {
        try await ScribeflowCloudBackupService.download().data
    }
}

enum CloudSyncProviderError: LocalizedError, Equatable {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud sync is not enabled for this build. Add the CloudKit entitlement and container before release."
        }
    }
}
