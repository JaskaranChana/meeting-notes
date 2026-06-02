import SwiftUI
import UniformTypeIdentifiers

struct DataControlsView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var backupDocument = ScribeflowBackupDocument()
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingDeleteAllConfirmation = false
    @State private var resultMessage: String?
    @State private var largeFileThresholdMB = 25.0
    @State private var pendingCleanupAction: StorageCleanupAction?

    private var snapshot: StorageSnapshot {
        store.storageSnapshot()
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    storageOverview
                    backupCard
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
                    resultMessage = "Backup exported."
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
                    store.deleteAllUserData()
                    resultMessage = "All local Scribeflow data was deleted."
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
        }
        .modifier(ScribeflowChrome())
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

    private var backupCard: some View {
        SurfaceCard(title: "Backup", subtitle: "Manual backup and restore for notes plus local audio files.") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Backups include notes, transcripts, metadata, and recording files. They are plain JSON, so store them somewhere private.")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    backupAction("Full backup", icon: "cloud.fill", action: { exportBackup(includeAudio: true) })
                    backupAction("Notes only", icon: "doc.text", action: { exportBackup(includeAudio: false) })
                    backupAction("Restore", icon: "arrow.counterclockwise", action: { showingImporter = true })
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
                .kerning(0.6)
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
        do {
            backupDocument = ScribeflowBackupDocument(data: try store.makeBackupData(includeAudio: includeAudio))
            showingExporter = true
        } catch {
            resultMessage = "Backup failed: \(error.localizedDescription)"
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
            try store.restoreBackupData(Data(contentsOf: url))
            resultMessage = "Backup restored."
        } catch {
            resultMessage = "Restore failed: \(error.localizedDescription)"
        }
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
                                icon: "icloud.slash",
                                tint: AppPalette.secondaryInk,
                                title: "No cloud sync",
                                detail: "Scribeflow does not upload your meetings to any server. There is no cross-device sync in this version."
                            )
                            infoRow(
                                icon: "externaldrive.fill",
                                tint: AppPalette.gold,
                                title: "Manual backup",
                                detail: "Open Storage & backup in Settings to export your data as a single file you control."
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
