import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct TodayView: View {
    @Environment(MeetingStore.self) private var store
    @Binding var selectedMeetingID: Meeting.ID?
    /// Open the unified capture surface in either `.record` or `.type` mode.
    let onCapture: (CaptureView.Mode) -> Void
    let onSettingsTap: () -> Void
    let onAskTap: () -> Void
    let onTasksTap: () -> Void
    @Binding var toast: ToastItem?
    @State private var hasAnimatedIn = false
    @State private var snap = TodaySnapshot()
    @State private var showingMicDiagnostics = false
    @State private var showingAudioImporter = false
    @State private var showingPalette = false
    @State private var snapshotBuilder = TodaySnapshotBuilder()
    @State private var upcomingEvents: [UpcomingEvent] = []
    @State private var calendarAccessRequested = false
    @State private var imminentEvent: UpcomingEvent?
    @State private var showingHowItWorks = false
    @State private var autoRecordWatchTimer: Timer?
    @State private var dismissedEventIDs: Set<String> = []
    @AppStorage("homeHeroStyle") private var heroStyleRaw = HeroStyle.briefing.rawValue
    @AppStorage("scribeflow.currentUserEmail") private var currentUserEmail = ""

    private var heroStyle: HeroStyle { HeroStyle(rawValue: heroStyleRaw) ?? .briefing }

    @State private var heroModelCache = HeroModel(today: 0, open: 0, streak: 0, attendees: [])

    /// Cached snapshot of the hero data. Body renders read this @State so we
    /// don't iterate `store.meetings` on every redraw — only when meetings,
    /// upcoming events, or the snapshot change (see `rebuildHeroModel`).
    private var heroModel: HeroModel { heroModelCache }

    private func rebuildHeroModel() {
        heroModelCache = computeHeroModel()
    }

    /// Builds the data the hero variants render from the snapshot + calendar.
    private func computeHeroModel() -> HeroModel {
        var nextTitle: String?
        var nextMeta: String?
        var attendees: [String] = []
        if let ev = upcomingEvents.first {
            nextTitle = ev.title
            let mins = Int(ev.startDate.timeIntervalSinceNow / 60)
            let countdown = mins <= 0 ? "now" : (mins < 60 ? "in \(mins) min" : "in \(mins / 60)h")
            nextMeta = "\(countdown) · \(ev.isVideoCall ? "Video call" : (ev.location ?? "In person"))"
        } else if let move = snap.nextMove {
            nextTitle = move.title
            nextMeta = move.subtitle
            if let mid = move.meetingID, let m = store.meeting(withID: mid) { attendees = m.attendees }
        }
        if attendees.isEmpty { attendees = snap.recentHomeMeetings.first?.attendees ?? [] }

        // This week vs last week capture totals (rolling 7-day windows).
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: .now)
        var week = 0, lastWeek = 0
        for m in store.meetings {
            let day = cal.startOfDay(for: m.when)
            guard let diff = cal.dateComponents([.day], from: day, to: startToday).day else { continue }
            if diff >= 0, diff < 7 { week += 1 }
            else if diff >= 7, diff < 14 { lastWeek += 1 }
        }

        return HeroModel(
            today: snap.todayCaptureCount,
            open: snap.totalOpenLoopsCount,
            streak: snap.longestStreakDays,
            nextTitle: nextTitle,
            nextMeta: nextMeta,
            attendees: attendees,
            weekTotal: week,
            lastWeekTotal: lastWeek
        )
    }

    private func heroPrep() {
        if let ev = upcomingEvents.first { prepareNote(for: ev) } else { onCapture(.type) }
    }

    @ViewBuilder
    private var heroView: some View {
        switch heroStyle {
        case .briefing:
            cinematicBriefing
        case .spotlight:
            HeroSpotlight(
                model: heroModel,
                onRecord: { onCapture(.record) },
                onType: { onCapture(.type) },
                onImport: { showingAudioImporter = true },
                onPrep: heroPrep,
                onCapture: { onCapture(.record) }
            )
        case .masthead:
            HeroMasthead(
                model: heroModel,
                onRecord: { onCapture(.record) },
                onType: { onCapture(.type) },
                onImport: { showingAudioImporter = true },
                onCapture: { onCapture(.record) }
            )
        case .focus:
            HeroFocus(
                model: heroModel,
                onRecord: { onCapture(.record) },
                onType: { onCapture(.type) },
                onImport: { showingAudioImporter = true },
                onCapture: { onCapture(.record) }
            )
        }
    }

    /// Today is a briefing. One hero card (status, value-prop, primary CTA)
    /// plus one standalone insight card directly under it ("what's relevant
    /// right now"). Two surfaces. No noise.
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                Color.clear.frame(height: 0).id("top")
                if let imminent = imminentEvent {
                    imminentMeetingBanner(imminent)
                        .motionEntrance(step: 0, active: hasAnimatedIn)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                heroView
                    .id(heroStyle)
                    .motionEntrance(step: 0, active: hasAnimatedIn)
                    .animation(AppMotion.smooth, value: heroStyle)

                if let event = upcomingEvents.first {
                    EditorialUpNext(
                        event: event,
                        onPrep: { prepareNote(for: event) },
                        onCapture: { captureForEvent(event) }
                    )
                    .motionEntrance(step: 2, active: hasAnimatedIn)
                } else if let move = snap.nextMove, heroStyle != .briefing {
                    // The briefing hero already surfaces the top move, so this
                    // nudge only shows for the other hero styles.
                    VStack(alignment: .leading, spacing: 12) {
                        EditorialSectionHead(title: "Up next")
                        NextMoveCard(
                            move: move,
                            onCapture: { onCapture(.record) },
                            onTasks: onTasksTap
                        )
                    }
                    .motionEntrance(step: 2, active: hasAnimatedIn)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // The cinematic briefing hero already carries the ranked plan;
                // only show the standalone card for the other hero styles.
                if heroStyle != .briefing {
                    dailyPlanCard
                        .motionEntrance(step: 2, active: hasAnimatedIn)
                }

                if upcomingEvents.count > 1 {
                    HomeAgendaSection(events: Array(upcomingEvents.dropFirst()),
                                      onPrep: prepareNote(for:),
                                      onCapture: captureForEvent(_:))
                        .motionEntrance(step: 3, active: hasAnimatedIn)
                }

                if !pinnedMeetings.isEmpty {
                    HomePinnedSection(meetings: pinnedMeetings, onSeeAll: onTasksTap)
                        .motionEntrance(step: 3, active: hasAnimatedIn)
                }

                if !snap.openLoops.isEmpty {
                    EditorialInbox(
                        loops: snap.openLoops,
                        total: snap.totalOpenLoopsCount,
                        onResolve: resolveOpenLoop(meetingID:),
                        onSeeAll: onTasksTap
                    )
                    .motionEntrance(step: 4, active: hasAnimatedIn)
                }

                if !snap.recentHomeMeetings.isEmpty {
                    EditorialRecent(meetings: snap.recentHomeMeetings, onSeeAll: onTasksTap)
                        .motionEntrance(step: 5, active: hasAnimatedIn)
                }

                if isHomeEffectivelyEmpty {
                    HomeEmptyHint(
                        onRecord: { onCapture(.record) },
                        onType:   { onCapture(.type) }
                    )
                    .motionEntrance(step: 6, active: hasAnimatedIn)
                }
            }
            .sheet(isPresented: $showingMicDiagnostics) {
                AudioDiagnosticsView().presentationDragIndicator(.visible)
            }
            .fileImporter(
                isPresented: $showingAudioImporter,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                allowsMultipleSelection: false
            ) { result in
                handleAudioImport(result)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .readingWidth()
        }
        .refreshable {
            HapticEngine.tap(.light)
            await refreshSnapshot(from: store.meetings)
            await refreshUpcoming()
            toast = ToastItem(message: "Up to date", icon: "checkmark.circle.fill")
        }
        .background(AppPalette.background.ignoresSafeArea())
        .accessibilityIdentifier("home.view")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    HapticEngine.tap(.light)
                    showingHowItWorks = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body.weight(.medium))
                }
                .tint(AppPalette.accent)
                .accessibilityLabel("How it works")
                .accessibilityIdentifier("home.howItWorksButton")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    HapticEngine.tap(.light)
                    showingPalette = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                }
                .tint(AppPalette.secondaryInk)
                .accessibilityLabel("Quick actions")
                .accessibilityIdentifier("home.commandPalette")
                Button {
                    onSettingsTap()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.medium))
                }
                .tint(AppPalette.secondaryInk)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("home.settingsButton")
            }
        }
        .sheet(isPresented: $showingPalette) {
            CommandPaletteSheet(
                onRecord:  { onCapture(.record) },
                onType:    { onCapture(.type) },
                onImport:  { showingAudioImporter = true },
                onAsk:     { onAskTap() },
                onTasks:   { onTasksTap() },
                onSettings:{ onSettingsTap() },
                onMicTest: { showingMicDiagnostics = true },
                onOpenMeeting: { id in
                    NotificationCenter.default.post(name: .scribeflowOpenMeeting, object: id)
                }
            )
        }
        .sheet(isPresented: $showingHowItWorks) {
            HowItWorksSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .navigationDestination(for: Meeting.ID.self) { id in
            MeetingDetailView(meetingID: id)
        }
        .onAppear {
            hasAnimatedIn = true
        }
        .task(id: store.revision) {
            await refreshSnapshot(from: store.meetings)
        }
        .task {
            await refreshUpcoming()
            startAutoRecordWatch()
        }
        .onDisappear {
            autoRecordWatchTimer?.invalidate()
            autoRecordWatchTimer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeflowDockScrollToTop)) { note in
            // Re-tap of the Today dock tab → scroll to top.
            guard (note.object as? String) == "home" else { return }
            withAnimation(AppMotion.smooth) {
                proxy.scrollTo("top", anchor: .top)
            }
        }
        }
    }

    // MARK: - Today's Plan

    /// A single prioritized commitment surfaced in the Daily Plan, with its
    /// computed urgency weight (0 = highest) used for ranking and styling.
    private struct DailyPlanItem: Identifiable {
        let id: Commitment.ID
        let commitment: Commitment
        let meetingID: Meeting.ID
        let meetingTitle: String
        let meetingDate: Date
        let weight: Int
        let dueDate: Date?
    }

    /// Ranks open commitments across every meeting into the top three things
    /// worth doing now: overdue / at-risk first, then by real deadline, then
    /// the rest by recency. Fulfilled / superseded items are excluded.
    private var dailyPlan: [DailyPlanItem] {
        let now = Date()
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let inFiveDays = cal.date(byAdding: .day, value: 5, to: now) ?? now

        func classify(_ c: Commitment, capturedAt: Date) -> (weight: Int, due: Date?)? {
            let due = DueDateParser.date(from: c.dueHint, capturedAt: capturedAt)
            switch c.status {
            case .fulfilled, .superseded:
                return nil
            case .atRisk:
                return (0, due)
            case .open:
                if let due {
                    if due < now            { return (0, due) }   // overdue
                    if due <= tomorrow      { return (1, due) }   // today / tomorrow
                    if due <= inFiveDays    { return (2, due) }   // this week
                }
                return (3, due)
            }
        }

        return store.meetings
            .flatMap { meeting in
                meeting.commitments.compactMap { c -> DailyPlanItem? in
                    guard let cls = classify(c, capturedAt: meeting.when) else { return nil }
                    return DailyPlanItem(
                        id: c.id,
                        commitment: c,
                        meetingID: meeting.id,
                        meetingTitle: meeting.title,
                        meetingDate: meeting.when,
                        weight: cls.weight,
                        dueDate: cls.due
                    )
                }
            }
            .sorted { lhs, rhs in
                lhs.weight != rhs.weight ? lhs.weight < rhs.weight : lhs.meetingDate > rhs.meetingDate
            }
            .prefix(3)
            .map { $0 }
    }

    private static let planRelFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    // MARK: - Cinematic briefing hero

    private var briefDateLine: String {
        let now = Date.now
        let weekday = now.formatted(.dateTime.weekday(.wide))
        let monthDay = now.formatted(.dateTime.month(.wide).day())
        return "\(weekday.uppercased()) · \(monthDay)"
    }

    private var briefName: String? {
        guard !currentUserEmail.isEmpty else { return nil }
        let local = currentUserEmail.split(separator: "@").first.map(String.init) ?? ""
        let first = local.split(whereSeparator: { ".-_0123456789".contains($0) }).first.map(String.init) ?? local
        guard first.count >= 2 else { return nil }
        // Skip generic mailbox names so the greeting never reads "Hi, You."
        let generic: Set<String> = ["you", "test", "admin", "user", "demo", "me", "hello", "hi", "info", "mail", "contact", "team"]
        guard !generic.contains(first.lowercased()) else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst().lowercased()
    }

    private var briefGreeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let base: String
        switch hour {
        case 5..<12:  base = "Good morning"
        case 12..<17: base = "Good afternoon"
        case 17..<22: base = "Good evening"
        default:      base = "Working late"
        }
        if let name = briefName { return "\(base), \(name)." }
        return "\(base)."
    }

    private var followThroughPct: Int {
        let all = store.meetings.flatMap(\.commitments)
        guard !all.isEmpty else { return 0 }
        let done = all.filter { $0.status == .fulfilled || $0.status == .superseded }.count
        return Int((Double(done) / Double(all.count) * 100).rounded())
    }

    private var weekMeetingCount: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        return store.meetings.filter { $0.when >= weekAgo }.count
    }

    private var cinematicBriefing: some View {
        let plan = dailyPlan
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(AppPalette.accent).frame(width: 40, height: 3)
                    Text(briefDateLine)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .kerning(1.0)
                        .foregroundStyle(AppPalette.accent)
                    Text(briefGreeting)
                        .scaledFont(size: 34, weight: .semibold, design: .serif, relativeTo: .largeTitle)
                        .foregroundStyle(AppPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                CaptureMenuButton(size: 44, onRecord: { onCapture(.record) }, onType: { onCapture(.type) }, onImport: { showingAudioImporter = true })
            }
            .padding(.bottom, 20)

            if plan.isEmpty {
                briefClearState
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(plan.count)")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                    Text(plan.count == 1 ? "thing needs you" : "things need you")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.secondaryInk)
                    Spacer()
                    Text("TODAY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .kerning(1.2)
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                .padding(.bottom, 6)

                VStack(spacing: 0) {
                    ForEach(Array(plan.enumerated()), id: \.element.id) { index, item in
                        briefRow(item)
                        if item.id != plan.last?.id {
                            Rectangle().fill(AppPalette.border.opacity(0.5)).frame(height: 1)
                        }
                    }
                }
                .padding(.bottom, 14)
            }

            Rectangle().fill(AppPalette.border.opacity(0.7)).frame(height: 1)
            HStack(spacing: 8) {
                briefStat("\(weekMeetingCount)", weekMeetingCount == 1 ? "meeting" : "meetings")
                Circle().fill(AppPalette.tertiaryInk.opacity(0.5)).frame(width: 3, height: 3)
                briefStat("\(followThroughPct)%", "follow-through")
                if followThroughPct >= 60 {
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.success)
                }
                Spacer()
                Button { onTasksTap() } label: {
                    HStack(spacing: 4) {
                        Text("All tasks").font(.caption.weight(.semibold))
                        Image(systemName: "arrow.right").font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(AppPalette.accent)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.95))
            }
            .padding(.top, 12)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(briefingSurface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8)
        )
        .appShadow(AppShadow.card)
    }

    @ViewBuilder
    private var briefingSurface: some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
        ZStack {
            shape.fill(AppPalette.cardBackground)
            shape.fill(
                LinearGradient(
                    colors: [AppPalette.accent.opacity(0.12), .clear],
                    startPoint: .topLeading, endPoint: .center
                )
            )
            Circle()
                .fill(RadialGradient(colors: [AppPalette.accent.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 130))
                .frame(width: 250, height: 250)
                .offset(x: 110, y: -90)
                .blur(radius: 16)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }

    private func briefRow(_ item: DailyPlanItem) -> some View {
        NavigationLink(value: item.meetingID) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: planIcon(item))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(planTint(item))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.commitment.statement)
                        .font(.system(size: 16, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(planReason(item))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(planTint(item))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .padding(.top, 4)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorialRowStyle(inset: 6))
        .accessibilityLabel("\(planReason(item)). \(item.commitment.statement)")
    }

    private var briefClearState: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(AppPalette.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're all clear")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(AppPalette.ink)
                Text("Nothing urgent across your meetings. Capture something new or get ahead.")
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
    }

    private func briefStat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.caption.weight(.bold)).foregroundStyle(AppPalette.ink)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(AppPalette.secondaryInk)
        }
    }

    @ViewBuilder
    private var dailyPlanCard: some View {
        let items = dailyPlan
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                EditorialSectionHead(title: "Today's plan", titleSize: 22) {
                    EditorialMeta(text: "\(items.count) TO DO")
                }
                Text("Ranked across every meeting — most urgent first.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.secondaryInk)

                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        dailyPlanRow(index + 1, item)
                            .editorialReveal()
                        if item.id != items.last?.id { EditorialRule() }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    AppPalette.cardBackground,
                    in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                        .strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.8)
                )
                .appShadow(AppShadow.soft)
            }
        }
    }

    private func dailyPlanRow(_ number: Int, _ item: DailyPlanItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(planTint(item))
                .frame(width: 16, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: planIcon(item))
                        .font(.caption.weight(.bold))
                    Text(planReason(item))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.planRelFormatter.localizedString(for: item.meetingDate, relativeTo: .now))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                .foregroundStyle(planTint(item))

                Text(item.commitment.statement)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    NavigationLink(value: item.meetingID) {
                        planActLabel("Open", "arrow.up.right")
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.95))

                    Button {
                        HapticEngine.notify(.success)
                        withAnimation(AppMotion.snappy) {
                            store.updateCommitmentStatus(.fulfilled, commitmentID: item.commitment.id, for: item.meetingID)
                        }
                        toast = ToastItem(message: "One off the list", icon: "checkmark.circle.fill")
                    } label: {
                        planActLabel("Mark done", "checkmark")
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.95))
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Priority \(number). \(planReason(item)). \(item.commitment.statement)")
    }

    private func planActLabel(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(AppPalette.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(AppPalette.accentSoft, in: Capsule())
        .overlay(Capsule().strokeBorder(AppPalette.accent.opacity(0.2), lineWidth: 0.7))
    }

    private func planTint(_ item: DailyPlanItem) -> Color {
        switch item.weight {
        case 0:     return AppPalette.coral
        case 1, 2:  return AppPalette.gold
        default:    return AppPalette.accent
        }
    }

    private func isOverdue(_ item: DailyPlanItem) -> Bool {
        guard let due = item.dueDate else { return false }
        return due < Date()
    }

    private func planIcon(_ item: DailyPlanItem) -> String {
        if isOverdue(item) { return "clock.badge.exclamationmark.fill" }
        switch item.weight {
        case 0:     return "exclamationmark.triangle.fill"
        case 1, 2:  return "bolt.fill"
        default:    return "circle"
        }
    }

    private func planReason(_ item: DailyPlanItem) -> String {
        let title = item.meetingTitle.isEmpty ? "a meeting" : item.meetingTitle
        if item.commitment.status == .atRisk { return "At risk · \(title)" }
        if isOverdue(item) { return "Overdue · \(title)" }
        switch item.weight {
        case 1, 2:
            if let due = item.commitment.dueHint, !due.isEmpty {
                return "Due \(due) · \(title)"
            }
            return "Due soon · \(title)"
        default:
            return "Open · \(title)"
        }
    }

    private func refreshUpcoming() async {
        let service = UpcomingEventsService.shared
        if !calendarAccessRequested {
            calendarAccessRequested = true
            _ = await service.requestAccessIfNeeded()
        }
        let events = service.fetchUpcoming()
        await MainActor.run {
            upcomingEvents = events
            refreshImminent()
            rebuildHeroModel()
        }
    }

    /// Foreground watcher: every 30 seconds re-check whether a calendar event
    /// is starting within the next 90 seconds. If so, surface a banner asking
    /// the user to record. Background auto-record is intentionally not used
    /// because iOS will not let an app silently start recording the mic.
    private func startAutoRecordWatch() {
        autoRecordWatchTimer?.invalidate()
        autoRecordWatchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                let service = UpcomingEventsService.shared
                upcomingEvents = service.fetchUpcoming()
                refreshImminent()
            }
        }
    }

    /// Human-readable countdown for the imminent meeting banner.
    private func countdownLabel(until date: Date, now: Date) -> String {
        let diff = Int(date.timeIntervalSince(now))
        if diff <= 0 { return "· LIVE NOW" }
        let minutes = diff / 60
        let seconds = diff % 60
        if minutes < 1 { return String(format: "· IN %ds", seconds) }
        if minutes < 60 { return String(format: "· IN %d:%02d", minutes, seconds) }
        let hours = minutes / 60
        return String(format: "· IN %dh %dm", hours, minutes % 60)
    }

    private func refreshImminent() {
        let now = Date.now
        let candidate = upcomingEvents.first { event in
            !dismissedEventIDs.contains(event.id) &&
            event.startDate.timeIntervalSince(now) <= 120 &&
            event.startDate.timeIntervalSince(now) >= -300
        }
        if imminentEvent?.id != candidate?.id {
            withAnimation(AppMotion.smooth) {
                imminentEvent = candidate
            }
        }
    }

    private func imminentMeetingBanner(_ event: UpcomingEvent) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(AppPalette.coral).frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    BreathingDot(tint: AppPalette.coral, size: 6)
                    Text("STARTING")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .kerning(0.9)
                        .foregroundStyle(AppPalette.coral)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(countdownLabel(until: event.startDate, now: context.date))
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .kerning(0.9)
                            .foregroundStyle(AppPalette.coral)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 4)
                    Button {
                        HapticEngine.tap(.light)
                        dismissedEventIDs.insert(event.id)
                        refreshImminent()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppPalette.tertiaryInk)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                Text(event.title)
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    HapticEngine.notify(.success)
                    UpcomingCaptureContext.shared.preferredTitle = event.title
                    dismissedEventIDs.insert(event.id)
                    AnalyticsLog.shared.log("calendar.autoRecord.armed", ["title": event.title])
                    onCapture(.record)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill").font(.caption.weight(.semibold))
                        Text("Start recording").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(AppPalette.coral, in: Capsule())
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.96))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppPalette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(AppPalette.border, lineWidth: 1)
        )
        .shadow(color: AppPalette.coral.opacity(0.18), radius: 10, y: 4)
    }

    // MARK: - Home v2 (premium rebuild)
    //
    // Goals: one focal point per section, no duplicate CTAs, calm hierarchy.
    // Sections appear in this order — each hides cleanly when empty:
    //   1. homeHero        — greeting + day-aware headline + primary CTA + 2 micro-stats
    //   2. homeQuickActions — 5 circular icon-only tiles (Record / Note / Voice / Import / Ask)
    //   3. homeTodaySchedule — up to 3 calendar events; "Prep / Capture" inline
    //   4. homeRecentNotes  — horizontal carousel of recent meeting cards
    //   5. homeActionInbox  — top 3 open follow-ups, single-tap done
    //   6. homeEmptyHint    — gentle onboarding card when there's literally nothing else

    private var isHomeEffectivelyEmpty: Bool {
        upcomingEvents.isEmpty
            && snap.recentHomeMeetings.isEmpty
            && snap.openLoops.isEmpty
            && pinnedMeetings.isEmpty
    }

    /// Top pinned meetings surfaced on Today. Driven by `Meeting.isPinned`,
    /// which is also what Library's pin/unpin toggles — so pinning anywhere
    /// surfaces it here.
    private var pinnedMeetings: [Meeting] {
        Array(store.meetings.filter(\.isPinned).sorted(by: Meeting.sortDescending).prefix(5))
    }

    private func prepareNote(for event: UpcomingEvent) {
        let attendeesHint: [String] = ["You"]
        let id = store.addMeeting(
            title: event.title,
            workspace: event.isVideoCall ? "Calls" : "Meetings",
            attendees: attendeesHint,
            objective: event.location ?? "Prepared from calendar",
            notes: "- Agenda:\n- Decisions:\n- Risks:\n- Next steps:",
            durationMinutes: max(15, Int(event.endDate.timeIntervalSince(event.startDate) / 60)),
            audioRecordings: []
        )
        selectedMeetingID = id
        toast = ToastItem(message: "Your prep note's ready", icon: "checkmark.circle.fill")
        HapticEngine.notify(.success)
    }

    private func captureForEvent(_ event: UpcomingEvent) {
        UpcomingCaptureContext.shared.preferredTitle = event.title
        onCapture(.record)
    }


    private func resolveOpenLoop(meetingID: Meeting.ID) {
        store.resolveFirstOpenCommitment(in: meetingID)
        Task { await refreshSnapshot(from: store.meetings) }
        toast = ToastItem(message: "One off the list", icon: "checkmark.circle.fill")
    }

    // MARK: - Audio import

    private func handleAudioImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                if let meetingID = await importAudioFile(from: url) {
                    await MainActor.run {
                        selectedMeetingID = meetingID
                        toast = ToastItem(message: "Audio's in", icon: "checkmark.circle.fill")
                        HapticEngine.notify(.success)
                    }
                } else {
                    await MainActor.run {
                        toast = ToastItem(message: "Couldn't bring that audio in", icon: "exclamationmark.triangle.fill")
                        HapticEngine.notify(.error)
                    }
                }
            }
        case .failure:
            toast = ToastItem(message: "Couldn't bring that audio in", icon: "exclamationmark.triangle.fill")
        }
    }

    @MainActor
    private func importAudioFile(from url: URL) async -> Meeting.ID? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        do {
            try RecordingFileStore.ensureDirectory()
            let recordingID = UUID()
            let destination = try RecordingFileStore.makeRecordingURL(id: recordingID)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            RecordingFileStore.protectFile(at: destination)

            let fileName = RecordingFileStore.fileName(for: destination)
            let fileSize = RecordingFileStore.fileSize(at: destination)
            let durationSeconds = await asyncAudioDurationSeconds(for: destination)

            let originalName = url.deletingPathExtension().lastPathComponent
            let cleanedTitle = originalName.replacingOccurrences(of: "_", with: " ").capitalized
            let title = cleanedTitle.isEmpty ? "Imported audio" : cleanedTitle

            let attachment = AudioRecordingAttachment(
                id: recordingID,
                title: title,
                createdAt: .now,
                durationSeconds: Int(durationSeconds.rounded()),
                fileName: fileName,
                transcript: "",
                linkedNote: "",
                source: .noteAttachment,
                fileSizeBytes: fileSize
            )

            let meetingID = store.addMeeting(
                title: title,
                workspace: "Imports",
                attendees: ["You"],
                objective: "Imported audio file",
                notes: "- Imported audio file: \(fileName)",
                durationMinutes: max(1, Int(durationSeconds / 60)),
                audioRecordings: [attachment]
            )
            return meetingID
        } catch {
            AnalyticsLog.shared.log("audioImport.failed", ["error": error.localizedDescription])
            return nil
        }
    }

    private func asyncAudioDurationSeconds(for url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : 0
        } catch {
            return 0
        }
    }


    private func refreshSnapshot(from meetings: [Meeting]) async {
        let nextSnapshot = await snapshotBuilder.make(from: meetings)
        guard !Task.isCancelled else { return }
        snap = nextSnapshot
        rebuildHeroModel()
    }
}

