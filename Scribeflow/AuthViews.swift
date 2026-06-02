import AuthenticationServices
import AVFoundation
import SwiftUI

/// Auth surface tokens — forward to the shared AppPalette so brand colors
/// stay in lockstep across login, settings, and the main app.
private enum AuthPalette {
    static let surface = AppPalette.cardBackground
    static let elevated = AppPalette.softSurface
    static let ink = AppPalette.ink
    static let secondaryInk = AppPalette.secondaryInk
    static let tertiaryInk = AppPalette.tertiaryInk
    static let accent = AppPalette.accent
    static let gold = AppPalette.gold
    static let coral = AppPalette.coral
}

struct AuthGateView<AuthenticatedContent: View>: View {
    @Environment(AuthSessionStore.self) private var authSession
    @ViewBuilder var authenticatedContent: () -> AuthenticatedContent

    var body: some View {
        Group {
            switch authSession.phase {
            case .checking:
                AuthLoadingView()
            case .signedOut, .locked:
                AuthenticationView()
            case .authenticated:
                authenticatedContent()
            }
        }
        .animation(AppMotion.smooth, value: authSession.phase)
    }
}

private struct AuthLoadingView: View {
    var body: some View {
        ZStack {
            AuthBackground()
            VStack(spacing: 16) {
                Image(decorative: "BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 5)
                ProgressView()
                    .tint(AuthPalette.accent)
            }
        }
    }
}

struct AuthenticationView: View {
    @Environment(AuthSessionStore.self) private var authSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false

    var body: some View {
        ZStack {
            AuthBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    authHeader
                    authCard
                    trustFooter
                }
                .padding(.horizontal, 22)
                .padding(.top, 32)
                .padding(.bottom, 34)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task {
            guard !appeared else { return }
            withAnimation(reduceMotion ? nil : AppMotion.smooth.delay(0.08)) {
                appeared = true
            }
        }
    }

