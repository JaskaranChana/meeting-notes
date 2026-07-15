import SwiftUI

struct MeetingsView: View {
    @Environment(MeetingStore.self) private var store
    let isActive: Bool
    @Binding var selectedMeetingID: Meeting.ID?
    let onAskTap: () -> Void
    @Binding var toast: ToastItem?
    @State private var searchText = ""
    @AppStorage("scribeflow.library.segment") private var segment: LibrarySegment = .all
    @AppStorage("scribeflow.library.type") private var typeFilter: LibraryTypeFilter = .all
    @AppStorage("scribeflow.library.date") private var dateFilter: LibraryDateFilter = .all
    @AppStorage("scribeflow.library.sort") private var sortMode: LibrarySortMode = .newest
    @State private var showingFilters = false
    @AppStorage("hasUsedLibraryFilters") private var hasUsedFilters = false
    @State private var hasAnimatedIn = false
    @State private var pendingDeleteMeeting: Meeting?
    @State private var pendingDeleteFinalizeID: UUID?
    @State private var snapshot = LibrarySnapshot()
    @State private var snapshotBuilder = LibrarySnapshotBuilder()

    private var snapshotKey: LibrarySnapshotKey {
        LibrarySnapshotKey(
            revision: store.revision,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: .meetings,
            collection: .all,
            typeFilter: typeFilter,
            dateFilter: dateFilter,
            sortMode: sortMode,
            segment: segment
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                Color.clear.frame(height: 0).id("top")
                libraryHero
                    .motionEntrance(step: 0, active: hasAnimatedIn)
                searchField
                    .motionEntrance(step: 1, active: hasAnimatedIn)
                segmentRow
                    .motionEntrance(step: 2, active: hasAnimatedIn)
                filterBar
                    .motionEntrance(step: 2, active: hasAnimatedIn)

                if segment == .all && !snapshot.pinnedResults.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        EditorialSectionHead(title: "Pinned", titleSize: 18) {
                            EditorialMeta(text: "\(snapshot.pinnedResults.count)")
                        }
                        ForEach(snapshot.pinnedResults) { meeting in
                            actionableLibraryRow(meeting)
                                .contextMenu(
                                    menuItems: { libraryContextMenu(meeting) },
                                    preview: { LibraryRowPreview(meeting: meeting) }
                                )
                        }
                    }
                    .motionEntrance(step: 3, active: hasAnimatedIn)
                }