// MARK: - Snapshot

private actor TodaySnapshotBuilder {
    func make(from meetings: [Meeting]) -> TodaySnapshot {
        TodaySnapshot(meetings: meetings)
    }
}

struct TodaySnapshot {
    var recentHomeMeetings: [Meeting] = []
    var dashboardCollections: [SmartCollectionCard] = []
    var openLoops: [OpenLoop] = []
    var totalOpenLoopsCount = 0
    var nextMove: NextMove? = nil
    var continueMeeting: Meeting? = nil
    var trailingMeetings: [Meeting] = []
    var todayCaptureCount = 0
    var weekCaptureCount = 0
    var totalCount = 0
    var longestStreakDays = 0
    var avgDurationMinutes = 0

    init() {}

    init(meetings: [Meeting]) {
        let recentMeetings = meetings.sorted(by: Meeting.sortDescending)
        let recent = Array(recentMeetings.prefix(5))
        let allOpenLoops = Self.openLoops(from: recentMeetings)
        recentHomeMeetings = recent
        dashboardCollections = Self.smartCollections(from: recentMeetings)
        openLoops = Array(allOpenLoops.prefix(100))
        totalOpenLoopsCount = allOpenLoops.count
        continueMeeting = recent.first
        trailingMeetings = Array(recent.dropFirst())
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let startOfWeek = Calendar.current.date(byAdding: .day, value: -6, to: startOfDay) ?? startOfDay
        todayCaptureCount = meetings.filter { $0.when >= startOfDay }.count
        weekCaptureCount = meetings.filter { $0.when >= startOfWeek }.count
        totalCount = meetings.count
        longestStreakDays = Self.streakDays(in: meetings)
        let nonZeroDurations = meetings.map(\.durationMinutes).filter { $0 > 0 }
        avgDurationMinutes = nonZeroDurations.isEmpty ? 0 : nonZeroDurations.reduce(0, +) / nonZeroDurations.count
        nextMove = Self.nextMove(
            from: recentMeetings,
            openLoops: allOpenLoops,
            todayCount: todayCaptureCount,
            streak: longestStreakDays
        )
    }