    private var authHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppPalette.softSurface)
                    .frame(width: 54, height: 54)
                    .overlay(
                        Image(decorative: "BrandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text("SCRIBEFLOW")
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .kerning(0.9)
                        .foregroundStyle(AuthPalette.tertiaryInk)
                    Text("Sign in to start")
                        .font(.system(.title, design: .serif).weight(.semibold))
                        .foregroundStyle(AuthPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Text("Your meetings, transcripts, and notes stay on this device.")
                .font(.subheadline)
                .foregroundStyle(AuthPalette.secondaryInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .locked(let session) = authSession.phase {
                lockedSessionCard(session)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if let message = authSession.errorMessage {
                AuthStatusBanner(message: message, systemImage: "info.circle.fill", tint: AuthPalette.coral)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let message = authSession.successMessage {
                AuthStatusBanner(message: message, systemImage: "checkmark.circle.fill", tint: AuthPalette.accent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                Task { await authSession.submitDeviceSignIn() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: DeviceAuthCapability.systemImage)
                        .font(.body.weight(.semibold))
                    Text(DeviceAuthCapability.label)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(AppPalette.accentButton, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: AppPalette.accent.opacity(0.22), radius: 12, y: 6)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityIdentifier("auth.signInWithDevice")
            .disabled(authSession.isLoading)

            HStack(spacing: 10) {
                Rectangle()
                    .fill(AuthPalette.secondaryInk.opacity(0.18))
                    .frame(height: 0.6)
                Text("OR")
                    .font(.caption2.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(AuthPalette.secondaryInk.opacity(0.7))
                Rectangle()
                    .fill(AuthPalette.secondaryInk.opacity(0.18))
                    .frame(height: 0.6)
            }
            .padding(.vertical, 2)

            // Sign in with Apple — required by App Store when any social
            // login is offered. Stays available even without a backend
            // because Apple owns the auth surface; we just persist the
            // returned credential locally.
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task { await authSession.completeAppleSignIn(result: result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .accessibilityIdentifier("auth.signInWithApple")
            .disabled(authSession.isLoading)

            if authSession.isLoading {
                HStack(spacing: 10) {
                    ProgressView().tint(AuthPalette.accent)
                    Text("Securing session…")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AuthPalette.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            }
        }
        .padding(20)
        .background(AuthPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .appShadow(AppShadow.card)
    }

    private func lockedSessionCard(_ session: AuthSession) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AuthPalette.accent)
                    .frame(width: 42, height: 42)
                    .background(AuthPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AuthPalette.ink)
                    Text(session.email)
                        .font(.caption)
                        .foregroundStyle(AuthPalette.secondaryInk)
                }

                Spacer(minLength: 0)
            }

            if authSession.canUseBiometrics {
                Button {
                    Task { await authSession.unlockWithBiometrics() }
                } label: {
                    Label("Unlock with \(authSession.biometricLabel)", systemImage: biometricSymbolName)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuthPalette.accent)
                .disabled(authSession.isLoading)
            }
        }
        .padding(14)
        .background(AuthPalette.surface.opacity(0.84), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
    }

    private var trustFooter: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sign in stays on this device — nothing is sent to a server.", systemImage: "iphone")
            Label("Face ID, Touch ID, or your passcode prove it's you.", systemImage: "faceid")
            Label("Session token is stored in the iOS Keychain.", systemImage: "key.fill")
        }
        .font(.footnote)
        .foregroundStyle(AuthPalette.tertiaryInk)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .background(AppPalette.softSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var biometricSymbolName: String {
        authSession.biometricLabel == "Touch ID" ? "touchid" : "faceid"
    }

    /// GoogleSignIn needs a UIViewController for its presentation. Walk the
    /// active scene's key window to find the topmost presented controller.
    private func topMostViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        let keyWindow = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

private struct AuthFieldContainer<Content: View>: View {
    enum MessageKind {
        case guidance
        case success
    }

    let title: String
    let message: String?
    let messageKind: MessageKind
    let isFocused: Bool
    @ViewBuilder var content: () -> Content

    private var tint: Color {
        if messageKind == .success && message != nil { return AuthPalette.accent }
        return isFocused ? AuthPalette.accent : AuthPalette.secondaryInk.opacity(0.45)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AuthPalette.secondaryInk)

            content()
                .padding(14)
                .background(AuthPalette.surface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(tint.opacity(isFocused ? 0.75 : 0.36), lineWidth: isFocused ? 1.2 : 0.8)
                        .allowsHitTesting(false)
                )
                .shadow(color: isFocused ? AuthPalette.accent.opacity(0.10) : .clear, radius: 10, y: 5)
                .animation(AppMotion.snappy, value: isFocused)

            if let message {
                Label(message, systemImage: messageKind == .success ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(messageKind == .success ? AuthPalette.accent : AuthPalette.secondaryInk)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(AppMotion.smooth, value: message)
    }
}

private struct AuthStatusBanner: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct AuthBackground: View {
    var body: some View {
        ZStack {
            AppPalette.background
                .ignoresSafeArea()
            AmbientGlow(tint: AppPalette.accent, intensity: 0.25, animated: true)
                .offset(y: -120)
                .ignoresSafeArea()
        }
    }
}

// MARK: - Local credential store (no backend)

import CryptoKit
import LocalAuthentication

struct LocalCredential: Codable {
    var email: String
    var username: String
    var passwordHash: String
    var createdAt: Date = .now
}

enum LocalAuthError: LocalizedError {
    case invalidEmail, weakPassword, usernameTooShort, alreadyExists, notFound, wrongPassword, biometricFailed, mismatch
    var errorDescription: String? {
        switch self {
        case .invalidEmail:      return "That email doesn't look right."
        case .weakPassword:      return "Password needs at least 6 characters."
        case .usernameTooShort:  return "Username needs at least 2 characters."
        case .alreadyExists:     return "An account with that email already exists."
        case .notFound:          return "We couldn't find an account with that email."
        case .wrongPassword:     return "That password doesn't match."
        case .biometricFailed:   return "Couldn't verify with Face ID."
        case .mismatch:          return "Passwords don't match."
        }
    }
}

enum LocalCredentialStore {
    private static let key = "scribeflow.localAccounts.v1"

    private static func load() -> [String: LocalCredential] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: LocalCredential].self, from: data)
        else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: LocalCredential]) {
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func hash(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func register(email: String, username: String, password: String) -> Result<LocalCredential, LocalAuthError> {
        let cleanEmail = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEmail(cleanEmail) else { return .failure(.invalidEmail) }
        guard cleanUser.count >= 2 else { return .failure(.usernameTooShort) }
        guard password.count >= 6 else { return .failure(.weakPassword) }
        var all = load()
        if all[cleanEmail] != nil { return .failure(.alreadyExists) }
        let cred = LocalCredential(email: cleanEmail, username: cleanUser, passwordHash: hash(password))
        all[cleanEmail] = cred
        save(all)
        return .success(cred)
    }

    static func login(email: String, password: String) -> Result<LocalCredential, LocalAuthError> {
        let cleanEmail = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEmail(cleanEmail) else { return .failure(.invalidEmail) }
        let all = load()
        guard let cred = all[cleanEmail] else { return .failure(.notFound) }
        guard cred.passwordHash == hash(password) else { return .failure(.wrongPassword) }
        return .success(cred)
    }

    static func user(forEmail email: String) -> LocalCredential? {
        load()[email.lowercased()]
    }

    private static func isValidEmail(_ e: String) -> Bool {
        let parts = e.split(separator: "@")
        return parts.count == 2 && parts[0].count >= 1 && parts[1].contains(".") && parts[1].count >= 3
    }
}

// MARK: - LocalAuthFlow — wraps the app root

/// Owns the full first-touch flow: onboarding pages → sign up / log in →
/// Face ID enroll (first time) or unlock (subsequent) → app. No backend.
struct LocalAuthFlow<Content: View>: View {
    @AppStorage("hasCompletedLaunchOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("scribeflow.currentUserEmail")  private var currentUserEmail = ""
    @AppStorage("scribeflow.wantsBiometric")    private var wantsBiometric = false
    @AppStorage("scribeflow.bioAsked")          private var bioAsked = false
    @State private var unlocked = false
    @State private var freshSignup = false
    @State private var successUsername: String?
    @State private var initialAuthMode: SignUpLoginView.Mode = .login
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            currentStage
        }
        .animation(AppMotion.smooth, value: hasCompletedOnboarding)
        .animation(AppMotion.smooth, value: currentUserEmail)
        .animation(AppMotion.smooth, value: unlocked)
        .onAppear {
            // Auto-unlock when biometric not enabled.
            if !currentUserEmail.isEmpty, !wantsBiometric { unlocked = true }
        }
    }

    @ViewBuilder
    private var currentStage: some View {
        if let name = successUsername {
            AuthSuccessFlash(name: name)
                .transition(.opacity)
        } else if !hasCompletedOnboarding {
            OnboardingPagesView { mode in
                initialAuthMode = mode
                hasCompletedOnboarding = true
            }
            .transition(.opacity)
        } else if currentUserEmail.isEmpty {
            SignUpLoginView(initialMode: initialAuthMode) { email, isNewUser in
                let user = LocalCredentialStore.user(forEmail: email)?.username ?? ""
                withAnimation(AppMotion.smooth) { successUsername = user }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                    withAnimation(AppMotion.smooth) {
                        currentUserEmail = email
                        freshSignup = isNewUser
                        unlocked = !wantsBiometric
                        successUsername = nil
                    }
                }
            }
            .transition(.opacity)
        } else if freshSignup || (wantsBiometric == false && !bioAsked) {
            // First-time prompt to enable Face ID.
            BiometricEnrollPromptView(
                username: LocalCredentialStore.user(forEmail: currentUserEmail)?.username ?? "",
                onEnable: {
                    enableBiometric()
                },
                onSkip: {
                    bioAsked = true
                    freshSignup = false
                    unlocked = true
                }
            )
            .transition(.opacity)
        } else if wantsBiometric && !unlocked {
            BiometricUnlockView(
                username: LocalCredentialStore.user(forEmail: currentUserEmail)?.username ?? "",
                onUnlock: { unlocked = true },
                onLogout: {
                    currentUserEmail = ""
                    unlocked = false
                }
            )
            .transition(.opacity)
        } else {
            content
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
        }
    }

    private func enableBiometric() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            // No biometrics available — just skip.
            bioAsked = true; freshSignup = false; unlocked = true
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "Use Face ID to unlock Scribeflow") { success, _ in
            DispatchQueue.main.async {
                bioAsked = true
                freshSignup = false
                if success {
                    HapticEngine.notify(.success)
                    wantsBiometric = true
                }
                unlocked = true
            }
        }
    }
}


// MARK: - Onboarding — flagship first-run (single screen)

/// First-run flow, redesigned as a four-step paged journey:
/// Welcome (dark) → Microphone → Calendar → Default template. Each step sets
/// its own surface; the dark welcome forces brand-cream colors regardless of
/// system appearance. Permission steps fire the real OS prompts then advance.
struct OnboardingPagesView: View {
    let onDone: (SignUpLoginView.Mode) -> Void
    @AppStorage("defaultNoteTemplate") private var defaultTemplateRaw = NoteTemplate.discovery.rawValue
    @State private var page = 0
    @State private var selectedTemplate: NoteTemplate = .discovery
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Fixed brand-stage colors for the forced-dark welcome screen.
    private let stage = Color(red: 0.059, green: 0.067, blue: 0.082)      // #0F1115
    private let stageInk = Color(red: 0.953, green: 0.941, blue: 0.910)   // #F3F0E8
    private let captureGreen = Color(red: 0.490, green: 0.820, blue: 0.639) // #7DD1A3

    private struct OnbTemplate: Identifiable {
        let template: NoteTemplate
        let name: String
        let desc: String
        var id: String { template.rawValue }
    }
    private let templates: [OnbTemplate] = [
        OnbTemplate(template: .discovery, name: "Discovery & sales", desc: "Decisions, objections, next steps"),
        OnbTemplate(template: .standup,   name: "Standup & sync",    desc: "Updates, blockers, action items"),
        OnbTemplate(template: .manager,   name: "1:1 & coaching",    desc: "Themes, commitments, follow-ups"),
        OnbTemplate(template: .exec,      name: "Plain notes",       desc: "Just the transcript and summary")
    ]

    var body: some View {
        ZStack {
            (page == 0 ? AnyView(stage.ignoresSafeArea()) : AnyView(AppPalette.background.ignoresSafeArea()))

            Group {
                switch page {
                case 0:  welcomeStep
                case 1:  micStep
                case 2:  calendarStep
                default: templateStep
                }
            }
            .id(page)
            .transition(pageTransition)
        }
        .animation(reduceMotion ? nil : AppMotion.smooth, value: page)
        .onAppear {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-OnbPage"), args.indices.contains(i + 1), let p = Int(args[i + 1]) {
                page = max(0, min(3, p))
            }
            #endif
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 6.0).repeatForever(autoreverses: true)) { glow.toggle() }
        }
    }

    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: 40)),
                removal: .opacity.combined(with: .offset(x: -40))
            )
    }

    // MARK: Navigation

    private func advance() {
        withAnimation(reduceMotion ? nil : AppMotion.smooth) { page = min(3, page + 1) }
    }
    private func back() {
        HapticEngine.tap(.light)
        withAnimation(reduceMotion ? nil : AppMotion.smooth) { page = max(0, page - 1) }
    }
    private func finish() {
        defaultTemplateRaw = selectedTemplate.rawValue
        HapticEngine.tap(.medium)
        onDone(.signUp)
    }
    private func requestMic() {
        AVAudioApplication.requestRecordPermission { _ in
            DispatchQueue.main.async { advance() }
        }
    }
    private func requestCalendar() {
        Task {
            _ = await UpcomingEventsService.shared.requestAccessIfNeeded()
            await MainActor.run { advance() }
        }
    }

    // MARK: 1 — Welcome (dark)

    private var welcomeStep: some View {
        ZStack {
            // Ambient teal glow, top-center.
            Circle()
                .fill(RadialGradient(
                    colors: [AppPalette.accent.opacity(0.55), .clear],
                    center: .center, startRadius: 0, endRadius: 230))
                .frame(width: 460, height: 360)
                .offset(x: glow ? 24 : -24, y: -176)
                .blur(radius: 32)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(captureGreen)
                        Image(systemName: "waveform").font(.system(size: 17, weight: .bold)).foregroundStyle(stage)
                    }
                    .frame(width: 34, height: 34)
                    Text("Scribeflow").font(.system(size: 20, weight: .medium, design: .serif)).foregroundStyle(stageInk)
                }
                .padding(.top, 64)

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 18) {
                    Text("MEETINGS, REMEMBERED")
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .kerning(1.1)
                        .foregroundStyle(captureGreen)
                    (Text("Every word\ncaptured.\n").foregroundStyle(stageInk)
                        + Text("Nothing lost.").foregroundStyle(.white.opacity(0.45)))
                        .font(.system(size: 40, weight: .medium, design: .serif))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Record, transcribe, and turn any conversation into decisions and follow-ups — automatically.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300, alignment: .leading)
                }

                Spacer(minLength: 28)

                VStack(spacing: 0) {
                    dots(active: 0, dark: true)
                    bigButton("Get started", bg: captureGreen, fg: stage) {
                        HapticEngine.tap(.medium); advance()
                    }
                    .padding(.top, 20)
                    Button {
                        HapticEngine.tap(.light); onDone(.login)
                    } label: {
                        (Text("Already have an account? ").foregroundStyle(.white.opacity(0.5))
                            + Text("Sign in").foregroundStyle(captureGreen))
                            .font(.system(size: 13, weight: .medium))
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding.haveAccount")
                }
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    // MARK: 2 — Microphone

    private var micStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            backRow.padding(.top, 52)

            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous).fill(AppPalette.accentSoft)
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(AppPalette.accent.opacity(0.15), lineWidth: 1)
                Image(systemName: "mic.fill").font(.system(size: 48, weight: .regular)).foregroundStyle(AppPalette.accent)
            }
            .frame(width: 132, height: 132)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)

            VStack(spacing: 12) {
                stepEyebrow("STEP 1 OF 3", center: true)
                Text("Let Scribeflow\nhear the room")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .foregroundStyle(AppPalette.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                Text("Microphone access lets us transcribe live. Audio is processed on-device — nothing is stored without your say-so.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 290)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)

            VStack(spacing: 0) {
                reassureRow("On-device transcription by default")
                reassureRow("Delete any recording in one tap")
            }
            .padding(.top, 24)

            Spacer(minLength: 16)

            VStack(spacing: 0) {
                dots(active: 1)
                bigButton("Allow microphone", bg: AppPalette.accent, fg: .white) { requestMic() }
                    .padding(.top, 20)
                subtleButton("Maybe later") { advance() }
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    // MARK: 3 — Calendar

    private var calendarStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            backRow.padding(.top, 52)

            VStack(alignment: .leading, spacing: 12) {
                stepEyebrow("STEP 2 OF 3")
                Text("Know what's\ncoming up")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(2)
                Text("Connect a calendar and Scribeflow will be ready to capture the moment each meeting starts.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 290, alignment: .leading)
            }
            .padding(.top, 36)

            VStack(spacing: 0) {
                calRow(time: "11:30", title: "AllFound — pricing & rollout", live: true)
                EditorialRule()
                calRow(time: "14:00", title: "Weekly 1:1 with Nora", live: false)
                EditorialRule()
                calRow(time: "16:30", title: "Standup — pricing pod", live: false)
            }
            .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.8))
            .padding(.top, 28)

            HStack(spacing: 8) {
                providerChip("Google")
                providerChip("Outlook")
                providerChip("iCloud")
            }
            .padding(.top, 14)

            Spacer(minLength: 16)

            VStack(spacing: 0) {
                dots(active: 2)
                bigButton("Connect calendar", bg: AppPalette.accent, fg: .white) { requestCalendar() }
                    .padding(.top, 20)
                subtleButton("Skip for now") { advance() }
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    // MARK: 4 — Default template

    private var templateStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                stepEyebrow("STEP 3 OF 3").padding(.top, 56)
                Text("How do you\nmeet most?")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(2)
                Text("Pick a default template. You can change it per meeting anytime.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(templates) { t in
                    templateCard(t)
                }
            }
            .padding(.top, 24)

            Spacer(minLength: 16)

            VStack(spacing: 0) {
                dots(active: 3)
                bigButton("Start using Scribeflow", bg: AppPalette.ink, fg: AppPalette.cardBackground) { finish() }
                    .padding(.top, 20)
                    .accessibilityIdentifier("onboarding.getStarted")
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    private func templateCard(_ t: OnbTemplate) -> some View {
        let on = selectedTemplate == t.template
        return Button {
            HapticEngine.select()
            withAnimation(AppMotion.snappy) { selectedTemplate = t.template }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(on ? AppPalette.accent : AppPalette.border, lineWidth: 1.5)
                        .background(Circle().fill(on ? AppPalette.accent : .clear))
                        .frame(width: 20, height: 20)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name)
                        .font(.system(size: 16, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                    Text(t.desc)
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppPalette.secondaryInk)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? AppPalette.accentSoft : AppPalette.paper,
                        in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(on ? AppPalette.accent : AppPalette.border.opacity(0.7), lineWidth: 1.5))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.98))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel("\(t.name). \(t.desc)")
    }

    // MARK: Shared pieces

    private func dots(active: Int, dark: Bool = false) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i == active
                          ? (dark ? captureGreen : AppPalette.accent)
                          : (dark ? Color.white.opacity(0.18) : AppPalette.border))
                    .frame(width: i == active ? 22 : 6, height: 6)
                    .animation(reduceMotion ? nil : AppMotion.snappy, value: active)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func bigButton(_ title: String, bg: Color, fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Capsule().fill(bg))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.97))
    }

    private func subtleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticEngine.tap(.light); action()
        } label: {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.secondaryInk)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var backRow: some View {
        Button(action: back) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                Text("Back").font(.system(size: 14))
            }
            .foregroundStyle(AppPalette.secondaryInk)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepEyebrow(_ text: String, center: Bool = false) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .kerning(1.1)
            .foregroundStyle(AppPalette.accent)
            .frame(maxWidth: .infinity, alignment: center ? .center : .leading)
    }

    private func reassureRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(AppPalette.success.opacity(0.18)).frame(width: 20, height: 20)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(AppPalette.success)
            }
            Text(text).font(.system(size: 13.5)).foregroundStyle(AppPalette.secondaryInk)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { EditorialRule() }
    }

    private func calRow(time: String, title: String, live: Bool) -> some View {
        HStack(spacing: 14) {
            Text(time)
                .font(.system(size: 12, weight: live ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(live ? AppPalette.accent : AppPalette.tertiaryInk)
                .frame(width: 44, alignment: .leading)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if live {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill").font(.system(size: 9, weight: .bold))
                    Text("auto").font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(AppPalette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppPalette.accentSoft, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func providerChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppPalette.secondaryInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(AppPalette.paper, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.7), lineWidth: 1))
    }
}


// MARK: - Sign up / Log in (local)

struct SignUpLoginView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case login = "Log in", signUp = "Sign up"
        var id: String { rawValue }
    }
    let onSuccess: (_ email: String, _ isNewUser: Bool) -> Void

    init(initialMode: Mode = .login,
         onSuccess: @escaping (_ email: String, _ isNewUser: Bool) -> Void) {
        self.onSuccess = onSuccess
        _mode = State(initialValue: initialMode)
    }

    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var showPassword = false
    @State private var isSubmitting = false
    @State private var brandPulse = false
    @FocusState private var focusedField: Field?

    private enum Field { case email, username, password, confirm }

    var body: some View {
        ZStack {
            AmbientAuthBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    brandHeader.padding(.top, 18)
                    Spacer(minLength: 20).fixedSize()
                    focalBrandDisc
                    Spacer(minLength: 18).fixedSize()
                    titleBlock
                    Spacer(minLength: 22).fixedSize()
                    formBlock
                    if let error {
                        errorBanner(error).padding(.top, 10)
                    }
                    Spacer(minLength: 18).fixedSize()
                    submitButton
                    Spacer(minLength: 20).fixedSize()
                    footerDock
                    Spacer(minLength: 18).fixedSize()
                }
                .frame(maxWidth: 340, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(AppMotion.smooth, value: mode)
        .onChange(of: mode) { _, _ in
            error = nil
            focusedField = mode == .login ? .email : .username
        }
        .onAppear { brandPulse = true }
    }

    /// Small iconic glass disc holding the brand mark. Editorial focal point
    /// that anchors the auth screen before any text.
    private var focalBrandDisc: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [AppPalette.accent.opacity(0.30), .clear],
                    center: .center, startRadius: 0, endRadius: 90))
                .frame(width: 160, height: 160)
                .blur(radius: 14)
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().fill(LinearGradient(
                    colors: [AppPalette.accent.opacity(0.22), AppPalette.gold.opacity(0.10)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(decorative: "BrandMark")
                    .resizable().scaledToFit()
                    .frame(width: 36, height: 36)
            }
            .frame(width: 84, height: 84)
            .overlay(Circle().strokeBorder(AppPalette.accent.opacity(0.28), lineWidth: 1))
            .shadow(color: AppPalette.accent.opacity(0.24), radius: 18, y: 10)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// Footer that pairs the storage note + mode-swap link, separated from the
    /// form by a hairline rule — feels like a deliberate dock, not loose text.
    private var footerDock: some View {
        VStack(spacing: 14) {
            Rectangle()
                .fill(AppPalette.border.opacity(0.7))
                .frame(height: 1)
            footerStorageNote
            modeSwap
        }
    }

    // MARK: Sections

    private var brandHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(AppPalette.accent.opacity(0.14)).frame(width: 32, height: 32)
                    Image(decorative: "BrandMark")
                        .resizable().scaledToFit().frame(width: 20, height: 20)
                }
                .scaleEffect(brandPulse ? 1.05 : 0.95)
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: brandPulse)

                Text("SCRIBEFLOW")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .kerning(1.4)
                    .foregroundStyle(AppPalette.tertiaryInk)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("ON DEVICE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .kerning(0.8)
                }
                .foregroundStyle(AppPalette.tertiaryInk)
            }
            Rectangle()
                .fill(AppPalette.border.opacity(0.7))
                .frame(height: 1)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Capsule().fill(AppPalette.accent).frame(width: 22, height: 3)
                Text(mode == .login ? "SIGN IN" : "CREATE ACCOUNT")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .kerning(1.1)
                    .foregroundStyle(AppPalette.accent)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)
            EditorialEyebrow(text: mode == .login ? "Welcome back" : "A clean slate",
                             tint: AppPalette.accent)
            Text(mode == .login ? "Sign in." : "One step\nto begin.")
                .scaledFont(size: 38, weight: .medium, design: .serif, relativeTo: .largeTitle)
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(mode == .login
                 ? "Pick up where you left off on this device."
                 : "Pick an email and a password. Everything stays on this device.")
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.secondaryInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(mode)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity
        ))
    }

    private var formBlock: some View {
        VStack(spacing: 12) {
            if mode == .signUp {
                field("Username", icon: "person.fill", text: $username, focused: .username,
                      contentType: .username, keyboard: .default)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            field("Email", icon: "envelope.fill", text: $email, focused: .email,
                  contentType: .emailAddress, keyboard: .emailAddress)
            passwordField("Password", icon: "lock.fill", text: $password, focused: .password)
            if mode == .signUp && !password.isEmpty {
                PasswordStrengthMeter(password: password)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
            if mode == .signUp {
                passwordField("Confirm password", icon: "lock.shield.fill", text: $confirm, focused: .confirm)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(AppMotion.snappy, value: mode)
        .animation(AppMotion.snappy, value: password.isEmpty)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.coral)
            Text(msg)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppPalette.coral)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppPalette.coral.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(AppPalette.coral.opacity(0.25), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private var submitButton: some View {
        Button {
            HapticEngine.tap(.medium)
            submit()
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView().scaleEffect(0.85).tint(.white)
                } else {
                    Text(mode == .login ? "Log in" : "Create account")
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(AppPalette.accentButton, in: Capsule())
            .shadow(color: AppPalette.accent.opacity(0.32), radius: 14, y: 6)
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        .disabled(isSubmitting)
    }

    private var footerStorageNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.tertiaryInk)
            Text("Stored on this device.")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .kerning(0.4)
                .foregroundStyle(AppPalette.tertiaryInk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(AppPalette.softSurface.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(AppPalette.border, lineWidth: 0.7))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var modeSwap: some View {
        Button {
            HapticEngine.select()
            withAnimation(AppMotion.snappy) { mode = mode == .login ? .signUp : .login }
        } label: {
            HStack(spacing: 4) {
                Text(mode == .login ? "Don't have an account?" : "Already have an account?")
                    .foregroundStyle(AppPalette.secondaryInk)
                Text(mode == .login ? "Sign up" : "Log in")
                    .foregroundStyle(AppPalette.accent)
                    .contentTransition(.opacity)
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Field helpers

    private func field(_ label: String, icon: String, text: Binding<String>, focused: Field, contentType: UITextContentType, keyboard: UIKeyboardType) -> some View {
        let isFocused = focusedField == focused
        return VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .kerning(0.9)
                .foregroundStyle(isFocused ? AppPalette.accent : AppPalette.tertiaryInk)
                .animation(AppMotion.snappy, value: isFocused)
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isFocused ? AppPalette.accent : AppPalette.tertiaryInk)
                    .frame(width: 18)
                TextField("", text: text)
                    .textContentType(contentType)
                    .keyboardType(keyboard)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 15))
                    .foregroundStyle(AppPalette.ink)
                    .focused($focusedField, equals: focused)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? AppPalette.accent : AppPalette.border, lineWidth: isFocused ? 1.5 : 1)
            )
            .shadow(color: isFocused ? AppPalette.accent.opacity(0.18) : .clear, radius: 10, y: 4)
            .animation(AppMotion.snappy, value: isFocused)
        }
    }

    private func passwordField(_ label: String, icon: String, text: Binding<String>, focused: Field) -> some View {
        let isFocused = focusedField == focused
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label.uppercased())
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .kerning(0.9)
                    .foregroundStyle(isFocused ? AppPalette.accent : AppPalette.tertiaryInk)
                    .animation(AppMotion.snappy, value: isFocused)
                Spacer()
                Button { showPassword.toggle() } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isFocused ? AppPalette.accent : AppPalette.tertiaryInk)
                    .frame(width: 18)
                Group {
                    if showPassword {
                        TextField("", text: text)
                    } else {
                        SecureField("", text: text)
                    }
                }
                .textContentType(focused == .password ? .password : .newPassword)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 15))
                .foregroundStyle(AppPalette.ink)
                .focused($focusedField, equals: focused)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? AppPalette.accent : AppPalette.border, lineWidth: isFocused ? 1.5 : 1)
            )
            .shadow(color: isFocused ? AppPalette.accent.opacity(0.18) : .clear, radius: 10, y: 4)
            .animation(AppMotion.snappy, value: isFocused)
        }
    }

    // MARK: Submit

    private func submit() {
        if mode == .signUp && password != confirm {
            HapticEngine.notify(.warning)
            withAnimation(AppMotion.snappy) { error = LocalAuthError.mismatch.errorDescription }
            return
        }
        isSubmitting = true
        let m = mode
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            let result: Result<LocalCredential, LocalAuthError>
            switch m {
            case .login:
                result = LocalCredentialStore.login(email: email, password: password)
            case .signUp:
                result = LocalCredentialStore.register(email: email, username: username, password: password)
            }
            isSubmitting = false
            switch result {
            case .success(let cred):
                HapticEngine.notify(.success)
                onSuccess(cred.email, m == .signUp)
            case .failure(let err):
                HapticEngine.notify(.warning)
                withAnimation(AppMotion.snappy) { error = err.errorDescription }
            }
        }
    }
}

