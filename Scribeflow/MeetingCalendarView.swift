import EventKit
import SwiftUI

struct MeetingCalendarView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let isActive: Bool
    @Binding var selectedMeetingID: Meeting.ID?
    let onCapture: (CaptureView.Mode) -> Void
    @Binding var toast: ToastItem?

    @AppStorage("scribeflow.calendar.scope") private var calendarScope: CalendarScope = .month
    @AppStorage("scribeflow.calendar.filter") private var calendarFilter: CalendarContentFilter = .all
    @State private var displayedMonth = Self.startOfMonth(for: .now)
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var accessState: CalendarAccessState = .notDetermined
    @State private var calendarEvents: [CalendarEventSnapshot] = []
    @State private var calendarEventRevision = 0
    @State private var isRequestingAccess = false
    @State private var snapshot = MeetingCalendarSnapshot()
    @State private var snapshotBuilder = MeetingCalendarSnapshotBuilder()
    @State private var prepPresentation: EventPrepPresentation?

    private var snapshotKey: MeetingCalendarSnapshotKey {
        MeetingCalendarSnapshotKey(
            revision: store.revision,
            displayedMonth: displayedMonth,
            selectedDate: selectedDate,
            eventRevision: calendarEventRevision
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    Color.clear.frame(height: 0).id("calendar.top")
                    calendarHeader
                    if calendarScope == .week {
                        calendarTimelineStrip
                    }
                    calendarModeContent

                    if accessState != .allowed {
                        calendarAccessCard
                    }

                    if calendarScope != .agenda {
                        selectedDayAgenda
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, AppDockMetrics.scrollEndPadding)
                .readingWidth()
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        HapticEngine.tap(.light)
                        jumpToToday()
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                            .font(.body.weight(.medium))
                    }
                    .tint(AppPalette.ink)
                    .accessibilityLabel("Jump to today")
                }
            }
            .refreshable {
                HapticEngine.tap(.light)
                await refreshCalendarEvents()
                toast = ToastItem(message: "Calendar refreshed", icon: "arrow.clockwise")
            }
            .navigationDestination(for: Meeting.ID.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .navigationDestination(for: MeetingCalendarAgendaDay.self) { day in
                MeetingCalendarDayDetailView(
                    day: day,
                    filter: calendarFilter,
                    linkedMeeting: snapshot.linkedMeeting(for:),
                    onPrep: showPrep(for:),
                    onCapture: capture(for:),
                    onCreateNote: { createNote(on: day.date) }
                )
            }
            .sheet(item: $prepPresentation) { presentation in
                EventPrepBriefSheet(
                    event: presentation.event,
                    brief: presentation.brief,
                    hasPreparedNote: presentation.hasPreparedNote,
                    onOpenNote: { prepareNote(for: presentation.event) },
                    onRecord: { capture(for: presentation.event) },
                    onOpenSource: openMeeting(_:)
                )
            }
            .task(id: isActive ? displayedMonth : nil) {
                guard isActive else { return }
                await refreshCalendarEvents()
            }
            .task(id: isActive ? snapshotKey : nil) {
                guard isActive else { return }
                await refreshSnapshot(for: snapshotKey)
            }
            .onChange(of: scenePhase) { _, phase in
                guard isActive, phase == .active else { return }
                Task { await refreshCalendarEvents() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                guard isActive else { return }
                Task { await refreshCalendarEvents() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .scribeflowDockScrollToTop)) { note in
                guard (note.object as? String) == "calendar" else { return }
                withAnimation(AppMotion.smooth) {
                    proxy.scrollTo("calendar.top", anchor: .top)
                }
            }
        }
    }

    private var calendarHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        calendarTitle
                        monthNavigation
                    }
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        calendarTitle
                        Spacer(minLength: 8)
                        monthNavigation
                    }
                }
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 0) {
                        calendarStat("\(visibleNoteCount)", "notes", AppPalette.accent)
                        EditorialRule()
                        calendarStat("\(visibleEventCount)", "events", AppPalette.gold)
                        EditorialRule()
                        calendarStat("\(snapshot.selectedOpenLoopCount)", "day open", AppPalette.coral)
                    }
                } else {
                    HStack(spacing: 0) {
                        calendarStat("\(visibleNoteCount)", "notes", AppPalette.accent)
                        calendarRule
                        calendarStat("\(visibleEventCount)", "events", AppPalette.gold)
                        calendarRule
                        calendarStat("\(snapshot.selectedOpenLoopCount)", "day open", AppPalette.coral)
                    }
                }
            }
            .overlay(alignment: .top) { EditorialRule() }
            .overlay(alignment: .bottom) { EditorialRule() }

            calendarLegend
            calendarControls
        }
        .accessibilityIdentifier("calendar.header")
    }

    private var calendarTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calendar")
                .font(AppFont.serif(.title, weight: .medium))
                .foregroundStyle(AppPalette.ink)
            Text(visiblePeriodTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryInk)
                .contentTransition(.numericText())
        }
    }

    private var monthNavigation: some View {
        HStack(spacing: 8) {
            monthButton("chevron.left", accessibilityLabel: "Previous \(calendarScope.periodName)") {
                moveVisiblePeriod(by: -1)
            }
            monthButton("chevron.right", accessibilityLabel: "Next \(calendarScope.periodName)") {
                moveVisiblePeriod(by: 1)
            }
        }
    }

    private var visiblePeriodTitle: String {
        guard calendarScope == .week,
              let interval = Calendar.current.dateInterval(of: .weekOfYear, for: selectedDate)
        else {
            return displayedMonth.formatted(.dateTime.month(.wide).year())
        }
        let inclusiveEnd = interval.end.addingTimeInterval(-1)
        let start = interval.start.formatted(.dateTime.month(.abbreviated).day())
        let end = inclusiveEnd.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(start) - \(end)"
    }

    private var visibleNoteCount: Int {
        guard calendarScope == .week else { return snapshot.monthMeetingCount }
        return snapshot.selectedWeekAgendaDays.reduce(0) { $0 + $1.meetings.count }
    }

    private var visibleEventCount: Int {
        guard calendarScope == .week else { return snapshot.monthEventCount }
        return snapshot.selectedWeekAgendaDays.reduce(0) { $0 + $1.events.count }
    }

    private var calendarTimelineStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(snapshot.selectedWeekDays) { day in
                    Button {
                        selectDay(day)
                    } label: {
                        VStack(spacing: 7) {
                            Text(day.weekdayLabel)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(day.isSelected ? .white.opacity(0.78) : AppPalette.tertiaryInk)
                            Text("\(day.dayNumber)")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(day.isSelected ? .white : AppPalette.ink)
                            HStack(spacing: 3) {
                                if day.noteCount > 0 {
                                    miniDot(AppPalette.accent)
                                }
                                if day.eventCount > 0 {
                                    miniDot(AppPalette.gold)
                                }
                                if day.hasOpenActions {
                                    miniDot(AppPalette.coral)
                                }
                                if !day.hasAnyActivity {
                                    miniDot(AppPalette.border.opacity(0.65))
                                }
                            }
                            .frame(height: 5)
                        }
                        .frame(width: 54, height: 76)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                                .fill(day.isSelected ? AppPalette.ink : AppPalette.cardBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                                .strokeBorder(day.isToday ? AppPalette.accent.opacity(0.55) : AppPalette.border.opacity(0.45), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.95))
                    .accessibilityLabel(accessibilityLabel(for: day))
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
        .accessibilityIdentifier("calendar.weekStrip")
    }

    private var calendarLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                legendChip("Notes", tint: AppPalette.accent)
                legendChip("Events", tint: AppPalette.gold)
                legendChip("Open loops", tint: AppPalette.coral)
            }
        }
    }

    private var calendarControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                calendarScopeMenu
            } else {
                Picker("Calendar view", selection: $calendarScope) {
                    ForEach(CalendarScope.allCases) { scope in
                        Label(scope.title, systemImage: scope.systemImage)
                            .tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Calendar view")
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        calendarFilterMenu
                        nextBusyDayButton
                    }
                } else {
                    HStack(spacing: 10) {
                        calendarFilterMenu
                        Spacer(minLength: 8)
                        nextBusyDayButton
                    }
                }
            }
        }
    }

    private var calendarScopeMenu: some View {
        Menu {
            Picker("Calendar view", selection: $calendarScope) {
                ForEach(CalendarScope.allCases) { scope in
                    Label(scope.title, systemImage: scope.systemImage).tag(scope)
                }
            }
        } label: {
            Label(calendarScope.title, systemImage: calendarScope.systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calendar view, \(calendarScope.title)")
    }

    private var calendarFilterMenu: some View {
        Menu {
            Picker("Show", selection: $calendarFilter) {
                ForEach(CalendarContentFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.systemImage).tag(filter)
                }
            }
        } label: {
            Label(calendarFilter.title, systemImage: calendarFilter.systemImage)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(AppPalette.softSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calendar filter, \(calendarFilter.title)")
    }

    private var nextBusyDayButton: some View {
        Button {
            HapticEngine.select()
            jumpToNextActivity()
        } label: {
            Label("Next busy day", systemImage: "forward.end.fill")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(AppPalette.cardBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.65), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppPalette.accent)
        .accessibilityLabel("Jump to next matching day")
    }

    @ViewBuilder
    private var calendarModeContent: some View {
        switch calendarScope {
        case .month:
            calendarGrid
        case .week:
            calendarWeekBoard
        case .agenda:
            calendarAgendaBoard
        }
    }

    private var calendarGrid: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Self.weekColumns, spacing: 8) {
                ForEach(Array(Self.weekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.tertiaryInk)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Self.weekColumns, spacing: 8) {
                ForEach(snapshot.days) { day in
                    Button {
                        selectDay(day)
                    } label: {
                        MeetingCalendarDayCell(day: day)
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.96))
                    .accessibilityLabel(accessibilityLabel(for: day))
                }
            }
        }
        .padding(14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8)
        )
        .appShadow(AppShadow.hairline)
        .accessibilityIdentifier("calendar.monthGrid")
    }

    private var calendarWeekBoard: some View {
        VStack(alignment: .leading, spacing: 10) {
            agendaSectionTitle("Week at a glance", count: snapshot.selectedWeekAgendaDays.filter { calendarFilter.matches($0) }.count)
            ForEach(snapshot.selectedWeekAgendaDays) { day in
                Button {
                    selectDate(day.date)
                } label: {
                    MeetingCalendarAgendaDayRow(
                        day: day,
                        filter: calendarFilter,
                        isSelected: Calendar.current.isDate(day.date, inSameDayAs: selectedDate)
                    )
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.98))
            }
        }
        .padding(14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8)
        )
        .appShadow(AppShadow.hairline)
        .accessibilityIdentifier("calendar.weekBoard")
    }

    @ViewBuilder
    private var calendarAgendaBoard: some View {
        let days = filteredMonthAgendaDays
        VStack(alignment: .leading, spacing: 10) {
            agendaSectionTitle("Month agenda", count: days.count)
            if days.isEmpty {
                EmptyStateCard(
                    title: "No matching calendar items",
                    subtitle: "Try another filter or connect Calendar to pull in scheduled meetings.",
                    systemImage: calendarFilter.systemImage,
                    tint: AppPalette.accent
                )
            } else {
                ForEach(days) { day in
                    NavigationLink(value: day) {
                        MeetingCalendarAgendaDayRow(
                            day: day,
                            filter: calendarFilter,
                            isSelected: Calendar.current.isDate(day.date, inSameDayAs: selectedDate)
                        )
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.98))
                }
            }
        }
        .padding(14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8)
        )
        .appShadow(AppShadow.hairline)
        .accessibilityIdentifier("calendar.agendaBoard")
    }

    @ViewBuilder
    private var calendarAccessCard: some View {
        if accessState == .notDetermined {
            MeetingCalendarAccessCard(
                title: "Connect calendar events",
                subtitle: "Saved Scribeflow notes already appear here. Connect Calendar to add your real meetings beside them.",
                systemImage: "calendar.badge.plus",
                actionTitle: "Connect",
                isLoading: isRequestingAccess,
                tint: AppPalette.accent,
                action: requestCalendarAccess
            )
        } else {
            MeetingCalendarAccessCard(
                title: "Calendar access is off",
                subtitle: "Open Settings to reconnect events. Your saved Scribeflow notes still appear by date.",
                systemImage: "calendar.badge.exclamationmark",
                actionTitle: "Settings",
                isLoading: false,
                tint: AppPalette.coral
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedDayAgenda: some View {
        let meetings = filteredSelectedMeetings
        let events = filteredSelectedEvents
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHead(title: selectedDateTitle, titleSize: 22) {
                EditorialMeta(text: selectedSummary(meetings: meetings, events: events))
            }

            if meetings.isEmpty && events.isEmpty {
                EmptyStateCard(
                    title: "No matching items on this day",
                    subtitle: emptySelectedDaySubtitle,
                    systemImage: calendarFilter.systemImage,
                    tint: AppPalette.accent
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !meetings.isEmpty {
                        agendaSectionTitle(calendarFilter == .openLoops ? "Open-loop notes" : "Scribeflow notes", count: meetings.count)
                        ForEach(meetings) { meeting in
                            NavigationLink(value: meeting.id) {
                                MeetingCalendarMeetingRow(meeting: meeting)
                            }
                            .buttonStyle(PressScaleButtonStyle(scale: 0.98))
                        }
                    }

                    if !events.isEmpty {
                        agendaSectionTitle("Calendar events", count: events.count)
                            .padding(.top, meetings.isEmpty ? 0 : 8)
                        ForEach(events) { event in
                            MeetingCalendarEventRow(
                                event: event,
                                linkedMeeting: snapshot.linkedMeeting(for: event),
                                onPrep: showPrep(for:),
                                onCapture: capture(for:)
                            )
                        }
                    }
                }
            }

            Button {
                HapticEngine.tap(.light)
                createNoteForSelectedDay()
            } label: {
                Label("Add note on this day", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.ink)
        }
        .accessibilityIdentifier("calendar.selectedAgenda")
    }

    private var filteredSelectedMeetings: [Meeting] {
        calendarFilter.visibleMeetings(from: snapshot.selectedMeetings)
    }

    private var filteredSelectedEvents: [CalendarEventSnapshot] {
        calendarFilter.visibleEvents(from: snapshot.selectedEvents)
    }

    private var filteredMonthAgendaDays: [MeetingCalendarAgendaDay] {
        snapshot.monthAgendaDays.filter { calendarFilter.matches($0) }
    }

    private var emptySelectedDaySubtitle: String {
        switch calendarFilter {
        case .all:
            "Add a note for this date, or connect Calendar to pull in scheduled meetings."
        case .notes:
            "No Scribeflow notes match this date yet."
        case .events:
            "No connected calendar events match this date yet."
        case .openLoops:
            "No open action loops are attached to this date."
        }
    }

    private func selectedSummary(meetings: [Meeting], events: [CalendarEventSnapshot]) -> String {
        let total = meetings.count + events.count
        return total == 0 ? "clear" : "\(total) item\(total == 1 ? "" : "s")"
    }

    private var selectedDateTitle: String {
        if Calendar.current.isDateInToday(selectedDate) {
            return "Today"
        }
        return selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private var calendarRule: some View {
        Rectangle().fill(AppPalette.border.opacity(0.7)).frame(width: 1, height: 30)
    }

    private func legendChip(_ label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            miniDot(tint)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.secondaryInk)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(AppPalette.softSurface, in: Capsule())
    }

    private func miniDot(_ tint: Color) -> some View {
        Circle()
            .fill(tint)
            .frame(width: 5, height: 5)
    }

    private func monthButton(
        _ systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticEngine.select()
            withAnimation(AppMotion.snappy) { action() }
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.ink)
                .frame(width: 38, height: 38)
                .background(AppPalette.softSurface, in: Circle())
                .overlay(Circle().strokeBorder(AppPalette.border.opacity(0.65), lineWidth: 0.8))
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func selectDay(_ day: MeetingCalendarDay) {
        HapticEngine.select()
        selectDate(day.date)
    }

    private func selectDate(_ date: Date) {
        withAnimation(AppMotion.snappy) {
            selectedDate = Calendar.current.startOfDay(for: date)
            if !Calendar.current.isDate(date, equalTo: displayedMonth, toGranularity: .month) {
                displayedMonth = Self.startOfMonth(for: date)
            }
        }
    }

    private func calendarStat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(AppFont.serif(.title3, weight: .medium))
                .foregroundStyle(tint)
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.tertiaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
    }

    private func agendaSectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.ink)
            Spacer()
            EditorialMeta(text: "\(count)")
        }
    }

    private func refreshCalendarEvents() async {
        let service = CalendarService.shared
        let access = service.refreshAccessState()
        let range = Self.visibleDateRange(for: displayedMonth)
        let events = access.canReadEvents
            ? await service.fetchEvents(from: range.start, to: range.end, limit: 240)
            : []

        guard !Task.isCancelled else { return }
        accessState = access
        if calendarEvents != events {
            calendarEvents = events
            calendarEventRevision &+= 1
        }
    }

    private func refreshSnapshot(for key: MeetingCalendarSnapshotKey) async {
        let meetings = store.meetings
        let events = calendarEvents
        let nextSnapshot = await snapshotBuilder.make(
            meetings: meetings,
            events: events,
            displayedMonth: key.displayedMonth,
            selectedDate: key.selectedDate
        )
        guard !Task.isCancelled, key == snapshotKey else { return }
        snapshot = nextSnapshot
    }

    private func requestCalendarAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        Task {
            let granted = await CalendarService.shared.requestAccessIfNeeded()
            await refreshCalendarEvents()
            isRequestingAccess = false
            toast = ToastItem(
                message: granted ? "Calendar connected" : "Calendar not connected",
                icon: granted ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark"
            )
        }
    }

    private func prepareNote(for event: CalendarEventSnapshot) {
        if let existing = store.meeting(linkedTo: event) {
            openMeeting(existing.id)
            toast = ToastItem(message: "That event already has a note", icon: "doc.text.fill")
            HapticEngine.tap(.light)
            return
        }

        let id = store.addMeeting(
            title: event.title,
            workspace: event.isVideoCall ? "Calls" : "Meetings",
            attendees: event.attendees,
            objective: event.objective,
            notes: event.prepNotesTemplate,
            when: event.startDate,
            stage: "Prepared from calendar",
            durationMinutes: event.durationMinutes,
            audioRecordings: [],
            calendarEventID: event.id,
            calendarStartDate: event.startDate,
            calendarEndDate: event.endDate
        )
        selectedDate = Calendar.current.startOfDay(for: event.startDate)
        openMeeting(id)
        HapticEngine.notify(.success)
        toast = ToastItem(message: "Note linked to calendar event", icon: "calendar.badge.checkmark")
    }

    private func showPrep(for event: CalendarEventSnapshot) {
        HapticEngine.tap(.light)
        prepPresentation = EventPrepPresentation(
            event: event,
            brief: store.eventPrepBrief(for: event),
            hasPreparedNote: store.meeting(linkedTo: event) != nil
        )
    }

    private func openMeeting(_ id: Meeting.ID) {
        selectedMeetingID = id
        NotificationCenter.default.post(name: .scribeflowOpenMeeting, object: id)
    }

    private func capture(for event: CalendarEventSnapshot) {
        UpcomingCaptureContext.shared.preferredEvent = event
        HapticEngine.tap(.light)
        onCapture(.record)
    }

    private func createNoteForSelectedDay() {
        createNote(on: selectedDate)
    }

    private func createNote(on date: Date) {
        let title = "Meeting · \(date.formatted(.dateTime.month(.abbreviated).day()))"
        let id = store.addMeeting(
            title: title,
            workspace: "Meetings",
            attendees: ["You"],
            objective: "Planned from calendar view",
            notes: "- Agenda:\n- Decisions:\n- Risks:\n- Next steps:",
            when: date,
            stage: "Created from calendar",
            durationMinutes: 30,
            audioRecordings: []
        )
        selectedMeetingID = id
        HapticEngine.notify(.success)
        toast = ToastItem(message: "Note added for \(date.formatted(.dateTime.month(.abbreviated).day()))", icon: "square.and.pencil")
    }

    private func moveVisiblePeriod(by delta: Int) {
        let calendar = Calendar.current
        if calendarScope == .week {
            guard let nextWeek = calendar.date(byAdding: .day, value: delta * 7, to: selectedDate) else { return }
            selectedDate = calendar.startOfDay(for: nextWeek)
            displayedMonth = Self.startOfMonth(for: nextWeek)
            return
        }

        guard let nextMonth = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        displayedMonth = Self.startOfMonth(for: nextMonth)
        selectedDate = displayedMonth
    }

    private func jumpToToday() {
        let today = Calendar.current.startOfDay(for: .now)
        displayedMonth = Self.startOfMonth(for: today)
        selectedDate = today
    }

    private func jumpToNextActivity() {
        let matchingDays = filteredMonthAgendaDays
        let selectedDay = Calendar.current.startOfDay(for: selectedDate)
        let nextDay = matchingDays.first { $0.date > selectedDay } ?? matchingDays.first

        guard let nextDay else {
            toast = ToastItem(message: "No matching calendar items", icon: calendarFilter.systemImage)
            return
        }

        selectDate(nextDay.date)
    }

    private func accessibilityLabel(for day: MeetingCalendarDay) -> String {
        var parts = [day.accessibilityDateLabel]
        if day.noteCount > 0 { parts.append("\(day.noteCount) Scribeflow note\(day.noteCount == 1 ? "" : "s")") }
        if day.eventCount > 0 { parts.append("\(day.eventCount) calendar event\(day.eventCount == 1 ? "" : "s")") }
        if day.hasOpenActions { parts.append("has open actions") }
        if day.isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    private static let weekColumns = Array(
        repeating: GridItem(.flexible(minimum: 34), spacing: 8, alignment: .center),
        count: 7
    )

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        return formatter
    }()

    private static func weekdaySymbols() -> [String] {
        let formatter = weekdayFormatter
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? formatter.veryShortWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let first = Calendar.current.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private static func startOfMonth(for date: Date) -> Date {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps).map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: date)
    }

    private static func visibleDateRange(for month: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = startOfMonth(for: month)
        let firstWeekday = calendar.component(.weekday, from: start)
        let leadingDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: start) ?? start
        let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart) ?? start
        return (gridStart, gridEnd)
    }
}

