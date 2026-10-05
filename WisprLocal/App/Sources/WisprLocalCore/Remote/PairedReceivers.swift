import CryptoKit
import Foundation
import Observation

/// A receiver Mac this sender is paired with. The KEY is not in here: it lives in the Keychain
/// (service `KeychainSecretStore.senderService`, account = `id`).
public struct PairedReceiver: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// Display name first, then aliases (host names) used to match Screen Sharing window titles.
    public var names: [String]
    public var host: String
    public var port: UInt16
    public var fingerprint: String
    public var pairedAt: Date

    public init(id: UUID = UUID(), names: [String], host: String, port: UInt16, fingerprint: String, pairedAt: Date = Date()) {
        self.id = id; self.names = names; self.host = host; self.port = port
        self.fingerprint = fingerprint; self.pairedAt = pairedAt
    }

    public var displayName: String { names.first ?? host }
    public var endpoint: BridgeEndpoint { BridgeEndpoint(host: host, port: port) }
}

/// Picks the receiver for the frontmost remote-viewer window (pure, unit-tested).
/// Screen Sharing's window title contains the remote computer name (or the address typed when
/// connecting). Longest matching token wins; else the manual default receiver; else none.
public enum ReceiverMatcher {
    static func tokens(_ r: PairedReceiver) -> [String] {
        var t: [String] = [r.host]
        for n in r.names {
            let l = n.lowercased()
            t.append(l)
            if l.hasSuffix(".local") { t.append(String(l.dropLast(6))) }
            // "studio.tail1234.ts.net" → "studio" (never for IP literals: "100" would match anything).
            if l.contains("."), TailnetAddress.ipv4Bytes(l) == nil, TailnetAddress.ipv6Bytes(l) == nil,
               let first = l.split(separator: ".").first { t.append(String(first)) }
        }
        return t.map { $0.lowercased() }.filter { $0.count >= 3 }
    }

    public static func match(windowTitle: String?, receivers: [PairedReceiver], defaultID: UUID?) -> PairedReceiver? {
        if let title = windowTitle?.lowercased(), !title.isEmpty {
            var best: (PairedReceiver, Int)?
            for r in receivers {
                for tok in tokens(r) where title.contains(tok) {
                    if tok.count > (best?.1 ?? 0) { best = (r, tok.count) }
                }
            }
            if let best { return best.0 }
        }
        return receivers.first { $0.id == defaultID }
    }
}

/// Persisted list of paired receivers (UserDefaults) + their keys (SecretStore / Keychain).
@MainActor
@Observable
public final class PairedReceiverStore {
    public static let defaultsKey = "remoteReceivers.v1"
    public static let shared = PairedReceiverStore()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: SecretStore
    public private(set) var receivers: [PairedReceiver] { didSet { save() } }

    public init(defaults: UserDefaults = .standard,
                secrets: SecretStore = KeychainSecretStore(service: KeychainSecretStore.senderService)) {
        self.defaults = defaults
        self.secrets = secrets
        receivers = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([PairedReceiver].self, from: $0) } ?? []
    }

    /// Decodes a pairing code and stores it (replacing an existing pairing to the same address).
    @discardableResult
    public func pair(code: String) throws -> PairedReceiver {
        let info = try PairingCode.decode(code)
        var r = PairedReceiver(names: info.names, host: info.host, port: info.port, fingerprint: info.fingerprint)
        if let existing = receivers.firstIndex(where: { $0.host == info.host && $0.port == info.port }) {
            r.id = receivers[existing].id
            try secrets.write(info.key, account: r.id.uuidString)
            receivers[existing] = r
        } else {
            try secrets.write(info.key, account: r.id.uuidString)
            receivers.append(r)
        }
        return r
    }

    public func unpair(_ id: UUID) {
        secrets.delete(account: id.uuidString)
        receivers.removeAll { $0.id == id }
    }

    public func key(for id: UUID) -> SymmetricKey? {
        secrets.read(account: id.uuidString).map { SymmetricKey(data: $0) }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(receivers) { defaults.set(d, forKey: Self.defaultsKey) }
    }
}
