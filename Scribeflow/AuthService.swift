import AuthenticationServices
import Foundation
import LocalAuthentication
import Observation
import UIKit

protocol AuthenticationServicing: Sendable {
    func login(email: String, password: String) async throws -> AuthSession
    func signup(email: String, password: String) async throws -> AuthSession
}

#if DEBUG
struct LocalDevelopmentAuthService: AuthenticationServicing {
    func login(email: String, password: String) async throws -> AuthSession {
        try await Task.sleep(for: .milliseconds(450))
        try Task.checkCancellation()

        if email.lowercased().hasSuffix("@fail.test") {
            throw AuthError.invalidCredentials
        }

        return makeSession(email: email)
    }

    func signup(email: String, password: String) async throws -> AuthSession {
        try await Task.sleep(for: .milliseconds(550))
        try Task.checkCancellation()
        return makeSession(email: email)
    }

    private func makeSession(email: String) -> AuthSession {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = trimmedEmail
            .split(separator: "@")
            .first
            .map { String($0).replacingOccurrences(of: ".", with: " ").capitalized }
            ?? "Scribeflow User"

        return AuthSession(
            userID: UUID().uuidString,
            email: trimmedEmail,
            displayName: name,
            accessToken: UUID().uuidString + "." + UUID().uuidString,
            issuedAt: .now,
            expiresAt: Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now,
            kind: .development
        )
    }
}
#endif

/// Release-safe placeholder. Email/password sign-in is disabled until a real
/// identity backend (Sign in with Apple exchange, custom OAuth, Firebase, etc.)
/// is wired in. Direct users to the Sign in with Apple path instead.
struct UnconfiguredRemoteAuthService: AuthenticationServicing {
    func login(email: String, password: String) async throws -> AuthSession {
        throw AuthError.backendUnavailable
    }

    func signup(email: String, password: String) async throws -> AuthSession {
        throw AuthError.backendUnavailable
    }
}

enum DefaultAuthService {
    static func make() -> AuthenticationServicing {
        #if DEBUG
        return LocalDevelopmentAuthService()
        #else
        return UnconfiguredRemoteAuthService()
        #endif
    }
}

protocol AccountDeletionServicing: Sendable {
    func deleteRemoteAccount(for session: AuthSession) async throws
}

struct BackendAccountDeletionService: AccountDeletionServicing {
    func deleteRemoteAccount(for session: AuthSession) async throws {
        guard session.kind.requiresRemoteDeletion else { return }
        guard let configuration = BackendConfiguration.current(),
              let url = URL(string: "/v1/account", relativeTo: configuration.baseURL)?.absoluteURL
        else {
            throw AuthError.backendUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.backendUnavailable
        }
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 else {
            throw AuthError.backendUnavailable
        }
    }
}

protocol BiometricAuthenticating: Sendable {
    func canAuthenticate() -> Bool
    func biometricLabel() -> String
    func authenticate(reason: String) async throws
}

struct LocalBiometricAuthenticator: BiometricAuthenticating {
    func canAuthenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func biometricLabel() -> String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        switch context.biometryType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        default:
            return "Biometrics"
        }
    }

    func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Use password"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw AuthError.biometricUnavailable
        }

        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )

        guard success else {
            throw AuthError.biometricFailed
        }
    }
}

private actor AuthSessionStorageWorker {
    private let store: AuthSessionStoring

    init(store: AuthSessionStoring) {
        self.store = store
    }

    func loadSession() throws -> AuthSession? {
        try store.loadSession()
    }

    func saveSession(_ session: AuthSession) throws {
        try store.saveSession(session)
    }

    func clearSession() throws {
        try store.clearSession()
    }
}

@MainActor
@Observable
final class AuthSessionStore {
    var phase: AuthSessionPhase = .checking
    var isLoading = false
    var errorMessage: String?
    var successMessage: String?

    @ObservationIgnored private let authService: AuthenticationServicing
    @ObservationIgnored private let sessionStorage: AuthSessionStorageWorker
    @ObservationIgnored private let biometricAuthenticator: BiometricAuthenticating
    @ObservationIgnored private let accountDeletionService: AccountDeletionServicing

    init(
        authService: AuthenticationServicing = DefaultAuthService.make(),
        sessionStore: AuthSessionStoring = KeychainAuthSessionStore(),
        biometricAuthenticator: BiometricAuthenticating = LocalBiometricAuthenticator(),
        accountDeletionService: AccountDeletionServicing = BackendAccountDeletionService()
    ) {
        self.authService = authService
        self.sessionStorage = AuthSessionStorageWorker(store: sessionStore)
        self.biometricAuthenticator = biometricAuthenticator
        self.accountDeletionService = accountDeletionService
        Task {
            await restore()
        }
    }