private enum CalendarScope: String, CaseIterable, Identifiable {
    case month
    case week
    case agenda

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: "Month"
        case .week: "Week"
        case .agenda: "Agenda"
        }
    }

    var systemImage: String {
        switch self {
        case .month: "calendar"
        case .week: "calendar.day.timeline.left"
        case .agenda: "list.bullet.rectangle"
        }
    }

    var periodName: String {
        self == .week ? "week" : "month"
    }
}

private enum CalendarContentFilter: String, CaseIterable, Identifiable {
    case all
    case notes
    case events
    case openLoops

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .notes: "Notes"
        case .events: "Events"
        case .openLoops: "Open loops"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .notes: "doc.text.fill"
        case .events: "calendar"
        case .openLoops: "checklist"
        }
    }

    func visibleMeetings(from meetings: [Meeting]) -> [Meeting] {
        switch self {
        case .all, .notes:
            meetings
        case .events:
            []
        case .openLoops:
            meetings.filter(meetingHasOpenLoops)
        }
    }

    func visibleEvents(from events: [CalendarEventSnapshot]) -> [CalendarEventSnapshot] {
        switch self {
        case .all, .events:
            events
        case .notes, .openLoops:
            []
        }
    }

    func matches(_ day: MeetingCalendarAgendaDay) -> Bool {
        !visibleMeetings(from: day.meetings).isEmpty || !visibleEvents(from: day.events).isEmpty
    }
}