    /// Surfaces the single most useful next action across the workspace, or
    /// `nil` when nothing genuinely needs the user. Strict priority order —
    /// the first matching signal wins so the card never competes with itself.
    private static func nextMove(
        from meetings: [Meeting],
        openLoops: [OpenLoop],
        todayCount: Int,
        streak: Int
    ) -> NextMove? {
        guard !meetings.isEmpty else { return nil }
        let active = meetings.filter { $0.status != .shared }

        // 1. An at-risk commitment is the most urgent thing on the board.
        if let meeting = active.first(where: { $0.commitments.contains { $0.status == .atRisk } }),
           let risk = meeting.commitments.first(where: { $0.status == .atRisk }) {
            return NextMove(
                kind: .resolveRisk,
                title: "An at-risk commitment needs you",
                subtitle: "\(truncated(risk.statement)) · \(meeting.title)",
                meetingID: meeting.id
            )
        }

        // 2. An open commitment whose timing reads as due today / overdue.
        for meeting in active {
            if let due = meeting.commitments.first(where: { $0.status == .open && isDueSoon($0.dueHint) }) {
                return NextMove(
                    kind: .dueCommitment,
                    title: "Due soon: \(truncated(due.statement))",
                    subtitle: due.dueHint.map { "\($0) · \(meeting.title)" } ?? meeting.title,
                    meetingID: meeting.id
                )
            }
        }

        // 3. A recent capture that still has no summary — finish the loop.
        if let meeting = meetings.first(where: {
            $0.summaries.isEmpty && (!$0.transcript.isEmpty || $0.rawNotes.count > 40)
        }) {
            return NextMove(
                kind: .summarize,
                title: "Summarize \(meeting.title.isEmpty ? "your last note" : meeting.title)",
                subtitle: "Notes captured — no summary yet",
                meetingID: meeting.id
            )
        }

        // 4. Follow-ups are piling up.
        if openLoops.count >= 3 {
            return NextMove(
                kind: .clearFollowUps,
                title: "\(openLoops.count) follow-ups are waiting",
                subtitle: "Clear them before they pile up",
                meetingID: nil
            )
        }

        // 5. Nothing captured today but a streak is running.
        if todayCount == 0 && streak >= 1 {
            return NextMove(
                kind: .keepStreak,
                title: streak == 1 ? "Capture to keep the habit" : "Keep your \(streak)-day streak alive",
                subtitle: "Nothing captured yet today",
                meetingID: nil
            )
        }

        return nil
    }

    private static func truncated(_ string: String, limit: Int = 60) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    private static func isDueSoon(_ hint: String?) -> Bool {
        guard let hint = hint?.lowercased() else { return false }
        let keys = ["today", "eod", "end of day", "overdue", "asap", "yesterday",
                    "this morning", "this afternoon", "by noon", "tonight", "right now"]
        return keys.contains { hint.contains($0) }
    }

    private static func streakDays(in meetings: [Meeting]) -> Int {
        guard !meetings.isEmpty else { return 0 }
        let calendar = Calendar.current
        let days = Set(meetings.map { calendar.startOfDay(for: $0.when) })
        var streak = 0
        var cursor = calendar.startOfDay(for: .now)
        while days.contains(cursor) {
            streak += 1
            guard let prior = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prior
        }
        return streak
    }


    private static func smartCollections(from meetings: [Meeting]) -> [SmartCollectionCard] {
        SmartCollectionKind.allCases.map { kind in
            SmartCollectionCard(kind: kind, count: Self.meetings(matching: kind, in: meetings).count)
        }
    }

    private static func meetings(matching kind: SmartCollectionKind, in meetings: [Meeting]) -> [Meeting] {
        switch kind {
        case .all:
            meetings
        case .followUp:
            meetings.filter { $0.status != .shared }
        case .calls:
            meetings.filter(\.isCallMeeting)
        case .pinned:
            meetings.filter(\.isPinned)
        case .shared:
            meetings.filter { $0.status == .shared }
        }
    }

    private static func openLoops(from meetings: [Meeting]) -> [OpenLoop] {
        meetings
            .filter { $0.status != .shared }
            .flatMap { meeting -> [OpenLoop] in
                let actionLoops = meeting.commitments
                    .filter { $0.status == .open || $0.status == .atRisk }
                    .prefix(2)
                    .map {
                        OpenLoop(
                            meetingID: meeting.id,
                            meetingTitle: meeting.title,
                            workspace: meeting.workspace,
                            kind: .action,
                            text: $0.formattedLine
                        )
                    }
                let riskLoops = riskLines(from: meeting).prefix(1).map {
                    OpenLoop(
                        meetingID: meeting.id,
                        meetingTitle: meeting.title,
                        workspace: meeting.workspace,
                        kind: .risk,
                        text: $0
                    )
                }
                return actionLoops + riskLoops
            }
    }

    private static func riskLines(from meeting: Meeting) -> [String] {
        let sources = [
            meeting.rawNotes,
            meeting.objective,
            meeting.summaries.flatMap { $0.summary.sections.flatMap(\.bullets) }.joined(separator: "\n"),
            meeting.transcript.prefix(12).map(\.text).joined(separator: "\n")
        ]

        var results: [String] = []
        for source in sources {
            for line in source.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let lower = trimmed.lowercased()
                if lower.contains("risk") || lower.contains("concern") || lower.contains("issue")
                    || lower.contains("blocker") || lower.contains("security") || lower.contains("timeline")
                    || lower.contains("budget") || lower.contains("delay") || lower.contains("problem") {
                    results.append(trimmed)
                    if results.count >= 4 { return results }
                }
            }
        }
        return results
    }

}

// MARK: - Next move

/// The single highest-value action Scribeflow suggests right now. Pure data —
/// presentation (tint, icon, routing) is derived in `NextMoveCard`.
struct NextMove: Hashable, Identifiable {
    enum Kind: Hashable {
        case resolveRisk
        case dueCommitment
        case summarize
        case clearFollowUps
        case keepStreak
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var subtitle: String
    /// Set when the move opens a specific meeting; `nil` routes to capture/tasks.
    var meetingID: Meeting.ID?

    var eyebrow: String { "NEXT MOVE" }

    var systemImage: String {
        switch kind {
        case .resolveRisk:    "exclamationmark.triangle.fill"
        case .dueCommitment:  "clock.badge.checkmark"
        case .summarize:      "sparkles"
        case .clearFollowUps: "checklist"
        case .keepStreak:     "flame.fill"
        }
    }

    var ctaLabel: String {
        switch kind {
        case .resolveRisk:    "Review risk"
        case .dueCommitment:  "Open note"
        case .summarize:      "Summarize"
        case .clearFollowUps: "Review tasks"
        case .keepStreak:     "Capture now"
        }
    }
}

/// Suggestion card directly under the hero. Tapping it does the move:
/// meeting-scoped moves push the detail via the NavigationStack; capture and
/// follow-up moves fire their callbacks.
struct NextMoveCard: View {
    let move: NextMove
    let onCapture: () -> Void
    let onTasks: () -> Void

    var body: some View {
        Group {
            if let id = move.meetingID {
                NavigationLink(value: id) { cardBody }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.98))
            } else {
                Button {
                    HapticEngine.tap(.medium)
                    if move.kind == .clearFollowUps { onTasks() } else { onCapture() }
                } label: { cardBody }
                .buttonStyle(PressScaleButtonStyle(scale: 0.98))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(move.title). \(move.ctaLabel).")
        .accessibilityIdentifier("home.nextMove")
    }

    private var tint: Color {
        switch move.kind {
        case .resolveRisk, .dueCommitment: AppPalette.coral
        case .summarize:                   AppPalette.accent
        case .clearFollowUps:              AppPalette.gold
        case .keepStreak:                  AppPalette.accentDeep
        }
    }

    private var cardBody: some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: move.systemImage, tint: tint, size: .medium)
            VStack(alignment: .leading, spacing: 4) {
                Text(move.eyebrow)
                    .font(.caption2.weight(.heavy))
                    .kerning(1.1)
                    .foregroundStyle(tint)
                Text(move.title)
                    .font(AppType.cardTitle())
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(move.subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(AppPalette.cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.10), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(tint.opacity(0.30), lineWidth: 1)
        )
        .appShadow(AppShadow.soft)
    }
}

// MARK: - Home sections (extracted)

/// Hero canvas — greeting eyebrow, day-aware headline, real-signal stats,
/// single accent-gradient primary CTA. Owns no state; parent passes the
/// snapshot and a record callback.
struct HomeRecentNotesSection: View {
    let meetings: [Meeting]
    @Environment(MeetingStore.self) private var store

    var body: some View {
        if meetings.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(eyebrow: "Lately", title: "Where you left off")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(meetings.prefix(6).enumerated()), id: \.element.id) { idx, meeting in
                            NavigationLink(value: meeting.id) {
                                card(meeting)
                            }
                            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                            .scrollTransition(.animated(AppMotion.smooth)) { content, phase in
                                content
                                    .opacity(phase.isIdentity ? 1 : 0.7)
                                    .scaleEffect(phase.isIdentity ? 1 : 0.95)
                                    .offset(y: phase.isIdentity ? 0 : 4)
                            }
                            .contextMenu {
                                Button(meeting.isPinned ? "Unpin" : "Pin",
                                       systemImage: meeting.isPinned ? AppSymbols.unpin : AppSymbols.pin) {
                                    store.togglePinned(for: meeting.id)
                                }
                                Button("Duplicate", systemImage: "doc.on.doc") {
                                    _ = store.duplicateMeeting(meeting.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func card(_ meeting: Meeting) -> some View {
        let hasAudio = !meeting.audioRecordings.isEmpty
        let tint = hasAudio ? AppPalette.accent : AppPalette.gold
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                IconBadge(
                    systemImage: hasAudio ? "waveform" : "doc.text.fill",
                    tint: tint,
                    size: .small
                )
                Spacer(minLength: 0)
                Text(Self.relativeTimeBadge(for: meeting.when))
                    .font(.caption2.weight(.heavy))
                    .kerning(0.6)
                    .foregroundStyle(AppPalette.tertiaryInk)
            }

            Spacer(minLength: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title.isEmpty ? "Untitled" : meeting.title)
                    .font(AppType.cardTitle())
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: "briefcase")
                        .font(.system(size: 9, weight: .heavy))
                    Text(meeting.workspace)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(AppPalette.secondaryInk)
            }
        }
        .padding(16)
        .frame(width: 220, alignment: .topLeading)
        .frame(minHeight: 160, alignment: .topLeading)
        // Flat warm paper — the icon badge carries the only color. No wash.
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(AppPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5)
        )
        .appShadow(AppShadow.hairline)
    }

    /// Cached — `RelativeDateTimeFormatter()` is costly to allocate, and this
    /// runs for every card in the recent-notes carousel each render.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func relativeTimeBadge(for date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now).uppercased()
    }
}