// MARK: - Biometric prompts

struct BiometricEnrollPromptView: View {
    let username: String
    let onEnable: () -> Void
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            AmbientAuthBackdrop()
            VStack(alignment: .leading, spacing: 22) {
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    BiometricRing()
                    Spacer()
                }
                .padding(.bottom, 8)
                Capsule().fill(AppPalette.accent).frame(width: 36, height: 3)
                EditorialEyebrow(text: "One last thing", tint: AppPalette.accent)
                Text("Use Face ID\nto unlock?")
                    .scaledFont(size: 30, weight: .medium, design: .serif, relativeTo: .largeTitle)
                    .foregroundStyle(AppPalette.ink)
                Text("Faster sign-in next time you open Scribeflow. Your password still works as a fallback.")
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    Button { HapticEngine.tap(.medium); onEnable() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "faceid")
                                .font(.body.weight(.semibold))
                            Text("Enable Face ID")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(AppPalette.accentButton, in: Capsule())
                        .shadow(color: AppPalette.accent.opacity(0.28), radius: 12, y: 5)
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.97))

                    Button { HapticEngine.tap(.light); onSkip() } label: {
                        Text("Not now")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
        }
    }
}

struct BiometricUnlockView: View {
    let username: String
    let onUnlock: () -> Void
    let onLogout: () -> Void
    @State private var attempting = false
    @State private var error: String?

