import SwiftUI

@main
struct ScribeflowApp: App {
    @State private var store = MeetingStore()
    @State private var authSession = AuthSessionStore()
    @State private var showingSplash = true
    @AppStorage("hasCompletedLaunchOnboarding") private var hasCompletedLaunchOnboarding = false
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue

    init() {
        MetricsSubscriber.shared.start()
        AnalyticsLog.shared.log("app.launch")
    }
 
    var body: some Scene {
        WindowGroup {
            ZStack {
                LocalAuthFlow {
                    ContentView()
                        .environment(store)
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

private struct LaunchOnboardingView: View {
    @State private var page = 0
    @State private var showCompletionPulse = false
    let onComplete: () -> Void

    private let pages: [LaunchOnboardingPage] = [
        LaunchOnboardingPage(
            eyebrow: "MEETING MEMORY",
            title: "Talk it through.\nKeep it all.",
            subtitle: "Hit record and talk. Scribeflow turns it into clean notes, decisions, and follow-ups — so nothing slips between meetings.",
            systemImage: "sparkles.rectangle.stack.fill",
            tint: AppPalette.accent
        ),
        LaunchOnboardingPage(
            eyebrow: "THE FLOW",
            title: "One path, three moves.",
            subtitle: "Capture the rough version, review the digest, then ask or share from the polished record.",
            systemImage: "arrow.triangle.branch",
            tint: AppPalette.gold
        ),
        LaunchOnboardingPage(
            eyebrow: "PRIVATE BY DESIGN",
            title: "Record clearly.\nKnow the limits.",
            subtitle: "Voice notes stay protected on device. Scribeflow cannot record cellular, FaceTime, WhatsApp, or audio from other apps.",
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
                    Image(decorative: "BrandMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                    Text("SCRIBEFLOW")
                        .font(.caption.weight(.bold))
                        .kerning(2.0)
                        .foregroundStyle(AppPalette.secondaryInk)
                    Spacer()
                    Button("Skip") {
                        HapticEngine.select()
                        onComplete()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
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
                PremiumPanel(cornerRadius: 34, contentPadding: 24) {
                    ZStack(alignment: .topTrailing) {
                        VStack(alignment: .leading, spacing: 22) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(page.tint.opacity(0.12))
                                Image(systemName: page.systemImage)
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundStyle(page.tint)
                            }
                            .frame(width: 74, height: 74)

                            VStack(alignment: .leading, spacing: 10) {
                                Text(page.eyebrow)
                                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                                    .kerning(0.9)
                                    .foregroundStyle(page.tint)
                                Text(page.title)
                                    .font(.system(size: 34, weight: .medium, design: .serif))
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
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(AppPalette.softSurface.opacity(0.8), in: Capsule())
                    }
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
                        WorkflowRailStep(index: 2, title: "Call limits", detail: "Use call notes or a compliant provider flow. No private APIs.", systemImage: "phone.badge.waveform", tint: AppPalette.gold)
                        Divider()
                        WorkflowRailStep(index: 3, title: "Control", detail: "Delete recordings locally or export only when you choose.", systemImage: "lock.shield.fill", tint: AppPalette.coral)
                    }
                } else {
                    HStack(spacing: 12) {
                        ProductMetric(value: "4", label: "Capture modes", tint: AppPalette.accent)
                        ProductMetric(value: "1", label: "Memory library", tint: AppPalette.gold)
                    }
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

/// Launch splash. A deep brand-gradient stage with a glowing brand disc that
/// springs in, wordmark + tagline that rise behind it, then the whole thing
/// fades out to reveal the app. Self-times its own dismissal via `onComplete`.
private struct SplashView: View {
    var onComplete: () -> Void = {}

    @State private var markIn = false
    @State private var ringExpand = false
    @State private var textIn = false
    @State private var halo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let stage = Color(red: 0.039, green: 0.055, blue: 0.071)        // near-black
    private let captureGreen = Color(red: 0.490, green: 0.820, blue: 0.639) // #7DD1A3

    var body: some View {
        ZStack {
            // Deep cinematic brand gradient.
            LinearGradient(
                colors: [
                    Color(red: 0.043, green: 0.063, blue: 0.078),
                    Color(red: 0.047, green: 0.184, blue: 0.196),
                    Color(red: 0.082, green: 0.345, blue: 0.353)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Soft drifting halo for depth.
            Circle()
                .fill(RadialGradient(
                    colors: [captureGreen.opacity(0.22), .clear],
                    center: .center, startRadius: 0, endRadius: 260))
                .frame(width: 520, height: 520)
                .scaleEffect(halo ? 1.08 : 0.9)
                .opacity(halo ? 0.9 : 0.55)
                .blur(radius: 20)
                .offset(y: -40)
                .allowsHitTesting(false)

            VStack(spacing: 22) {
                // Brand disc — concentric ring + glass mark.
                ZStack {
                    Circle()
                        .strokeBorder(captureGreen.opacity(0.35), lineWidth: 1.2)
                        .frame(width: 140, height: 140)
                        .scaleEffect(ringExpand ? 1 : 0.6)
                        .opacity(ringExpand ? 1 : 0)

                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(captureGreen.opacity(0.16)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                        .frame(width: 104, height: 104)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 14)

                    Image(decorative: "BrandMark")
                        .resizable().scaledToFit()
                        .frame(width: 50, height: 50)
                }
                .scaleEffect(markIn ? 1 : 0.82)
                .opacity(markIn ? 1 : 0)

                VStack(spacing: 10) {
                    Text("Scribeflow")
                        .font(.system(size: 34, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                    Text("MEETINGS, REMEMBERED")
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .kerning(2.2)
                        .foregroundStyle(captureGreen.opacity(0.85))
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onComplete() }
            return
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { markIn = true }
        withAnimation(.easeOut(duration: 0.9)) { ringExpand = true }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { halo = true }
        withAnimation(.easeOut(duration: 0.6).delay(0.28)) { textIn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { onComplete() }
    }
}