private func meetingOpenLoopCount(_ meeting: Meeting) -> Int {
    guard meeting.allowsAccountabilityExtraction else { return 0 }
    return meeting.commitments.reduce(0) { count, commitment in
        count + (commitment.status == .open || commitment.status == .atRisk ? 1 : 0)
    }
}

private func meetingHasOpenLoops(_ meeting: Meeting) -> Bool {
    meetingOpenLoopCount(meeting) > 0
}

private struct MeetingCalendarSnapshotKey: Hashable {
    let revision: Int
    let displayedMonth: Date
    let selectedDate: Date
    let eventRevision: Int
}

private actor MeetingCalendarSnapshotBuilder {
    func make(
        meetings: [Meeting],
        events: [CalendarEventSnapshot],
        displayedMonth: Date,
        selectedDate: Date
    ) -> MeetingCalendarSnapshot {
        MeetingCalendarSnapshot(
            meetings: meetings,
            events: events,
            displayedMonth: displayedMonth,
            selectedDate: selectedDate
        )
    }
}

private struct MeetingCalendarSnapshot {
    var days: [MeetingCalendarDay] = []
    var selectedWeekDays: [MeetingCalendarDay] = []
    var selectedWeekAgendaDays: [MeetingCalendarAgendaDay] = []
    var monthAgendaDays: [MeetingCalendarAgendaDay] = []
    var selectedMeetings: [Meeting] = []
    var selectedEvents: [CalendarEventSnapshot] = []
    var linkedMeetingsByEventID: [String: Meeting] = [:]
    var linkedMeetingsByFingerprint: [String: Meeting] = [:]
    var monthMeetingCount = 0
    var monthEventCount = 0
    var selectedOpenLoopCount = 0