/// Top open follow-ups across the workspace, with single-tap resolve and
/// overflow to the Tasks tab.
struct HomeEmptyHint: View {
    var onRecord: () -> Void = {}
    var onType: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(AppPalette.accent).frame(width: 36, height: 3)

            VStack(alignment: .leading, spacing: 6) {
                EditorialEyebrow(text: "Start here", tint: AppPalette.accent)
                Text("Your first meeting,\ncaptured cleanly.")
                    .scaledFont(size: 26, weight: .medium, design: .serif, relativeTo: .title)
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                Text("Tap Record and talk. Scribeflow turns it into notes, decisions, and follow-ups on its own.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }

            HStack(spacing: 8) {
                Button {
                    HapticEngine.tap(.medium)
                    onRecord()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").font(.subheadline.weight(.semibold))
                        Text("Record meeting").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(AppPalette.accentButton, in: Capsule())
                    .shadow(color: AppPalette.accent.opacity(0.28), radius: 10, y: 4)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.96))

                Button {
                    HapticEngine.tap(.light)
                    onType()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil").font(.caption.weight(.semibold))
                        Text("Type a note").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AppPalette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(AppPalette.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(AppPalette.border, lineWidth: 1))
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.96))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous).fill(AppPalette.cardBackground)
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .fill(LinearGradient(colors: [AppPalette.accent.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .center))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.8)
        )
        .appShadow(AppShadow.card)
    }
}



// MARK: - HowItWorksSheet (cinematic single-canvas demo)

/// One continuous auto-playing demo showing the full lifecycle of a meeting
/// inside Scribeflow. Single anchored canvas — content morphs between five
/// stages (Capture → Processing → Review → Recall → Action) with a tight
/// caption and progress strip. No swipe pages, no tabs — feels like a
/// product launch video.
struct HowItWorksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Stage: Int, CaseIterable, Identifiable {
        case capture, processing, review, recall, action, done
        var id: Int { rawValue }

        var caption: String {
            switch self {
            case .capture:    return "Just press record."
            case .processing: return "Watch AI organize."
            case .review:     return "Read in seconds."
            case .recall:     return "Find any moment."
            case .action:     return "Synced everywhere."
            case .done:       return "Ready when you are."
            }
        }

        var duration: TimeInterval {
            switch self {
            case .capture:    return 6.0
            case .processing: return 3.8
            case .review:     return 5.5
            case .recall:     return 5.0
            case .action:     return 5.5
            case .done:       return .infinity
            }
        }

        var tint: Color {
            switch self {
            case .capture:    return AppPalette.accent
            case .processing: return AppPalette.accentDeep
            case .review:     return AppPalette.gold
            case .recall:     return AppPalette.success
            case .action:     return AppPalette.coral
            case .done:       return AppPalette.accent
            }
        }
    }

    @State private var stage: Stage = .capture
    @State private var stageProgress: CGFloat = 0
    @State private var ready = false
    @State private var advanceTask: Task<Void, Never>?
    @State private var totalProgress: CGFloat = 0
    @State private var recallQuery: String = ""
    @State private var recallReplayKey: Int = 0
    @State private var canvasPulse: Bool = false

    private static let runnableStages: [Stage] = [.capture, .processing, .review, .recall, .action]


    private var totalRuntime: TimeInterval {
        Self.runnableStages.map(\.duration).reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()
                // Deferred until the sheet finishes presenting — the blurred
                // backdrop + particle field are expensive to rasterize and
                // caused a hitch on open if drawn during the transition.
                if ready {
                    ambientBackdrop
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    progressTrack
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    meetingAnchor
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                    stageCanvas
                        .padding(.horizontal, 20)
                        .frame(maxHeight: .infinity)
                        .overlay {
                            // Tap zones: left third = back, right two-thirds = next.
                            // Stories-style navigation.
                            GeometryReader { geo in
                                HStack(spacing: 0) {
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            HapticEngine.tap(.light)
                                            stepBack()
                                        }
                                        .frame(width: geo.size.width / 3)
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            HapticEngine.tap(.light)
                                            stepForward()
                                        }
                                }
                            }
                            .accessibilityHidden(true)
                        }

                    captionBlock
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 14)

                    if stage == .done {
                        primaryControl
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                    } else {
                        tapHint
                            .padding(.bottom, 14)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        HapticEngine.tap(.light)
                        replay()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption.weight(.heavy))
                            Text("Replay")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(stage.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(stage.tint.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(stage.tint.opacity(0.22), lineWidth: 0.6))
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.90))
                    .accessibilityLabel("Replay demo")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        HapticEngine.tap(.light)
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(AppPalette.secondaryInk)
                }
            }
            .sensoryFeedback(.selection, trigger: stage)
            .task {
                guard !ready else { return }
                // Let the sheet present cleanly, then fade in ambient + start play.
                try? await Task.sleep(for: .milliseconds(340))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.45)) { ready = true }
                kickoff()
            }
            .onDisappear { advanceTask?.cancel() }
        }
    }

    private var ambientBackdrop: some View {
        ZStack {
            Circle()
                .fill(stage.tint.opacity(0.20))
                .frame(width: 420, height: 420)
                .blur(radius: 44)
                .offset(x: -110, y: -240)
            Circle()
                .fill(AppPalette.gold.opacity(0.10))
                .frame(width: 340, height: 340)
                .blur(radius: 44)
                .offset(x: 150, y: 240)
            Circle()
                .fill(stage.tint.opacity(0.08))
                .frame(width: 240, height: 240)
                .blur(radius: 34)
                .offset(x: 60, y: -40)

            AmbientParticleField(tint: stage.tint)
        }
        .drawingGroup()
        .animation(reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.9), value: stage)
        .allowsHitTesting(false)
    }


    /// Anchored meeting reference badge — persistent through every stage,
    /// communicates "this is the same meeting moving through each phase."
    private var meetingAnchor: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(stage.tint.opacity(0.18))
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(stage.tint.opacity(0.30), lineWidth: 0.7)
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(stage.tint)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Q4 Roadmap Review")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 8, weight: .heavy))
                    Text("Wed · 2:00 PM")
                        .font(.caption2.weight(.semibold))
                    Circle()
                        .fill(AppPalette.tertiaryInk.opacity(0.4))
                        .frame(width: 2, height: 2)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 8, weight: .heavy))
                    Text("4")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(AppPalette.secondaryInk)
            }
            Spacer(minLength: 0)
            stageBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .adaptiveMaterial(solid: AppPalette.softSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(stage.tint.opacity(0.25), lineWidth: 0.8))
        .appShadow(AppShadow.hairline)
    }

    private var stageBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stage.tint)
                .frame(width: 6, height: 6)
            Text(stageBadgeText)
                .font(.caption2.weight(.heavy))
                .kerning(1.0)
                .foregroundStyle(stage.tint)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(stage.tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(stage.tint.opacity(0.22), lineWidth: 0.6))
    }

    private var stageBadgeText: String {
        switch stage {
        case .done:       return "DONE"
        default:
            let idx = (Self.runnableStages.firstIndex(of: stage) ?? 0) + 1
            return "STEP \(idx) OF \(Self.runnableStages.count)"
        }
    }


    /// Anchored visual stage. Inner content crossfades + scales as the stage
    /// advances, while the framing card stays put.
    private var stageCanvas: some View {
        ZStack {
            stageView(.capture)    { CapturePreview() }
            stageView(.processing) { ProcessingPreview() }
            stageView(.review)     { ReviewPreview() }
            stageView(.recall)     { RecallPreview() }
            stageView(.action)     { ActionPreview() }
            stageView(.done)       { DonePreview() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                .fill(AppPalette.cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    stage.tint.opacity(0.08),
                                    .clear,
                                    stage.tint.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.6), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .blendMode(.plusLighter)
                        .opacity(0.4)
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                .strokeBorder(AppPalette.cardBackground.opacity(0.4), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                .strokeBorder(stage.tint.opacity(0.25), lineWidth: 0.7)
        )
        .appShadow(AppShadow.hero)
        .scaleEffect(canvasPulse ? 0.985 : 1)
        .animation(reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.55), value: stage)
        .onChange(of: stage) { _, _ in
            guard !reduceMotion else { return }
            canvasPulse = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                    canvasPulse = false
                }
            }
        }
    }

    @ViewBuilder
    private func stageView<Content: View>(_ s: Stage, @ViewBuilder _ make: () -> Content) -> some View {
        let isVisible = stage == s
        make()
            .padding(14)
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.96, anchor: .center)
            .allowsHitTesting(isVisible)
    }

    /// Single big caption per stage. Two or three words max.
    private var captionBlock: some View {
        VStack(spacing: 10) {
            actorChip
            Text(stage.caption)
                .scaledFont(size: 36, weight: .bold, design: .serif, relativeTo: .largeTitle)
                .foregroundStyle(AppPalette.ink)
                .contentTransition(.opacity)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .id(stage)
                .transition(.opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.94)))
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.45, dampingFraction: 0.82), value: stage)
    }

    private var actorChip: some View {
        HStack(spacing: 5) {
            Image(systemName: actorIcon)
                .font(.system(size: 9, weight: .heavy))
            Text(actorLabel)
                .font(.caption2.weight(.heavy))
                .kerning(1.2)
        }
        .foregroundStyle(stage.tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(stage.tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(stage.tint.opacity(0.22), lineWidth: 0.6))
        .contentTransition(.opacity)
    }

    private var actorIcon: String {
        switch stage {
        case .capture, .recall: return "person.fill"
        case .processing, .review, .action: return "sparkles"
        case .done: return "checkmark.seal.fill"
        }
    }

    private var actorLabel: String {
        switch stage {
        case .capture, .recall: return "YOU"
        case .processing, .review, .action: return "SCRIBEFLOW"
        case .done: return "READY"
        }
    }


    /// Multi-segment progress bar: one segment per runnable stage. Active
    /// segment fills over its dwell; completed segments stay fully filled.
    private var progressTrack: some View {
        HStack(spacing: 6) {
            ForEach(Self.runnableStages, id: \.rawValue) { s in
                segment(for: s)
            }
        }
        .frame(height: 5)
    }

    private func segment(for s: Stage) -> some View {
        let runIndex = Self.runnableStages.firstIndex(of: s) ?? 0
        let currentIndex = Self.runnableStages.firstIndex(of: stage) ?? Self.runnableStages.count
        let isCompleted = runIndex < currentIndex || stage == .done
        let isActive = stage == s
        return Button {
            HapticEngine.tap(.light)
            jumpToStage(s)
        } label: {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppPalette.divider.opacity(0.40))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [s.tint, s.tint.opacity(0.78)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: isCompleted ? geo.size.width : (isActive ? geo.size.width * stageProgress : 0))
                        .shadow(color: isActive ? s.tint.opacity(0.55) : .clear, radius: 6, y: 0)
                        .overlay(
                            Capsule()
                                .fill(.white.opacity(isActive ? 0.30 : 0))
                                .frame(width: 24)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .opacity(isActive ? 1 : 0)
                                .animation(
                                    isActive && !reduceMotion
                                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                        : .linear(duration: 0.01),
                                    value: isActive
                                )
                                .frame(width: isCompleted ? geo.size.width : (isActive ? geo.size.width * stageProgress : 0), alignment: .trailing)
                                .allowsHitTesting(false)
                        )
                }
            }
            .frame(height: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to step \(runIndex + 1)")
    }

    private func replay() {
        stageProgress = 0
        recallQuery = ""
        recallReplayKey += 1
        withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.45, dampingFraction: 0.85)) {
            stage = .capture
        }
        runStage(.capture)
    }

    private func stepBack() {
        if stage == .done {
            jumpToStage(.action)
            return
        }
        guard let idx = Self.runnableStages.firstIndex(of: stage), idx > 0 else { return }
        jumpToStage(Self.runnableStages[idx - 1])
    }

    private func stepForward() {
        if stage == .done { return }
        guard let idx = Self.runnableStages.firstIndex(of: stage) else { return }
        let nextIndex = idx + 1
        if nextIndex < Self.runnableStages.count {
            jumpToStage(Self.runnableStages[nextIndex])
        } else {
            jumpToStage(.done)
        }
    }

    /// Quiet first-time hint shown under the canvas while the user steps
    /// through. Fades once they've interacted past Capture.
    private var tapHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 11, weight: .heavy))
            Text("Tap to continue")
                .font(.caption.weight(.bold))
                .kerning(0.4)
        }
        .foregroundStyle(AppPalette.tertiaryInk)
        .opacity(stage == .capture ? 1 : 0.6)
        .animation(reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.4), value: stage)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var primaryControl: some View {
        if stage == .done {
            VStack(spacing: 10) {
                Button {
                    HapticEngine.notify(.success)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.subheadline.weight(.heavy))
                        Text("Get started")
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppPalette.accentButton, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.8))
                    .shadow(color: AppPalette.accent.opacity(0.34), radius: 16, y: 8)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))

                Button {
                    HapticEngine.tap(.light)
                    replay()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption.weight(.heavy))
                        Text("Watch again")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(AppPalette.secondaryInk)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                .accessibilityLabel("Replay demo")
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            Button {
                HapticEngine.tap(.light)
                jumpToStage(.done)
            } label: {
                HStack(spacing: 6) {
                    Text("Skip")
                        .font(.caption.weight(.bold))
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 10, weight: .heavy))
                }
                .foregroundStyle(AppPalette.secondaryInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppPalette.softSurface.opacity(0.85), in: Capsule())
                .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.6))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.92))
            .frame(maxWidth: .infinity)
        }
    }

    private func kickoff() {
        stage = .capture
        runStage(stage)
    }

    private func runStage(_ s: Stage) {
        advanceTask?.cancel()
        stageProgress = 0
        guard s != .done else { return }
        let duration = s.duration
        let anim: Animation = reduceMotion ? .linear(duration: 0.01) : .linear(duration: duration)
        withAnimation(anim) { stageProgress = 1 }
        advanceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            let next: Stage? = Stage(rawValue: s.rawValue + 1)
            if let next {
                withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.5, dampingFraction: 0.85)) {
                    stage = next
                }
                runStage(next)
            }
        }
    }

    private func jumpToStage(_ s: Stage) {
        advanceTask?.cancel()
        stageProgress = 0
        withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.45, dampingFraction: 0.85)) {
            stage = s
        }
        if s == .done {
            stageProgress = 1
        } else {
            runStage(s)
        }
    }
}

