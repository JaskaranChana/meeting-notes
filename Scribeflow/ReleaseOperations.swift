import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ReleaseReadinessState: String, Codable, Hashable, Sendable {
    case ready
    case external
    case attention

    var title: String {
        switch self {
        case .ready: "Ready"
        case .external: "External setup"
        case .attention: "Needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .external: "hourglass.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: AppPalette.success
        case .external: AppPalette.gold
        case .attention: AppPalette.coral
        }
    }
}

struct ReleaseReadinessCheck: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: ReleaseReadinessState
}

struct ReleaseReadinessSnapshot: Codable, Hashable, Sendable {
    let generatedAt: Date
    let checks: [ReleaseReadinessCheck]

    var attentionCount: Int { checks.filter { $0.state == .attention }.count }
    var externalCount: Int { checks.filter { $0.state == .external }.count }
}

enum ReleaseReadinessBuilder {
    static func make(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> ReleaseReadinessSnapshot {
        let privacyManifestPresent = bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil
        let microphoneCopyPresent = nonEmptyInfoValue("NSMicrophoneUsageDescription", bundle: bundle)
        let speechCopyPresent = nonEmptyInfoValue("NSSpeechRecognitionUsageDescription", bundle: bundle)
        let automaticBackupsEnabled = defaults.object(forKey: "scribeflow.automaticBackupsEnabled") == nil
            || defaults.bool(forKey: "scribeflow.automaticBackupsEnabled")

        return ReleaseReadinessSnapshot(
            generatedAt: .now,
            checks: [
                ReleaseReadinessCheck(
                    id: "privacy-manifest",
                    title: "Privacy manifest",
                    detail: privacyManifestPresent
                        ? "Included in the application bundle."
                        : "PrivacyInfo.xcprivacy is missing from the built application.",
                    state: privacyManifestPresent ? .ready : .attention
                ),
                ReleaseReadinessCheck(
                    id: "permission-copy",
                    title: "Recording permissions",
                    detail: microphoneCopyPresent && speechCopyPresent
                        ? "Microphone and speech usage descriptions are present."
                        : "One or more recording permission descriptions are missing.",
                    state: microphoneCopyPresent && speechCopyPresent ? .ready : .attention
                ),
                ReleaseReadinessCheck(
                    id: "identity-boundary",
                    title: "Account boundary",
                    detail: "Release uses one Keychain-backed session and complete deletion path.",
                    state: .ready
                ),
                ReleaseReadinessCheck(
                    id: "local-recovery",
                    title: "Automatic recovery",
                    detail: automaticBackupsEnabled
                        ? "Protected local snapshots are enabled."
                        : "The user has disabled automatic local snapshots.",
                    state: automaticBackupsEnabled ? .ready : .external
                ),
                ReleaseReadinessCheck(
                    id: "transcription-backend",
                    title: "Production transcription",
                    detail: BackendConfiguration.current() == nil
                        ? "Add the production URL and backend-issued auth before claiming cloud transcription."
                        : "A valid HTTPS production endpoint is configured.",
                    state: BackendConfiguration.current() == nil ? .external : .ready
                ),
                ReleaseReadinessCheck(
                    id: "cloud-provisioning",
                    title: "Private iCloud backup",
                    detail: ScribeflowCloudBackupService.isConfigured
                        ? "The build flag is enabled; verify the profile and deployed CloudKit schema on device."
                        : "Enable only after the container, profile, and production schema are ready.",
                    state: ScribeflowCloudBackupService.isConfigured ? .ready : .external
                )
            ]
        )
    }

    private static func nonEmptyInfoValue(_ key: String, bundle: Bundle) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum DiagnosticPayloadKind: String, Codable, Hashable, Sendable {
    case metrics
    case diagnostics
}

struct StoredDiagnosticPayload: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let receivedAt: Date
    let kind: DiagnosticPayloadKind
    let originalByteCount: Int
    let payload: Data
}

struct DiagnosticsArchiveSummary: Hashable, Sendable {
    let payloadCount: Int
    let totalBytes: Int
    let latestDate: Date?
}

private struct DiagnosticsExportPackage: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
    let buildNumber: String
    let operatingSystem: String
    let readiness: ReleaseReadinessSnapshot
    let payloads: [StoredDiagnosticPayload]
}