    var selectedSummary: String {
        let total = selectedMeetings.count + selectedEvents.count
        return total == 0 ? "clear" : "\(total) item\(total == 1 ? "" : "s")"
    }

    init() {}

    init(meetings: [Meeting], events: [CalendarEventSnapshot], displayedMonth: Date, selectedDate: Date) {
        let calendar = Calendar.current
        let monthStart = Self.startOfMonth(for: displayedMonth, calendar: calendar)
        let monthInterval = calendar.dateInterval(of: .month, for: monthStart)
        let selectedDay = calendar.startOfDay(for: selectedDate)
        let range = Self.visibleDateRange(for: monthStart, calendar: calendar)

        let meetingsByDay = Dictionary(grouping: meetings, by: { meeting in
            calendar.startOfDay(for: meeting.calendarStartDate ?? meeting.when)
        })
        let eventsByDay = Dictionary(grouping: events, by: { event in
            calendar.startOfDay(for: event.startDate)
        })

        selectedMeetings = (meetingsByDay[selectedDay] ?? []).sorted(by: Self.sortMeetingsByTime)
        selectedEvents = (eventsByDay[selectedDay] ?? []).sorted { $0.startDate < $1.startDate }
        for meeting in meetings {
            if let eventID = meeting.calendarEventID {
                linkedMeetingsByEventID[eventID] = meeting
            }
            if let startDate = meeting.calendarStartDate {
                linkedMeetingsByFingerprint[Self.eventFingerprint(title: meeting.title, startDate: startDate)] = meeting
            }
        }
        selectedOpenLoopCount = selectedMeetings.reduce(0) { total, meeting in
            total + meetingOpenLoopCount(meeting)
        }

        if let monthInterval {
            for meeting in meetings where monthInterval.contains(meeting.calendarStartDate ?? meeting.when) {
                monthMeetingCount += 1
            }
            for event in events where monthInterval.contains(event.startDate) {
                monthEventCount += 1
            }
        }

        days = (0..<42).compactMap { offset -> MeetingCalendarDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: range.start) else { return nil }
            let day = calendar.startOfDay(for: date)
            let dayMeetings = meetingsByDay[day] ?? []
            let dayEvents = eventsByDay[day] ?? []
            let openLoopCount = dayMeetings.reduce(0) { total, meeting in
                total + meetingOpenLoopCount(meeting)
            }
            return MeetingCalendarDay(
                date: day,
                dayNumber: calendar.component(.day, from: day),
                weekdayLabel: day.formatted(.dateTime.weekday(.abbreviated)),
                agendaTitleLabel: day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                accessibilityDateLabel: day.formatted(.dateTime.weekday(.wide).month(.wide).day()),
                isInDisplayedMonth: calendar.isDate(day, equalTo: monthStart, toGranularity: .month),
                isToday: calendar.isDateInToday(day),
                isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                noteCount: dayMeetings.count,
                eventCount: dayEvents.count,
                openLoopCount: openLoopCount
            )
        }