    var currentSession: AuthSession? {
        switch phase {
        case .authenticated(let session), .locked(let session):
            session
        case .checking, .signedOut:
            nil
        }
    }

    var isAuthenticated: Bool {
        if case .authenticated = phase { return true }
        return false
    }

    var hasLockedSession: Bool {
        if case .locked = phase { return true }
        return false
    }

    var biometricLabel: String {
        biometricAuthenticator.biometricLabel()
    }

    var canUseBiometrics: Bool {
        hasLockedSession && biometricAuthenticator.canAuthenticate()
    }

    func restore() async {
        phase = .checking
        isLoading = true
        errorMessage = nil
        successMessage = nil

        do {
            guard let session = try await sessionStorage.loadSession() else {
                phase = .signedOut
                isLoading = false
                return
            }

            if session.isExpired {
                try? await sessionStorage.clearSession()
                phase = .signedOut
                errorMessage = AuthError.sessionExpired.localizedDescription
            } else if session.kind.needsAppleCredentialCheck,
                      await appleCredentialIsInvalid(for: session.userID) {
                try? await sessionStorage.clearSession()
                KeychainAuthSessionStore.clearCachedAppleEmail(for: session.userID)
                phase = .signedOut
                errorMessage = "Your Apple authorization changed. Sign in again to continue."
            } else {
                phase = .authenticated(session)
            }
        } catch {
            phase = .signedOut
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Sign in using only this device — Face ID / Touch ID / passcode.
    /// Works on any device with a passcode set; no remote account needed.
    @MainActor
    func submitDeviceSignIn() async {
        isLoading = true
        errorMessage = nil
        successMessage = nil

        let result = await DeviceAuthService.signIn()
        switch result {
        case .success(let session):
            do {
                try await sessionStorage.saveSession(session)
                phase = .authenticated(session)
                successMessage = "Signed in on this device."
                HapticEngine.notify(.success)
            } catch {
                errorMessage = AuthError.tokenStorageFailed.localizedDescription
                HapticEngine.notify(.error)
            }
        case .cancelled:
            errorMessage = nil
        case .unavailable(let message):
            errorMessage = message
            HapticEngine.notify(.warning)
        case .failure(let message):
            errorMessage = message
            HapticEngine.notify(.error)
        }

        isLoading = false
    }

    /// Sign in with Google. Returns to the app with a normal `AuthSession`
    /// regardless of provider. If the GoogleSignIn SDK is not yet linked
    /// (Swift package not added), this surfaces a clear configuration error
    /// instead of failing silently.
    @MainActor
    func submitGoogleSignIn(presentingViewController: UIViewController) async {
        isLoading = true
        errorMessage = nil
        successMessage = nil

        let result = await GoogleSignInService.signIn(presenting: presentingViewController)
        switch result {
        case .success(let session):
            do {
                try await sessionStorage.saveSession(session)
                phase = .authenticated(session)
                successMessage = "Signed in with Google."
                HapticEngine.notify(.success)
            } catch {
                errorMessage = AuthError.tokenStorageFailed.localizedDescription
                HapticEngine.notify(.error)
            }
        case .cancelled:
            errorMessage = nil
        case .notConfigured:
            errorMessage = "Google Sign-In is not configured yet. Add the GoogleSignIn Swift package and your OAuth client ID, then try again."
            HapticEngine.notify(.warning)
        case .failure(let message):
            errorMessage = message
            HapticEngine.notify(.error)
        }

        isLoading = false
    }

    func submit(mode: AuthMode, email: String, password: String) async {
        let validation = AuthCredentialsValidator.validate(email: email, password: password)
        guard validation.canSubmit else {
            errorMessage = validation.emailError ?? validation.passwordError
            return
        }

        isLoading = true
        errorMessage = nil
        successMessage = nil

        do {
            let session: AuthSession
            switch mode {
            case .login:
                session = try await authService.login(email: email, password: password)
            case .signup:
                session = try await authService.signup(email: email, password: password)
            }

            try await sessionStorage.saveSession(session)
            phase = .authenticated(session)
            successMessage = mode == .login ? "Signed in securely." : "Account created securely."
            HapticEngine.notify(.success)
        } catch {
            errorMessage = error.localizedDescription
            HapticEngine.notify(.error)
        }

        isLoading = false
    }

    func unlockWithBiometrics() async {
        guard case .locked(let session) = phase else { return }

        isLoading = true
        errorMessage = nil
        successMessage = nil

        do {
            try await biometricAuthenticator.authenticate(reason: "Unlock Scribeflow")
            phase = .authenticated(session)
            successMessage = "Unlocked with \(biometricLabel)."
            HapticEngine.notify(.success)
        } catch {
            errorMessage = error.localizedDescription
            HapticEngine.notify(.error)
        }

        isLoading = false
    }

    func lock() {
        guard case .authenticated(let session) = phase else { return }
        phase = .locked(session)
    }

    func logout() {
        guard !isLoading else { return }
        isLoading = false
        errorMessage = nil
        successMessage = nil
        Task {
            await performLogout()
        }
    }

    private func performLogout() async {
        isLoading = true
        do {
            try await sessionStorage.clearSession()
        } catch {
            errorMessage = error.localizedDescription
        }
        GoogleSignInService.signOut()
        isLoading = false
        phase = .signedOut
        successMessage = "Signed out securely."
    }

    /// Completes a Sign in with Apple flow. The `ASAuthorization` payload is
    /// produced by `SignInWithAppleButton`; we extract the credential, persist
    /// a local session keyed by Apple's user identifier, and store the
    /// identity token in the Keychain alongside the session.
    /// A real backend should validate the identity token server-side and
    /// exchange it for an app-scoped access token — this implementation is
    /// safe to ship as the UX surface while that endpoint is being built.
    func completeAppleSignIn(result: Result<ASAuthorization, Error>) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        successMessage = nil

        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = AuthError.invalidCredentials.localizedDescription
                isLoading = false
                return
            }

            let email = credential.email
                ?? (KeychainAuthSessionStore.cachedAppleEmail(for: credential.user) ?? "")
            let nameComponents = credential.fullName
            let displayName: String
            if let givenName = nameComponents?.givenName, !givenName.isEmpty {
                let familyName = nameComponents?.familyName ?? ""
                displayName = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
            } else if !email.isEmpty {
                displayName = email
                    .split(separator: "@")
                    .first
                    .map { String($0).replacingOccurrences(of: ".", with: " ").capitalized }
                    ?? "Scribeflow User"
            } else {
                displayName = "Scribeflow User"
            }

            if let email = credential.email, !email.isEmpty {
                KeychainAuthSessionStore.cacheAppleEmail(email, for: credential.user)
            }

            let token: String
            if let data = credential.identityToken, let str = String(data: data, encoding: .utf8) {
                token = str
            } else {
                token = credential.user
            }

            let session = AuthSession(
                userID: credential.user,
                email: email,
                displayName: displayName,
                accessToken: token,
                issuedAt: .now,
                expiresAt: Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now,
                kind: .appleLocal
            )

            do {
                try await sessionStorage.saveSession(session)
                phase = .authenticated(session)
                successMessage = "Signed in with Apple."
                HapticEngine.notify(.success)
            } catch {
                errorMessage = AuthError.tokenStorageFailed.localizedDescription
                HapticEngine.notify(.error)
            }
        case .failure(let error):
            // ASAuthorizationError.canceled is a tap-Cancel, not a problem.
            let nsError = error as NSError
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
                HapticEngine.notify(.error)
            }
        }

        isLoading = false
    }

    /// Permanently deletes the user's account. The caller is responsible for
    /// wiping local on-device data (recordings, notes, caches) before invoking
    /// this — typically by calling `MeetingStore.deleteAllUserData()`.
    /// App Store Guideline 5.1.1(v) requires this entry point whenever the app
    /// supports account creation.
    func deleteAccount() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        successMessage = nil

        let session = currentSession
        do {
            if let session {
                try await accountDeletionService.deleteRemoteAccount(for: session)
            }
            if ScribeflowCloudBackupService.isConfigured {
                try await ScribeflowCloudBackupService.deleteBackup()
            }
        } catch {
            errorMessage = "Remote account or iCloud data could not be deleted. Nothing on this device was removed."
            isLoading = false
            HapticEngine.notify(.error)
            return false
        }

        do {
            try await sessionStorage.clearSession()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            HapticEngine.notify(.error)
            return false
        }
        if let session, session.kind.needsAppleCredentialCheck {
            KeychainAuthSessionStore.clearCachedAppleEmail(for: session.userID)
        }
        DeviceAuthService.clearLocalIdentity()
        GoogleSignInService.signOut()
        phase = .signedOut
        isLoading = false
        successMessage = "Account deleted. Local data was removed."
        HapticEngine.notify(.success)
        return true
    }

    private func appleCredentialIsInvalid(for userID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                if error != nil {
                    continuation.resume(returning: false)
                    return
                }
                switch state {
                case .revoked, .notFound:
                    continuation.resume(returning: true)
                case .authorized, .transferred:
                    continuation.resume(returning: false)
                @unknown default:
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