// MARK: - Processing / Done previews

/// Concrete before → after transformation. Shows the *exact* moment AI
/// turns raw speech into a structured action item. This is the wow stage —
/// user sees the actual phrase from the Capture transcript morph into a
/// clean task card with owner + due date. No abstraction.
private struct ProcessingPreview: View {
    @State private var showTranscript = false
    @State private var sweepX: CGFloat = -260
    @State private var showArrow = false
    @State private var showExtract = false
    @State private var extractScale: CGFloat = 0.85
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            transcriptCard
                .opacity(showTranscript ? 1 : 0)
                .offset(y: showTranscript ? 0 : -6)
                .overlay(alignment: .leading) {
                    if showTranscript && !reduceMotion {
                        // Sparkle sweep moving left → right across the
                        // transcript card. Visualizes AI "reading" the line.
                        LinearGradient(
                            colors: [.clear, AppPalette.accent.opacity(0.45), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 90)
                        .blur(radius: 8)
                        .offset(x: sweepX)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                        .mask(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                }

            arrowBridge
                .opacity(showArrow ? 1 : 0)
                .scaleEffect(showArrow ? 1 : 0.7)

            extractCard
                .opacity(showExtract ? 1 : 0)
                .scaleEffect(extractScale, anchor: .top)
                .offset(y: showExtract ? 0 : 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { runReveal() }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(AppPalette.secondaryInk)
                Text("WHAT WAS SAID")
                    .font(.caption2.weight(.heavy))
                    .kerning(1.2)
                    .foregroundStyle(AppPalette.secondaryInk)
            }
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle().fill(AppPalette.accent.opacity(0.18))
                    Text("A")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(AppPalette.accent)
                }
                .frame(width: 20, height: 20)
                Text("\"We should ship the analytics dashboard before the holidays.\"")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(AppPalette.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.softSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.45), lineWidth: 0.6)
        )
        .clipped()
    }

    private var arrowBridge: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ZStack {
                Capsule()
                    .fill(AppPalette.accent.opacity(0.12))
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .heavy))
                    Text("AI EXTRACTS")
                        .font(.caption2.weight(.heavy))
                        .kerning(1.3)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .heavy))
                }
                .foregroundStyle(AppPalette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    private var extractCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(AppPalette.success)
                Text("ACTION ITEM EXTRACTED")
                    .font(.caption2.weight(.heavy))
                    .kerning(1.2)
                    .foregroundStyle(AppPalette.success)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AppPalette.success)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ship analytics dashboard")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.ink)
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 9, weight: .heavy))
                            Text("Due Dec 15")
                                .font(.caption2.weight(.heavy))
                        }
                        .foregroundStyle(AppPalette.coral)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppPalette.coral.opacity(0.12), in: Capsule())

                        HStack(spacing: 4) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 9, weight: .heavy))
                            Text("Alex")
                                .font(.caption2.weight(.heavy))
                        }
                        .foregroundStyle(AppPalette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppPalette.accent.opacity(0.12), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppPalette.success.opacity(0.30), lineWidth: 0.9)
        )
        .appShadow(AppShadow.hairline)
    }

    private func runReveal() {
        let anim: Animation = reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.42, dampingFraction: 0.82)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(anim) { showTranscript = true }
            if !reduceMotion {
                // Sweep across the transcript card.
                try? await Task.sleep(for: .milliseconds(220))
                withAnimation(.easeInOut(duration: 0.9)) { sweepX = 280 }
            }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 700))
            withAnimation(anim) { showArrow = true }
            try? await Task.sleep(for: .milliseconds(240))
            withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.5, dampingFraction: 0.7)) {
                showExtract = true
                extractScale = 1.0
            }
        }
    }
}

/// Final card — recaps the four capabilities the user just watched in
/// action. Closes the loop emotionally before the Get Started CTA.
private struct DonePreview: View {
    @State private var visibleRows = 0
    @State private var confetti: [ConfettiBit] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rows: [(String, String, Color)] = [
        ("waveform.badge.mic", "Capture meetings", AppPalette.accent),
        ("sparkles", "Notes write themselves", AppPalette.gold),
        ("quote.bubble.fill", "Ask across every meeting", AppPalette.success),
        ("checkmark.seal.fill", "Action turns into follow-through", AppPalette.coral)
    ]

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(rows[i].2.opacity(0.14))
                            Image(systemName: rows[i].0)
                                .font(.footnote.weight(.heavy))
                                .foregroundStyle(rows[i].2)
                        }
                        .frame(width: 28, height: 28)
                        Text(rows[i].1)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.ink)
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(rows[i].2)
                    }
                    .padding(10)
                    .background(AppPalette.softSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(AppPalette.border.opacity(0.45), lineWidth: 0.6)
                    )
                    .opacity(i < visibleRows ? 1 : 0)
                    .offset(y: i < visibleRows ? 0 : 8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)

            // Confetti burst overlay
            ForEach(confetti) { bit in
                Image(systemName: "sparkle")
                    .font(.system(size: bit.size, weight: .heavy))
                    .foregroundStyle(bit.color)
                    .position(x: bit.x, y: bit.y)
                    .opacity(bit.opacity)
                    .rotationEffect(.degrees(bit.rotation))
                    .allowsHitTesting(false)
            }
        }
        .onAppear { runReveal() }
    }

    private func runReveal() {
        let anim: Animation = reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.4, dampingFraction: 0.78)
        Task { @MainActor in
            for i in 1...rows.count {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(anim) { visibleRows = i }
            }
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(200))
            launchConfetti()
        }
    }

    private func launchConfetti() {
        let palette: [Color] = [AppPalette.accent, AppPalette.gold, AppPalette.success, AppPalette.coral]
        for _ in 0..<24 {
            let bit = ConfettiBit(
                x: CGFloat.random(in: 60...260),
                y: CGFloat.random(in: 40...180),
                size: CGFloat.random(in: 10...18),
                color: palette.randomElement() ?? AppPalette.accent,
                opacity: 0,
                rotation: Double.random(in: 0...360)
            )
            confetti.append(bit)
        }
        for idx in confetti.indices {
            let delay = Double.random(in: 0...0.6)
            withAnimation(.easeOut(duration: 0.6).delay(delay)) {
                confetti[idx].opacity = 1
                confetti[idx].rotation += 90
            }
            withAnimation(.easeIn(duration: 0.8).delay(delay + 0.6)) {
                confetti[idx].opacity = 0
                confetti[idx].y += 60
            }
        }
    }
}

/// Slow-drifting sparkle particles behind the canvas. Decorative atmosphere
/// only — fills empty vertical space with subtle motion, keeps the sheet
/// feeling alive even when the active stage is mid-dwell.
private struct AmbientParticleField: View {
    let tint: Color
    @State private var particles: [Particle] = AmbientParticleField.seed()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Particle: Identifiable {
        let id = UUID()
        var x: CGFloat
        var startY: CGFloat
        var endY: CGFloat
        var size: CGFloat
        var minOpacity: Double
        var maxOpacity: Double
        var duration: Double
        var delay: Double
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles) { p in
                    ParticleDot(
                        particle: p,
                        boundsHeight: geo.size.height,
                        tint: tint,
                        animate: !reduceMotion
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .drawingGroup()
        }
        .allowsHitTesting(false)
    }

    private static func seed() -> [Particle] {
        (0..<14).map { _ in
            Particle(
                x: CGFloat.random(in: 0.06...0.94),
                startY: CGFloat.random(in: 0.55...1.0),
                endY: CGFloat.random(in: -0.05...0.30),
                size: CGFloat.random(in: 4...11),
                minOpacity: Double.random(in: 0.05...0.18),
                maxOpacity: Double.random(in: 0.30...0.55),
                duration: Double.random(in: 7...12),
                delay: Double.random(in: 0...4)
            )
        }
    }
}

private struct ParticleDot: View {
    let particle: AmbientParticleField.Particle
    let boundsHeight: CGFloat
    let tint: Color
    let animate: Bool

    @State private var driftPhase: CGFloat = 0
    @State private var opacityPhase: Double = 0

    var body: some View {
        GeometryReader { geo in
            let xPos = geo.size.width * particle.x
            let startYPos = boundsHeight * particle.startY
            let endYPos = boundsHeight * particle.endY
            let yPos = startYPos + (endYPos - startYPos) * driftPhase

            Image(systemName: "sparkle")
                .font(.system(size: particle.size, weight: .bold))
                .foregroundStyle(tint.opacity(particle.minOpacity + (particle.maxOpacity - particle.minOpacity) * opacityPhase))
                .position(x: xPos, y: yPos)
        }
        .onAppear {
            guard animate else {
                driftPhase = 0.5
                opacityPhase = 0.5
                return
            }
            withAnimation(
                .easeInOut(duration: particle.duration)
                    .repeatForever(autoreverses: false)
                    .delay(particle.delay)
            ) {
                driftPhase = 1
            }
            withAnimation(
                .easeInOut(duration: particle.duration * 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(particle.delay)
            ) {
                opacityPhase = 1
            }
        }
    }
}

private struct ConfettiBit: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var color: Color
    var opacity: Double
    var rotation: Double
}

/// Step 4 preview — meeting outputs landing in calendar, email, and tasks.
/// Three lightweight cards stagger in, each demonstrating one integration
/// surface the meeting has been routed into.
private struct ActionPreview: View {
    @State private var visibleRows = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Row {
        let icon: String
        let tint: Color
        let title: String
    }

    private let rows: [Row] = [
        Row(icon: "calendar.badge.clock", tint: AppPalette.coral, title: "Calendar"),
        Row(icon: "envelope.fill", tint: AppPalette.accent, title: "Email draft"),
        Row(icon: "checklist", tint: AppPalette.success, title: "Tasks"),
        Row(icon: "bubble.left.and.bubble.right.fill", tint: AppPalette.gold, title: "Slack"),
        Row(icon: "doc.fill.badge.plus", tint: AppPalette.accentDeep, title: "Notion")
    ]

    var body: some View {
        ZStack {
            Image(systemName: "arrow.up.right.circle.fill")
                .font(.system(size: 220, weight: .light))
                .foregroundStyle(AppPalette.coral.opacity(0.05))
                .rotationEffect(.degrees(12))
                .offset(x: -30, y: 20)
                .allowsHitTesting(false)

            VStack(spacing: 12) {
                ForEach(rows.indices, id: \.self) { i in
                    actionRow(rows[i])
                        .opacity(i < visibleRows ? 1 : 0)
                        .offset(y: i < visibleRows ? 0 : 14)
                        .scaleEffect(i < visibleRows ? 1 : 0.94, anchor: .top)
                    if i < rows.count - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { runReveal() }
        .accessibilityLabel("Calendar, email, tasks, Slack, and Notion all updated")
    }

    private func actionRow(_ row: Row) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(row.tint.opacity(0.16))
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(row.tint.opacity(0.28), lineWidth: 0.8)
                Image(systemName: row.icon)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(row.tint)
            }
            .frame(width: 42, height: 42)

            Text(row.title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)

            Spacer(minLength: 0)

            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(row.tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.7)
        )
        .appShadow(AppShadow.hairline)
    }

    private func actionRow(icon: String, tint: Color, title: String, subtitle: String, trailing: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 0.7)
                Image(systemName: icon)
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(trailing)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 0.6))
        }
        .padding(10)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.45), lineWidth: 0.6)
        )
    }

    private func runReveal() {
        let anim: Animation = reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.45, dampingFraction: 0.78)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            for i in 1...rows.count {
                withAnimation(anim) { visibleRows = i }
                try? await Task.sleep(for: .milliseconds(240))
            }
        }
    }
}

