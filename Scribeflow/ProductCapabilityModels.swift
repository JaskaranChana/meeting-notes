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
                title: "Account login",
                detail: "No production auth provider is configured. Add Sign in with Apple or a backend identity service before claiming accounts.",
                systemImage: "person.crop.circle.badge.exclamationmark",
                state: .needsBackend
            ),
            ProductCapabilityStatus(
                id: "cloud-sync",
                title: "Cloud sync",
                detail: "Notes, transcripts, and audio are stored locally. Cross-device sync needs encrypted server storage or CloudKit entitlements.",
                systemImage: "icloud.slash",
                state: .needsBackend
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
                detail: "Local extraction is available. Granola-level summaries need a private AI backend with evals, retention policy, and user consent.",
                systemImage: "sparkles",
                state: .localOnly
            ),
            ProductCapabilityStatus(
                id: "speaker-detection",
                title: "Speaker detection",
                detail: "Speaker labels can be parsed and corrected. Strong diarization needs a transcription provider that supports speaker separation.",
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

struct UnconfiguredCloudSyncProvider: CloudSyncProviding {
    func pushBackup(_ data: Data) async throws -> Date {
        throw CloudSyncProviderError.notConfigured
    }

    func pullLatestBackup() async throws -> Data {
        throw CloudSyncProviderError.notConfigured
    }
}

enum CloudSyncProviderError: LocalizedError, Equatable {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud sync is not configured in this build. Add an authenticated backend or CloudKit container first."
        }
    }
}
