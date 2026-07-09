import SwiftUI
import EventKit

// MARK: - Aggregated action item

struct AggregatedActionItem: Identifiable, Hashable {
    var id: Commitment.ID { commitment.id }
    let commitment: Commitment
    let meetingID: Meeting.ID
    let meetingTitle: String
    let workspace: String
    let meetingDate: Date
    let isMeetingPinned: Bool

    /// Absolute deadline resolved from the free-text hint relative to capture.
    var dueDate: Date? { commitment.dueDateOverride ?? DueDateParser.date(from: commitment.dueHint, capturedAt: meetingDate) }

    var dueLabel: String? {
        if let override = commitment.dueDateOverride {
            return override.formatted(.dateTime.month(.abbreviated).day())
        }
        return commitment.dueHint?.nilIfBlank?.capitalized
    }

    private var isLive: Bool { commitment.status == .open || commitment.status == .atRisk }

    /// Past its real deadline and still open — judged by time, not keywords.
    var isOverdue: Bool {
        guard isLive, let due = dueDate else { return false }
        return due < Date()
    }

    /// Due within the next two days (and not already overdue).
    var isDueSoon: Bool {
        guard isLive, let due = dueDate else { return false }
        let now = Date()
        guard due >= now, let horizon = Calendar.current.date(byAdding: .day, value: 2, to: now) else { return false }
        return due <= horizon
    }

    var priority: ActionPriority {
        // Real-time urgency wins; then the model's judgment; then a heuristic.
        if commitment.status == .atRisk || isOverdue { return .high }
        if let p = commitment.priority?.lowercased() {
            if p == "high" { return .high }
            if p == "low" { return .low }
            return .medium
        }
        if isDueSoon { return .medium }
        return commitment.status == .open ? .medium : .low
    }
}

enum ActionPriority: Hashable {
    case high, medium, low

    var label: String {
        switch self {
        case .high:   return "High"
        case .medium: return "Med"
        case .low:    return "Low"
        }
    }

    var tint: Color {
        switch self {
        case .high:   return AppPalette.coral
        case .medium: return AppPalette.gold
        case .low:    return AppPalette.secondaryInk
        }
    }
}

// MARK: - Filter & sort

enum ActionItemFilter: String, CaseIterable, Identifiable {
    case open, atRisk, done, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open:   return "Open"
        case .atRisk: return "At risk"
        case .done:   return "Done"
        case .all:    return "All"
        }
    }

    var systemImage: String {
        switch self {
        case .open:   return "circle"
        case .atRisk: return "exclamationmark.triangle.fill"
        case .done:   return "checkmark.circle.fill"
        case .all:    return "tray.full.fill"
        }
    }

    func matches(_ item: AggregatedActionItem) -> Bool {
        switch self {
        case .open:   return item.commitment.status == .open
        case .atRisk: return item.commitment.status == .atRisk
        case .done:   return item.commitment.status == .fulfilled || item.commitment.status == .superseded
        case .all:    return true
        }
    }
}

enum ActionItemSort: String, CaseIterable, Identifiable {
    case priority, recent, meeting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .priority: return "Priority"
        case .recent:   return "Recent"
        case .meeting:  return "Meeting"
        }
    }
}

private struct ActionItemsSnapshotKey: Hashable {
    let revision: Int
    let query: String
    let filter: ActionItemFilter
    let sort: ActionItemSort

    var hasSearchQuery: Bool { !query.isEmpty }
}

private struct ActionItemsMeetingGroup {
    let meetingID: Meeting.ID
    let meetingTitle: String
    let items: [AggregatedActionItem]
}

private struct ActionItemsDateGroup {
    let title: String
    let items: [AggregatedActionItem]
}

private struct ActionItemsDisplaySnapshot {
    var filteredItems: [AggregatedActionItem] = []
    var dateGroups: [ActionItemsDateGroup] = []
    var meetingGroups: [ActionItemsMeetingGroup] = []
    var openCount = 0
    var atRiskCount = 0
    var doneCount = 0
    var attentionCount = 0
    var attentionHeadline = ""
    var attentionDetail = ""
    var shouldPreferAtRiskFilter = false

