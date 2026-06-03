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
    var dueDate: Date? { DueDateParser.date(from: commitment.dueHint, capturedAt: meetingDate) }

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
        if commitment.status == .atRisk || isOverdue { return .high }
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

// MARK: - View

struct ActionItemsView: View {
    @Environment(MeetingStore.self) private var store
    @Binding var selectedMeetingID: Meeting.ID?
    @Binding var toast: ToastItem?

    @AppStorage("scribeflow.tasks.filter") private var filter: ActionItemFilter = .open
    @AppStorage("scribeflow.tasks.sort") private var sort: ActionItemSort = .priority
    @State private var query: String = ""
    @State private var hasAnimatedIn = false
    /// Built once per store change, not on every render — the counts, filters,
    /// and banner all read this instead of re-flattening every meeting's
    /// commitments ~10× per body pass.
    @State private var cachedItems: [AggregatedActionItem] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                summaryHeader
                    .motionEntrance(step: 0, active: hasAnimatedIn)

                attentionBanner
                    .motionEntrance(step: 1, active: hasAnimatedIn)

                filterRow
                    .motionEntrance(step: 2, active: hasAnimatedIn)

                if !hasAnimatedIn && filteredItems.isEmpty {
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
            .padding(.bottom, 32)
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
        .onAppear { hasAnimatedIn = true }
        .task(id: store.revision) { cachedItems = buildAggregatedItems() }
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
                Text("Aggregated from every meeting, voice note, and call.")
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
                    filter = atRiskItems.isEmpty ? .open : .atRisk
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
                            ActionItemRow(item: item, onStatusChange: setStatus, onOpen: openMeeting, onAddToReminders: addToReminders)
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
                            ActionItemRow(item: item, onStatusChange: setStatus, onOpen: openMeeting, onAddToReminders: addToReminders)
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

    private func buildAggregatedItems() -> [AggregatedActionItem] {
        store.meetings.flatMap { meeting in
            meeting.commitments.map { commitment in
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
    }

    private var filteredItems: [AggregatedActionItem] {
        let base = allItems
            .filter { filter.matches($0) }
            .filter { matches(query: query, item: $0) }

        switch sort {
        case .priority:
            return base.sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return priorityRank(lhs.priority) < priorityRank(rhs.priority)
                }
                return lhs.meetingDate > rhs.meetingDate
            }
        case .recent:
            return base.sorted { $0.meetingDate > $1.meetingDate }
        case .meeting:
            return base.sorted { lhs, rhs in
                if lhs.isMeetingPinned != rhs.isMeetingPinned { return lhs.isMeetingPinned }
                if lhs.meetingDate != rhs.meetingDate { return lhs.meetingDate > rhs.meetingDate }
                return lhs.meetingTitle < rhs.meetingTitle
            }
        }
    }

    private struct MeetingGroup {
        let meetingID: Meeting.ID
        let meetingTitle: String
        let items: [AggregatedActionItem]
    }

    private struct DateGroup {
        let title: String
        let items: [AggregatedActionItem]
    }

    /// Date-bucketed sections for non-meeting sorts: Today / This week /
    /// Earlier, by the source meeting's capture date.
    private var dateGroups: [DateGroup] {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: .now)
        let weekAgo = cal.date(byAdding: .day, value: -7, to: startToday) ?? startToday
        var today: [AggregatedActionItem] = []
        var week: [AggregatedActionItem] = []
        var earlier: [AggregatedActionItem] = []
        for item in filteredItems {
            if item.meetingDate >= startToday      { today.append(item) }
            else if item.meetingDate >= weekAgo    { week.append(item) }
            else                                   { earlier.append(item) }
        }
        var out: [DateGroup] = []
        if !today.isEmpty   { out.append(DateGroup(title: "Today", items: today)) }
        if !week.isEmpty    { out.append(DateGroup(title: "This week", items: week)) }
        if !earlier.isEmpty { out.append(DateGroup(title: "Earlier", items: earlier)) }
        return out
    }

    private var groupedByMeeting: [MeetingGroup] {
        var order: [Meeting.ID] = []
        var titles: [Meeting.ID: String] = [:]
        var buckets: [Meeting.ID: [AggregatedActionItem]] = [:]
        for item in filteredItems {
            if buckets[item.meetingID] == nil {
                order.append(item.meetingID)
                titles[item.meetingID] = item.meetingTitle
            }
            buckets[item.meetingID, default: []].append(item)
        }
        return order.map { id in
            MeetingGroup(meetingID: id, meetingTitle: titles[id] ?? "", items: buckets[id] ?? [])
        }
    }

    private func priorityRank(_ p: ActionPriority) -> Int {
        switch p {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    private func matches(query: String, item: AggregatedActionItem) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return item.commitment.statement.localizedStandardContains(q)
            || item.commitment.owner.localizedStandardContains(q)
            || item.meetingTitle.localizedStandardContains(q)
            || (item.commitment.dueHint?.localizedStandardContains(q) ?? false)
    }

    // MARK: - Stats

    /// Past their real deadline and still open — time-judged, not keyword-judged.
    private var overdueItems: [AggregatedActionItem] {
        allItems.filter { $0.isOverdue }
    }

    /// At-risk commitments — the modeled "needs action now" signal.
    private var atRiskItems: [AggregatedActionItem] {
        allItems.filter { $0.commitment.status == .atRisk }
    }

    /// Due within the next two days by real date (and not already overdue).
    private var dueSoonItems: [AggregatedActionItem] {
        allItems.filter { $0.isDueSoon }
    }

    /// Distinct items needing attention across overdue / at-risk / due-soon.
    private var attentionCount: Int {
        var ids = Set(overdueItems.map(\.id))
        ids.formUnion(atRiskItems.map(\.id))
        ids.formUnion(dueSoonItems.map(\.id))
        return ids.count
    }

    private var attentionHeadline: String {
        let n = attentionCount
        return "\(n) item\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") attention"
    }

    private var attentionDetail: String {
        var parts: [String] = []
        if !overdueItems.isEmpty { parts.append("\(overdueItems.count) overdue") }
        if !atRiskItems.isEmpty { parts.append("\(atRiskItems.count) at risk") }
        let dueSoonNotAtRisk = dueSoonItems.filter { $0.commitment.status != .atRisk }
        if !dueSoonNotAtRisk.isEmpty { parts.append("\(dueSoonNotAtRisk.count) due soon") }
        return parts.joined(separator: " · ")
    }

    private var openCount: Int { allItems.filter { $0.commitment.status == .open }.count }
    private var atRiskCount: Int { allItems.filter { $0.commitment.status == .atRisk }.count }
    private var doneCount: Int { allItems.filter { $0.commitment.status == .fulfilled || $0.commitment.status == .superseded }.count }

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
        case .superseded: message = "Superseded"
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
            Divider()
            Button {
                onAddToReminders(item)
            } label: { Label("Add to Reminders", systemImage: "list.bullet.rectangle") }
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
        } else if let due = item.commitment.dueHint, !due.isEmpty {
            metaChip(due.capitalized, icon: "clock.fill", tint: item.isDueSoon ? AppPalette.gold : AppPalette.secondaryInk)
        }
    }

    private var overdueLabel: String {
        guard let due = item.dueDate else { return "Overdue" }
        let days = Calendar.current.dateComponents([.day], from: due, to: Date()).day ?? 0
        return days >= 1 ? "Overdue \(days)d" : "Overdue"
    }
}