// MARK: - Visual previews (all SwiftUI primitives, no external assets)

/// Mini live-capture mockup: REC dot + mono timer + animated waveform bars +
/// "live transcript" placeholder lines. Shows the user what they'll see when
/// they tap Start Capture.
private struct CapturePreview: View {
    @State private var showHeader = false
    @State private var showBars = false
    @State private var showSpeakers = false
    @State private var visibleLines = 0
    @State private var elapsed = 0
    @State private var ticker: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barHeights: [CGFloat] = [10, 22, 14, 30, 18, 26, 12, 28, 16, 22, 10, 24, 14, 20, 12]

    private struct Line {
        let speaker: String
        let initial: String
        let text: String
        let tint: Color
    }

    private let lines: [Line] = [
        Line(speaker: "Alex",  initial: "A", text: "Ship the analytics dashboard before the holidays.", tint: AppPalette.accent),
        Line(speaker: "Maya",  initial: "M", text: "Vendor shortlist by Thursday.", tint: AppPalette.coral),
        Line(speaker: "Priya", initial: "P", text: "Two backend hires in January.", tint: AppPalette.gold),
        Line(speaker: "Sam",   initial: "S", text: "Revisit pricing tiers next quarter.", tint: AppPalette.success)
    ]

    var body: some View {
        ZStack {
            // Giant decorative motif behind the content — fills space without
            // adding text. Faint waveform-mic glyph in stage tint.
            Image(systemName: "waveform")
                .font(.system(size: 220, weight: .light))
                .foregroundStyle(AppPalette.accent.opacity(0.06))
                .rotationEffect(.degrees(-8))
                .offset(x: 40, y: 20)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                // Top: live indicator + timer.
                HStack(spacing: 8) {
                    Circle()
                        .fill(AppPalette.coral)
                        .frame(width: 10, height: 10)
                        .shadow(color: AppPalette.coral.opacity(0.5), radius: 3)
                        .opacity(showBars ? 1 : 0.4)
                    Spacer(minLength: 0)
                    Text(timerText)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppPalette.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .opacity(showHeader ? 1 : 0)
                .offset(y: showHeader ? 0 : 6)

                Spacer(minLength: 8)

                // Hero waveform — bigger, dominates the upper area.
                HStack(alignment: .center, spacing: 4) {
                    ForEach(barHeights.indices, id: \.self) { i in
                        Capsule()
                            .fill(AppPalette.accent.opacity(0.85))
                            .frame(width: 4, height: showBars
                                   ? barHeights[i] * 1.8
                                   : max(8, barHeights[i] * 0.6))
                            .animation(
                                reduceMotion
                                    ? .linear(duration: 0)
                                    : .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.05),
                                value: showBars
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .drawingGroup()
                .opacity(showBars ? 1 : 0)

                Spacer(minLength: 12)

                // Speaker chips — initials only, no label text.
                HStack(spacing: 6) {
                    ForEach(lines, id: \.speaker) { line in
                        Text(line.initial)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(line.tint)
                            .frame(width: 24, height: 24)
                            .background(line.tint.opacity(0.15), in: Circle())
                            .overlay(Circle().strokeBorder(line.tint.opacity(0.35), lineWidth: 0.8))
                    }
                    Spacer(minLength: 0)
                }
                .opacity(showSpeakers ? 1 : 0)
                .offset(y: showSpeakers ? 0 : 6)

                Spacer(minLength: 12)

                // Transcript cascade fills lower half.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines.indices, id: \.self) { i in
                        transcriptRow(lines[i])
                            .opacity(i < visibleLines ? 1 : 0)
                            .offset(x: i < visibleLines ? 0 : -10)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { runReveal() }
        .onDisappear { ticker?.cancel() }
        .accessibilityLabel("Recording Q4 Roadmap Review with live transcript")
    }

    private func transcriptRow(_ line: Line) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(line.tint.opacity(0.20))
                Circle().strokeBorder(line.tint.opacity(0.30), lineWidth: 0.7)
                Text(line.initial)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(line.tint)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.speaker)
                    .font(.caption2.weight(.heavy))
                    .kerning(0.4)
                    .foregroundStyle(line.tint)
                Text(line.text)
                    .font(.footnote)
                    .foregroundStyle(AppPalette.ink.opacity(0.88))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func transcriptLine(speaker: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(AppPalette.accent.opacity(0.18))
                Text(String(speaker.prefix(1)))
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(AppPalette.accent)
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(speaker)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(AppPalette.secondaryInk)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(AppPalette.ink.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var timerText: String {
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func runReveal() {
        let anim: Animation = reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.42, dampingFraction: 0.82)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(anim) { showHeader = true }
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(anim) { showBars = true }
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(anim) { showSpeakers = true }
            for i in 1...lines.count {
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(anim) { visibleLines = i }
            }
        }
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: 0.2)) {
                    elapsed = (elapsed + 1) % 600
                }
            }
        }
    }
}

/// Mini summary card mockup: header strip + 3 bullet placeholder lines + 1
/// action-item row with checkbox. Shows the post-meeting "Review" surface.
private struct ReviewPreview: View {
    @State private var showHeader = false
    @State private var visibleBullets = 0
    @State private var showAction = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bullets: [String] = [
        "Ship analytics dashboard before Dec 15",
        "Hire 2 backend engineers in Jan",
        "Revisit pricing tiers next quarter"
    ]

    var body: some View {
        ZStack {
            Image(systemName: "sparkles")
                .font(.system(size: 220, weight: .light))
                .foregroundStyle(AppPalette.gold.opacity(0.06))
                .offset(x: 30, y: 40)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .heavy))
                    Text("AI SUMMARY")
                        .font(.caption.weight(.heavy))
                        .kerning(1.4)
                }
                .foregroundStyle(AppPalette.gold)
                .opacity(showHeader ? 1 : 0)
                .offset(y: showHeader ? 0 : 4)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(bullets.indices, id: \.self) { i in
                        bulletRow(bullets[i])
                            .opacity(i < visibleBullets ? 1 : 0)
                            .offset(x: i < visibleBullets ? 0 : -10)
                    }
                }

                Spacer(minLength: 4)

                actionItemCard
                    .opacity(showAction ? 1 : 0)
                    .offset(y: showAction ? 0 : 10)
                    .scaleEffect(showAction ? 1 : 0.96, anchor: .leading)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { runReveal() }
        .accessibilityLabel("AI summary with three decisions and one action item")
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(AppPalette.gold)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppPalette.ink.opacity(0.88))
                .lineSpacing(2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var actionItemCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppPalette.success.opacity(0.16))
                Circle().strokeBorder(AppPalette.success.opacity(0.30), lineWidth: 0.7)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(AppPalette.success)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Maya · vendor shortlist")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9, weight: .heavy))
                    Text("Due Thursday")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(AppPalette.coral)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(AppPalette.success.opacity(0.20), lineWidth: 0.8)
        )
        .appShadow(AppShadow.hairline)
    }

    private func runReveal() {
        let anim: Animation = reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.30)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(anim) { showHeader = true }
            for i in 1...bullets.count {
                try? await Task.sleep(for: .milliseconds(260))
                withAnimation(anim) { visibleBullets = i }
            }
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(anim) { showAction = true }
        }
    }
}

/// Mini "Ask across notes" mockup: search field + answer bubble with a
/// pinned source pill. Shows the Recall / Ask experience.
/// Interactive recall stage. Auto-plays the first canned question, but the
/// user can tap any suggestion chip to swap to a different question →
/// answer pair. Demonstrates "ask anything" by letting the user actually
/// pick what to ask.
private struct RecallPreview: View {
    @State private var showSearch = false
    @State private var typedQuery = ""
    @State private var showAnswer = false
    @State private var showSource = false
    @State private var currentIndex = 0
    @State private var pendingTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct QA {
        let chip: String
        let question: String
        let answer: String
        let source: String
        let recency: String
    }

    private let questions: [QA] = [
        QA(chip: "Pricing?",
           question: "What did we decide about pricing?",
           answer: "Pricing tiers will be revisited next quarter, based on customer feedback from the Oct launch.",
           source: "Q4 Roadmap Review",
           recency: "· 2 weeks ago"),
        QA(chip: "Action items?",
           question: "Any open follow-ups for Maya?",
           answer: "Maya owns the vendor shortlist, due Thursday — sent over after the Q4 review.",
           source: "Q4 Roadmap Review",
           recency: "· 2 weeks ago"),
        QA(chip: "Hiring plan?",
           question: "What's the hiring plan for January?",
           answer: "Two backend engineers in Jan to support analytics rollout. Recruiter brief ready.",
           source: "Q4 Roadmap Review",
           recency: "· 2 weeks ago")
    ]

    var body: some View {
        ZStack {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 220, weight: .light))
                .foregroundStyle(AppPalette.success.opacity(0.05))
                .offset(x: -20, y: 30)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 14) {
                // Search field — bigger and more refined.
                HStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(AppPalette.success)
                    Text(typedQuery.isEmpty ? "Ask anything…" : typedQuery)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(typedQuery.isEmpty ? AppPalette.tertiaryInk : AppPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppPalette.cardBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(AppPalette.success.opacity(0.25), lineWidth: 0.8))
                .appShadow(AppShadow.hairline)
                .opacity(showSearch ? 1 : 0)
                .offset(y: showSearch ? 0 : 4)

                HStack(spacing: 7) {
                    ForEach(questions.indices, id: \.self) { i in
                        Button {
                            HapticEngine.tap(.light)
                            select(i)
                        } label: {
                            Text(questions[i].chip)
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(currentIndex == i ? .white : AppPalette.success)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(currentIndex == i ? AppPalette.success : AppPalette.success.opacity(0.10))
                                )
                                .overlay(
                                    Capsule().strokeBorder(AppPalette.success.opacity(currentIndex == i ? 0 : 0.30), lineWidth: 0.7)
                                )
                        }
                        .buttonStyle(PressScaleButtonStyle(scale: 0.90))
                    }
                    Spacer(minLength: 0)
                }
                .opacity(showSearch ? 1 : 0)

                // Answer card — premium presence.
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(AppPalette.success.opacity(0.16))
                        Circle().strokeBorder(AppPalette.success.opacity(0.28), lineWidth: 0.7)
                        Image(systemName: "quote.bubble.fill")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(AppPalette.success)
                    }
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(questions[currentIndex].answer)
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.ink.opacity(0.88))
                            .lineSpacing(2)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(currentIndex)
                            .transition(.opacity.combined(with: .offset(y: 6)))

                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(AppPalette.accent)
                            Text(questions[currentIndex].source)
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(AppPalette.accent)
                            Text(questions[currentIndex].recency)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppPalette.accent.opacity(0.6))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AppPalette.accentSoft.opacity(0.7), in: Capsule())
                        .overlay(Capsule().strokeBorder(AppPalette.accent.opacity(0.18), lineWidth: 0.6))
                        .opacity(showSource ? 1 : 0)
                        .scaleEffect(showSource ? 1 : 0.85, anchor: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .strokeBorder(AppPalette.success.opacity(0.18), lineWidth: 0.7)
                )
                .appShadow(AppShadow.hairline)
                .opacity(showAnswer ? 1 : 0)
                .offset(y: showAnswer ? 0 : 10)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { runReveal(for: 0, initial: true) }
        .onDisappear { pendingTask?.cancel() }
        .accessibilityLabel("Asking across your notes — tap a suggestion to see a different answer")
    }

    private func select(_ index: Int) {
        guard index != currentIndex else { return }
        pendingTask?.cancel()
        withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.25)) {
            showAnswer = false
            showSource = false
        }
        currentIndex = index
        runReveal(for: index, initial: false)
    }

    private func runReveal(for index: Int, initial: Bool) {
        let anim: Animation = reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.35)
        let target = questions[index].question
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            if initial {
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(anim) { showSearch = true }
                try? await Task.sleep(for: .milliseconds(220))
            } else {
                try? await Task.sleep(for: .milliseconds(150))
            }
            typedQuery = ""
            if reduceMotion {
                typedQuery = target
            } else {
                for ch in target {
                    typedQuery.append(ch)
                    try? await Task.sleep(for: .milliseconds(22))
                }
            }
            try? await Task.sleep(for: .milliseconds(240))
            withAnimation(anim) { showAnswer = true }
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { showSource = true }
        }
    }
}

// MARK: - Editorial Today sections