    var body: some View {
        ZStack {
            AmbientAuthBackdrop()
            VStack(alignment: .leading, spacing: 22) {
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    BiometricRing()
                    Spacer()
                }
                .padding(.bottom, 8)
                HStack(spacing: 10) {
                    EditorialAvatar(name: username.isEmpty ? "U" : username, size: 32)
                    EditorialEyebrow(text: username.isEmpty ? "Welcome back" : "Hi, \(username)", tint: AppPalette.accent)
                    Spacer(minLength: 0)
                }
                Text("Unlock\nScribeflow.")
                    .scaledFont(size: 30, weight: .medium, design: .serif, relativeTo: .largeTitle)
                    .foregroundStyle(AppPalette.ink)
                Text("Use Face ID to continue. Your meetings stay locked until you do.")
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.secondaryInk)

                if let error {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppPalette.coral)
                        .padding(.top, 4)
                }

                Spacer(minLength: 0)

                Button { tryUnlock() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: attempting ? "ellipsis" : "faceid")
                            .font(.body.weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(attempting ? "Verifying…" : "Unlock with Face ID")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(AppPalette.accentButton, in: Capsule())
                    .shadow(color: AppPalette.accent.opacity(0.28), radius: 12, y: 5)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.97))
                .disabled(attempting)

                Button { HapticEngine.tap(.light); onLogout() } label: {
                    Text("Sign out")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.tertiaryInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
        }
        .onAppear { tryUnlock() }
    }

    private func tryUnlock() {
        guard !attempting else { return }
        attempting = true
        error = nil
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            attempting = false
            withAnimation { error = "Face ID isn't available on this device." }
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "Unlock Scribeflow") { success, evalErr in
            DispatchQueue.main.async {
                attempting = false
                if success {
                    HapticEngine.notify(.success)
                    onUnlock()
                } else {
                    HapticEngine.notify(.warning)
                    withAnimation {
                        error = evalErr?.localizedDescription ?? "Couldn't verify."
                    }
                }
            }
        }
    }
}