    static func make(
        allItems: [AggregatedActionItem],
        query: String,
        filter: ActionItemFilter,
        sort: ActionItemSort
    ) -> ActionItemsDisplaySnapshot {
        let filtered = sortedItems(
            allItems
                .filter { filter.matches($0) }
                .filter { matches(query: query, item: $0) },
            sort: sort
        )
        let overdue = allItems.filter(\.isOverdue)
        let atRisk = allItems.filter { $0.commitment.status == .atRisk }
        let dueSoon = allItems.filter(\.isDueSoon)
        let dueSoonNotAtRisk = dueSoon.filter { $0.commitment.status != .atRisk }

        var attentionIDs = Set(overdue.map(\.id))
        attentionIDs.formUnion(atRisk.map(\.id))
        attentionIDs.formUnion(dueSoon.map(\.id))
        let attentionCount = attentionIDs.count

        var attentionParts: [String] = []
        if !overdue.isEmpty { attentionParts.append("\(overdue.count) overdue") }
        if !atRisk.isEmpty { attentionParts.append("\(atRisk.count) at risk") }
        if !dueSoonNotAtRisk.isEmpty { attentionParts.append("\(dueSoonNotAtRisk.count) due soon") }

        return ActionItemsDisplaySnapshot(
            filteredItems: filtered,
            dateGroups: dateGroups(from: filtered),
            meetingGroups: meetingGroups(from: filtered),
            openCount: allItems.filter { $0.commitment.status == .open }.count,
            atRiskCount: atRisk.count,
            doneCount: allItems.filter { $0.commitment.status == .fulfilled || $0.commitment.status == .superseded }.count,
            attentionCount: attentionCount,
            attentionHeadline: "\(attentionCount) item\(attentionCount == 1 ? "" : "s") need\(attentionCount == 1 ? "s" : "") attention",
            attentionDetail: attentionParts.joined(separator: " · "),
            shouldPreferAtRiskFilter: !atRisk.isEmpty
        )
    }

