import SwiftUI

struct LibrarySearchMatch: Equatable {
    let label: String
    let snippet: String
}

enum LibrarySearchMatcher {
    static func matches(_ meeting: Meeting, query rawQuery: String) -> Bool {
        match(in: meeting, query: rawQuery) != nil
    }

    static func match(in meeting: Meeting, query rawQuery: String) -> LibrarySearchMatch? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        let fields: [(String, String)] = [
            ("Title", meeting.title),
            ("Workspace", meeting.workspace),
            ("Objective", meeting.objective),
            ("People", meeting.attendees.joined(separator: ", ")),
            ("Notes", meeting.rawNotes)
        ]

        for (label, value) in fields {
            if let snippet = snippet(in: value, query: query) {
                return LibrarySearchMatch(label: label, snippet: snippet)
            }
        }

        for line in meeting.transcript {
            if let snippet = snippet(in: line.text, query: query) {
                return LibrarySearchMatch(label: "Transcript", snippet: snippet)
            }
        }

        for recording in meeting.audioRecordings {
            let recordingFields: [(String, String)] = [
                ("Recording", recording.title),
                ("Recording transcript", recording.transcript),
                ("Recording note", recording.linkedNote)
            ]
            for (label, value) in recordingFields {
                if let snippet = snippet(in: value, query: query) {
                    return LibrarySearchMatch(label: label, snippet: snippet)
                }
            }
        }

        return nil
    }

    private static func snippet(in text: String, query: String) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let range = text.range(of: query, options: options) {
            return contextualSnippet(in: text, around: range)
        }

        // A multi-word query may span a line break or repeated whitespace.
        // Only normalize the complete field for that less-common case; single
        // word searches avoid allocating a second full transcript string.
        guard query.contains(where: \.isWhitespace) else { return nil }
        let cleanedText = collapsedWhitespace(text)
        guard let range = cleanedText.range(of: query, options: options) else { return nil }
        return contextualSnippet(in: cleanedText, around: range)
    }

    private static func contextualSnippet(
        in text: String,
        around range: Range<String.Index>
    ) -> String {
        let leadingCharacters = min(44, text.distance(from: text.startIndex, to: range.lowerBound))
        let trailingCharacters = min(58, text.distance(from: range.upperBound, to: text.endIndex))
        let start = text.index(range.lowerBound, offsetBy: -leadingCharacters)
        let end = text.index(range.upperBound, offsetBy: trailingCharacters)

        var result = collapsedWhitespace(String(text[start..<end]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { result = "..." + result }
        if end < text.endIndex { result += "..." }
        return result
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Library mode

enum LibraryMode: String, CaseIterable, Identifiable {
    case meetings
    case folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetings: "Meetings"
        case .folders:  "Folders"
        }
    }
}

// MARK: - Meeting cards

struct MeetingCard: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatusBadge(status: meeting.status)
                Spacer()
                if meeting.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                Text(meeting.when, style: .relative)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(1)

                Text(meeting.objective)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(2)
                    .lineSpacing(2)
            }

            HStack(spacing: 6) {
                Image(systemName: "briefcase")
                    .font(.system(size: 9, weight: .medium))
                Text(meeting.workspace)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(AppPalette.tertiaryInk)
        }
        .padding(22)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5)
        )
        .appShadow(AppShadow.soft)
    }
}

struct CompactMeetingRow: View {
    let meeting: Meeting
    var includesChrome = true

    private var snippet: String? {
        let summary = meeting.summary(for: meeting.selectedTemplate)
        if let bullet = summary.sections.first?.bullets.first, !bullet.isEmpty {
            return bullet
        }
        return nil
    }

    var body: some View {
        if includesChrome {
            rowContent
                .padding(16)
                .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
                .appShadow(AppShadow.hairline)
        } else {
            rowContent.padding(16)
        }
    }

    private var rowContent: some View {
        let tint = meeting.status == .live ? AppPalette.coral : AppPalette.accent
        return HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tint.opacity(0.08))
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: meeting.status == .live ? "waveform" : "doc.text.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tint)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(meeting.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(meeting.when, style: .relative)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                Text(meeting.workspace)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.tertiaryInk)
                if let snippet {
                    Text(snippet)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .lineLimit(1)
                        .lineSpacing(1)
                        .padding(.top, 1)
                }
            }
        }
    }
}

