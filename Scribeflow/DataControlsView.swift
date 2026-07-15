import CloudKit
import SwiftUI
import UniformTypeIdentifiers

struct DataControlsView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage("scribeflow.lastManualBackupAt") private var lastManualBackupAt = 0.0
    @AppStorage("scribeflow.lastManualBackupIncludedAudio") private var lastManualBackupIncludedAudio = false
    @AppStorage("scribeflow.lastCloudBackupAt") private var lastCloudBackupAt = 0.0
    @AppStorage("scribeflow.lastCloudBackupIncludedAudio") private var lastCloudBackupIncludedAudio = false
    @AppStorage("scribeflow.automaticBackupsEnabled") private var automaticBackupsEnabled = true

    @State private var backupDocument = ScribeflowBackupDocument()
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingRestoreConfirmation = false
    @State private var showingDeleteAllConfirmation = false
    @State private var resultMessage: String?
    @State private var largeFileThresholdMB = 25.0
    @State private var pendingCleanupAction: StorageCleanupAction?
    @State private var pendingRestoreData: Data?
    @State private var pendingRestorePreview: ScribeflowBackupPreview?
    @State private var currentExportIncludesAudio = false
    @State private var cloudAccountState: CloudBackupAccountState = .unknown
    @State private var isUploadingCloudBackup = false
    @State private var isDownloadingCloudBackup = false
    @State private var isPreparingExport = false
    @State private var isCreatingAutomaticBackup = false
    @State private var automaticBackups: [AutomaticBackupSnapshot] = []

    private var snapshot: StorageSnapshot {
        store.storageSnapshot()
    }

    private var lastBackupDate: Date? {
        lastManualBackupAt > 0 ? Date(timeIntervalSince1970: lastManualBackupAt) : nil
    }

    private var lastBackupDetail: String {
        guard let lastBackupDate else {
            return "No manual backup has been exported yet."
        }
        let scope = lastManualBackupIncludedAudio ? "Full copy" : "Notes only"
        return "\(scope) exported \(lastBackupDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private var lastBackupValue: String {
        lastBackupDate == nil ? "Not backed up" : "Backed up"
    }

    private var lastCloudBackupDate: Date? {
        lastCloudBackupAt > 0 ? Date(timeIntervalSince1970: lastCloudBackupAt) : nil
    }

    private var lastCloudBackupDetail: String {
        guard let lastCloudBackupDate else {
            return cloudAccountState.detail
        }
        let scope = lastCloudBackupIncludedAudio ? "Full copy" : "Notes only"
        return "\(scope) saved to iCloud \(lastCloudBackupDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private var cloudBackupValue: String {
        if isUploadingCloudBackup || isDownloadingCloudBackup { return "Working" }
        if lastCloudBackupDate != nil { return "Saved" }
        return cloudAccountState.title
    }

    private var cloudActionsDisabled: Bool {
        !cloudAccountState.isAvailable || isUploadingCloudBackup || isDownloadingCloudBackup
    }

    private var latestAutomaticBackup: AutomaticBackupSnapshot? {
        automaticBackups.first
    }

    private var restoreConfirmationMessage: String {
        guard let pendingRestorePreview else {
            return "This will replace the local Scribeflow library on this device."
        }
        return "Backup from \(pendingRestorePreview.exportedAtLabel) contains \(pendingRestorePreview.summary). Restoring replaces the local Scribeflow library on this device."
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    dataSafetyCard
                    storageOverview
                    backupCard
                    automaticBackupCard
                    if ScribeflowCloudBackupService.isConfigured {
                        cloudBackupCard
                    }
                    cleanupCard
                    recordingsCard
                    dangerZone
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Storage & backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(AppPalette.ink)
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: backupDocument,
                contentType: .json,
                defaultFilename: "Scribeflow Backup"
            ) { result in
                switch result {
                case .success:
                    lastManualBackupAt = Date().timeIntervalSince1970
                    lastManualBackupIncludedAudio = currentExportIncludesAudio
                    resultMessage = currentExportIncludesAudio
                        ? "Full backup exported."
                        : "Notes-only backup exported."
                case .failure(let error):
                    resultMessage = "Backup failed: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                restore(from: result)
            }
            .confirmationDialog(
                "Delete all Scribeflow data?",
                isPresented: $showingDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete all data", role: .destructive) {
                    Task {
                        await store.deleteAllUserData()
                        resultMessage = "All local Scribeflow data was deleted."
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes notes, transcripts, recordings, and local app data from this device. Export a backup first if you may need it later.")
            }
            .confirmationDialog(
                pendingCleanupAction?.title ?? "Delete recordings?",
                isPresented: Binding(
                    get: { pendingCleanupAction != nil },
                    set: { if !$0 { pendingCleanupAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pendingCleanupAction {
                    Button("Delete recordings", role: .destructive) {
                        runCleanup(pendingCleanupAction)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingCleanupAction = nil
                }
            } message: {
                Text(pendingCleanupAction?.confirmationMessage ?? "")
            }
            .confirmationDialog(
                "Restore this backup?",
                isPresented: $showingRestoreConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore and replace local data", role: .destructive) {
                    confirmRestore()
                }
                Button("Cancel", role: .cancel) {
                    pendingRestoreData = nil
                    pendingRestorePreview = nil
                }
            } message: {
                Text(restoreConfirmationMessage)
            }
        }
        .modifier(ScribeflowChrome())
        .task {
            if ScribeflowCloudBackupService.isConfigured {
                await refreshCloudAccountState()
            }
            await refreshAutomaticBackups()
        }
        .onChange(of: automaticBackupsEnabled) { _, isEnabled in
            guard isEnabled else { return }
            createAutomaticBackup()
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            guard ScribeflowCloudBackupService.isConfigured else { return }
            Task { await refreshCloudAccountState() }
        }
    }

    private var dataSafetyCard: some View {
        SurfaceCard(title: "Data safety", subtitle: "Local-first notes with backups you control.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppPalette.accent.opacity(0.12))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "checkmark.shield.fill")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(AppPalette.accent)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Saved on this device")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text("Scribeflow keeps notes, transcripts, and recordings local. Export a backup whenever you want a copy outside the app.")
                            .font(.footnote)
                            .foregroundStyle(AppPalette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 10) {
                    safetyStatusRow(
                        icon: "iphone",
                        tint: AppPalette.accent,
                        title: "Local library",
                        detail: "\(snapshot.notesCount) note\(snapshot.notesCount == 1 ? "" : "s") stored on device",
                        value: "Active"
                    )
                    safetyStatusRow(
                        icon: "externaldrive.fill",
                        tint: AppPalette.gold,
                        title: "Manual backup",
                        detail: lastBackupDetail,
                        value: lastBackupValue
                    )
                    safetyStatusRow(
                        icon: automaticBackupsEnabled ? "clock.arrow.circlepath" : "pause.circle",
                        tint: automaticBackupsEnabled ? AppPalette.accent : AppPalette.secondaryInk,
                        title: "Automatic snapshots",
                        detail: latestAutomaticBackup.map {
                            "Latest \($0.createdAt.formatted(date: .abbreviated, time: .shortened))"
                        } ?? "A local recovery copy is created after meaningful changes.",
                        value: automaticBackupsEnabled ? "On" : "Paused"
                    )
                    safetyStatusRow(
                        icon: "arrow.triangle.2.circlepath",
                        tint: AppPalette.secondaryInk,
                        title: "Restore safety",
                        detail: "Backups are previewed before local data is replaced.",
                        value: "Review first"
                    )
                    safetyStatusRow(
                        icon: "icloud",
                        tint: cloudAccountState.isAvailable ? AppPalette.accent : AppPalette.secondaryInk,
                        title: "iCloud backup",
                        detail: lastCloudBackupDetail,
                        value: cloudBackupValue
                    )
                }
            }
        }
    }

    private var storageOverview: some View {
        SurfaceCard(title: "Storage", subtitle: "Local notes, transcripts, and audio files.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 0) {
                    storageRing("Total", snapshot.totalSizeLabel, 1.0, AppPalette.ink)
                    Spacer()
                    storageRing("Audio", snapshot.audioSizeLabel, snapshot.audioFraction, AppPalette.accent)
                    Spacer()
                    storageRing("Notes", "\(snapshot.notesCount)", min(1, Double(snapshot.notesCount) / max(1, Double(snapshot.notesCount + snapshot.recordingsCount))), AppPalette.gold)
                }

                if let resultMessage {
                    Text(resultMessage)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                }
            }
        }
    }

    private func storageRing(_ title: String, _ value: String, _ fraction: Double, _ tint: Color) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(AppPalette.softSurface, lineWidth: 4)
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(value)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }
        }
    }

    private func safetyStatusRow(icon: String, tint: Color, title: String, detail: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(tint.opacity(0.10), in: Capsule(style: .continuous))
        }
        .padding(12)
        .background(AppPalette.paper.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var backupCard: some View {
        SurfaceCard(title: "Backup", subtitle: "Export a copy you control, then restore it later if needed.") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notes-only backup is the safest choice for large libraries. A full copy can include up to 64 MB of recordings in the same protected export.")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    backupAction("Notes only", icon: "doc.text", action: { exportBackup(includeAudio: false) })
                    backupAction("Full copy", icon: "externaldrive.fill", action: { exportBackup(includeAudio: true) })
                    backupAction("Restore", icon: "arrow.counterclockwise", action: { showingImporter = true })
                }
            }
        }
    }

    private var automaticBackupCard: some View {
        SurfaceCard(title: "Automatic snapshots", subtitle: "Local recovery copies of notes and transcripts, kept on this device.") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $automaticBackupsEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep recovery history")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text("Scribeflow keeps up to seven notes-only snapshots and limits background work to one snapshot every six hours.")
                            .font(.caption)
                            .foregroundStyle(AppPalette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(AppPalette.accent)

                Divider()

                if automaticBackups.isEmpty {
                    Text("No automatic snapshot yet.")
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                } else {
                    VStack(spacing: 0) {
                        ForEach(automaticBackups) { backup in
                            automaticBackupRow(backup)
                            if backup.id != automaticBackups.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        createAutomaticBackup()
                    } label: {
                        Label(isCreatingAutomaticBackup ? "Saving" : "Back up now", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.ink)
                    .disabled(isCreatingAutomaticBackup || store.meetings.isEmpty)

                    Button {
                        if let latestAutomaticBackup {
                            prepareAutomaticRestore(latestAutomaticBackup)
                        }
                    } label: {
                        Label("Restore latest", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.accent)
                    .disabled(latestAutomaticBackup == nil)
                }
            }
        }
    }

    private func automaticBackupRow(_ backup: AutomaticBackupSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.badge.clock")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(backup.detail)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
            }

            Spacer(minLength: 8)

            Button {
                prepareAutomaticRestore(backup)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.accent)
            .accessibilityLabel("Restore snapshot from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
        .padding(.vertical, 9)
    }

    private var cloudBackupCard: some View {
        SurfaceCard(title: "iCloud backup", subtitle: "Optional private backup for consumers who want cross-device safety.") {
            VStack(alignment: .leading, spacing: 12) {
                safetyStatusRow(
                    icon: cloudAccountState.isAvailable ? "checkmark.icloud.fill" : "icloud.slash",
                    tint: cloudAccountState.isAvailable ? AppPalette.accent : AppPalette.secondaryInk,
                    title: cloudAccountState.title,
                    detail: cloudAccountState.detail,
                    value: cloudAccountState.isAvailable ? "Private" : "Check"
                )

                Text("This saves one notes-only Scribeflow backup to the user's private iCloud account. Recordings stay on this device unless exported separately.")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    cloudAction(
                        title: "Check",
                        icon: "arrow.clockwise",
                        isDisabled: isUploadingCloudBackup || isDownloadingCloudBackup
                    ) {
                        Task { await refreshCloudAccountState() }
                    }
                    cloudAction(
                        title: "Save",
                        icon: "icloud.and.arrow.up",
                        isDisabled: cloudActionsDisabled
                    ) {
                        saveCloudBackup(includeAudio: false)
                    }
                    cloudAction(
                        title: "Restore",
                        icon: "icloud.and.arrow.down",
                        isDisabled: cloudActionsDisabled
                    ) {
                        restoreCloudBackup()
                    }
                }
            }
        }
    }

    private var cleanupCard: some View {
        let thresholdBytes = Int(largeFileThresholdMB * 1_000_000)
        let largeFiles = snapshot.recordingsLargerThan(bytes: thresholdBytes)
        let oldFiles = snapshot.recordingsOlderThan(days: 30)

        return SurfaceCard(title: "Storage cleanup", subtitle: "Remove heavy audio while keeping notes and transcripts.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Large file limit")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(thresholdBytes), countStyle: .file))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                    Spacer()
                    Text("\(largeFiles.count)")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(largeFiles.isEmpty ? AppPalette.secondaryInk : AppPalette.coral)
                }

                Slider(value: $largeFileThresholdMB, in: 5...100, step: 5)
                    .tint(AppPalette.accent)

                HStack(spacing: 10) {
                    cleanupButton(
                        title: "Large",
                        icon: "scalemass.fill",
                        action: .largeRecordings(minimumBytes: thresholdBytes),
                        isDisabled: largeFiles.isEmpty
                    )

                    cleanupButton(
                        title: "30 days",
                        icon: "calendar.badge.clock",
                        action: .olderRecordings(days: 30),
                        isDisabled: oldFiles.isEmpty
                    )

                    cleanupButton(
                        title: "All audio",
                        icon: "waveform.slash",
                        action: .allRecordings,
                        isDisabled: snapshot.recordings.isEmpty
                    )
                }
            }
        }
    }

    private var recordingsCard: some View {
        SurfaceCard(title: "Recordings", subtitle: "\(snapshot.recordingsCount) local audio file\(snapshot.recordingsCount == 1 ? "" : "s").") {
            if snapshot.recordings.isEmpty {
                EmptyStateCard(title: "No local audio", subtitle: "Voice recordings you save will appear here with file sizes.")
            } else {
                VStack(spacing: 10) {
                    ForEach(snapshot.recordings.sorted { $0.sizeBytes > $1.sizeBytes }) { item in
                        recordingStorageRow(item)
                    }
                }
            }
        }
    }

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Danger zone")
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppPalette.coral)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 14) {
                Text("Permanently removes notes, transcripts, recordings, and all local data. Export a backup first.")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.tertiaryInk)

                Button(role: .destructive) {
                    showingDeleteAllConfirmation = true
                } label: {
                    Label("Delete all my data", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppPalette.coral)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppPalette.coral.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppPalette.coral.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(PressScaleButtonStyle())
            }
            .padding(18)
            .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AppPalette.coral.opacity(0.20), lineWidth: 0.5))
        }
    }

    private func backupAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.accent)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(PressScaleButtonStyle())
    }

    private func cloudAction(
        title: String,
        icon: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isDisabled ? AppPalette.tertiaryInk : AppPalette.accent)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isDisabled ? AppPalette.tertiaryInk : AppPalette.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppPalette.accent.opacity(isDisabled ? 0.03 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isDisabled)
    }

    private func recordingStorageRow(_ item: StorageRecordingItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppPalette.accent.opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.recordingTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                Text(item.meetingTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(1)
                Text("\(item.durationLabel) · \(item.sizeLabel)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryInk)
            }

            Spacer(minLength: 8)

            Button(role: .destructive) {
                store.deleteRecording(item.recordingID, from: item.meetingID)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline.weight(.bold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(AppPalette.coral)
            .accessibilityLabel("Delete recording")
        }
        .padding(12)
        .background(AppPalette.paper.opacity(0.84), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func cleanupButton(title: String, icon: String, action: StorageCleanupAction, isDisabled: Bool) -> some View {
        Button {
            pendingCleanupAction = action
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.headline.weight(.bold))
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(action == .allRecordings ? AppPalette.coral : AppPalette.ink)
        .disabled(isDisabled)
    }

    private func exportBackup(includeAudio: Bool) {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        Task { @MainActor in
            defer { isPreparingExport = false }
            do {
                currentExportIncludesAudio = includeAudio
                let data = try await store.makeBackupData(includeAudio: includeAudio)
                guard !Task.isCancelled else { return }
                backupDocument = ScribeflowBackupDocument(data: data)
                showingExporter = true
            } catch {
                resultMessage = "Backup failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshAutomaticBackups() async {
        do {
            automaticBackups = try await store.automaticBackups()
        } catch {
            resultMessage = "Automatic backups unavailable: \(error.localizedDescription)"
        }
    }

    private func createAutomaticBackup() {
        guard !isCreatingAutomaticBackup else { return }
        isCreatingAutomaticBackup = true
        Task { @MainActor in
            defer { isCreatingAutomaticBackup = false }
            do {
                let backup = try await store.makeAutomaticBackupNow()
                await refreshAutomaticBackups()
                resultMessage = "Saved local snapshot: \(backup.detail)."
            } catch {
                resultMessage = "Automatic backup failed: \(error.localizedDescription)"
            }
        }
    }

    private func prepareAutomaticRestore(_ backup: AutomaticBackupSnapshot) {
        Task { @MainActor in
            do {
                let data = try await store.automaticBackupData(for: backup)
                pendingRestorePreview = try store.backupPreview(from: data)
                pendingRestoreData = data
                showingRestoreConfirmation = true
            } catch {
                resultMessage = "Restore failed: \(error.localizedDescription)"
                await refreshAutomaticBackups()
            }
        }
    }

    private func refreshCloudAccountState() async {
        cloudAccountState = .checking
        cloudAccountState = await ScribeflowCloudBackupService.accountState()
    }

    private func saveCloudBackup(includeAudio: Bool) {
        Task { @MainActor in
            guard cloudAccountState.isAvailable else {
                resultMessage = cloudAccountState.detail
                return
            }

            isUploadingCloudBackup = true
            defer { isUploadingCloudBackup = false }

            do {
                let data = try await store.makeBackupData(includeAudio: includeAudio)
                let preview = try store.backupPreview(from: data)
                let receipt = try await ScribeflowCloudBackupService.upload(
                    data: data,
                    preview: preview,
                    includesAudio: includeAudio
                )
                lastCloudBackupAt = receipt.exportedAt.timeIntervalSince1970
                lastCloudBackupIncludedAudio = receipt.includesAudio
                resultMessage = "Saved iCloud backup: \(receipt.summary)."
            } catch {
                resultMessage = "iCloud backup failed: \(error.localizedDescription)"
                await refreshCloudAccountState()
            }
        }
    }

    private func restoreCloudBackup() {
        Task { @MainActor in
            guard cloudAccountState.isAvailable else {
                resultMessage = cloudAccountState.detail
                return
            }

            isDownloadingCloudBackup = true
            defer { isDownloadingCloudBackup = false }

            do {
                let cloudBackup = try await ScribeflowCloudBackupService.download()
                pendingRestorePreview = try store.backupPreview(from: cloudBackup.data)
                pendingRestoreData = cloudBackup.data
                resultMessage = "Downloaded iCloud backup: \(cloudBackup.receipt.summary)."
                showingRestoreConfirmation = true
            } catch {
                resultMessage = "iCloud restore failed: \(error.localizedDescription)"
                await refreshCloudAccountState()
            }
        }
    }

    private func runCleanup(_ action: StorageCleanupAction) {
        let deletedCount = store.cleanupRecordings(action)
        pendingCleanupAction = nil
        resultMessage = deletedCount == 0
            ? "No recordings matched that cleanup."
            : "Deleted \(deletedCount) recording file\(deletedCount == 1 ? "" : "s"). Notes and transcripts stayed saved."
    }

    private func restore(from result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > 750_000_000 {
                throw MeetingStore.BackupError.tooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            pendingRestorePreview = try store.backupPreview(from: data)
            pendingRestoreData = data
            showingRestoreConfirmation = true
        } catch {
            resultMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func confirmRestore() {
        guard let pendingRestoreData else {
            resultMessage = "Restore failed: no backup file was loaded."
            return
        }

        do {
            try store.restoreBackupData(pendingRestoreData)
            resultMessage = pendingRestorePreview.map {
                "Restored \($0.summary) from backup."
            } ?? "Backup restored."
            Task { await refreshAutomaticBackups() }
        } catch {
            resultMessage = "Restore failed: \(error.localizedDescription)"
        }

        self.pendingRestoreData = nil
        pendingRestorePreview = nil
    }
}

struct AccountSyncView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SurfaceCard(title: "Storage", subtitle: "How your notes are kept safe.") {
                        VStack(alignment: .leading, spacing: 14) {
                            infoRow(
                                icon: "iphone",
                                tint: AppPalette.accent,
                                title: "On this device",
                                detail: "Notes, transcripts, and audio recordings are stored locally and protected with file-level encryption."
                            )
                            infoRow(
                                icon: "externaldrive.fill",
                                tint: AppPalette.gold,
                                title: "User-controlled backups",
                                detail: "Storage & backup can export a full copy or notes-only copy that the user can keep in iCloud Drive, Files, or encrypted storage."
                            )
                            infoRow(
                                icon: "icloud",
                                tint: AppPalette.secondaryInk,
                                title: "Optional iCloud sync next",
                                detail: "The current app is local-first. The next layer should add user-controlled iCloud backup and cross-device restore without making cloud storage required."
                            )
                        }
                    }
                }
                .padding(20)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(AppPalette.ink)
                }
            }
        }
        .modifier(ScribeflowChrome())
    }

    private func infoRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
