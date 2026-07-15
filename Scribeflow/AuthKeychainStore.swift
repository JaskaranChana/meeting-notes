import Foundation
import Security

protocol AuthSessionStoring: Sendable {
    func loadSession() throws -> AuthSession?
    func saveSession(_ session: AuthSession) throws
    func clearSession() throws
}

enum KeychainStoreError: LocalizedError, Equatable {
    case encodeFailed
    case decodeFailed
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            "Could not encode the secure session."
        case .decodeFailed:
            "Could not read the secure session."
        case .unhandledStatus(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}

struct KeychainSecretStore {
    let service: String

    func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainStoreError.decodeFailed
        }
        return data
    }

    func set(_ data: Data, for account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unhandledStatus(updateStatus)
        }

        var item = query
        item.merge(attributes) { _, replacement in replacement }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(addStatus)
        }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct KeychainAuthSessionStore: AuthSessionStoring {
    private let service = "ai.scribeflow.app.auth"
    private let account = "session"

    func loadSession() throws -> AuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainStoreError.decodeFailed
        }

        do {
            return try JSONDecoder.authDecoder.decode(AuthSession.self, from: data)
        } catch {
            throw KeychainStoreError.decodeFailed
        }
    }

    func saveSession(_ session: AuthSession) throws {
        guard let data = try? JSONEncoder.authEncoder.encode(session) else {
            throw KeychainStoreError.encodeFailed
        }

        try? clearSession()

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(status)
        }
    }

    func clearSession() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    // MARK: Apple Sign-In email cache
    //
    // Apple only returns the email + name on the *first* authorization for a
    // given Apple ID. Subsequent sign-ins return nil for those fields. Cache
    // the value the first time we see it, keyed by Apple's stable user ID.

    static func cacheAppleEmail(_ email: String, for user: String) {
        UserDefaults.standard.set(email, forKey: appleEmailDefaultsKey(for: user))
    }

    static func cachedAppleEmail(for user: String) -> String? {
        UserDefaults.standard.string(forKey: appleEmailDefaultsKey(for: user))
    }

    static func clearCachedAppleEmail(for user: String) {
        UserDefaults.standard.removeObject(forKey: appleEmailDefaultsKey(for: user))
    }

    private static func appleEmailDefaultsKey(for user: String) -> String {
        "ai.scribeflow.app.apple.email.\(user)"
    }
}

private extension JSONEncoder {
    static var authEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var authDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