/// Premium Today hero — cream paper card with a soft teal wash + ambient glow,
/// a date eyebrow, time-aware serif greeting, contextual subtitle, a capture
/// menu, and an inline three-stat strip divided by hairlines.
private struct EditorialHeroCard: View {
    let today: Int
    let open: Int
    let streak: Int
    var week: Int = 0
    var lastWeek: Int = 0
    let onRecord: () -> Void
    let onType: () -> Void
    let onImport: () -> Void
    var onOpenTasks: () -> Void = {}

    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12:  "Good morning."
        case 12..<17: "Good afternoon."
        case 17..<22: "Good evening."
        default:      "Working late."
        }
    }

    private var dateLine: String {
        let now = Date.now
        let weekday = now.formatted(.dateTime.weekday(.abbreviated))
        let monthDay = now.formatted(.dateTime.month(.abbreviated).day())
        return "\(weekday) · \(monthDay)"
    }

    private var subtitle: String {
        if today > 0 && open > 0 {
            return "\(today) \(today == 1 ? "meeting" : "meetings") today · \(open) to follow up"
        }
        if open > 0  { return "\(open) follow-up\(open == 1 ? "" : "s") waiting" }
        if today > 0 { return "\(today) \(today == 1 ? "meeting" : "meetings") captured today" }
        return "A clear slate — capture your first note."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule().fill(AppPalette.accent).frame(width: 36, height: 3)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    EditorialEyebrow(text: dateLine, tint: AppPalette.accent)
                    Text(greeting)
                        .scaledFont(size: 28, weight: .medium, design: .serif, relativeTo: .title)
                        .foregroundStyle(AppPalette.ink)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                CaptureMenuButton(size: 42, onRecord: onRecord, onType: onType, onImport: onImport)
            }

            EditorialRule()

            HStack(spacing: 14) {
                stat("Today", today, today == 1 ? "meeting" : "meetings")
                statRule
                Button {
                    HapticEngine.tap(.light)
                    onOpenTasks()
                } label: {
                    stat("Open", open, open == 1 ? "follow-up" : "follow-ups", accent: true)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.96))
                .accessibilityLabel("Open tasks — \(open)")
                .accessibilityHint("Opens your Tasks list")
                statRule
                stat("Streak", streak, streak == 1 ? "day" : "days")
            }

            HeroInsightLine(week: week, last: lastWeek)
                .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroSurface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8)
        )
        .appShadow(AppShadow.card)
        .onAppear {
            guard !revealed else { return }
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.easeOut(duration: 0.85).delay(0.15)) { revealed = true }
            }
        }
    }

    @ViewBuilder
    private var heroSurface: some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
        ZStack {
            shape.fill(AppPalette.cardBackground)
            shape.fill(
                LinearGradient(
                    colors: [AppPalette.accent.opacity(0.10), .clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            )
            // Slow-drifting accent aurora — gives the primary surface gentle,
            // living depth. Uses adaptive `accent`, so it reads correctly in
            // light and dark. Holds still under Reduce Motion.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [AppPalette.accent.opacity(0.16), .clear],
                        center: .center, startRadius: 0, endRadius: 120
                    )
                )
                .frame(width: 230, height: 230)
                .offset(x: 100, y: -80)
                .blur(radius: 14)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [AppPalette.accent.opacity(0.09), .clear],
                        center: .center, startRadius: 0, endRadius: 90
                    )
                )
                .frame(width: 170, height: 170)
                .offset(x: -60, y: 110)
                .blur(radius: 20)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }

    private var statRule: some View {
        Rectangle().fill(AppPalette.border.opacity(0.7)).frame(width: 1, height: 30)
    }

    private func stat(_ label: String, _ value: Int, _ unit: String, accent: Bool = false) -> some View {
        // A zero stat recedes (dimmed, tertiary ink) so the eye lands on the
        // live numbers; an `accent` stat that has data glows in brand teal so
        // the one actionable count reads as the hero of the row.
        let isZero = value == 0
        let numberColor: Color = isZero
            ? AppPalette.tertiaryInk
            : (accent ? AppPalette.accent : AppPalette.ink)
        return VStack(alignment: .leading, spacing: 4) {
            EditorialEyebrow(text: label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountUpNumber(
                    value: revealed ? Double(value) : 0,
                    font: .system(size: 24, weight: .medium, design: .serif),
                    color: numberColor
                )
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isZero ? 0.6 : 1)
    }
}

/// Up-next meeting card with an accent left rail and Prep / Capture chips.
private struct EditorialUpNext: View {
    let event: UpcomingEvent
    let onPrep: () -> Void
    let onCapture: () -> Void

    private var timeRange: String {
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
    private var source: String { event.isVideoCall ? "Video call" : (event.location ?? "In person") }
    private var countdown: String {
        let mins = Int(event.startDate.timeIntervalSinceNow / 60)
        if mins <= 0 { return "now" }
        if mins < 60 { return "in \(mins) min" }
        return "in \(mins / 60)h"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHead(title: "Up next") {
                EditorialMeta(text: countdown, tint: AppPalette.accent)
            }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    EditorialEyebrow(text: "\(timeRange) · \(source)", tint: AppPalette.accent)
                    Text(event.title)
                        .font(.system(size: 22, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button { HapticEngine.tap(.light); onPrep() } label: {
                            EditorialChip(text: "Prep", variant: .outline)
                        }
                        .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                        Button { HapticEngine.tap(.light); onCapture() } label: {
                            EditorialChip(text: "Capture", systemImage: "mic.fill", variant: .accent)
                        }
                        .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                Rectangle().fill(AppPalette.accent).frame(width: 4)
            }
            .background(AppPalette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(AppPalette.border, lineWidth: 1)
            )
        }
    }
}

/// Open follow-ups as a hairline-divided checklist.
private struct EditorialInbox: View {
    let loops: [OpenLoop]
    let total: Int
    let onResolve: (Meeting.ID) -> Void
    let onSeeAll: () -> Void

    var body: some View {
        let visible = Array(loops.prefix(3))
        VStack(alignment: .leading, spacing: 6) {
            EditorialSectionHead(title: "Inbox") {
                if total > visible.count {
                    Button { HapticEngine.tap(.light); onSeeAll() } label: {
                        EditorialMeta(text: "\(total) open", tint: AppPalette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    EditorialMeta(text: "\(total) open \(total == 1 ? "loop" : "loops")")
                }
            }
            VStack(spacing: 0) {
                ForEach(visible) { loop in
                    EditorialLoopRow(loop: loop) { onResolve(loop.meetingID) }
                        .editorialReveal()
                    if loop.id != visible.last?.id { EditorialRule() }
                }
            }
        }
    }
}

private struct EditorialLoopRow: View {
    let loop: OpenLoop
    let onResolve: () -> Void
    private var isRisk: Bool { loop.kind == .risk }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { HapticEngine.notify(.success); onResolve() } label: {
                Circle()
                    .strokeBorder(isRisk ? AppPalette.coral : AppPalette.tertiaryInk.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 17, height: 17)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.85))
            .accessibilityLabel("Mark done")

            NavigationLink(value: loop.meetingID) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loop.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        EditorialMeta(text: loop.meetingTitle)
                        Text("·").foregroundStyle(AppPalette.border)
                        EditorialMeta(text: isRisk ? "risk" : "action",
                                      tint: isRisk ? AppPalette.coral : AppPalette.secondaryInk)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(EditorialRowStyle(inset: 6))
        }
        .padding(.vertical, 12)
    }
}

/// Recent notes as numbered editorial rows.
private struct EditorialRecent: View {
    let meetings: [Meeting]
    let onSeeAll: () -> Void

    var body: some View {
        let shown = Array(meetings.prefix(4))
        VStack(alignment: .leading, spacing: 6) {
            EditorialSectionHead(title: "Recent") {
                Button { HapticEngine.tap(.light); onSeeAll() } label: {
                    HStack(spacing: 4) {
                        Text("View all")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(AppPalette.accent)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, meeting in
                    EditorialRecentRow(index: idx + 1, meeting: meeting)
                        .editorialReveal()
                    if idx < shown.count - 1 { EditorialRule() }
                }
            }
        }
    }
}

private struct EditorialRecentRow: View {
    let index: Int
    let meeting: Meeting

    private var sub: String {
        let people = meeting.attendees.prefix(3).joined(separator: ", ")
        let dur = meeting.durationMinutes > 0 ? "\(meeting.durationMinutes)m" : ""
        return [people, dur].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var tags: [String] {
        meeting.workspace
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationLink(value: meeting.id) {
            HStack(alignment: .top, spacing: 14) {
                Text(String(format: "%02d", index))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .frame(width: 22, alignment: .trailing)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title.isEmpty ? "Untitled" : meeting.title)
                        .font(.system(size: 18, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.secondaryInk)
                            .lineLimit(1)
                    }
                    if !tags.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(tags.prefix(2), id: \.self) { EditorialMeta(text: $0) }
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                EditorialMeta(text: HomeRecentNotesSection.relativeTimeBadge(for: meeting.when))
                    .padding(.top, 3)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorialRowStyle())
    }
}

// MARK: - Home hero styles

/// Selectable Today hero treatments. Persisted via @AppStorage("homeHeroStyle")
/// and switched in Settings.
enum HeroStyle: String, CaseIterable, Identifiable {
    case briefing, spotlight, masthead, focus
    var id: String { rawValue }
    var title: String {
        switch self {
        case .briefing:  "Briefing"
        case .spotlight: "Spotlight"
        case .masthead:  "Masthead"
        case .focus:     "Focus"
        }
    }
    var icon: String {
        switch self {
        case .briefing:  "rectangle.grid.1x2.fill"
        case .spotlight: "calendar.badge.clock"
        case .masthead:  "textformat.size.larger"
        case .focus:     "circle.dashed"
        }
    }
}

/// Data the hero variants render. Built from the Today snapshot + calendar.
struct HeroModel {
    var today: Int
    var open: Int
    var streak: Int
    var nextTitle: String?
    var nextMeta: String?
    var attendees: [String]
    var weekTotal: Int = 0
    var lastWeekTotal: Int = 0
}

/// One quiet, informative trend line — this week's captures versus last week,
/// with a single directional glyph. Calm: one row, no chart.
struct HeroInsightLine: View {
    let week: Int
    let last: Int
    private var delta: Int { week - last }

    private var symbol: String {
        if week == 0 { return "moon.zzz.fill" }
        if delta > 0 { return "arrow.up.right" }
        if delta < 0 { return "arrow.down.right" }
        return "equal"
    }
    /// Premium amber for momentum, teal for steady/first, muted when down or
    /// idle — a second brand color so the line reads as a highlight, not noise.
    private var tint: Color {
        if week == 0 { return AppPalette.secondaryInk }
        if delta > 0 { return AppPalette.gold }
        if delta < 0 { return AppPalette.secondaryInk }
        return AppPalette.accent
    }
    private var text: String {
        if week == 0 { return "Nothing captured this week yet" }
        if last == 0 { return "\(week) this week · first active week" }
        if delta > 0 { return "\(week) this week · \(delta) more than last" }
        if delta < 0 { return "\(week) this week · \(-delta) fewer than last" }
        return "\(week) this week · steady"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 0.8))
    }
}

private func heroGreeting() -> String {
    switch Calendar.current.component(.hour, from: .now) {
    case 5..<12:  return "Good morning."
    case 12..<17: return "Good afternoon."
    case 17..<22: return "Good evening."
    default:      return "Working late."
    }
}

private func heroDateLine() -> String {
    let now = Date.now
    return "\(now.formatted(.dateTime.weekday(.abbreviated))) · \(now.formatted(.dateTime.month(.abbreviated).day()))"
}

/// Shared accent capture menu (Record / Type / Import).
struct CaptureMenuButton: View {
    var size: CGFloat = 42
    let onRecord: () -> Void
    let onType: () -> Void
    let onImport: () -> Void

    var body: some View {
        Menu {
            Button { onRecord() } label: { Label("Record meeting", systemImage: AppSymbols.mic) }
            Button { onType() }   label: { Label("Type a note", systemImage: AppSymbols.note) }
            Button { onImport() } label: { Label("Import audio", systemImage: AppSymbols.importAudio) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(AppPalette.accentButton, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: AppPalette.accent.opacity(0.30), radius: 10, y: 4)
        }
        .accessibilityLabel("New capture")
        .accessibilityIdentifier("home.captureMenu")
    }
}

// ① Spotlight — greeting + next-meeting card with accent rail.
private struct HeroSpotlight: View {
    let model: HeroModel
    let onRecord: () -> Void
    let onType: () -> Void
    let onImport: () -> Void
    let onPrep: () -> Void
    let onCapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    EditorialEyebrow(text: heroDateLine(), tint: AppPalette.accent)
                    Text(heroGreeting())
                        .font(.system(size: 24, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                }
                Spacer()
                CaptureMenuButton(size: 40, onRecord: onRecord, onType: onType, onImport: onImport)
            }

            if let title = model.nextTitle {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        EditorialEyebrow(text: model.nextMeta ?? "Up next", tint: AppPalette.accent)
                        Text(title)
                            .font(.system(size: 20, weight: .medium, design: .serif))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            if !model.attendees.isEmpty {
                                EditorialAvatarStack(names: model.attendees, size: 22, max: 3)
                            }
                            Spacer(minLength: 0)
                            Button { HapticEngine.tap(.light); onPrep() } label: {
                                EditorialChip(text: "Prep", variant: .outline)
                            }.buttonStyle(PressScaleButtonStyle(scale: 0.94))
                            Button { HapticEngine.tap(.light); onCapture() } label: {
                                EditorialChip(text: "Capture", systemImage: "mic.fill", variant: .accent)
                            }.buttonStyle(PressScaleButtonStyle(scale: 0.94))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    Rectangle().fill(AppPalette.accent).frame(width: 4)
                }
                .background(AppPalette.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(AppPalette.border, lineWidth: 1))
            } else {
                Button { HapticEngine.tap(.medium); onCapture() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mic.fill").font(.subheadline.weight(.semibold))
                        Text("Start capture").font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right").font(.footnote.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(AppPalette.accentButton, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                }.buttonStyle(PressScaleButtonStyle(scale: 0.98))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("\(model.today) today")
                    Text("·").foregroundStyle(AppPalette.border)
                    Text("\(model.open) open")
                    Text("·").foregroundStyle(AppPalette.border)
                    Text("\(model.streak)-day streak")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppPalette.secondaryInk)
                HeroInsightLine(week: model.weekTotal, last: model.lastWeekTotal)
            }
        }
    }
}

