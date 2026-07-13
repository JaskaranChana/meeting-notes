import Foundation
import LocalAuthentication
import UIKit

/// Result of a device sign-in attempt.
enum DeviceSignInResult {
    case success(AuthSession)
    case cancelled
    case unavailable(String)
    case failure(String)
}

/// Local-only authentication: the user proves they own this device using
/// Face ID, Touch ID, or the device passcode. No remote account, no
/// third-party SDK, no developer-program entitlement required.
///
/// On first sign-in we mint a stable local user ID and persist it so the
/// user keeps the same identity across sign-outs (their notes are still
/// associated with them).
enum DeviceAuthService {

    private static let localUserIDKey = "scribeflow.device.localUserID"
    private static let displayNameKey = "scribeflow.device.displayName"

    @MainActor
    static func signIn(reason: String = "Sign in to Scribeflow") async -> DeviceSignInResult {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        // .deviceOwnerAuthentication = biometrics with passcode fallback.
        // Works on every device whether or not Face ID / Touch ID is enrolled.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            let message = error?.localizedDescription
                ?? "Set up a device passcode or Face ID / Touch ID to sign in."
            return .unavailable(message)
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard success else {
                return .failure("Could not verify it's you. Please try again.")
            }
            return .success(makeOrRestoreSession())
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel:
                return .cancelled
            case .userFallback:
                // User chose "Use Passcode" — LAContext continues, this case
                // shouldn't usually surface, but treat it as cancel.
                return .cancelled
            default:
                return .failure(laError.localizedDescription)
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Forgets the local user identity. Called as part of full account
    /// deletion / "delete all data". A normal logout does NOT call this —
    /// we keep the same userID so re-signing-in lands you back in your data.
    static func clearLocalIdentity() {
        UserDefaults.standard.removeObject(forKey: localUserIDKey)
        UserDefaults.standard.removeObject(forKey: displayNameKey)
    }

    /// Returns the display name the user picked (if any).
    static var savedDisplayName: String? {
        UserDefaults.standard.string(forKey: displayNameKey)?.nonEmpty
    }

    /// Persist a chosen display name. Settings can call this if you add a
    /// "Your name" row later.
    static func saveDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: displayNameKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: displayNameKey)
        }
    }

    // MARK: - Session minting

    @MainActor
    private static func makeOrRestoreSession() -> AuthSession {
        let userID = stableUserID()
        let displayName = savedDisplayName ?? "You"
        let expires = Calendar.current.date(byAdding: .year, value: 10, to: .now) ?? .now

        return AuthSession(
            userID: userID,
            email: "", // No email when signing in from device only.
            displayName: displayName,
            accessToken: UUID().uuidString, // Synthetic — no remote validation needed.
            issuedAt: .now,
            expiresAt: expires,
            kind: .localDevice
        )
    }

    private static func stableUserID() -> String {
        if let existing = UserDefaults.standard.string(forKey: localUserIDKey), !existing.isEmpty {
            return existing
        }
        let new = "device-" + UUID().uuidString
        UserDefaults.standard.set(new, forKey: localUserIDKey)
        return new
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Convenience: does this device have Face ID, Touch ID, or just passcode?
/// Used by the UI to label the button correctly.
enum DeviceAuthCapability {
    static var label: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return "Continue"
        }
        // Touch the biometry type — only meaningful after canEvaluatePolicy.
        switch context.biometryType {
        case .faceID:
            return "Continue with Face ID"
        case .touchID:
            return "Continue with Touch ID"
        case .opticID:
            return "Continue with Optic ID"
        default:
            return "Continue with Passcode"
        }
    }

    static var systemImage: String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        switch context.biometryType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .opticID:
            return "opticid"
        default:
            return "lock.fill"
        }
    }
}
