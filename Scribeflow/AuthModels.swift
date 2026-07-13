import Foundation

enum AuthSessionKind: String, Codable, Hashable, Sendable {
    case localDevice
    case appleLocal
    case googleLocal
    case development
    case remote
    case legacy

    var title: String {
        switch self {
        case .localDevice: "On this device"
        case .appleLocal: "Apple ID on this device"
        case .googleLocal: "Google identity on this device"
        case .development: "Development session"
        case .remote: "Scribeflow account"
        case .legacy: "Local session"
        }
    }

    var canAuthenticateBackend: Bool { self == .remote }
    var needsAppleCredentialCheck: Bool { self == .appleLocal }
    var requiresRemoteDeletion: Bool { self == .remote }
}

struct AuthSession: Codable, Hashable, Identifiable, Sendable {
    var id: String { userID }
    let userID: String
    let email: String
    let displayName: String
    let accessToken: String
    let issuedAt: Date
    let expiresAt: Date
    let kind: AuthSessionKind

    init(
        userID: String,
        email: String,
        displayName: String,
        accessToken: String,
        issuedAt: Date,
        expiresAt: Date,
        kind: AuthSessionKind = .legacy
    ) {
        self.userID = userID
        self.email = email
        self.displayName = displayName
        self.accessToken = accessToken
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.kind = kind
    }

    var isExpired: Bool {
        expiresAt <= .now
    }

    var accountLabel: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? kind.title
    }

    private enum CodingKeys: String, CodingKey {
        case userID, email, displayName, accessToken, issuedAt, expiresAt, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(String.self, forKey: .userID)
        email = try container.decode(String.self, forKey: .email)
        displayName = try container.decode(String.self, forKey: .displayName)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        issuedAt = try container.decode(Date.self, forKey: .issuedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        kind = try container.decodeIfPresent(AuthSessionKind.self, forKey: .kind) ?? .legacy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userID, forKey: .userID)
        try container.encode(email, forKey: .email)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(issuedAt, forKey: .issuedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(kind, forKey: .kind)
    }
}

enum AuthMode: Equatable {
    case login
    case signup

    var title: String {
        switch self {
        case .login:
            "Welcome back"
        case .signup:
            "Create account"
        }
    }

    var subtitle: String {
        switch self {
        case .login:
            "Sign in to protect your meeting memory."
        case .signup:
            "Start with a secure local session."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .login:
            "Log in"
        case .signup:
            "Sign up"
        }
    }

    var alternateActionTitle: String {
        switch self {
        case .login:
            "Create an account"
        case .signup:
            "I already have an account"
        }
    }
}

enum AuthSessionPhase: Equatable {
    case checking
    case signedOut
    case locked(AuthSession)
    case authenticated(AuthSession)
}

struct AuthFormValidationResult: Equatable {
    var emailError: String?
    var passwordError: String?
    var canSubmit: Bool {
        emailError == nil && passwordError == nil
    }
}

enum AuthCredentialsValidator {
    static func validate(email: String, password: String) -> AuthFormValidationResult {
        AuthFormValidationResult(
            emailError: emailError(email),
            passwordError: passwordError(password)
        )
    }

    static func emailError(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Add your email to continue." }

        let pattern = #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#
        let predicate = NSPredicate(format: "SELF MATCHES[c] %@", pattern)
        return predicate.evaluate(with: trimmed) ? nil : "Use a valid email with an @ and domain."
    }

    static func passwordError(_ password: String) -> String? {
        guard !password.isEmpty else { return "Add your password to continue." }
        guard password.count >= 8 else { return "Use 8 or more characters." }
        guard password.rangeOfCharacter(from: .uppercaseLetters) != nil else { return "Add one uppercase letter." }
        guard password.rangeOfCharacter(from: .lowercaseLetters) != nil else { return "Add one lowercase letter." }
        guard password.rangeOfCharacter(from: .decimalDigits) != nil else { return "Add one number." }
        return nil
    }
}

enum AuthError: LocalizedError, Equatable {
    case invalidCredentials
    case backendUnavailable
    case tokenStorageFailed
    case biometricUnavailable
    case biometricFailed
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "We could not sign you in with those details."
        case .backendUnavailable:
            "Authentication service is not connected yet."
        case .tokenStorageFailed:
            "Your secure session could not be saved. Please try again."
        case .biometricUnavailable:
            "Face ID or Touch ID is not available on this device."
        case .biometricFailed:
            "Biometric unlock was not completed."
        case .sessionExpired:
            "Your session expired. Please sign in again."
        }
    }
}