actor DiagnosticsArchive {
    static let shared = DiagnosticsArchive()

    private let maximumPayloads = 8
    private let maximumPayloadBytes = 4 * 1_024 * 1_024
    private let fileURL: URL
    private var payloads: [StoredDiagnosticPayload]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = base.appendingPathComponent("Scribeflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("diagnostics.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        payloads = (try? Data(contentsOf: fileURL))
            .flatMap { try? decoder.decode([StoredDiagnosticPayload].self, from: $0) }
            ?? []
    }

    func append(kind: DiagnosticPayloadKind, data: Data) {
        let storedData: Data
        if data.count <= maximumPayloadBytes {
            storedData = data
        } else {
            let summary = "{\"truncated\":true,\"originalByteCount\":\(data.count)}"
            storedData = Data(summary.utf8)
        }

        payloads.append(StoredDiagnosticPayload(
            id: UUID(),
            receivedAt: .now,
            kind: kind,
            originalByteCount: data.count,
            payload: storedData
        ))
        if payloads.count > maximumPayloads {
            payloads.removeFirst(payloads.count - maximumPayloads)
        }
        persist()
    }

    func summary() -> DiagnosticsArchiveSummary {
        DiagnosticsArchiveSummary(
            payloadCount: payloads.count,
            totalBytes: payloads.reduce(0) { $0 + $1.payload.count },
            latestDate: payloads.map(\.receivedAt).max()
        )
    }

    func exportData(readiness: ReleaseReadinessSnapshot, bundle: Bundle = .main) throws -> Data {
        let package = DiagnosticsExportPackage(
            schemaVersion: 1,
            generatedAt: .now,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            readiness: readiness,
            payloads: payloads
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(package)
    }

    func clear() {
        payloads.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payloads) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }
}

struct DiagnosticsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()

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

struct DiagnosticsAndReadinessView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var readiness = ReleaseReadinessBuilder.make()
    @State private var archiveSummary = DiagnosticsArchiveSummary(payloadCount: 0, totalBytes: 0, latestDate: nil)
    @State private var exportDocument = DiagnosticsDocument()
    @State private var showingExporter = false
    @State private var resultMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    readinessSection
                    diagnosticsSection
                }
                .appScreenContent(top: AppSpacing.lg, bottom: AppLayout.sheetBottomPadding)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle(AppStrings.Screen.appHealth)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppStrings.Action.done) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { await refresh() }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "Scribeflow Diagnostics"
            ) { result in
                resultMessage = result.isSuccess
                    ? "Diagnostics exported."
                    : "Diagnostics export was not completed."
            }
            .alert("App health", isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )) {
                Button("OK", role: .cancel) { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
        }
        .modifier(ScribeflowChrome())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorialEyebrow(text: "Private diagnostics")
            Text(readiness.attentionCount == 0 ? "Core checks are healthy" : "Action is required")
                .font(.system(.title, design: .serif).weight(.medium))
                .foregroundStyle(AppPalette.ink)
            Text("\(readiness.externalCount) item\(readiness.externalCount == 1 ? "" : "s") depend on external service or Apple configuration.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Readiness")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppPalette.ink)
                .padding(.bottom, 8)

            ForEach(Array(readiness.checks.enumerated()), id: \.element.id) { index, check in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: check.state.systemImage)
                        .foregroundStyle(check.state.tint)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(check.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            Spacer()
                            Text(check.state.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(check.state.tint)
                        }
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(AppPalette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 12)
                if index < readiness.checks.count - 1 {
                    Divider().padding(.leading, 36)
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MetricKit archive")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(diagnosticsDetail)
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                }
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(AppPalette.accent)
            }

            Button {
                prepareExport()
            } label: {
                Label("Export diagnostics", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.ink)

            Button(role: .destructive) {
                Task {
                    await DiagnosticsArchive.shared.clear()
                    await refresh()
                }
            } label: {
                Label("Clear diagnostics", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Label("Stored only on this device until you explicitly export it.", systemImage: "lock.shield.fill")
                .font(.footnote)
                .foregroundStyle(AppPalette.secondaryInk)
        }
    }

    private var diagnosticsDetail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(archiveSummary.totalBytes), countStyle: .file)
        guard let latestDate = archiveSummary.latestDate else { return "No payloads received yet." }
        return "\(archiveSummary.payloadCount) payload\(archiveSummary.payloadCount == 1 ? "" : "s"), \(size), latest \(latestDate.formatted(date: .abbreviated, time: .shortened))."
    }

    private func refresh() async {
        readiness = ReleaseReadinessBuilder.make()
        archiveSummary = await DiagnosticsArchive.shared.summary()
    }

    private func prepareExport() {
        Task {
            do {
                let data = try await DiagnosticsArchive.shared.exportData(readiness: readiness)
                exportDocument = DiagnosticsDocument(data: data)
                showingExporter = true
            } catch {
                resultMessage = "Diagnostics could not be prepared."
            }
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