// MARK: - Shared auth atmosphere

/// Soft cream paper with twin radial glows (teal top-left, gold bottom-right)
/// — gives every auth screen a quiet sense of depth without going noisy.
struct AmbientAuthBackdrop: View {
    var primary: Color = AppPalette.accent
    var secondary: Color = AppPalette.gold
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppPalette.background
            Circle()
                .fill(RadialGradient(colors: [primary.opacity(0.18), .clear],
                                     center: .center, startRadius: 0, endRadius: 280))
                .frame(width: 520, height: 520)
                .offset(x: drift ? -110 : -140, y: drift ? -260 : -240)
                .blur(radius: 44)
            Circle()
                .fill(RadialGradient(colors: [secondary.opacity(0.12), .clear],
                                     center: .center, startRadius: 0, endRadius: 240))
                .frame(width: 440, height: 440)
                .offset(x: drift ? 160 : 130, y: drift ? 270 : 290)
                .blur(radius: 44)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 7.0).repeatForever(autoreverses: true)) {
                drift.toggle()
            }
        }
    }
}

/// Brief check-mark celebration shown between login success and the next
/// stage. "You're in, Maya." Auto-dismisses via the wrapper that owns its
/// lifetime.
struct AuthSuccessFlash: View {
    let name: String
    @State private var scale: CGFloat = 0.7
    @State private var rotation: Double = -10
    @State private var revealed = false
    @State private var confettiOut = false