        let agendaDays = days.map { day in
            MeetingCalendarAgendaDay(
                date: day.date,
                dayNumberLabel: "\(day.dayNumber)",
                weekdayLabel: day.weekdayLabel,
                titleLabel: day.agendaTitleLabel,
                isToday: day.isToday,
                meetings: (meetingsByDay[day.date] ?? []).sorted(by: Self.sortMeetingsByTime),
                events: (eventsByDay[day.date] ?? []).sorted { $0.startDate < $1.startDate },
                openLoopCount: day.openLoopCount
            )
        }

        if let selectedWeek = calendar.dateInterval(of: .weekOfYear, for: selectedDay) {
            selectedWeekDays = days.filter { selectedWeek.contains($0.date) }
            selectedWeekAgendaDays = agendaDays.filter { selectedWeek.contains($0.date) }
        } else {
            selectedWeekDays = Array(days.prefix(7))
            selectedWeekAgendaDays = Array(agendaDays.prefix(7))
        }

        if let monthInterval {
            monthAgendaDays = agendaDays.filter { day in
                monthInterval.contains(day.date) && day.hasAnyActivity
            }
        }
    }

    func linkedMeeting(for event: CalendarEventSnapshot) -> Meeting? {
        linkedMeetingsByEventID[event.id]
            ?? linkedMeetingsByFingerprint[Self.eventFingerprint(title: event.title, startDate: event.startDate)]
    }

    private static func eventFingerprint(title: String, startDate: Date) -> String {
        let normalizedTitle = title
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let minute = Int(startDate.timeIntervalSince1970 / 60)
        return "\(normalizedTitle)|\(minute)"
    }

    private static func sortMeetingsByTime(_ lhs: Meeting, _ rhs: Meeting) -> Bool {
        let lhsDate = lhs.calendarStartDate ?? lhs.when
        let rhsDate = rhs.calendarStartDate ?? rhs.when
        if lhsDate == rhsDate { return Meeting.sortDescending(lhs, rhs) }
        return lhsDate < rhsDate
    }

    private static func startOfMonth(for date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps).map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: date)
    }

    private static func visibleDateRange(for month: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let start = startOfMonth(for: month, calendar: calendar)
        let firstWeekday = calendar.component(.weekday, from: start)
        let leadingDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: start) ?? start
        let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart) ?? start
        return (gridStart, gridEnd)
    }
}