                VStack(alignment: .leading, spacing: 6) {
                    EditorialSectionHead(
                        title: searchText.isEmpty ? "All meetings" : "Results",
                        titleSize: 18
                    ) {
                        EditorialMeta(text: "\(snapshot.libraryResults.count)")
                    }

                    if !hasAnimatedIn && snapshot.libraryResults.isEmpty {
                        // First-paint skeleton — replaces the brief flash of empty
                        // results before the snapshot builder finishes its work.
                        ForEach(0..<4, id: \.self) { _ in
                            librarySkeletonRow
                        }
                    } else if snapshot.libraryResults.isEmpty && snapshot.isMeetingStoreEmpty && searchText.isEmpty {
                        libraryFirstRunCard
                    } else if snapshot.libraryResults.isEmpty {
                        EmptyStateCard(
                            title: "Nothing matches",
                            subtitle: "Try another word, or clear the filters to see everything.",
                            systemImage: "magnifyingglass",
                            tint: AppPalette.accent
                        )
                    } else {
                        // Date-grouped sections — Today / This Week / Earlier
                        // pattern. Pinned items are not in libraryResults
                        // (rendered above), so grouping is purely chronological.
                        ForEach(libraryDateGroups, id: \.title) { group in
                            Section {
                                ForEach(group.meetings) { meeting in
                                    actionableLibraryRow(meeting)
                                        .contextMenu(
                                            menuItems: { libraryContextMenu(meeting) },
                                            preview: { LibraryRowPreview(meeting: meeting) }
                                        )
                                }
                            } header: {
                                EditorialSectionHead(title: group.title, titleSize: 18) {
                                    EditorialMeta(text: "\(group.meetings.count)")
                                }
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    AppPalette.background
                                        .opacity(0.96)
                                        .blur(radius: 0.5)
                                )
                            }
                        }
                    }
                }
                .motionEntrance(step: 4, active: hasAnimatedIn)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, AppDockMetrics.scrollEndPadding)
            .readingWidth()
        }
        .refreshable {
            HapticEngine.tap(.light)
            toast = ToastItem(message: "Up to date", icon: "checkmark.circle.fill")
        }
        .background(AppPalette.background.ignoresSafeArea())
        .accessibilityIdentifier("library.view")
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Meeting.ID.self) { id in
            MeetingDetailView(meetingID: id)
        }
        .onAppear {
            hasAnimatedIn = true
        }
        .task(id: isActive ? snapshotKey : nil) {
            guard isActive else { return }
            await refreshSnapshot(for: snapshotKey)
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { pendingDeleteMeeting != nil },
                set: { if !$0 { pendingDeleteMeeting = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDeleteMeeting {
                Button("Delete \(pendingDeleteMeeting.title)", role: .destructive) {
                    let id = pendingDeleteMeeting.id
                    self.pendingDeleteMeeting = nil
                    var removed: (Meeting, Int)?
                    withAnimation(AppMotion.snappy) {
                        removed = store.softDeleteMeeting(id)
                    }
                    guard let (snapshot, index) = removed else { return }
                    HapticEngine.notify(.warning)
                    let toastID = UUID()
                    pendingDeleteFinalizeID = toastID
                    toast = ToastItem(
                        message: "Deleted \"\(snapshot.title)\"",
                        icon: "trash",
                        actionTitle: "Undo",
                        action: { [weak store] in
                            pendingDeleteFinalizeID = nil
                            withAnimation(AppMotion.snappy) {
                                store?.restoreMeeting(snapshot, at: index)
                            }
                        }
                    )
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(5))
                        guard pendingDeleteFinalizeID == toastID else { return }
                        pendingDeleteFinalizeID = nil
                        store.finalizeDelete(snapshot)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteMeeting = nil
            }
        } message: {
            Text("This cannot be undone. Pinning is safer if you only want to move it out of the way.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeflowDockScrollToTop)) { note in
            guard (note.object as? String) == "library" else { return }
            withAnimation(AppMotion.smooth) {
                proxy.scrollTo("top", anchor: .top)
            }
        }
        }
    }

    private func actionableLibraryRow(_ meeting: Meeting) -> some View {
        EditorialLibraryRow(meeting: meeting, searchQuery: searchText)
            .editorialReveal()
    }

    private func refreshSnapshot(for key: LibrarySnapshotKey) async {
        let delay: Duration = key.hasSearchQuery ? .milliseconds(140) : .milliseconds(70)
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }

        let meetings = store.meetings
        let nextSnapshot = await snapshotBuilder.snapshot(for: key, meetings: meetings)
        guard !Task.isCancelled, key == snapshotKey else { return }

        if snapshot != nextSnapshot {
            snapshot = nextSnapshot
        }
    }

    /// Skeleton row shown during the snapshot's first build. Calms the
    /// momentary "no results" flash so the page feels instantly populated.
    /// Splits `snapshot.libraryResults` into chronological buckets.
    private struct DateGroup {
        let title: String
        let meetings: [Meeting]
    }

    private var libraryDateGroups: [DateGroup] {
        let cal = Calendar.current
        let now = Date.now
        let startOfToday = cal.startOfDay(for: now)
        let weekAgo = cal.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let monthAgo = cal.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday

        var today: [Meeting] = []
        var week: [Meeting] = []
        var month: [Meeting] = []
        var earlier: [Meeting] = []

        for m in snapshot.libraryResults {
            if m.when >= startOfToday        { today.append(m) }
            else if m.when >= weekAgo        { week.append(m) }
            else if m.when >= monthAgo       { month.append(m) }
            else                             { earlier.append(m) }
        }

        var out: [DateGroup] = []
        if !today.isEmpty   { out.append(DateGroup(title: "Today", meetings: today)) }
        if !week.isEmpty    { out.append(DateGroup(title: "This week", meetings: week)) }
        if !month.isEmpty   { out.append(DateGroup(title: "This month", meetings: month)) }
        if !earlier.isEmpty { out.append(DateGroup(title: "Earlier", meetings: earlier)) }
        return out
    }

    /// Smart segment chip row. Quick lateral filters that don't require opening
    /// the filter sheet — pinned, audio-bearing, action-bearing, owed to me.
    private var segmentRow: some View {
        // Tally all segment counts in a single pass over the results instead of
        // five independent `.filter().count` calls (which allocated five
        // throwaway arrays) every time the row re-renders.
        let counts = segmentCounts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibrarySegment.allCases) { seg in
                    Button {
                        HapticEngine.select()
                        withAnimation(AppMotion.snappy) { segment = seg }
                    } label: {
                        HStack(spacing: 6) {
                            if let icon = seg.icon {
                                Image(systemName: icon).font(.system(size: 10.5, weight: .bold))
                            }
                            Text(seg.title).font(.system(size: 12.5, weight: segment == seg ? .semibold : .medium))
                            let n = counts[seg] ?? 0
                            if n > 0 {
                                Text("\(n)").font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle((segment == seg ? Color.white : AppPalette.tertiaryInk).opacity(0.7))
                            }
                        }
                        .foregroundStyle(segment == seg ? .white : AppPalette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(segment == seg ? AppPalette.ink : AppPalette.softSurface)
                        )
                        .overlay(
                            Capsule().strokeBorder(segment == seg ? .clear : AppPalette.border.opacity(0.6), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var segmentCounts: [LibrarySegment: Int] {
        snapshot.segmentCounts
    }

    private var librarySkeletonRow: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppPalette.softSurface)
                .frame(width: 44, height: 44)
                .shimmer()
            VStack(alignment: .leading, spacing: 8) {
                SkeletonRow(height: 12)
                SkeletonRow(width: 160, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.45), lineWidth: 0.7)
        )
        .accessibilityHidden(true)
    }

    private var libraryFirstRunCard: some View {
        EmptyStateCard(
            title: "Nothing here yet",
            subtitle: "Every meeting, voice note, and quick thought lands here. Head to Today to capture your first.",
            systemImage: "rectangle.stack.fill",
            tint: AppPalette.accent
        )
    }

    private var libraryHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    EditorialEyebrow(text: "Library")
                    Text("All meetings")
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                }

                Spacer(minLength: 8)

                Button {
                    HapticEngine.tap(.medium)
                    onAskTap()
                } label: {
                    EditorialChip(text: "Ask", systemImage: "sparkle.magnifyingglass", variant: .ink)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                .accessibilityLabel("Ask across your library")
            }

            EditorialMeta(text: "\(snapshot.totalMeetingsCount) saved · \(snapshot.pinnedCount) pinned · \(snapshot.openLoopCount) follow-ups")
        }
        .padding(.top, 2)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppPalette.tertiaryInk)

            TextField("Search meetings, people, transcripts…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .foregroundStyle(AppPalette.ink)

            if searchText.isEmpty {
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
            } else {
                Button {
                    HapticEngine.tap(.light)
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(AppPalette.border, lineWidth: 1)
        )
    }

    /// Compact filter strip. Active filters appear as chips with tap-to-clear.
    /// One `Filters` button opens a sheet with the full filter set. Far less
    /// cognitive load than three pickers always visible.
    private var filterBar: some View {
        HStack(spacing: 8) {
            if typeFilter != .all {
                activeChip(filter: typeFilter.title, systemImage: typeFilter.systemImage) {
                    withAnimation(AppMotion.snappy) { typeFilter = .all }
                }
            }
            if dateFilter != .all {
                activeChip(filter: dateFilter.title, systemImage: "calendar") {
                    withAnimation(AppMotion.snappy) { dateFilter = .all }
                }
            }
            if sortMode != .newest {
                activeChip(filter: sortMode.title, systemImage: "arrow.up.arrow.down") {
                    withAnimation(AppMotion.snappy) { sortMode = .newest }
                }
            }

            Spacer(minLength: 0)

            Button {
                HapticEngine.tap(.light)
                hasUsedFilters = true
                showingFilters = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.footnote.weight(.heavy))
                    Text("Filters")
                        .font(.footnote.weight(.bold))
                    if activeFilterCount > 0 {
                        Text("\(activeFilterCount)")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(AppPalette.accent, in: Capsule())
                    }
                }
                .foregroundStyle(AppPalette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppPalette.cardBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if !hasUsedFilters && activeFilterCount == 0 {
                        Circle()
                            .fill(AppPalette.accent)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.2))
                            .offset(x: 2, y: -2)
                    }
                }
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.94))
            .accessibilityLabel(activeFilterCount > 0 ? "Filters — \(activeFilterCount) active" : "Filters")
        }
        .sheet(isPresented: $showingFilters) {
            filterSheet
                .presentationDetents([.fraction(0.45), .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var activeFilterCount: Int {
        var n = 0
        if typeFilter != .all { n += 1 }
        if dateFilter != .all { n += 1 }
        if sortMode != .newest { n += 1 }
        return n
    }

    private func activeChip(filter: String, systemImage: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .heavy))
            Text(filter)
                .font(.caption.weight(.bold))
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.heavy))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear \(filter)")
        }
        .foregroundStyle(AppPalette.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppPalette.accent.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(AppPalette.accent.opacity(0.22), lineWidth: 0.6))
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private var filterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    filterGroup(title: "TYPE") {
                        ForEach(LibraryTypeFilter.allCases) { filter in
                            filterSheetRow(
                                title: filter.title,
                                systemImage: filter.systemImage,
                                isSelected: typeFilter == filter
                            ) {
                                HapticEngine.tap(.light)
                                withAnimation(AppMotion.snappy) { typeFilter = filter }
                            }
                        }
                    }
                    filterGroup(title: "DATE") {
                        ForEach(LibraryDateFilter.allCases) { filter in
                            filterSheetRow(
                                title: filter.title,
                                systemImage: "calendar",
                                isSelected: dateFilter == filter
                            ) {
                                HapticEngine.tap(.light)
                                withAnimation(AppMotion.snappy) { dateFilter = filter }
                            }
                        }
                    }
                    filterGroup(title: "SORT") {
                        ForEach(LibrarySortMode.allCases) { mode in
                            filterSheetRow(
                                title: mode.title,
                                systemImage: "arrow.up.arrow.down",
                                isSelected: sortMode == mode
                            ) {
                                HapticEngine.tap(.light)
                                withAnimation(AppMotion.snappy) { sortMode = mode }
                            }
                        }
                    }

                    if activeFilterCount > 0 {
                        Button {
                            HapticEngine.tap(.light)
                            withAnimation(AppMotion.snappy) {
                                typeFilter = .all
                                dateFilter = .all
                                sortMode = .newest
                            }
                        } label: {
                            Text("Reset all filters")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppPalette.coral)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(AppPalette.coral.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                    }
                }
                .padding(20)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        HapticEngine.tap(.light)
                        showingFilters = false
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(AppPalette.accent)
                }
            }
        }
    }

    private func filterGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.heavy))
                .kerning(1.4)
                .foregroundStyle(AppPalette.secondaryInk)
            VStack(spacing: 0) {
                content()
            }
            .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.8)
            )
            .appShadow(AppShadow.soft)
        }
    }

    private func filterSheetRow(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isSelected ? AppPalette.accent : AppPalette.tertiaryInk)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Divider()
                    .background(AppPalette.divider.opacity(0.3))
                    .padding(.leading, 48)
            }
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985))
    }

    @ViewBuilder
    private func libraryContextMenu(_ meeting: Meeting) -> some View {
        Group {
            Button(meeting.isPinned ? "Unpin" : "Pin",
                   systemImage: meeting.isPinned ? "pin.slash" : "pin.fill") {
                store.togglePinned(for: meeting.id)
                toast = ToastItem(
                    message: meeting.isPinned ? "Unpinned" : "Pinned",
                    icon: meeting.isPinned ? "pin.slash" : "pin.fill"
                )
            }

            ShareLink(
                item: meetingDigestMarkdown(meeting, signals: store.signals(for: meeting)),
                subject: Text(meeting.title.isEmpty ? "Meeting" : meeting.title),
                preview: SharePreview(meeting.title.isEmpty ? "Meeting" : meeting.title)
            ) {
                Label("Share digest", systemImage: "doc.plaintext")
            }

            Button("Duplicate", systemImage: "doc.on.doc") {
                if let duplicatedID = store.duplicateMeeting(meeting.id) {
                    selectedMeetingID = duplicatedID
                }
            }

            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeleteMeeting = meeting
            }
        }
    }

}

