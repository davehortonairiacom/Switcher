import Foundation
import Security

/// Somewhere to keep gateway API keys.
///
/// Abstracted so tests can run against memory — hitting the real Keychain from a
/// test binary can block on an authorisation prompt.
public protocol KeyStoring: Sendable {
    func key(for id: UUID) -> String?
    func setKey(_ key: String, for id: UUID) throws
    func deleteKey(for id: UUID)
}

/// Keys held in memory only. For tests.
public final class InMemoryKeyStore: KeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    public init() {}
    public func key(for id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }; return storage[id]
    }
    public func setKey(_ key: String, for id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { storage[id] = nil } else { storage[id] = trimmed }
    }
    public func deleteKey(for id: UUID) {
        lock.lock(); defer { lock.unlock() }; storage[id] = nil
    }
}

/// Gateway API keys, kept in the login Keychain rather than on disk.
///
/// A key still reaches `settings.json` in plaintext while that gateway is
/// active — that's how Claude Code consumes it — but Switcher's own copy at
/// rest is protected, and keys for inactive profiles never touch the filesystem.
public struct KeychainStore: KeyStoring, Sendable {
    public static let shared = KeychainStore()
    public init() {}

    public static let service = "ai.airia.switcher"

    public static func setKey(_ key: String, for id: UUID) throws {
        let account = id.uuidString
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deleteKey(for: id) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    public static func key(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func deleteKey(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - KeyStoring

    public func key(for id: UUID) -> String? { Self.key(for: id) }
    public func setKey(_ key: String, for id: UUID) throws { try Self.setKey(key, for: id) }
    public func deleteKey(for id: UUID) { Self.deleteKey(for: id) }

    public struct KeychainError: LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        }
    }
}
