import SwiftUI

@MainActor
final class ScribeflowRuntime {
    static let shared = ScribeflowRuntime()

    let store: MeetingStore

    private init() {
        let store = MeetingStore()
        self.store = store
        MeetingProcessingCoordinator.shared.attach(store)
    }
}

@main
@MainActor
struct ScribeflowApp: App {
    @UIApplicationDelegateAdaptor(ScribeflowAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: MeetingStore
    @State private var authSession = AuthSessionStore()
    @State private var showingSplash = !UserDefaults.standard.bool(forKey: "hasCompletedLaunchOnboarding")
    @AppStorage("hasCompletedLaunchOnboarding") private var hasCompletedLaunchOnboarding = false
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage("scribeflow.requireAppUnlock") private var requireAppUnlock = false

    init() {
        _store = State(initialValue: ScribeflowRuntime.shared.store)
        NotificationRouter.shared.configure()
        MetricsSubscriber.shared.start()
        AnalyticsLog.shared.log("app.launch")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Group {
                    if store.isLoadingLibrary {
                        LibraryLaunchProgressView(stage: store.libraryLoadingStage)
                    } else {
                        #if DEBUG
                        ContentView()
                            .environment(store)
                        #else
                        if hasCompletedLaunchOnboarding {
                            if requireAppUnlock {
                                AuthGateView {
                                    ContentView()
                                        .environment(store)
                                }
                            } else {
                                ContentView()
                                    .environment(store)
                            }
                        } else {
                            LaunchOnboardingView {
                                hasCompletedLaunchOnboarding = true
                            }
                        }
                        #endif
                    }
                }
                .environment(authSession)
                .preferredColorScheme(AppearancePreference(rawValue: appearanceRaw)?.colorScheme)
                .onOpenURL { url in
                    // OAuth callback from Google Sign-In (no-op if SDK is not yet linked).
                    GoogleSignInURLHandler.handle(url)
                }

                if showingSplash {
                    SplashView { withAnimation(.easeOut(duration: 0.5)) { showingSplash = false } }
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .task {
                await store.loadLibraryIfNeeded()
                await MeetingProcessingCoordinator.shared.resume(using: store)
                store.enforceRetentionPolicies()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, requireAppUnlock {
                    authSession.lock()
                } else if phase == .active, store.hasLoadedLibrary {
                    store.enforceRetentionPolicies()
                }
            }
        }
        .commands {
            // Hardware-keyboard / Mac Catalyst shortcuts. Each routes through
            // `PendingCaptureInbox`, which the root scene drains identically
            // to Siri/Shortcuts requests.
            CommandGroup(after: .newItem) {
                Button("Start Recording") {
                    PendingCaptureInbox.shared.requestStartRecord()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("New Quick Note") {
                    PendingCaptureInbox.shared.requestStartType()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Last Meeting") {
                    PendingCaptureInbox.shared.requestOpenLastMeeting()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Ask Across Notes") {
                    PendingCaptureInbox.shared.requestOpenAsk()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

private struct LibraryLaunchProgressView: View {
    let stage: String

    var body: some View {
        ZStack {
            AppPalette.background
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ScribeflowBrandMark(size: 58)

                ProgressView()
                    .controlSize(.regular)
                    .tint(AppPalette.accent)

                Text(stage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(stage)
        }
    }
}

private struct LaunchOnboardingView: View {
    @State private var page = 0
    @State private var showCompletionPulse = false
    let onComplete: () -> Void

    private let pages: [LaunchOnboardingPage] = [
        LaunchOnboardingPage(
            eyebrow: "CAPTURE",
            title: "Capture anything.",
            subtitle: "Start with a meeting, voice note, or quick thought. Scribeflow keeps the original source and organizes it after you save.",
            systemImage: "sparkles.rectangle.stack.fill",
            tint: AppPalette.accent
        ),
        LaunchOnboardingPage(
            eyebrow: "REVIEW",
            title: "Understand with sources.",
            subtitle: "Summaries, decisions, and follow-ups stay connected to the note or transcript that supports them.",
            systemImage: "checkmark.seal.fill",
            tint: AppPalette.gold
        ),
        LaunchOnboardingPage(
            eyebrow: "CONTROL",
            title: "You choose what leaves.",
            subtitle: "Your workspace is local-first. You control recording, sharing, export, backup, reminders, and deletion.",
            systemImage: "lock.shield.fill",
            tint: AppPalette.coral
        )
    ]

    var body: some View {
        ZStack {
            AppPalette.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    ScribeflowBrandMark(size: 34)
                    Text("SCRIBEFLOW")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.secondaryInk)
                    Spacer()
                    Button("Skip") {
                        HapticEngine.select()
                        onComplete()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .appTapTarget()
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 8)

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        launchPage(page, index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack(spacing: 16) {
                    HStack(spacing: 7) {
                        ForEach(pages.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == page ? AppPalette.accent : AppPalette.border)
                                .frame(width: index == page ? 28 : 7, height: 6)
                                .animation(AppMotion.snappy, value: page)
                        }
                    }

                    Button {
                        HapticEngine.tap(.medium)
                        if page < pages.count - 1 {
                            withAnimation(AppMotion.smooth) { page += 1 }
                        } else {
                            withAnimation(AppMotion.smooth) { showCompletionPulse = true }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(280))
                                onComplete()
                            }
                        }
                    } label: {
                        LaunchActionLabel(
                            title: page == pages.count - 1 ? "Enter Scribeflow" : "Continue",
                            subtitle: page == pages.count - 1 ? "Open your workspace" : "See how it works",
                            systemImage: page == pages.count - 1 ? "checkmark.seal.fill" : "arrow.right",
                            tint: AppPalette.ink,
                            isPrimary: true
                        )
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.98))
                    .accessibilityIdentifier("onboarding.continueButton")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 26)
            }

            if showCompletionPulse {
                Color.white.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
    }

    private func launchPage(_ page: LaunchOnboardingPage, index: Int) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: 22) {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                                .fill(page.tint.opacity(0.12))
                            Image(systemName: page.systemImage)
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(page.tint)
                        }
                        .frame(width: 68, height: 68)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(page.eyebrow)
                                .font(AppFont.mono(.caption2, weight: .medium))
                                .foregroundStyle(page.tint)
                            Text(page.title)
                                .font(AppFont.serif(.largeTitle, weight: .medium))
                                .foregroundStyle(AppPalette.ink)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(page.subtitle)
                                .font(.body)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("0\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.secondaryInk.opacity(0.55))
                }

                if index == 1 {
                    PremiumPanel(cornerRadius: 28, contentPadding: 20) {
                        WorkflowRailStep(index: 1, title: "Capture", detail: "Live meeting, voice note, phone-call note, or quick note.", systemImage: "waveform.badge.mic", tint: AppPalette.accent)
                        Divider()
                        WorkflowRailStep(index: 2, title: "Review", detail: "Confirm actions, decisions, and risks.", systemImage: "checklist.checked", tint: AppPalette.gold)
                        Divider()
                        WorkflowRailStep(index: 3, title: "Recall", detail: "Ask across notes or share a clean brief.", systemImage: "quote.bubble.fill", tint: AppPalette.coral)
                    }
                } else if index == 2 {
                    PremiumPanel(cornerRadius: 28, contentPadding: 20) {
                        WorkflowRailStep(index: 1, title: "Voice notes", detail: "Record, transcribe, attach, and play back from Library.", systemImage: "waveform.badge.mic", tint: AppPalette.accent)
                        Divider()
                        WorkflowRailStep(index: 2, title: "Call limits", detail: "Use typed call notes. Scribeflow cannot capture audio from another app.", systemImage: "phone.badge.waveform", tint: AppPalette.gold)
                        Divider()
                        WorkflowRailStep(index: 3, title: "Control", detail: "Delete recordings locally or export only when you choose.", systemImage: "lock.shield.fill", tint: AppPalette.coral)
                    }
                } else {
                    Label("Private by default. No account required for local use.", systemImage: "lock.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 18)
        }
    }
}

private struct LaunchOnboardingPage {
    let eyebrow: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
}

/// First-run bridge between the native launch frame and onboarding. Returning
/// users skip it so launch never waits on decorative animation.
private struct SplashView: View {
    var onComplete: () -> Void = {}

    @State private var markIn = false
    @State private var ringExpand = false
    @State private var textIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .strokeBorder(AppPalette.accent.opacity(0.20), lineWidth: 1)
                        .frame(width: 112, height: 112)
                        .scaleEffect(ringExpand ? 1 : 0.78)
                        .opacity(ringExpand ? 1 : 0)
                    ScribeflowBrandMark(size: 72)
                }
                .scaleEffect(markIn ? 1 : 0.82)
                .opacity(markIn ? 1 : 0)

                VStack(spacing: 7) {
                    Text("Scribeflow")
                        .font(AppFont.serif(.largeTitle, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("CAPTURE. UNDERSTAND. REMEMBER.")
                        .font(AppFont.mono(.caption2, weight: .semibold))
                        .foregroundStyle(AppPalette.accent)
                }
                .opacity(textIn ? 1 : 0)
                .offset(y: textIn ? 0 : 12)
            }
            .padding(24)
        }
        .onAppear(perform: run)
    }

    private func run() {
        if reduceMotion {
            markIn = true; ringExpand = true; textIn = true
            DispatchQueue.main.async { onComplete() }
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { markIn = true }
        withAnimation(.easeOut(duration: 0.45)) { ringExpand = true }
        withAnimation(.easeOut(duration: 0.32).delay(0.12)) { textIn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { onComplete() }
    }
}