// ② Masthead — newspaper dateline + huge serif greeting + rules.
private struct HeroMasthead: View {
    let model: HeroModel
    let onRecord: () -> Void
    let onType: () -> Void
    let onImport: () -> Void
    let onCapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                EditorialMeta(text: "\(heroDateLine()) · \(model.today) MTG · \(model.open) OPEN")
                Spacer(minLength: 8)
                CaptureMenuButton(size: 34, onRecord: onRecord, onType: onType, onImport: onImport)
            }
            EditorialRule()
            Text(heroGreeting())
                .scaledFont(size: 40, weight: .medium, design: .serif, relativeTo: .largeTitle)
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)

            HeroInsightLine(week: model.weekTotal, last: model.lastWeekTotal)

            EditorialRule()
            HStack(spacing: 8) {
                if let t = model.nextTitle {
                    Text("Next — \(t)")
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { HapticEngine.tap(.light); onCapture() } label: {
                    HStack(spacing: 6) {
                        Text("Capture today").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(AppPalette.accent)
                }.buttonStyle(PressScaleButtonStyle(scale: 0.95))
            }
        }
    }
}

// ③ Focus — progress ring + single focus line + streak.
private struct HeroFocus: View {
    let model: HeroModel
    let onRecord: () -> Void
    let onType: () -> Void
    let onImport: () -> Void
    let onCapture: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private var progress: Double { min(1.0, Double(model.streak) / 7.0) }
    private var focusLine: String {
        if model.open > 0 { return "Clear \(model.open) open loop\(model.open == 1 ? "" : "s")" }
        if model.today > 0 { return "\(model.today) captured today" }
        return "Capture your first note"
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(AppPalette.border, lineWidth: 5).frame(width: 58, height: 58)
                Circle().trim(from: 0, to: revealed ? progress : 0)
                    .stroke(AppPalette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 58, height: 58)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppPalette.ink)
            }
            VStack(alignment: .leading, spacing: 6) {
                EditorialEyebrow(text: "Today's focus", tint: AppPalette.accent)
                Text(focusLine)
                    .font(.system(size: 19, weight: .medium, design: .serif))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HeroInsightLine(week: model.weekTotal, last: model.lastWeekTotal)
            }
            Spacer(minLength: 0)
            CaptureMenuButton(size: 40, onRecord: onRecord, onType: onType, onImport: onImport)
        }
        .padding(18)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous).fill(AppPalette.cardBackground)
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .fill(LinearGradient(colors: [AppPalette.accent.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .center))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous).strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8))
        .appShadow(AppShadow.card)
        .onAppear {
            guard !revealed else { return }
            if reduceMotion { revealed = true }
            else { withAnimation(.easeOut(duration: 0.9).delay(0.15)) { revealed = true } }
        }
    }
}

// MARK: - Hero style picker (visual previews for Settings)

/// Tiny schematic of each hero layout, drawn from primitives — lets users pick
/// a hero by look, not by name.
struct HeroPreviewThumb: View {
    let style: HeroStyle
    private var ink: Color { AppPalette.ink.opacity(0.8) }
    private var faint: Color { AppPalette.border }

    var body: some View {
        Group {
            switch style {
            case .briefing:
                VStack(alignment: .leading, spacing: 6) {
                    bar(26, 4, AppPalette.accent)
                    bar(60, 9, ink)
                    Spacer(minLength: 2)
                    HStack(spacing: 7) { ForEach(0..<3, id: \.self) { _ in bar(20, 14, faint) } }
                }
            case .spotlight:
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(AppPalette.accent).frame(width: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        bar(28, 4, AppPalette.accent)
                        bar(58, 8, ink)
                        HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().fill(faint).frame(width: 10, height: 10) } }
                    }
                }
            case .masthead:
                VStack(alignment: .leading, spacing: 7) {
                    bar(72, 3, faint)
                    bar(58, 15, ink)
                    bar(72, 3, faint)
                }
            case .focus:
                HStack(spacing: 10) {
                    Circle().trim(from: 0, to: 0.62)
                        .stroke(AppPalette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        bar(24, 4, AppPalette.accent)
                        bar(52, 8, ink)
                        bar(38, 4, faint)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ w: CGFloat, _ h: CGFloat, _ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(c).frame(width: w, height: h)
    }
}

/// Selectable 2×2 grid of hero previews. Binds to the raw `HeroStyle` value.
struct HeroStylePicker: View {
    @Binding var selectionRaw: String
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: cols, spacing: 12) {
            ForEach(HeroStyle.allCases) { style in
                let selected = selectionRaw == style.rawValue
                Button {
                    HapticEngine.tap(.light)
                    withAnimation(AppMotion.snappy) { selectionRaw = style.rawValue }
                } label: {
                    VStack(spacing: 8) {
                        HeroPreviewThumb(style: style)
                            .frame(height: 78)
                            .frame(maxWidth: .infinity)
                            .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                    .strokeBorder(selected ? AppPalette.accent : AppPalette.border.opacity(0.6), lineWidth: selected ? 2 : 1)
                            )
                            .overlay(alignment: .topTrailing) {
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(AppPalette.accent)
                                        .padding(6)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                        Text(style.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? AppPalette.ink : AppPalette.secondaryInk)
                    }
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                .accessibilityLabel("\(style.title) hero")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(14)
    }
}

// MARK: - Command Palette

/// Search-first quick actions sheet. ⌘K-style entry point — record, type,
/// import, ask, jump to a recent meeting, run mic test, open settings. Filters
/// actions + recents as you type.
struct CommandPaletteSheet: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let onRecord: () -> Void
    let onType: () -> Void
    let onImport: () -> Void
    let onAsk: () -> Void
    let onTasks: () -> Void
    let onSettings: () -> Void
    let onMicTest: () -> Void
    let onOpenMeeting: (Meeting.ID) -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Action: Identifiable {
        let id: String
        let title: String
        let icon: String
        let subtitle: String
        let tint: Color
        let run: () -> Void
        var keywords: String { (title + " " + subtitle).lowercased() }
    }

    private var allActions: [Action] {
        [
            Action(id: "rec",  title: "Record meeting", icon: "mic.fill",
                   subtitle: "Start a live capture", tint: AppPalette.accent) { onRecord(); dismiss() },
            Action(id: "type", title: "Type a note", icon: "square.and.pencil",
                   subtitle: "Quick text capture", tint: AppPalette.accent) { onType(); dismiss() },
            Action(id: "imp",  title: "Import audio", icon: "square.and.arrow.down",
                   subtitle: "Audio file → transcript", tint: AppPalette.accent) { onImport(); dismiss() },
            Action(id: "ask",  title: "Ask your library", icon: "sparkle.magnifyingglass",
                   subtitle: "AI across every meeting", tint: AppPalette.gold) { onAsk(); dismiss() },
            Action(id: "tasks", title: "Open tasks", icon: "checklist",
                   subtitle: "Everything you owe", tint: AppPalette.coral) { onTasks(); dismiss() },
            Action(id: "mic", title: "Microphone test", icon: "waveform.and.mic",
                   subtitle: "Check input, route & permissions", tint: AppPalette.secondaryInk) { onMicTest(); dismiss() },
            Action(id: "set", title: "Settings", icon: "gearshape.fill",
                   subtitle: "Appearance, privacy, account", tint: AppPalette.secondaryInk) { onSettings(); dismiss() }
        ]
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private var filteredActions: [Action] {
        guard !trimmed.isEmpty else { return Array(allActions.prefix(4)) }
        return allActions.filter { $0.keywords.contains(trimmed) }
    }

    private var filteredRecents: [Meeting] {
        let base = store.meetings.sorted(by: Meeting.sortDescending)
        if trimmed.isEmpty { return Array(base.prefix(5)) }
        return base.filter {
            $0.title.lowercased().contains(trimmed)
                || $0.workspace.lowercased().contains(trimmed)
                || $0.attendees.contains(where: { $0.lowercased().contains(trimmed) })
        }.prefix(8).map { $0 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !filteredActions.isEmpty {
                            section("Quick actions") {
                                ForEach(Array(filteredActions.enumerated()), id: \.element.id) { idx, a in
                                    actionRow(a)
                                    if idx < filteredActions.count - 1 { EditorialRule() }
                                }
                            }
                        }

                        if !filteredRecents.isEmpty {
                            section(trimmed.isEmpty ? "Recent meetings" : "Meetings") {
                                ForEach(Array(filteredRecents.enumerated()), id: \.element.id) { idx, m in
                                    meetingRow(m)
                                    if idx < filteredRecents.count - 1 { EditorialRule() }
                                }
                            }
                        }

                        if filteredActions.isEmpty && filteredRecents.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(AppPalette.tertiaryInk)
                                Text("Nothing matches \u{201C}\(query)\u{201D}")
                                    .font(.system(size: 14))
                                    .foregroundStyle(AppPalette.secondaryInk)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Quick")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { HapticEngine.tap(.light); dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .tint(AppPalette.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { try? await Task.sleep(for: .milliseconds(120)); focused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppPalette.tertiaryInk)
            TextField("Search or run a command…", text: $query)
                .focused($focused)
                .font(.system(size: 15))
                .foregroundStyle(AppPalette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    if let first = filteredActions.first { first.run() }
                    else if let m = filteredRecents.first { onOpenMeeting(m.id); dismiss() }
                }
            if !query.isEmpty {
                Button { HapticEngine.tap(.light); query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AppPalette.tertiaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(AppPalette.border, lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorialEyebrow(text: title)
            VStack(spacing: 0) { content() }
        }
    }

    private func actionRow(_ a: Action) -> some View {
        Button(action: { HapticEngine.tap(.light); a.run() }) {
            HStack(spacing: 14) {
                Image(systemName: a.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(a.tint, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppPalette.ink)
                    Text(a.subtitle).font(.system(size: 12)).foregroundStyle(AppPalette.secondaryInk).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorialRowStyle())
    }

    private func meetingRow(_ m: Meeting) -> some View {
        Button(action: { onOpenMeeting(m.id); dismiss() }) {
            HStack(spacing: 12) {
                EditorialAvatar(name: m.attendees.first ?? m.title, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.title.isEmpty ? "Untitled" : m.title)
                        .font(.system(size: 14, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    EditorialMeta(text: m.workspace)
                }
                Spacer(minLength: 0)
                EditorialMeta(text: HomeRecentNotesSection.relativeTimeBadge(for: m.when))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorialRowStyle())
    }
}

// MARK: - Home: Pinned + Agenda

/// Pinned meetings surfaced on Today. Same `isPinned` flag Library uses, so
/// pinning anywhere keeps it within reach.
private struct HomePinnedSection: View {
    @Environment(MeetingStore.self) private var store
    let meetings: [Meeting]
    let onSeeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorialSectionHead(title: "Pinned") {
                EditorialMeta(text: "\(meetings.count)", tint: AppPalette.accent)
            }
            VStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { idx, m in
                    NavigationLink(value: m.id) {
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(AppPalette.accent).frame(width: 7, height: 7).padding(.top, 8)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.title.isEmpty ? "Untitled" : m.title)
                                    .font(.system(size: 16, weight: .medium, design: .serif))
                                    .foregroundStyle(AppPalette.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                EditorialMeta(text: m.workspace)
                            }
                            Spacer(minLength: 0)
                            Button {
                                HapticEngine.tap(.light)
                                store.togglePinned(for: m.id)
                            } label: {
                                Image(systemName: "pin.slash")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppPalette.tertiaryInk)
                                    .padding(8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Unpin")
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(EditorialRowStyle())
                    .editorialReveal()
                    if idx < meetings.count - 1 { EditorialRule() }
                }
            }
        }
    }
}

/// "Later today" — additional calendar events under the Up next spotlight.
private struct HomeAgendaSection: View {
    let events: [UpcomingEvent]
    let onPrep: (UpcomingEvent) -> Void
    let onCapture: (UpcomingEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorialSectionHead(title: "Later today") {
                EditorialMeta(text: "\(events.count)")
            }
            VStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { idx, ev in
                    agendaRow(ev)
                        .editorialReveal()
                    if idx < events.count - 1 { EditorialRule() }
                }
            }
        }
    }

    private func agendaRow(_ ev: UpcomingEvent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ev.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppPalette.accent)
                EditorialMeta(text: ev.isVideoCall ? "Video" : (ev.location?.uppercased() ?? "IN PERSON"))
            }
            .frame(width: 64, alignment: .leading)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(ev.title)
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { HapticEngine.tap(.light); onPrep(ev) } label: {
                        EditorialChip(text: "Prep", variant: .outline)
                    }.buttonStyle(PressScaleButtonStyle(scale: 0.94))
                    Button { HapticEngine.tap(.light); onCapture(ev) } label: {
                        EditorialChip(text: "Capture", systemImage: "mic.fill", variant: .accent)
                    }.buttonStyle(PressScaleButtonStyle(scale: 0.94))
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}