    /// Six tiny dots burst outward from the check-mark.
    private let burstAngles: [Double] = stride(from: 0.0, to: 360.0, by: 60.0).map { $0 }

    var body: some View {
        ZStack {
            AmbientAuthBackdrop()
            VStack(spacing: 22) {
                ZStack {
                    // Confetti burst
                    ForEach(Array(burstAngles.enumerated()), id: \.offset) { idx, angle in
                        let isGold = idx.isMultiple(of: 2)
                        Circle()
                            .fill(isGold ? AppPalette.gold : AppPalette.accent)
                            .frame(width: 6, height: 6)
                            .offset(x: confettiOut ? cos(angle * .pi / 180) * 86 : 0,
                                    y: confettiOut ? sin(angle * .pi / 180) * 86 : 0)
                            .opacity(confettiOut ? 0 : 1)
                            .scaleEffect(confettiOut ? 0.4 : 1)
                    }
                    Circle()
                        .fill(AppPalette.accent.opacity(0.14))
                        .frame(width: 104, height: 104)
                    Circle()
                        .strokeBorder(AppPalette.accent.opacity(0.30), lineWidth: 1)
                        .frame(width: 104, height: 104)
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(AppPalette.accent)
                        .scaleEffect(scale)
                        .rotationEffect(.degrees(rotation))
                }
                Text(name.isEmpty ? "You're in." : "You're in, \(name).")
                    .scaledFont(size: 26, weight: .medium, design: .serif, relativeTo: .title)
                    .foregroundStyle(AppPalette.ink)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 6)
            }
        }
        .onAppear {
            HapticEngine.notify(.success)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) {
                scale = 1.0
                rotation = 0
            }
            withAnimation(.easeOut(duration: 0.45).delay(0.15)) { revealed = true }
            withAnimation(.easeOut(duration: 0.85).delay(0.10)) { confettiOut = true }
        }
    }
}