    private static func sortedItems(_ items: [AggregatedActionItem], sort: ActionItemSort) -> [AggregatedActionItem] {
        switch sort {
        case .priority:
            return items.sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return priorityRank(lhs.priority) < priorityRank(rhs.priority)
                }
                return lhs.meetingDate > rhs.meetingDate
            }
        case .recent:
            return items.sorted { $0.meetingDate > $1.meetingDate }
        case .meeting:
            return items.sorted { lhs, rhs in
                if lhs.isMeetingPinned != rhs.isMeetingPinned { return lhs.isMeetingPinned }
                if lhs.meetingDate != rhs.meetingDate { return lhs.meetingDate > rhs.meetingDate }
                return lhs.meetingTitle < rhs.meetingTitle
            }
        }
    }

    private static func dateGroups(from items: [AggregatedActionItem]) -> [ActionItemsDateGroup] {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: .now)
        let weekAgo = cal.date(byAdding: .day, value: -7, to: startToday) ?? startToday
        var today: [AggregatedActionItem] = []
        var week: [AggregatedActionItem] = []
        var earlier: [AggregatedActionItem] = []
        for item in items {
            if item.meetingDate >= startToday { today.append(item) }
            else if item.meetingDate >= weekAgo { week.append(item) }
            else { earlier.append(item) }
        }
        var out: [ActionItemsDateGroup] = []
        if !today.isEmpty { out.append(ActionItemsDateGroup(title: "Today", items: today)) }
        if !week.isEmpty { out.append(ActionItemsDateGroup(title: "This week", items: week)) }
        if !earlier.isEmpty { out.append(ActionItemsDateGroup(title: "Earlier", items: earlier)) }
        return out
    }

    private static func meetingGroups(from items: [AggregatedActionItem]) -> [ActionItemsMeetingGroup] {
        var order: [Meeting.ID] = []
        var titles: [Meeting.ID: String] = [:]
        var buckets: [Meeting.ID: [AggregatedActionItem]] = [:]
        for item in items {
            if buckets[item.meetingID] == nil {
                order.append(item.meetingID)
                titles[item.meetingID] = item.meetingTitle
            }
            buckets[item.meetingID, default: []].append(item)
        }
        return order.map { id in
            ActionItemsMeetingGroup(meetingID: id, meetingTitle: titles[id] ?? "", items: buckets[id] ?? [])
        }
    }

    private static func priorityRank(_ priority: ActionPriority) -> Int {
        switch priority {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    private static func matches(query: String, item: AggregatedActionItem) -> Bool {
        guard !query.isEmpty else { return true }
        return item.commitment.statement.localizedStandardContains(query)
            || item.commitment.owner.localizedStandardContains(query)
            || item.meetingTitle.localizedStandardContains(query)
            || (item.commitment.dueHint?.localizedStandardContains(query) ?? false)
    }
}

private actor ActionItemsSnapshotBuilder {
    func make(meetings: [Meeting], key: ActionItemsSnapshotKey) -> (items: [AggregatedActionItem], snapshot: ActionItemsDisplaySnapshot) {
        let items = meetings.flatMap { meeting in
            guard !meeting.isPersonalCapture else { return [AggregatedActionItem]() }
            return meeting.commitments.map { commitment in
                AggregatedActionItem(
                    commitment: commitment,
                    meetingID: meeting.id,
                    meetingTitle: meeting.title,
                    workspace: meeting.workspace,
                    meetingDate: meeting.when,
                    isMeetingPinned: meeting.isPinned
                )
            }
        }
        let snapshot = ActionItemsDisplaySnapshot.make(
            allItems: items,
            query: key.query,
            filter: key.filter,
            sort: key.sort
        )
        return (items, snapshot)
    }
}

// MARK: - View

struct ActionItemsView: View {
    @Environment(MeetingStore.self) private var store
    @Binding var selectedMeetingID: Meeting.ID?
    @Binding var toast: ToastItem?

    @AppStorage("scribeflow.tasks.filter") private var filter: ActionItemFilter = .open
    @AppStorage("scribeflow.tasks.sort") private var sort: ActionItemSort = .priority
    @State private var query: String = ""
    @State private var hasAnimatedIn = false
    @State private var reminderDraft: ReminderReviewDraft?
    @State private var hasLoadedSnapshot = false
    /// Built once per store change, not on every render — the counts, filters,
    /// and banner all read this instead of re-flattening every meeting's
    /// commitments ~10× per body pass.
    @State private var cachedItems: [AggregatedActionItem] = []
    @State private var displaySnapshot = ActionItemsDisplaySnapshot()
    @State private var snapshotBuilder = ActionItemsSnapshotBuilder()

    private var snapshotKey: ActionItemsSnapshotKey {
        ActionItemsSnapshotKey(
            revision: store.revision,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: filter,
            sort: sort
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                summaryHeader
                    .motionEntrance(step: 0, active: hasAnimatedIn)

                attentionBanner
                    .motionEntrance(step: 1, active: hasAnimatedIn)

                filterRow
                    .motionEntrance(step: 2, active: hasAnimatedIn)

                if !hasLoadedSnapshot && filteredItems.isEmpty {
                    tasksSkeleton
                } else if filteredItems.isEmpty {
                    emptyState
                        .motionEntrance(step: 3, active: hasAnimatedIn)
                } else {
                    itemsList
                        .motionEntrance(step: 3, active: hasAnimatedIn)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, AppDockMetrics.scrollEndPadding)
            .readingWidth()
        }
        .background(AppPalette.background.ignoresSafeArea())
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            HapticEngine.tap(.light)
            toast = ToastItem(message: "Up to date", icon: "checkmark.circle.fill")
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search action items")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(ActionItemSort.allCases) { mode in
                            Label(mode.title, systemImage: sortIcon(for: mode)).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.body.weight(.medium))
                }
                .tint(AppPalette.ink)
                .accessibilityLabel("Sort options")
            }
        }
        .navigationDestination(for: Meeting.ID.self) { id in
            MeetingDetailView(meetingID: id)
        }
        .sheet(item: $reminderDraft) { draft in
            ReminderReviewSheet(
                draft: draft,
                onCancel: { reminderDraft = nil },
                onSave: saveReminder
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear { hasAnimatedIn = true }
        .task(id: snapshotKey) {
            await refreshDisplaySnapshot(for: snapshotKey)
        }
    }

    private func refreshDisplaySnapshot(for key: ActionItemsSnapshotKey) async {
        if key.hasSearchQuery {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }

        let meetings = store.meetings
        let result = await snapshotBuilder.make(meetings: meetings, key: key)
        guard !Task.isCancelled, key == snapshotKey else { return }

        cachedItems = result.items
        displaySnapshot = result.snapshot
        hasLoadedSnapshot = true
    }

    private func sortIcon(for mode: ActionItemSort) -> String {
        switch mode {
        case .priority: return "exclamationmark.circle"
        case .recent:   return "clock"
        case .meeting:  return "folder"
        }
    }

    // MARK: - Sections

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                EditorialEyebrow(text: "Tasks")
                Text("Everything you owe")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .foregroundStyle(AppPalette.ink)
                Text("Aggregated from meetings and calls with clear commitments.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.secondaryInk)
            }

            HStack(spacing: 0) {
                statButton(.open, openCount, "Open", AppPalette.accent)
                cellRule
                statButton(.atRisk, atRiskCount, "At risk", AppPalette.coral)
                cellRule
                statButton(.done, doneCount, "Done", AppPalette.success)
            }
            .overlay(alignment: .top) { EditorialRule() }
            .overlay(alignment: .bottom) { EditorialRule() }
        }
    }

    private var cellRule: some View {
        Rectangle().fill(AppPalette.border.opacity(0.7)).frame(width: 1, height: 30)
    }

    /// Tappable stat — jumps the list straight to that filter.
    private func statButton(_ target: ActionItemFilter, _ value: Int, _ label: String, _ tint: Color) -> some View {
        Button {
            HapticEngine.select()
            withAnimation(AppMotion.snappy) { filter = target }
        } label: {
            statCell(value, label, tint)
                .overlay(alignment: .bottom) {
                    if filter == target {
                        Capsule().fill(tint).frame(height: 2).padding(.horizontal, 12)
                    }
                }
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.96))
        .accessibilityLabel("\(label), \(value). Tap to filter.")
    }

    private func statCell(_ value: Int, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            EditorialEyebrow(text: label)
            CountUpNumber(
                value: hasAnimatedIn ? Double(value) : 0,
                font: .system(size: 24, weight: .medium, design: .serif),
                color: tint
            )
            .animation(.easeOut(duration: 0.8), value: hasAnimatedIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
    }

    /// Surfaces commitments that need attention now — at-risk (overdue
    /// equivalent) plus open items whose due hint reads as imminent. Tapping
    /// focuses the matching filter so the list narrows to those items.
    @ViewBuilder
    private var attentionBanner: some View {
        if attentionCount > 0 {
            Button {
                HapticEngine.tap(.light)
                withAnimation(AppMotion.snappy) {
                    filter = displaySnapshot.shouldPreferAtRiskFilter ? .atRisk : .open
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppPalette.coral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attentionHeadline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text(attentionDetail)
                            .font(.caption)
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.secondaryInk)
                }
                .padding(14)
                .background(
                    AppPalette.coral.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .strokeBorder(AppPalette.coral.opacity(0.25), lineWidth: 0.8)
                )
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.98))
            .accessibilityLabel("\(attentionHeadline). \(attentionDetail)")
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ActionItemFilter.allCases) { mode in
                    Button {
                        HapticEngine.select()
                        withAnimation(AppMotion.snappy) { filter = mode }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.systemImage)
                                .font(.caption.weight(.bold))
                            Text(mode.title)
                                .font(.subheadline.weight(.semibold))
                            Text("\(count(for: mode))")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(filter == mode ? .white.opacity(0.8) : AppPalette.secondaryInk.opacity(0.7))
                        }
                        .foregroundStyle(filter == mode ? .white : AppPalette.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(filter == mode ? AppPalette.ink : AppPalette.softSurface)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(filter == mode ? .clear : AppPalette.border.opacity(0.5), lineWidth: 0.7)
                        )
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                }
            }
        }
    }

    @ViewBuilder
    private var itemsList: some View {
        if sort == .meeting {
            // Group by meeting
            ForEach(groupedByMeeting, id: \.meetingID) { group in
                VStack(alignment: .leading, spacing: 4) {
                    EditorialSectionHead(title: group.meetingTitle, titleSize: 18) {
                        EditorialMeta(text: "\(group.items.count)")
                    }
                    VStack(spacing: 0) {
                        ForEach(group.items) { item in
                            ActionItemRow(item: item, onStatusChange: setStatus, onOpen: openMeeting, onAddToReminders: addToReminders, onScheduleReminder: scheduleReminder)
                            if item.id != group.items.last?.id { EditorialRule() }
                        }
                    }
                }
            }
        } else {
            ForEach(dateGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 4) {
                    EditorialSectionHead(title: group.title, titleSize: 18) {
                        EditorialMeta(text: "\(group.items.count)")
                    }
                    VStack(spacing: 0) {
                        ForEach(group.items) { item in
                            ActionItemRow(item: item, onStatusChange: setStatus, onOpen: openMeeting, onAddToReminders: addToReminders, onScheduleReminder: scheduleReminder)
                                .editorialReveal()
                            if item.id != group.items.last?.id { EditorialRule() }
                        }
                    }
                }
            }
        }
    }

    /// First-paint skeleton — five faint rows so the screen feels instantly
    /// alive while the snapshot builder is still resolving.
    private var tasksSkeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { i in
                HStack(spacing: 14) {
                    Circle()
                        .fill(AppPalette.softSurface)
                        .frame(width: 26, height: 26)
                        .shimmer()
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonRow(height: 11)
                        SkeletonRow(width: 130, height: 9)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                if i < 4 {
                    Divider().background(AppPalette.divider.opacity(0.4)).padding(.leading, 56)
                }
            }
        }
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.7)
        )
        .accessibilityHidden(true)
    }

    private var emptyState: some View {
        EmptyStateCard(
            title: emptyTitle,
            subtitle: emptySubtitle,
            systemImage: filter == .done ? "checkmark.seal.fill" : "tray.fill",
            tint: filter == .done ? AppPalette.success : AppPalette.accent
        )
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "No matches" }
        switch filter {
        case .open:   return "Inbox zero"
        case .atRisk: return "Nothing at risk"
        case .done:   return "No completed items yet"
        case .all:    return "No action items yet"
        }
    }

    private var emptySubtitle: String {
        if !query.isEmpty { return "Try different keywords or clear the search." }
        switch filter {
        case .open:   return "All caught up. Capture a meeting and anything to do will show up here."
        case .atRisk: return "Things get flagged At risk when the timing or owner isn't clear."
        case .done:   return "Check things off and they'll gather here."
        case .all:    return "Capture a meeting or voice note and to-dos will start landing here."
        }
    }

    // MARK: - Data

    private var allItems: [AggregatedActionItem] { cachedItems }

    private var filteredItems: [AggregatedActionItem] {
        displaySnapshot.filteredItems
    }

    /// Date-bucketed sections for non-meeting sorts: Today / This week /
    /// Earlier, by the source meeting's capture date.
    private var dateGroups: [ActionItemsDateGroup] {
        displaySnapshot.dateGroups
    }

    private var groupedByMeeting: [ActionItemsMeetingGroup] {
        displaySnapshot.meetingGroups
    }

    // MARK: - Stats

    /// Distinct items needing attention across overdue / at-risk / due-soon.
    private var attentionCount: Int {
        displaySnapshot.attentionCount
    }

    private var attentionHeadline: String {
        displaySnapshot.attentionHeadline
    }

    private var attentionDetail: String {
        displaySnapshot.attentionDetail
    }

    private var openCount: Int { displaySnapshot.openCount }
    private var atRiskCount: Int { displaySnapshot.atRiskCount }
    private var doneCount: Int { displaySnapshot.doneCount }

    private func count(for filter: ActionItemFilter) -> Int {
        switch filter {
        case .open:   return openCount
        case .atRisk: return atRiskCount
        case .done:   return doneCount
        case .all:    return allItems.count
        }
    }

    // MARK: - Actions

    private func setStatus(_ status: CommitmentStatus, item: AggregatedActionItem) {
        HapticEngine.notify(status == .fulfilled ? .success : .warning)
        store.updateCommitmentStatus(status, commitmentID: item.commitment.id, for: item.meetingID)
        let message: String
        switch status {
        case .fulfilled:  message = "One off the list"
        case .open:       message = "Back on the list"
        case .atRisk:     message = "Flagged at risk"
        case .superseded: message = "Skipped"
        }
        toast = ToastItem(message: message, icon: status == .fulfilled ? "checkmark.circle.fill" : "flag.fill")
    }

    private func openMeeting(_ id: Meeting.ID) {
        HapticEngine.select()
        selectedMeetingID = id
    }

    private func addToReminders(_ item: AggregatedActionItem) {
        Task {
            var notes = "From “\(item.meetingTitle)” · captured in Scribeflow"
            if item.commitment.owner != "Owner not named" {
                notes = "Owner: \(item.commitment.owner)\n" + notes
            }
            let result = await RemindersExporter.add(
                title: item.commitment.statement,
                due: item.dueDate,
                notes: notes
            )
            switch result {
            case .success:
                HapticEngine.notify(.success)
                toast = ToastItem(message: "Added to Reminders", icon: "checkmark.circle.fill")
            case .failure(let error):
                HapticEngine.notify(.warning)
                toast = ToastItem(message: error.message, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func scheduleReminder(_ item: AggregatedActionItem) {
        reminderDraft = ReminderReviewDraft(item: item)
    }

    private func saveReminder(_ request: ReminderReviewRequest) {
        reminderDraft = nil
        var commitment = request.item.commitment
        commitment.owner = request.owner
        commitment.dueDateOverride = request.dueDate
        store.updateCommitmentDetails(
            commitmentID: commitment.id,
            for: request.item.meetingID,
            owner: request.owner,
            dueDateOverride: request.dueDate
        )
        Task {
            let result: Result<String, ReminderScheduler.ScheduleError>
            switch request.timing {
            case .dueDate:
                result = await ReminderScheduler.schedule(
                    commitment: commitment,
                    meetingID: request.item.meetingID,
                    meetingTitle: request.item.meetingTitle,
                    dueDate: request.dueDate
                )
            case .after24Hours, .after48Hours:
                result = await ReminderScheduler.schedule(
                    commitment: commitment,
                    meetingID: request.item.meetingID,
                    meetingTitle: request.item.meetingTitle,
                    fireDate: request.fireDate
                )
            }
            switch result {
            case .success:
                HapticEngine.notify(.success)
                toast = ToastItem(message: "Reminder scheduled", icon: "bell.badge.fill")
            case .failure(let error):
                HapticEngine.notify(.warning)
                toast = ToastItem(message: error.message, icon: "exclamationmark.triangle.fill")
            }
        }
    }
}

// MARK: - Reminders export

/// Sends an action item to Apple Reminders (title, due date, context note),
/// requesting access on first use. No data is stored by Scribeflow for this —
/// it hands off to the user's own Reminders app.
enum RemindersExporter {
    enum ExportError: Error {
        case accessDenied
        case noList
        case saveFailed

        var message: String {
            switch self {
            case .accessDenied: return "Allow Reminders access in Settings to add tasks."
            case .noList:       return "No Reminders list is available to add to."
            case .saveFailed:   return "Couldn't add to Reminders. Try again."
            }
        }
    }

    @MainActor
    static func add(title: String, due: Date?, notes: String?) async -> Result<Void, ExportError> {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else { return .failure(.accessDenied) }
        guard let list = store.defaultCalendarForNewReminders() else { return .failure(.noList) }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = list
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
        }
        do {
            try store.save(reminder, commit: true)
            return .success(())
        } catch {
            return .failure(.saveFailed)
        }
    }
}

// MARK: - Row

private struct ActionItemRow: View {
    let item: AggregatedActionItem
    let onStatusChange: (CommitmentStatus, AggregatedActionItem) -> Void
    let onOpen: (Meeting.ID) -> Void
    let onAddToReminders: (AggregatedActionItem) -> Void
    let onScheduleReminder: (AggregatedActionItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                let next: CommitmentStatus = item.commitment.status == .fulfilled ? .open : .fulfilled
                onStatusChange(next, item)
            } label: {
                ZStack {
                    Circle()
                        .stroke(checkboxStroke, lineWidth: 1.6)
                        .frame(width: 26, height: 26)
                    if item.commitment.status == .fulfilled {
                        Circle()
                            .fill(AppPalette.accent)
                            .frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else if item.commitment.status == .atRisk {
                        Image(systemName: "exclamationmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.coral)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.commitment.status == .fulfilled ? "Mark not done" : "Mark done")
            .padding(.top, 1)

            NavigationLink(value: item.meetingID) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.commitment.statement)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(item.commitment.status == .fulfilled ? AppPalette.secondaryInk : AppPalette.ink)
                            .strikethrough(item.commitment.status == .fulfilled, color: AppPalette.secondaryInk)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)

                        if let rationale = item.commitment.rationale?.nilIfBlank {
                            Text(rationale)
                                .font(.caption)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 8) {
                            if item.commitment.owner != "Owner not named" {
                                metaChip(
                                    item.commitment.owner,
                                    icon: item.commitment.owner == "You" ? "person.fill" : "person",
                                    tint: item.commitment.owner == "You" ? AppPalette.accent : AppPalette.secondaryInk
                                )
                            }
                            dueChip
                            priorityChip
                            sourceChip
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.caption2)
                                .foregroundStyle(AppPalette.secondaryInk.opacity(0.65))
                            Text(item.meetingTitle)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AppPalette.secondaryInk)
                                .lineLimit(1)
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(AppPalette.secondaryInk.opacity(0.5))
                            Text(item.meetingDate, style: .relative)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(AppPalette.secondaryInk.opacity(0.7))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryInk.opacity(0.5))
                        .padding(.top, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(EditorialRowStyle(inset: 6))
        }
        .padding(.vertical, 14)
        .background(item.isOverdue ? AppPalette.coral.opacity(0.05) : Color.clear)
        .overlay(alignment: .leading) {
            if item.isOverdue {
                Rectangle()
                    .fill(AppPalette.coral)
                    .frame(width: 3)
                    .padding(.vertical, 10)
            }
        }
        .contextMenu {
            Button {
                onStatusChange(.fulfilled, item)
            } label: { Label("Mark done", systemImage: "checkmark.circle") }
            Button {
                onStatusChange(.atRisk, item)
            } label: { Label("Flag at risk", systemImage: "exclamationmark.triangle") }
            Button {
                onStatusChange(.open, item)
            } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
            Button {
                onStatusChange(.superseded, item)
            } label: { Label("Skip", systemImage: "forward.end.circle") }
            Divider()
            Button {
                onAddToReminders(item)
            } label: { Label("Add to Reminders", systemImage: "list.bullet.rectangle") }
            Button {
                onScheduleReminder(item)
            } label: { Label("Notify me", systemImage: "bell.badge") }
            Button {
                onOpen(item.meetingID)
            } label: { Label("Open meeting", systemImage: "doc.text.magnifyingglass") }
        }
    }

    private var checkboxStroke: Color {
        switch item.commitment.status {
        case .fulfilled: return AppPalette.accent
        case .atRisk:    return AppPalette.coral
        case .open:      return AppPalette.border.opacity(0.9)
        case .superseded: return AppPalette.secondaryInk.opacity(0.5)
        }
    }

    private var priorityChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(item.priority.tint)
                .frame(width: 6, height: 6)
            Text(item.priority.label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(item.priority.tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(item.priority.tint.opacity(0.10), in: Capsule())
    }

    private func metaChip(_ text: String, icon: String, tint: Color = AppPalette.secondaryInk, strong: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(strong ? .white : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            strong ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.08)),
            in: Capsule()
        )
    }

    @ViewBuilder private var dueChip: some View {
        if item.isOverdue {
            metaChip(overdueLabel, icon: "clock.badge.exclamationmark.fill", tint: AppPalette.coral, strong: true)
        } else if let due = item.dueLabel, !due.isEmpty {
            metaChip(due, icon: "clock.fill", tint: item.isDueSoon ? AppPalette.gold : AppPalette.secondaryInk)
        }
    }

    @ViewBuilder private var sourceChip: some View {
        let source = item.commitment.sourceSpeaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty, source != "Meeting" {
            metaChip(
                source == "AI" ? "AI inferred" : source,
                icon: "quote.bubble.fill",
                tint: source == "AI" ? AppPalette.gold : AppPalette.accent
            )
        }
    }

    private var overdueLabel: String {
        guard let due = item.dueDate else { return "Overdue" }
        let days = Calendar.current.dateComponents([.day], from: due, to: Date()).day ?? 0
        return days >= 1 ? "Overdue \(days)d" : "Overdue"
    }
}

private enum ReminderTimingChoice: String, CaseIterable, Identifiable {
    case after24Hours
    case after48Hours
    case dueDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .after24Hours: return "24h"
        case .after48Hours: return "48h"
        case .dueDate: return "Due"
        }
    }

    var hours: Int? {
        switch self {
        case .after24Hours: return 24
        case .after48Hours: return 48
        case .dueDate: return nil
        }
    }
}

