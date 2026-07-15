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
                ScribeflowBrandMark(size: 76)
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
                ScribeflowBrandMark(size: 54)

                VStack(alignment: .leading, spacing: 5) {
                    Text("SCRIBEFLOW")
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(AuthPalette.tertiaryInk)
                    Text("Your private workspace")
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
                    Text(session.accountLabel)
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
            Label("Device sign-in stays local. Apple sign-in is handled by Apple.", systemImage: "iphone")
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