private struct MeetingCalendarDay: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let dayNumber: Int
    let weekdayLabel: String
    let agendaTitleLabel: String
    let accessibilityDateLabel: String
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let noteCount: Int
    let eventCount: Int
    let openLoopCount: Int

    var hasOpenActions: Bool { openLoopCount > 0 }

    var hasAnyActivity: Bool {
        noteCount > 0 || eventCount > 0 || hasOpenActions
    }
}

private struct MeetingCalendarAgendaDay: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let dayNumberLabel: String
    let weekdayLabel: String
    let titleLabel: String
    let isToday: Bool
    let meetings: [Meeting]
    let events: [CalendarEventSnapshot]
    let openLoopCount: Int

    var noteCount: Int { meetings.count }
    var eventCount: Int { events.count }
    var hasAnyActivity: Bool { noteCount > 0 || eventCount > 0 || openLoopCount > 0 }
}

private struct MeetingCalendarDayDetailView: View {
    let day: MeetingCalendarAgendaDay
    let filter: CalendarContentFilter
    let linkedMeeting: (CalendarEventSnapshot) -> Meeting?
    let onPrep: (CalendarEventSnapshot) -> Void
    let onCapture: (CalendarEventSnapshot) -> Void
    let onCreateNote: () -> Void

    private var meetings: [Meeting] { filter.visibleMeetings(from: day.meetings) }
    private var events: [CalendarEventSnapshot] { filter.visibleEvents(from: day.events) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                    Spacer(minLength: 8)
                    EditorialMeta(text: summary)
                }