struct ActionableCompactMeetingRow: View {
    let meeting: Meeting
    let onTogglePinned: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: meeting.id) {
                CompactMeetingRow(meeting: meeting, includesChrome: false)
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 74)

            MeetingQuickActionBar(
                isPinned: meeting.isPinned,
                reviewLabel: "Open note",
                onTogglePinned: onTogglePinned,
                onDelete: onDelete
            )
        }
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
        .appShadow(AppShadow.hairline)
    }
}

// MARK: - Library rows


/// Content-dense editorial library row: serif title (with pin dot), one-line
/// summary, then an avatar stack + duration / actions / audio meta strip and a
/// trailing relative timestamp. Flat on the page, separated by hairlines.
struct EditorialLibraryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let meeting: Meeting
    var searchMatch: LibrarySearchMatch? = nil

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private static func relativeBadge(for date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now).uppercased()
    }

    private var summaryLine: String {
        if let searchMatch {
            return "\(searchMatch.label): \(searchMatch.snippet)"
        }
        if meeting.status == .processing { return meeting.stage }
        if let title = (meeting.summaries.first(where: { $0.template == meeting.selectedTemplate })
            ?? meeting.summaries.first)?.summary.title,
           !title.isEmpty {
            return title
        }
        let objective = meeting.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !objective.isEmpty { return objective }
        return meeting.rawNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }
    private var openActions: Int {
        return meeting.commitments.filter { $0.status == .open || $0.status == .atRisk }.count
    }
    private var durationLabel: String { meeting.durationMinutes > 0 ? "\(meeting.durationMinutes)m" : "" }

    /// Leading glyph that classifies the row at a glance — live capture, audio
    /// note, typed note, or transcript-backed meeting. Mirrors the long-press
    /// preview's icon so the visual vocabulary stays consistent.
    private var leadIcon: String {
        if meeting.status == .live { return AppSymbols.mic }
        if meeting.status == .processing { return "waveform.badge.magnifyingglass" }
        if !meeting.audioRecordings.isEmpty { return AppSymbols.voice }
        if meeting.transcript.isEmpty && !meeting.rawNotes.isEmpty { return AppSymbols.note }
        return "doc.text.fill"
    }

    var body: some View {
        NavigationLink(value: meeting.id) {
            HStack(alignment: .top, spacing: 13) {
                IconBadge(systemImage: leadIcon, size: .small)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if meeting.isPinned {
                            Circle().fill(AppPalette.accent).frame(width: 6, height: 6)
                        }
                        Text(meeting.title.isEmpty ? "Untitled" : meeting.title)
                            .font(AppFont.serif(.body, weight: .medium))
                            .foregroundStyle(AppPalette.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !summaryLine.isEmpty {
                        Text(summaryLine)
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.secondaryInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    WrappingHStack(spacing: 10) {
                        rowMetadata
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !dynamicTypeSize.isAccessibilitySize {
                    EditorialMeta(text: Self.relativeBadge(for: meeting.when))
                        .padding(.top, 3)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { EditorialRule() }
        }
        .buttonStyle(EditorialRowStyle())
    }

    @ViewBuilder
    private var rowMetadata: some View {
        if meeting.status == .processing {
            EditorialMeta(text: "processing", tint: AppPalette.gold)
        }
        if !meeting.attendees.isEmpty {
            EditorialAvatarStack(names: meeting.attendees, size: 18, max: 3)
        }
        if !durationLabel.isEmpty { EditorialMeta(text: durationLabel) }
        if openActions > 0 {
            EditorialMeta(text: "\(openActions) action\(openActions == 1 ? "" : "s")", tint: AppPalette.coral)
        }
        if !meeting.audioRecordings.isEmpty {
            EditorialMeta(text: "audio", tint: AppPalette.accent)
        }
        if dynamicTypeSize.isAccessibilitySize {
            EditorialMeta(text: Self.relativeBadge(for: meeting.when))
        }
    }
}


struct MeetingQuickActionBar: View {
    let isPinned: Bool
    let reviewLabel: String
    let onTogglePinned: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Label(reviewLabel, systemImage: "arrow.up.forward")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppPalette.tertiaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer(minLength: 8)
            Button { onTogglePinned() } label: {
                Image(systemName: isPinned ? "pin.slash" : "pin")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .frame(width: AppLayout.minimumTapTarget, height: AppLayout.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPinned ? "Unpin meeting" : "Pin meeting")
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .frame(width: AppLayout.minimumTapTarget, height: AppLayout.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete meeting")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}

// MARK: - Folder views

struct FolderRow: View {
    let folder: WorkspaceFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [AppPalette.accent.opacity(0.22), AppPalette.accent.opacity(0.08)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 50, height: 50)
                    .overlay(Image(systemName: "folder.fill").foregroundStyle(AppPalette.accent))

                VStack(alignment: .leading, spacing: 6) {
                    Text(folder.name).font(.headline).foregroundStyle(AppPalette.ink)
                    Text(folder.description).font(.subheadline).foregroundStyle(AppPalette.secondaryInk).lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Label("\(folder.meetingCount) meetings", systemImage: "rectangle.stack.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(AppPalette.secondaryInk)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(AppPalette.softSurface, in: Capsule())

                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                    Text(folder.latestMeetingDate, style: .relative)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(AppPalette.secondaryInk)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(AppPalette.softSurface, in: Capsule())
            }
        }
        .padding(20)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
        .appShadow(AppShadow.hairline)
    }
}

private struct FolderDetailSnapshotKey: Hashable {
    let libraryRevision: Int
    let folderName: String
    let query: String

    init(libraryRevision: Int, folderName: String, query: String) {
        self.libraryRevision = libraryRevision
        self.folderName = folderName
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool { !query.isEmpty }
}

private struct FolderDetailSnapshot: Equatable {
    var meetings: [Meeting] = []
    var visibleMeetings: [Meeting] = []
    var searchMatches: [Meeting.ID: LibrarySearchMatch] = [:]
}

private actor FolderDetailSnapshotBuilder {
    private var cachedRevision: Int?
    private var cachedFolderName = ""
    private var cachedMeetings: [Meeting] = []

    func make(meetings: [Meeting], key: FolderDetailSnapshotKey) -> FolderDetailSnapshot {
        if cachedRevision != key.libraryRevision
            || cachedFolderName.caseInsensitiveCompare(key.folderName) != .orderedSame {
            cachedRevision = key.libraryRevision
            cachedFolderName = key.folderName
            cachedMeetings = meetings
                .filter { $0.workspace.caseInsensitiveCompare(key.folderName) == .orderedSame }
                .sorted(by: Meeting.sortDescending)
        }

        guard key.isSearching else {
            return FolderDetailSnapshot(meetings: cachedMeetings, visibleMeetings: cachedMeetings)
        }

        var matches: [Meeting] = []
        var searchMatches: [Meeting.ID: LibrarySearchMatch] = [:]
        matches.reserveCapacity(min(cachedMeetings.count, 24))
        for meeting in cachedMeetings {
            guard !Task.isCancelled else { break }
            if let match = LibrarySearchMatcher.match(in: meeting, query: key.query) {
                matches.append(meeting)
                searchMatches[meeting.id] = match
            }
        }
        return FolderDetailSnapshot(
            meetings: cachedMeetings,
            visibleMeetings: matches,
            searchMatches: searchMatches
        )
    }
}

struct FolderDetailView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let folder: WorkspaceFolder
    @Binding var selectedMeetingID: Meeting.ID?

    @State private var prompt = ""
    @State private var includeTranscripts = true
    @State private var modelSelection: ChatModelSelection = .auto
    @State private var isRunningChat = false
    @State private var answer: String?
    @State private var searchText = ""
    @State private var showsFolderChat = false
    @State private var snapshot = FolderDetailSnapshot()
    @State private var snapshotBuilder = FolderDetailSnapshotBuilder()
    @State private var hasLoadedSnapshot = false

    private var snapshotKey: FolderDetailSnapshotKey {
        FolderDetailSnapshotKey(
            libraryRevision: store.revision,
            folderName: folder.name,
            query: searchText
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                folderSummary
                folderChatTool

                EditorialSectionHead(title: snapshotKey.isSearching ? "Results" : "Meetings", titleSize: 20) {
                    EditorialMeta(text: "\(snapshot.visibleMeetings.count)")
                }

                if !hasLoadedSnapshot {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading meetings")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 92)
                } else if snapshot.visibleMeetings.isEmpty {
                    EmptyStateCard(
                        title: snapshotKey.isSearching ? "Nothing matches" : "No meetings yet",
                        subtitle: snapshotKey.isSearching
                            ? "Try another word or clear the search."
                            : "Saved notes in this workspace will appear here.",
                        systemImage: snapshotKey.isSearching ? "magnifyingglass" : "tray",
                        tint: AppPalette.accent
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.visibleMeetings) { meeting in
                            EditorialLibraryRow(
                                meeting: meeting,
                                searchMatch: snapshot.searchMatches[meeting.id]
                            )
                        }
                    }
                }
            }
            .appScreenContent(top: AppSpacing.lg)
        }
        .background(AppPalette.background.ignoresSafeArea())
        .accessibilityIdentifier("folderdetail.view")
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search this folder")
        .navigationDestination(for: Meeting.ID.self) { id in MeetingDetailView(meetingID: id) }
        .task(id: snapshotKey) {
            let key = snapshotKey
            if key.isSearching {
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard !Task.isCancelled else { return }
            let meetings = store.meetings
            let nextSnapshot = await snapshotBuilder.make(meetings: meetings, key: key)
            guard !Task.isCancelled, snapshotKey == key else { return }
            snapshot = nextSnapshot
            hasLoadedSnapshot = true
        }
    }

    private var folderSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(folder.description)
                .font(.body)
                .foregroundStyle(AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        meta("Meetings", value: "\(snapshot.meetings.count)")
                        meta("Updated", value: folder.latestMeetingDate.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    HStack(spacing: 24) {
                        meta("Meetings", value: "\(snapshot.meetings.count)")
                        meta("Updated", value: folder.latestMeetingDate.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
    }

    private var folderChatTool: some View {
        DisclosureGroup(isExpanded: $showsFolderChat) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(WorkspaceRecipe.allCases) { recipe in
                            Button(recipe.title) { runRecipe(recipe) }
                                .buttonStyle(.bordered).tint(AppPalette.ink).disabled(isRunningChat)
                        }
                    }
                }
                TextField("Ask anything about this folder", text: $prompt, axis: .vertical)
                    .padding(.horizontal, 14).padding(.vertical, 14)
                    .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                HStack(spacing: 12) {
                    Toggle("Use transcripts", isOn: $includeTranscripts)
                        .font(.footnote.weight(.semibold)).tint(AppPalette.accent)
                    Spacer()
                    Picker("Answer model", selection: $modelSelection) {
                        ForEach(ChatModelSelection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Text(modelSelection.helperText).font(.footnote).foregroundStyle(AppPalette.secondaryInk)
                Button(isRunningChat ? "Answering..." : "Ask folder") { runPrompt(prompt) }
                    .buttonStyle(.borderedProminent).tint(AppPalette.accent)
                    .disabled(isRunningChat || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let answer {
                    Text(answer).font(.subheadline).foregroundStyle(AppPalette.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .padding(.top, 12)
        } label: {
            HStack {
                Label("Ask this folder", systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer(minLength: 8)
                Text("Uses your notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.accent)
            }
            .frame(minHeight: 44)
        }
        .tint(AppPalette.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.45), lineWidth: 0.7)
        )
    }

    private func meta(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(AppPalette.secondaryInk)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(AppPalette.ink)
        }
    }

    private func runRecipe(_ recipe: WorkspaceRecipe) { prompt = recipe.prompt; runPrompt(recipe.prompt) }

    private func runPrompt(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !isRunningChat else { return }
        isRunningChat = true; answer = nil
        Task {
            let response = await store.answerAcrossMeetings(
                prompt: cleaned, includeTranscripts: includeTranscripts,
                workspaceFilter: folder.name, modelSelection: modelSelection
            )
            await MainActor.run { answer = response; isRunningChat = false }
        }
    }
}
