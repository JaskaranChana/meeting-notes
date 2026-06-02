import Foundation
import UIKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

/// Result of a Google Sign-In attempt, normalized so the caller does not need
/// to import the GoogleSignIn SDK directly.
enum GoogleSignInResult {
    case success(AuthSession)
    case cancelled
    case notConfigured
    case failure(String)
}

/// Wraps GoogleSignIn so the rest of the app stays SDK-agnostic.
///
/// Build behavior:
/// - **Without the GoogleSignIn Swift package added**: every call returns
///   `.notConfigured`, so the build still succeeds and the UI shows a clear
///   configuration error.
/// - **With the GoogleSignIn package added**: real OAuth flow runs as long as
///   `GIDClientID` is present in Info.plist.
///
/// Setup steps to enable Google Sign-In:
/// 1. Xcode → File → Add Package Dependencies → `https://github.com/google/GoogleSignIn-iOS`
/// 2. Create an iOS OAuth 2.0 client at https://console.cloud.google.com/apis/credentials
/// 3. Copy the *Client ID* into Info.plist under the key `GIDClientID`
/// 4. Copy the *reversed Client ID* (e.g. `com.googleusercontent.apps.123…`)
///    into Info.plist under `CFBundleURLTypes → CFBundleURLSchemes`
enum GoogleSignInService {

    @MainActor
    static func signIn(presenting presenter: UIViewController) async -> GoogleSignInResult {
        #if canImport(GoogleSignIn)
        return await performSignIn(presenting: presenter)
        #else
        return .notConfigured
        #endif
    }

    @MainActor
    static func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
    }

    #if canImport(GoogleSignIn)
    @MainActor
    private static func performSignIn(presenting presenter: UIViewController) async -> GoogleSignInResult {
        guard configureClientIDIfNeeded() else {
            return .notConfigured
        }

        do {
            let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            let user = signInResult.user
            let profile = user.profile
            let idToken = user.idToken?.tokenString ?? user.accessToken.tokenString

            let email = profile?.email ?? ""
            let userID = user.userID ?? email
            let displayName = profile?.name ?? email.split(separator: "@").first.map(String.init) ?? "Scribeflow user"
            // Google OAuth tokens typically expire in ~1h, but we treat the
            // session as long-lived locally; we'll silently refresh via the
            // SDK on next launch.
            let expires = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now

            let session = AuthSession(
                userID: userID,
                email: email,
                displayName: displayName,
                accessToken: idToken,
                issuedAt: .now,
                expiresAt: expires
            )
            return .success(session)
        } catch let error as NSError {
            if error.code == GIDSignInError.canceled.rawValue {
                return .cancelled
            }
            return .failure(error.localizedDescription)
        }
    }

    private static func configureClientIDIfNeeded() -> Bool {
        if GIDSignIn.sharedInstance.configuration != nil { return true }
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty else {
            return false
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        return true
    }
    #endif
}

// MARK: - URL handling for OAuth callback

/// Forward the OAuth redirect URL from `onOpenURL` / app delegate to the SDK.
/// Wire this once in the SwiftUI scene with `.onOpenURL { GoogleSignInURLHandler.handle($0) }`.
enum GoogleSignInURLHandler {
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        return GIDSignIn.sharedInstance.handle(url)
        #else
        return false
        #endif
    }
}