                if meetings.isEmpty && events.isEmpty {
                    EmptyStateCard(
                        title: "No matching items",
                        subtitle: "Choose another calendar filter to see more on this day.",
                        systemImage: filter.systemImage,
                        tint: AppPalette.accent
                    )
                } else {
                    if !meetings.isEmpty {
                        EditorialSectionHead(title: filter == .openLoops ? "Open-loop notes" : "Scribeflow notes", titleSize: 20)
                        ForEach(meetings) { meeting in
                            NavigationLink(value: meeting.id) {
                                MeetingCalendarMeetingRow(meeting: meeting)
                            }
                            .buttonStyle(PressScaleButtonStyle(scale: 0.98))
                        }
                    }

                    if !events.isEmpty {
                        EditorialSectionHead(title: "Calendar events", titleSize: 20)
                            .padding(.top, meetings.isEmpty ? 0 : 6)
                        ForEach(events) { event in
                            MeetingCalendarEventRow(
                                event: event,
                                linkedMeeting: linkedMeeting(event),
                                onPrep: onPrep,
                                onCapture: onCapture
                            )
                        }
                    }
                }

                Button {
                    HapticEngine.tap(.light)
                    onCreateNote()
                } label: {
                    Label("Add note on this day", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.ink)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
            .readingWidth()
        }
        .background(AppPalette.background.ignoresSafeArea())
        .navigationTitle("Day agenda")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summary: String {
        let total = meetings.count + events.count
        return total == 0 ? "clear" : "\(total) item\(total == 1 ? "" : "s")"
    }
}

private struct MeetingCalendarDayCell: View {
    let day: MeetingCalendarDay