/// Compact preview shown on `.contextMenu(preview:)` long-press of a library
/// row. Sized to feel like a glance card: header + meta strip + first summary
/// bullet. Kept small so the system can pop it without jank.
private struct LibraryRowPreview: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppPalette.accent.opacity(0.12))
                    Image(systemName: leadIcon)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                    Text(meeting.when, format: .dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryInk)
                }
                Spacer(minLength: 0)
            }

            if !metaStrip.isEmpty {
                HStack(spacing: 6) {
                    ForEach(metaStrip, id: \.self) { chip in
                        Text(chip)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppPalette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(AppPalette.accent.opacity(0.12)))
                    }
                }
            }

            if let bullet = primaryBullet {
                Text(bullet)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !meeting.rawNotes.isEmpty {
                Text(meeting.rawNotes.prefix(220))
                    .font(.footnote)
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(AppPalette.cardBackground)
    }

    private var leadIcon: String {
        if meeting.status == .live { return "waveform.badge.mic" }
        if !meeting.audioRecordings.isEmpty { return "mic.fill" }
        if meeting.transcript.isEmpty && !meeting.rawNotes.isEmpty { return "square.and.pencil" }
        return "doc.text.fill"
    }

    private var primaryBullet: String? {
        guard let summary = meeting.summaries.first(where: { $0.template == meeting.selectedTemplate })
                ?? meeting.summaries.first
        else { return nil }
        return summary.summary.sections.first?.bullets.first
    }

    private var metaStrip: [String] {
        var out: [String] = []
        if meeting.isPinned { out.append("PINNED") }
        let openCount = meeting.allowsAccountabilityExtraction
            ? meeting.commitments.filter { $0.status == .open || $0.status == .atRisk }.count
            : 0
        if openCount > 0 { out.append("\(openCount) OPEN") }
        if !meeting.audioRecordings.isEmpty { out.append("AUDIO") }
        if !meeting.attendees.isEmpty { out.append("\(meeting.attendees.count) ATTENDEES") }
        return out
    }
}

// MARK: - Library smart segments

enum LibrarySegment: String, CaseIterable, Identifiable {
    case all, pinned, audio, actions, mine
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:     "All"
        case .pinned:  "Pinned"
        case .audio:   "Audio"
        case .actions: "Actions"
        case .mine:    "Owed me"
        }
    }

    var icon: String? {
        switch self {
        case .all:     nil
        case .pinned:  "pin.fill"
        case .audio:   "waveform"
        case .actions: "checklist"
        case .mine:    "person.fill"
        }
    }

    func matches(_ m: Meeting) -> Bool {
        switch self {
        case .all:     return true
        case .pinned:  return m.isPinned
        case .audio:   return !m.audioRecordings.isEmpty
        case .actions: return m.allowsAccountabilityExtraction && !m.commitments.isEmpty
        case .mine:
            guard m.allowsAccountabilityExtraction else { return false }
            return m.commitments.contains { c in
                guard c.status == .open || c.status == .atRisk else { return false }
                let o = c.owner.lowercased()
                return o.contains("you") || o == "me" || o == "i" || o.contains("self")
            }
        }
    }
}