private struct ReminderReviewDraft: Identifiable, Hashable {
    var id: Commitment.ID { item.id }
    let item: AggregatedActionItem
}

private struct ReminderReviewRequest {
    let item: AggregatedActionItem
    let owner: String
    let dueDate: Date
    let timing: ReminderTimingChoice

    var fireDate: Date {
        switch timing {
        case .dueDate:
            return ReminderScheduler.reminderDate(for: dueDate) ?? dueDate
        case .after24Hours, .after48Hours:
            let hours = timing.hours ?? 24
            let fromMeeting = Calendar.current.date(byAdding: .hour, value: hours, to: item.meetingDate) ?? Date()
            let fromNow = Calendar.current.date(byAdding: .hour, value: hours, to: .now) ?? Date()
            return max(fromMeeting, fromNow)
        }
    }
}

private struct ReminderReviewSheet: View {
    let draft: ReminderReviewDraft
    let onCancel: () -> Void
    let onSave: (ReminderReviewRequest) -> Void

    @State private var owner: String
    @State private var dueDate: Date
    @State private var timing: ReminderTimingChoice

    init(
        draft: ReminderReviewDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ReminderReviewRequest) -> Void
    ) {
        self.draft = draft
        self.onCancel = onCancel
        self.onSave = onSave
        _owner = State(initialValue: draft.item.commitment.owner == "Owner not named" ? "" : draft.item.commitment.owner)
        let fallback = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        _dueDate = State(initialValue: draft.item.dueDate ?? fallback)
        _timing = State(initialValue: draft.item.dueDate == nil ? .after24Hours : .dueDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(draft.item.commitment.statement)
                            .font(.headline)
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(draft.item.meetingTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                    .padding(.vertical, 4)
                }

                Section("Owner") {
                    TextField("Owner", text: $owner)
                        .textInputAutocapitalization(.words)
                }

                Section("Timing") {
                    Picker("Timing", selection: $timing) {
                        ForEach(ReminderTimingChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    if timing == .dueDate {
                        DatePicker("Due date", selection: $dueDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    } else {
                        HStack {
                            Text("Reminder")
                            Spacer()
                            Text(fireDate.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(AppPalette.secondaryInk)
                        }
                    }
                }
            }
            .navigationTitle("Save reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(ReminderReviewRequest(
                            item: draft.item,
                            owner: cleanedOwner,
                            dueDate: dueDate,
                            timing: timing
                        ))
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var cleanedOwner: String {
        let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Owner not named" : trimmed
    }

    private var fireDate: Date {
        ReminderReviewRequest(item: draft.item, owner: cleanedOwner, dueDate: dueDate, timing: timing).fireDate
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
