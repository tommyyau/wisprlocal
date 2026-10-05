import CryptoKit
import Foundation

/// The receiver's long-lived pairing key: 32 random bytes, generated on first run and kept in
/// the Keychain (generic password, service "WisprLocal Receiver"). Never logged.
public enum ReceiverIdentity {
    public static let keyAccount = "pairing-key"

    public static func loadOrCreateKey(store: SecretStore = KeychainSecretStore(service: KeychainSecretStore.receiverService)) throws -> Data {
        if let k = store.read(account: keyAccount), k.count == PairingCode.keyLength { return k }
        return try regenerate(store: store)
    }

    /// New key: every previously paired sender stops working (re-pair needed).
    @discardableResult
    public static func regenerate(store: SecretStore = KeychainSecretStore(service: KeychainSecretStore.receiverService)) throws -> Data {
        let k = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try store.write(k, account: keyAccount)
        return k
    }
}
