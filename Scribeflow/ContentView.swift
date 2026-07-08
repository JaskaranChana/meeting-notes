import CoreSpotlight
import SwiftUI

/// Tracks how many detail views are pushed across the tab stacks, so the
/// floating dock can hide while you're reading a meeting and reappear at root.
@MainActor @Observable final class NavChrome {
    var detailDepth = 0
}

/// Root tab shell. Five daily-use tabs: **Today** (briefing), **Library**
/// (notes), **Tasks** (action items), **Calendar** (meeting schedule), and
/// **Ask** (workspace-wide AI). Settings is a sheet from Today's toolbar.
struct ContentView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if DEBUG
    @State private var selectedTab: RootTab = AppQARoute.current?.defaultTab ?? .home
    #else
    @State private var selectedTab: RootTab = .home
    #endif
    @State private var selectedMeetingID: Meeting.ID?
    @State private var captureMode: CaptureView.Mode?
    @State private var showingSettings = false
    @State private var isPrivacyScreenVisible = false
    @State private var toast: ToastItem?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var spotlightIndexTask: Task<Void, Never>?
    @State private var openActionItemCount = 0
    @StateObject private var pendingInbox = PendingCaptureInbox.shared
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @State private var navChrome = NavChrome()

    var body: some View {
        ZStack {
            Group {
                #if DEBUG
                if let route = AppQARoute.current {
                    qaRoot(for: route)
                } else {
                    mainTabs
                }
                #else
                mainTabs
                #endif
            }
            .environment(navChrome)
            .fullScreenCover(item: Binding(
                get: { captureMode.map { CaptureModeWrapper(mode: $0) } },
                set: { wrapper in captureMode = wrapper?.mode }
            )) { wrapper in
                CaptureView(
                    initialMode: wrapper.mode,
                    selectedMeetingID: $selectedMeetingID,
                    toast: $toast
                )
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView(showsDoneButton: true)
                }
                // A presented sheet doesn't inherit the root's
                // preferredColorScheme, so the appearance toggle inside Settings
                // wouldn't restyle the sheet itself until reopened. Apply it here
                // so the switch lands instantly.
                .preferredColorScheme(AppearancePreference(rawValue: appearanceRaw)?.colorScheme)
            }
            .tint(AppPalette.accent)
            .onAppear {
                selectedMeetingID = selectedMeetingID ?? store.recentMeetings.first?.id
                refreshRootChromeSnapshot()
            }

            if isPrivacyScreenVisible {
                privacyScreen
                    .transition(.opacity)
                    .zIndex(100)
            }

            if let toast {
                ToastView(item: toast, onDismiss: {
                    toastDismissTask?.cancel()
                    withAnimation(AppMotion.smooth) { self.toast = nil }
                })
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .top)),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .zIndex(99)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 60)
                .allowsHitTesting(toast.actionTitle != nil)
            }
        }
        .animation(AppMotion.fade, value: isPrivacyScreenVisible)
        .animation(AppMotion.bounce, value: toast != nil)
        .onChange(of: scenePhase) { _, phase in
            withAnimation(AppMotion.fade) {
                isPrivacyScreenVisible = phase == .background
            }
            if phase == .active {
                drainPendingCaptureIntents()
            }
        }
        .onChange(of: store.lastSaveFailed) { _, failed in
            guard failed else { return }
            toast = ToastItem(
                message: "Couldn't save changes — your latest edits may not persist.",
                icon: "exclamationmark.triangle.fill"
            )
        }
        .task {
            // Surface launch-time recovery so silent data loss is never silent.
            if store.loadFailed {
                toast = ToastItem(
                    message: "Some saved data couldn't be read. The original was kept for recovery.",
                    icon: "exclamationmark.triangle.fill"
                )
            } else if store.recoveredFromBackup {
                toast = ToastItem(
                    message: "Restored your notes from a backup.",
                    icon: "arrow.clockwise"
                )
            }
        }
        .onChange(of: store.revision) { _, _ in
            refreshRootChromeSnapshot()
            scheduleSpotlightIndex()
        }
        .onContinueUserActivity(SpotlightIndex.activityType) { activity in
            handleSpotlightActivity(activity)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            handleSpotlightActivity(activity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeflowOpenMeeting)) { note in
            if let meetingID = note.object as? Meeting.ID {
                activateRootTab(.library)
                selectedMeetingID = meetingID
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeflowToast)) { note in
            if let item = note.object as? ToastItem {
                toast = item
            }
        }
        .onChange(of: pendingInbox.startRecordRequested) { _, requested in
            if requested { drainPendingCaptureIntents() }
        }
        .onChange(of: pendingInbox.startTypeRequested) { _, requested in
            if requested { drainPendingCaptureIntents() }
        }
        .onChange(of: pendingInbox.openLastMeetingRequested) { _, requested in
            if requested { drainPendingCaptureIntents() }
        }
        .onChange(of: pendingInbox.openAskRequested) { _, requested in
            if requested { drainPendingCaptureIntents() }
        }
        .task { drainPendingCaptureIntents() }
        .sensoryFeedback(.success, trigger: toast?.id)
        .sensoryFeedback(.selection, trigger: selectedMeetingID)
        .onChange(of: toast) { _, newToast in
            toastDismissTask?.cancel()
            guard let newToast else { return }
            let lifetime: Duration = newToast.actionTitle != nil ? .seconds(5) : .milliseconds(2200)
            toastDismissTask = Task { @MainActor in
                try? await Task.sleep(for: lifetime)
                guard !Task.isCancelled else { return }
                withAnimation(AppMotion.smooth) { toast = nil }
            }
        }
        .onDisappear {
            toastDismissTask?.cancel()
            toastDismissTask = nil
            spotlightIndexTask?.cancel()
            spotlightIndexTask = nil
        }
    }

    @ViewBuilder
    private var privacyScreen: some View {
        ZStack {
            Rectangle()
                .fill(reduceTransparency ? AnyShapeStyle(AppPalette.paper) : AnyShapeStyle(.ultraThinMaterial))
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(decorative: "BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .opacity(0.88)
                Text("SCRIBEFLOW")
                    .font(.caption.weight(.bold))
                    .kerning(2.2)
                    .foregroundStyle(AppPalette.ink.opacity(0.6))
            }
        }
    }

    /// Reserves bottom space so scroll content (and pushed detail views) clear
    /// the floating dock — the dock is an overlay, so each tab must inset itself.
    private var dockClearance: some View {
        Color.clear.frame(height: navChrome.detailDepth == 0 ? AppDockMetrics.scrollClearance : 0)
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TodayView(
                    selectedMeetingID: $selectedMeetingID,
                    onCapture: { mode in captureMode = mode },
                    onSettingsTap: { showingSettings = true },
                    onAskTap: { activateRootTab(.ask) },
                    onTasksTap: { activateRootTab(.tasks) },
                    toast: $toast
                )
                .toolbar(.hidden, for: .tabBar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dockClearance }
            .tag(RootTab.home)

            NavigationStack {
                MeetingsView(
                    selectedMeetingID: $selectedMeetingID,
                    onAskTap: { activateRootTab(.ask) },
                    toast: $toast
                )
                .toolbar(.hidden, for: .tabBar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dockClearance }
            .tag(RootTab.library)

            NavigationStack {
                ActionItemsView(
                    selectedMeetingID: $selectedMeetingID,
                    toast: $toast
                )
                .toolbar(.hidden, for: .tabBar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dockClearance }
            .tag(RootTab.tasks)

            NavigationStack {
                MeetingCalendarView(
                    selectedMeetingID: $selectedMeetingID,
                    onCapture: { mode in captureMode = mode },
                    toast: $toast
                )
                .toolbar(.hidden, for: .tabBar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dockClearance }
            .tag(RootTab.calendar)

            NavigationStack {
                AskView()
                    .toolbar(.hidden, for: .tabBar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dockClearance }
            .tag(RootTab.ask)
        }
        .tint(AppPalette.accent)
        .overlay(alignment: .bottom) {
            if navChrome.detailDepth == 0 {
                FloatingTabDock(
                    items: [
                        FloatingTabDockItem(id: RootTab.home.rawValue, label: "Today", systemImage: "sparkles"),
                        FloatingTabDockItem(id: RootTab.library.rawValue, label: "Library", systemImage: "rectangle.stack"),
                        FloatingTabDockItem(id: RootTab.tasks.rawValue, label: "Tasks", systemImage: "checklist", badge: openActionItemCount),
                        FloatingTabDockItem(id: RootTab.calendar.rawValue, label: "Calendar", systemImage: "calendar"),
                        FloatingTabDockItem(id: RootTab.ask.rawValue, label: "Ask", systemImage: "sparkle.magnifyingglass")
                    ],
                    selection: Binding(
                        get: { selectedTab.rawValue },
                        set: { newValue in
                            if let tab = RootTab(rawValue: newValue) {
                                selectedTab = tab
                            }
                        }
                    )
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(AppMotion.smooth, value: navChrome.detailDepth)
        .modifier(ScribeflowChrome())
    }

    private func activateRootTab(_ tab: RootTab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
    }

    /// Spotlight search results come back through `NSUserActivity`. The
    /// activity carries the meeting UUID in either the searchable item
    /// identifier or the user-info dictionary; we route to Library and
    /// select the matching meeting for navigation.
    private func handleSpotlightActivity(_ activity: NSUserActivity) {
        let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
            ?? activity.userInfo?["meetingID"] as? String
        guard let identifier, let uuid = UUID(uuidString: identifier) else { return }
        activateRootTab(.library)
        selectedMeetingID = uuid
    }

    /// Drain Siri / Shortcuts pending intents into UI state. Called when the
    /// scene becomes active and whenever the inbox publishes a new request,
    /// covering both cold-launch and warm-resume paths.
    private func drainPendingCaptureIntents() {
        if pendingInbox.startRecordRequested {
            pendingInbox.startRecordRequested = false
            captureMode = .record
        }
        if pendingInbox.startTypeRequested {
            pendingInbox.startTypeRequested = false
            captureMode = .type
        }
        if pendingInbox.openLastMeetingRequested {
            pendingInbox.openLastMeetingRequested = false
            if let latest = store.recentMeetings.first {
                activateRootTab(.library)
                selectedMeetingID = latest.id
            }
        }
        if pendingInbox.openAskRequested {
            pendingInbox.openAskRequested = false
            activateRootTab(.ask)
        }
    }

    private func refreshRootChromeSnapshot() {
        openActionItemCount = store.meetings.reduce(0) { partial, meeting in
            partial + meeting.commitments.reduce(0) { total, commitment in
                total + (commitment.status == .open || commitment.status == .atRisk ? 1 : 0)
            }
        }
    }

    private func scheduleSpotlightIndex() {
        spotlightIndexTask?.cancel()
        spotlightIndexTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let snapshot = store.meetings
            await Task.detached(priority: .utility) {
                SpotlightIndex.index(snapshot)
            }.value
        }
    }

    #if DEBUG
    @ViewBuilder
    private func qaRoot(for route: AppQARoute) -> some View {
        switch route {
        case .home, .library, .calendar, .ask:
            mainTabs
        case .quickNote:
            CaptureView(initialMode: .type, selectedMeetingID: $selectedMeetingID, toast: $toast)
        case .meetingDetail:
            if let meetingID = store.recentMeetings.first?.id {
                NavigationStack {
                    MeetingDetailView(meetingID: meetingID)
                }
            } else {
                NavigationStack {
                    EmptyStateCard(
                        title: "No meetings available",
                        subtitle: "Seed data is required to render the QA route."
                    )
                    .padding(20)
                }
            }
        case .liveCapture:
            CaptureView(initialMode: .record, selectedMeetingID: $selectedMeetingID, toast: $toast)
        case .folderDetail:
            if let folder = store.workspaceFolders().first {
                NavigationStack {
                    FolderDetailView(folder: folder, selectedMeetingID: $selectedMeetingID)
                }
            } else {
                NavigationStack {
                    EmptyStateCard(
                        title: "No folders available",
                        subtitle: "Seed data is required to render the QA route."
                    )
                    .padding(20)
                }
            }
        }
    }
    #endif
}

private enum RootTab: String, Hashable {
    case home
    case library
    case tasks
    case calendar
    case ask
}

/// Identifiable wrapper so `fullScreenCover(item:)` can drive on the capture
/// mode enum directly. The cover dismisses when the binding goes to nil.
private struct CaptureModeWrapper: Identifiable {
    let mode: CaptureView.Mode
    var id: String { mode.rawValue }
}

#if DEBUG
private enum AppQARoute: String {
    case home
    case library
    case calendar
    case ask
    case quickNote
    case meetingDetail
    case liveCapture
    case folderDetail

    static var current: AppQARoute? {
        guard let rawValue = LaunchArgument.value(for: "-ScribeflowQARoute") else { return nil }
        return AppQARoute(rawValue: rawValue)
    }

    var defaultTab: RootTab {
        switch self {
        case .library:
            return .library
        case .calendar:
            return .calendar
        case .ask:
            return .ask
        default:
            return .home
        }
    }
}

private enum LaunchArgument {
    static func contains(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    static func value(for flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }
}
#endif