    var body: some View {
        VStack(spacing: 5) {
            Text("\(day.dayNumber)")
                .font(.system(size: 15, weight: day.isSelected || day.isToday ? .bold : .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)

            HStack(spacing: 3) {
                if day.noteCount > 0 {
                    Circle()
                        .fill(AppPalette.accent)
                        .frame(width: 5, height: 5)
                }
                if day.eventCount > 0 {
                    Circle()
                        .fill(AppPalette.gold)
                        .frame(width: 5, height: 5)
                }
                if day.hasOpenActions {
                    Circle()
                        .fill(AppPalette.coral)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(border, lineWidth: day.isToday || day.isSelected ? 1.1 : 0.7)
        )
        .opacity(day.isInDisplayedMonth ? 1 : 0.42)
    }

    private var foreground: Color {
        if day.isSelected { return .white }
        if day.isToday { return AppPalette.accent }
        return AppPalette.ink
    }

    private var background: some ShapeStyle {
        if day.isSelected {
            return AnyShapeStyle(AppPalette.ink)
        }
        if day.isToday {
            return AnyShapeStyle(AppPalette.accent.opacity(0.12))
        }
        if day.noteCount > 0 || day.eventCount > 0 {
            return AnyShapeStyle(AppPalette.softSurface)
        }
        return AnyShapeStyle(Color.clear)
    }

    private var border: Color {
        if day.isSelected { return AppPalette.ink }
        if day.isToday { return AppPalette.accent.opacity(0.45) }
        return AppPalette.border.opacity(day.noteCount > 0 || day.eventCount > 0 ? 0.55 : 0.22)
    }
}

private struct MeetingCalendarAgendaDayRow: View {
    let day: MeetingCalendarAgendaDay
    let filter: CalendarContentFilter
    let isSelected: Bool

    private var visibleMeetings: [Meeting] {
        filter.visibleMeetings(from: day.meetings)
    }

    private var visibleEvents: [CalendarEventSnapshot] {
        filter.visibleEvents(from: day.events)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 3) {
                Text(day.dayNumberLabel)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isSelected ? .white : AppPalette.ink)
                Text(day.weekdayLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isSelected ? .white.opacity(0.72) : AppPalette.tertiaryInk)
            }
            .frame(width: 48, height: 54)
            .background(isSelected ? AppPalette.ink : AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(day.titleLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    if day.isToday {
                        EditorialMeta(text: "Today")
                    }
                }
                Text(primarySummary)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if !visibleMeetings.isEmpty {
                        countChip("\(visibleMeetings.count)", "Notes", tint: AppPalette.accent)
                    }
                    if !visibleEvents.isEmpty {
                        countChip("\(visibleEvents.count)", "Events", tint: AppPalette.gold)
                    }
                    if day.openLoopCount > 0 && filter != .events {
                        countChip("\(day.openLoopCount)", "Open", tint: AppPalette.coral)
                    }
                    if visibleMeetings.isEmpty && visibleEvents.isEmpty {
                        countChip("0", "Clear", tint: AppPalette.tertiaryInk)
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.tertiaryInk)
        }
        .padding(12)
        .background(AppPalette.cardBackground.opacity(isSelected ? 1 : 0.72), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(isSelected ? AppPalette.accent.opacity(0.45) : AppPalette.border.opacity(0.45), lineWidth: 0.8)
        )
    }

    private var primarySummary: String {
        if let meeting = visibleMeetings.first {
            return meeting.title
        }
        if let event = visibleEvents.first {
            return event.title
        }
        return "No matching items"
    }

    private func countChip(_ value: String, _ label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.caption2.weight(.heavy))
            Text(label)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
    }
}

private struct MeetingCalendarMeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(AppPalette.accent.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: meeting.status == .live ? "waveform.badge.mic" : "doc.text.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppPalette.accent)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meetingTime)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                    Text(meeting.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                }

                Text(meeting.workspace)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.secondaryInk)

                HStack(spacing: 6) {
                    if meeting.isPinned {
                        chip("Pinned", icon: "pin.fill", tint: AppPalette.gold)
                    }
                    let open = meetingOpenLoopCount(meeting)
                    if open > 0 {
                        chip("\(open) open", icon: "checklist", tint: AppPalette.coral)
                    }
                    if meeting.calendarEventID != nil {
                        chip("Linked", icon: "calendar", tint: AppPalette.accent)
                    }
                }
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.tertiaryInk)
                .padding(.top, 3)
        }
        .padding(14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.8)
        )
    }

    private var meetingTime: String {
        (meeting.calendarStartDate ?? meeting.when).formatted(.dateTime.hour().minute())
    }

    private func chip(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.10), in: Capsule())
    }
}

private struct MeetingCalendarEventRow: View {
    let event: CalendarEventSnapshot
    let linkedMeeting: Meeting?
    let onPrep: (CalendarEventSnapshot) -> Void
    let onCapture: (CalendarEventSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(AppPalette.gold.opacity(0.14))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: event.isVideoCall ? "video.fill" : "calendar")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppPalette.gold)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(eventTime)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.gold)
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                    Text(eventSubtitle)
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let linkedMeeting {
                    NavigationLink(value: linkedMeeting.id) {
                        Label("Open note", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.ink)
                } else {
                    Button {
                        onPrep(event)
                    } label: {
                        Label("Prep", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.ink)
                }

                Button {
                    onCapture(event)
                } label: {
                    Label("Record", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.accent)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(AppPalette.gold.opacity(0.24), lineWidth: 0.8)
        )
    }

    private var eventTime: String {
        "\(event.startDate.formatted(.dateTime.hour().minute()))-\(event.endDate.formatted(.dateTime.hour().minute()))"
    }

    private var eventSubtitle: String {
        let cleanedLocation = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let location: String
        if event.isVideoCall {
            location = "Video call"
        } else if let cleanedLocation, !cleanedLocation.isEmpty {
            location = cleanedLocation
        } else {
            location = "Calendar event"
        }
        if event.attendees.isEmpty { return location }
        return "\(location) · \(event.attendees.prefix(2).joined(separator: ", "))"
    }
}

private struct MeetingCalendarAccessCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let actionTitle: String
    let isLoading: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                HapticEngine.tap(.light)
                action()
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(actionTitle)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(tint, in: Capsule())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.95))
            .disabled(isLoading)
        }
        .padding(14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.8)
        )
    }
}
