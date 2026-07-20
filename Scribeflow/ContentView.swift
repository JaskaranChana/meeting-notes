import CoreSpotlight
import SwiftUI

private struct RootChromeSnapshot: Sendable {
    let openActionItemCount: Int
}

private actor RootChromeSnapshotBuilder {
    func make(from meetings: [Meeting]) -> RootChromeSnapshot {
        RootChromeSnapshot(
            openActionItemCount: meetings.reduce(0) { partial, meeting in
                return partial + meeting.commitments.reduce(0) { total, commitment in
                    total + (commitment.status == .open || commitment.status == .atRisk ? 1 : 0)
                }
            }
        )
    }
}

private struct SpotlightRefreshKey: Hashable {
    let revision: Int
    let sceneIsActive: Bool
}

/// Owns broad store observation outside the root tab shell. A meeting edit can
/// restart badge/index maintenance without invalidating every NavigationStack
/// and tab in `ContentView`.
private struct RootStoreMaintenanceObserver: View {
    @Environment(MeetingStore.self) private var store
    let sceneIsActive: Bool
    @Binding var openActionItemCount: Int
    let onToast: (ToastItem) -> Void
    @State private var snapshotBuilder = RootChromeSnapshotBuilder()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .task {
                if store.loadFailed {
                    onToast(ToastItem(
                        message: "Some saved data couldn't be read. The original was kept for recovery.",
                        icon: "exclamationmark.triangle.fill"
                    ))
                } else if store.recoveredFromBackup {
                    onToast(ToastItem(
                        message: "Restored your notes from a backup.",
                        icon: "arrow.clockwise"
                    ))
                }
            }
            .onChange(of: store.lastSaveFailed) { _, failed in
                guard failed else { return }
                onToast(ToastItem(
                    message: "Couldn't save changes - your latest edits may not persist.",
                    icon: "exclamationmark.triangle.fill"
                ))
            }
            .task(id: store.revision) {
                let expectedRevision = store.revision
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let snapshot = await snapshotBuilder.make(from: store.meetings)
                guard !Task.isCancelled, store.revision == expectedRevision else { return }
                if openActionItemCount != snapshot.openActionItemCount {
                    openActionItemCount = snapshot.openActionItemCount
                }
            }
            .task(id: SpotlightRefreshKey(
                revision: store.revision,
                sceneIsActive: sceneIsActive
            ), priority: .utility) {
                guard sceneIsActive else { return }
                let expectedRevision = store.revision
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, store.revision == expectedRevision else { return }
                await SpotlightIndex.index(store.meetings)
            }
    }
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
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var tasksPath = NavigationPath()
    @State private var calendarPath = NavigationPath()
    @State private var askPath = NavigationPath()
    @State private var captureMode: CaptureView.Mode?
    @State private var showingSettings = false
    @State private var isPrivacyScreenVisible = false
    @State private var toast: ToastItem?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var openActionItemCount = 0
    @StateObject private var pendingInbox = PendingCaptureInbox.shared
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage("scribeflow.navigation.lastRootTab") private var lastRootTabRaw = RootTab.home.rawValue

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
                #if DEBUG
                if AppQARoute.current == nil {
                    selectedTab = RootTab(rawValue: lastRootTabRaw) ?? .home
                }
                #else
                selectedTab = RootTab(rawValue: lastRootTabRaw) ?? .home
                #endif
            }

            Group {
                if isPrivacyScreenVisible {
                    privacyScreen
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .animation(AppMotion.fade, value: isPrivacyScreenVisible)

            Group {
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
            .animation(AppMotion.bounce, value: toast?.id)

            RootStoreMaintenanceObserver(
                sceneIsActive: scenePhase == .active,
                openActionItemCount: $openActionItemCount,
                onToast: { toast = $0 }
            )
        }
        .onChange(of: scenePhase) { _, phase in
            withAnimation(AppMotion.fade) {
                isPrivacyScreenVisible = phase != .active
            }
            if phase == .active {
                store.enforceRetentionPolicies()
                drainPendingCaptureIntents()
            } else {
                Task { await store.flushPersistence() }
            }
        }
        .onChange(of: selectedTab) { _, tab in
            lastRootTabRaw = tab.rawValue
        }
        .onContinueUserActivity(SpotlightIndex.activityType) { activity in
            handleSpotlightActivity(activity)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            handleSpotlightActivity(activity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeflowOpenMeeting)) { note in
            if let meetingID = note.object as? Meeting.ID {
                openMeeting(meetingID)
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
        .onChange(of: pendingInbox.openMeetingID) { _, meetingID in
            if meetingID != nil { drainPendingCaptureIntents() }
        }
        .task { drainPendingCaptureIntents() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await MeetingProcessingCoordinator.shared.resume(using: store)
            await TranscriptionRecoveryCoordinator.shared.processPending(using: store)
        }
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
        }
    }

    @ViewBuilder
    private var privacyScreen: some View {
        ZStack {
            Rectangle()
                .fill(reduceTransparency ? AnyShapeStyle(AppPalette.paper) : AnyShapeStyle(.ultraThinMaterial))
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ScribeflowBrandMark(size: 64)
                    .opacity(0.92)
                Text("SCRIBEFLOW")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.ink.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private var rootDock: some View {
        if selectedNavigationDepth == 0 {
            RootTabBar(
                items: [
                    RootTabBarItem(id: RootTab.home.rawValue, label: AppStrings.Navigation.today, systemImage: "house"),
                    RootTabBarItem(id: RootTab.library.rawValue, label: AppStrings.Navigation.library, systemImage: "rectangle.stack"),
                    RootTabBarItem(id: RootTab.tasks.rawValue, label: AppStrings.Navigation.tasks, systemImage: "checklist", badge: openActionItemCount),
                    RootTabBarItem(id: RootTab.calendar.rawValue, label: AppStrings.Navigation.calendar, systemImage: "calendar"),
                    RootTabBarItem(id: RootTab.ask.rawValue, label: AppStrings.Navigation.ask, systemImage: "magnifyingglass")
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

    private var mainTabs: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                NavigationStack(path: $homePath) {
                    TodayView(
                        isActive: selectedTab == .home,
                        selectedMeetingID: $selectedMeetingID,
                        onCapture: { mode in captureMode = mode },
                        onSettingsTap: { showingSettings = true },
                        onAskTap: { activateRootTab(.ask) },
                        onTasksTap: { activateRootTab(.tasks) },
                        onLibraryTap: { activateRootTab(.library) },
                        toast: $toast
                    )
                    .toolbar(.hidden, for: .tabBar)
                }
                .tag(RootTab.home)

                NavigationStack(path: $libraryPath) {
                    MeetingsView(
                        isActive: selectedTab == .library,
                        selectedMeetingID: $selectedMeetingID,
                        onAskTap: { activateRootTab(.ask) },
                        toast: $toast
                    )
                    .toolbar(.hidden, for: .tabBar)
                }
                .tag(RootTab.library)

                NavigationStack(path: $tasksPath) {
                    ActionItemsView(
                        isActive: selectedTab == .tasks,
                        selectedMeetingID: $selectedMeetingID,
                        toast: $toast
                    )
                    .toolbar(.hidden, for: .tabBar)
                }
                .tag(RootTab.tasks)

                NavigationStack(path: $calendarPath) {
                    MeetingCalendarView(
                        isActive: selectedTab == .calendar,
                        selectedMeetingID: $selectedMeetingID,
                        onCapture: { mode in captureMode = mode },
                        toast: $toast
                    )
                    .toolbar(.hidden, for: .tabBar)
                }
                .tag(RootTab.calendar)

                NavigationStack(path: $askPath) {
                    AskView(isActive: selectedTab == .ask)
                        .toolbar(.hidden, for: .tabBar)
                }
                .tag(RootTab.ask)
            }
            .toolbar(.hidden, for: .tabBar)
            .tint(AppPalette.accent)

            if selectedNavigationDepth == 0 {
                RootDockChrome {
                    rootDock
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(AppPalette.background.ignoresSafeArea())
        .modifier(ScribeflowChrome())
    }

    private var selectedNavigationDepth: Int {
        switch selectedTab {
        case .home: homePath.count
        case .library: libraryPath.count
        case .tasks: tasksPath.count
        case .calendar: calendarPath.count
        case .ask: askPath.count
        }
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
        openMeeting(uuid)
    }

    /// Drain Siri / Shortcuts pending intents into UI state. Called when the
    /// scene becomes active and whenever the inbox publishes a new request,
    /// covering both cold-launch and warm-resume paths.
    private func drainPendingCaptureIntents() {
        if let meetingID = pendingInbox.openMeetingID {
            pendingInbox.openMeetingID = nil
            openMeeting(meetingID)
        }
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
                openMeeting(latest.id)
            }
        }
        if pendingInbox.openAskRequested {
            pendingInbox.openAskRequested = false
            activateRootTab(.ask)
        }
    }

    private func openMeeting(_ meetingID: Meeting.ID) {
        guard store.meeting(withID: meetingID) != nil else { return }
        selectedMeetingID = meetingID
        activateRootTab(.library)
        libraryPath = NavigationPath()
        libraryPath.append(meetingID)
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
