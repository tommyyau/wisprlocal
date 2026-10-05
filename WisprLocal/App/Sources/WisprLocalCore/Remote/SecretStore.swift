import Foundation
import Security
import Synchronization

/// Where pairing keys live. Production = Keychain generic passwords; tests = in-memory.
/// Keys are NEVER logged, printed, or written anywhere else.
public protocol SecretStore: Sendable {
    func read(account: String) -> Data?
    func write(_ secret: Data, account: String) throws
    func delete(account: String)
}

public struct KeychainSecretStore: SecretStore {
    /// Service of the RECEIVER's own key.
    public static let receiverService = "WisprLocal Receiver"
    /// Service of the keys the SENDER (main app) holds for its paired receivers.
    public static let senderService = "WisprLocal Sender"

    public let service: String
    public init(service: String) { self.service = service }

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            if case .status(let s) = self { return "Keychain error \(s)" }
            return nil
        }
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func write(_ secret: Data, account: String) throws {
        let q = base(account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        var add = q
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let s = SecItemAdd(add as CFDictionary, nil)
        guard s == errSecSuccess else { throw KeychainError.status(s) }
    }

    public func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}

/// Test double.
public final class InMemorySecretStore: SecretStore {
    private let m = Mutex<[String: Data]>([:])
    public init() {}
    public func read(account: String) -> Data? { m.withLock { $0[account] } }
    public func write(_ secret: Data, account: String) throws { m.withLock { $0[account] = secret } }
    public func delete(account: String) { _ = m.withLock { $0.removeValue(forKey: account) } }
}