/// Four-segment password strength bar — fills/colors as the password grows.
struct PasswordStrengthMeter: View {
    let password: String

    private var score: Int {
        var s = 0
        if password.count >= 6  { s += 1 }
        if password.count >= 10 { s += 1 }
        if password.contains(where: \.isUppercase) || password.contains(where: \.isLowercase) { s += 1 }
        if password.contains(where: \.isNumber) || password.contains(where: { !$0.isLetter && !$0.isNumber }) { s += 1 }
        return min(s, 4)
    }
    private var tint: Color {
        switch score {
        case 0, 1: return AppPalette.coral
        case 2:    return AppPalette.gold
        default:   return AppPalette.success
        }
    }
    private var label: String {
        switch score {
        case 0: return "Too short"
        case 1: return "Weak"
        case 2: return "Okay"
        case 3: return "Strong"
        default: return "Very strong"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(i < score ? tint : AppPalette.border)
                        .frame(height: 3)
                        .animation(AppMotion.smooth, value: score)
                }
            }
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .kerning(0.5)
                .foregroundStyle(tint)
                .contentTransition(.opacity)
        }
    }
}

/// Pulsing accent ring around the faceid glyph. Used on the enroll +
/// unlock screens to make biometrics feel inviting.
struct BiometricRing: View {
    @State private var pulse = false
    @State private var rotate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Outer pulsing accent ring
            Circle()
                .strokeBorder(AppPalette.accent.opacity(pulse ? 0 : 0.40), lineWidth: 2)
                .frame(width: 124, height: 124)
                .scaleEffect(pulse ? 1.28 : 0.90)
            // Dashed gold arc that slowly rotates — adds depth without noise
            Circle()
                .trim(from: 0.0, to: 0.30)
                .stroke(AppPalette.gold.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 6]))
                .frame(width: 108, height: 108)
                .rotationEffect(.degrees(rotate ? 360 : 0))
            // Cream paper face under the glyph
            Circle()
                .fill(AppPalette.cardBackground)
                .frame(width: 88, height: 88)
                .overlay(Circle().strokeBorder(AppPalette.accent.opacity(0.20), lineWidth: 1))
                .shadow(color: AppPalette.accent.opacity(0.20), radius: 14, y: 6)
            Image(systemName: "faceid")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(AppPalette.accent)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
            withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                rotate.toggle()
            }
        }
    }
}
