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
        let cleanedText = collapsedWhitespace(text)
        guard let range = cleanedText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        let leadingCharacters = min(44, cleanedText.distance(from: cleanedText.startIndex, to: range.lowerBound))
        let trailingCharacters = min(58, cleanedText.distance(from: range.upperBound, to: cleanedText.endIndex))
        let start = cleanedText.index(range.lowerBound, offsetBy: -leadingCharacters)
        let end = cleanedText.index(range.upperBound, offsetBy: trailingCharacters)

        var result = String(cleanedText[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > cleanedText.startIndex { result = "..." + result }
        if end < cleanedText.endIndex { result += "..." }
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
    let meeting: Meeting
    var searchQuery: String = ""

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private static func relativeBadge(for date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now).uppercased()
    }

    private var summaryLine: String {
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
        guard meeting.allowsAccountabilityExtraction else { return 0 }
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
                            .scaledFont(size: 17, weight: .medium, design: .serif, relativeTo: .body)
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !summaryLine.isEmpty {
                        Text(summaryLine)
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.secondaryInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        if meeting.status == .processing {
                            EditorialMeta(text: "processing", tint: AppPalette.gold)
                        }
                        if !meeting.attendees.isEmpty {
                            EditorialAvatarStack(names: meeting.attendees, size: 18, max: 3)
                        }
                        if !durationLabel.isEmpty { EditorialMeta(text: durationLabel) }
                        if openActions > 0 {
                            Text("·").foregroundStyle(AppPalette.border)
                            EditorialMeta(text: "\(openActions) action\(openActions == 1 ? "" : "s")", tint: AppPalette.coral)
                        }
                        if !meeting.audioRecordings.isEmpty {
                            Text("·").foregroundStyle(AppPalette.border)
                            EditorialMeta(text: "audio", tint: AppPalette.accent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                EditorialMeta(text: Self.relativeBadge(for: meeting.when))
                    .padding(.top, 3)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { EditorialRule() }
        }
        .buttonStyle(EditorialRowStyle())
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
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

struct FolderDetailView: View {
    @Environment(MeetingStore.self) private var store
    let folder: WorkspaceFolder
    @Binding var selectedMeetingID: Meeting.ID?

    @State private var prompt = ""
    @State private var includeTranscripts = true
    @State private var modelSelection: ChatModelSelection = .auto
    @State private var isRunningChat = false
    @State private var answer: String?

    private var meetings: [Meeting] { store.meetings(in: folder) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SurfaceCard(title: "Folder", subtitle: folder.name) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(folder.description).font(.subheadline).foregroundStyle(AppPalette.secondaryInk)
                        HStack(spacing: 10) {
                            meta("Meetings", value: "\(folder.meetingCount)")
                            meta("Updated", value: folder.latestMeetingDate.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                folderChatCard
                SurfaceCard(title: "Meetings", subtitle: "Notes inside this folder") {
                    if meetings.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "tray")
                                .font(.title3)
                                .foregroundStyle(AppPalette.tertiaryInk)
                            Text("No meetings yet in this folder.")
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.secondaryInk)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(meetings) { meeting in
                                NavigationLink(value: meeting.id) { CompactMeetingRow(meeting: meeting) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(AppPalette.background.ignoresSafeArea())
        .accessibilityIdentifier("folderdetail.view")
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Meeting.ID.self) { id in MeetingDetailView(meetingID: id) }
    }

    private var folderChatCard: some View {
        SurfaceCard(title: "Folder chat", subtitle: "Ask across this workspace with source-linked answers.") {
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
                    .background(AppPalette.cardBackground.opacity(0.90), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(spacing: 12) {
                    Toggle("Use transcripts", isOn: $includeTranscripts)
                        .font(.footnote.weight(.semibold)).tint(AppPalette.accent)
                    Spacer()
                    Picker("Model", selection: $modelSelection) {
                        ForEach(ChatModelSelection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Text(modelSelection.helperText).font(.footnote).foregroundStyle(AppPalette.secondaryInk)
                Button(isRunningChat ? "Thinking..." : "Run chat") { runPrompt(prompt) }
                    .buttonStyle(.borderedProminent).tint(AppPalette.accent)
                    .disabled(isRunningChat || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let answer {
                    Text(answer).font(.subheadline).foregroundStyle(AppPalette.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(AppPalette.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private func meta(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).kerning(0.9).foregroundStyle(AppPalette.secondaryInk)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(AppPalette.ink)
        }
        .padding(12)
        .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
