import CryptoKit
import Foundation

/// Wire protocol v1: one length-prefixed JSON message per TCP connection, one ack back.
///   frame   = UInt32 big-endian byte count ‖ JSON
///   message = {v:1, nonce, ts, text, mac}   ts = Unix milliseconds
///   mac     = base64 HMAC-SHA256(key, v ‖ nonce ‖ ts ‖ text), each field length-prefixed (UInt32
///             BE) so field boundaries are unambiguous.
///   ack     = {v:1, nonce, status}
/// An EMPTY text is an authenticated ping: fully verified, answered `pong`, nothing inserted.
public enum BridgeLimits {
    public static let version = 1
    public static let maxTextBytes = 20 * 1024
    public static let maxClockSkewMs: Int64 = 30_000
    public static let nonceCapacity = 1000
    /// Frame cap: text (≤20 KB) JSON-escaped can grow ~6×; anything bigger is rejected unread.
    public static let maxFrameBytes = 256 * 1024
    public static let defaultPort: UInt16 = 47_655
}

public struct BridgeMessage: Codable, Sendable, Equatable {
    public var v: Int
    public var nonce: String
    public var ts: Int64
    public var text: String
    public var mac: String
}

public enum BridgeStatus: String, Codable, Sendable, Equatable {
    case ok
    case pong
    case badMAC = "bad_mac"
    case stale
    case replay
    case tooLarge = "too_large"
    case malformed
    case badVersion = "bad_version"
    case insertFailed = "insert_failed"
    case forbiddenPeer = "forbidden_peer"
    /// The receiver Mac has Secure Event Input on (a password field is focused): refused, not
    /// pasted (SEC-4). The sender must NOT fall back to typing.
    case secureInput = "secure_input"
}

/// The receiver's insertion policy (SEC-4), in Core so it is unit-testable. Order matters:
/// a focused password field on the receiver Mac refuses BEFORE anything touches the pasteboard.
public enum ReceiverDeliveryPolicy {
    @MainActor public static func deliver(_ text: String,
                               secureInputActive: () -> Bool,
                               accessibilityTrusted: () -> Bool,
                               insert: (String) async throws -> Void) async -> BridgeStatus {
        if secureInputActive() { return .secureInput }
        guard accessibilityTrusted() else { return .insertFailed }
        do { try await insert(text) }
        catch PasteGateError.secureInput { return .secureInput }
        catch { return .insertFailed }
        return .ok
    }
}

public struct BridgeAck: Codable, Sendable, Equatable {
    public var v: Int
    public var nonce: String
    public var status: BridgeStatus
}

public enum BridgeCrypto {
    public static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    static func macInput(v: Int, nonce: String, ts: Int64, text: String) -> Data {
        var d = Data()
        func field(_ bytes: Data) {
            var n = UInt32(bytes.count).bigEndian
            d.append(Data(bytes: &n, count: 4))
            d.append(bytes)
        }
        field(Data(String(v).utf8))
        field(Data(nonce.utf8))
        field(Data(String(ts).utf8))
        field(Data(text.utf8))
        return d
    }

    public static func mac(key: SymmetricKey, v: Int, nonce: String, ts: Int64, text: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: macInput(v: v, nonce: nonce, ts: ts, text: text), using: key)
        return Data(code).base64EncodedString()
    }

    public static func randomNonce() -> String {
        var g = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }).base64EncodedString()
    }

    public static func seal(text: String, key: SymmetricKey, ts: Int64 = nowMs(), nonce: String = randomNonce()) -> BridgeMessage {
        BridgeMessage(v: BridgeLimits.version, nonce: nonce, ts: ts, text: text,
                      mac: mac(key: key, v: BridgeLimits.version, nonce: nonce, ts: ts, text: text))
    }

    /// Constant-time MAC check.
    public static func isAuthentic(_ m: BridgeMessage, key: SymmetricKey) -> Bool {
        guard let mac = Data(base64Encoded: m.mac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: macInput(v: m.v, nonce: m.nonce, ts: m.ts, text: m.text), using: key)
    }
}

/// Fixed-capacity set of recently seen nonces; evicts the oldest.
struct NonceLRU {
    let capacity: Int
    private var order: [String] = []
    private var seen: Set<String> = []
    init(capacity: Int) { self.capacity = capacity }

    func contains(_ n: String) -> Bool { seen.contains(n) }
    mutating func insert(_ n: String) {
        guard seen.insert(n).inserted else { return }
        order.append(n)
        if order.count > capacity { seen.remove(order.removeFirst()) }
    }
    var count: Int { seen.count }
}

/// Receiver-side checks, in order: version, size, timestamp, MAC, replay. A nonce is recorded
/// only once its MAC verified (forged nonces can't evict real ones).
public struct BridgeVerifier: Sendable {
    let key: SymmetricKey
    var nonces = NonceLRU(capacity: BridgeLimits.nonceCapacity)

    public init(key: SymmetricKey) { self.key = key }

    public mutating func verify(_ m: BridgeMessage, nowMs: Int64 = BridgeCrypto.nowMs()) -> BridgeStatus {
        guard m.v == BridgeLimits.version else { return .badVersion }
        guard !m.nonce.isEmpty, m.nonce.utf8.count <= 64 else { return .malformed }
        guard m.text.utf8.count <= BridgeLimits.maxTextBytes else { return .tooLarge }
        let (delta, overflow) = m.ts.subtractingReportingOverflow(nowMs)
        guard !overflow, delta >= -BridgeLimits.maxClockSkewMs,
              delta <= BridgeLimits.maxClockSkewMs else { return .stale }
        guard BridgeCrypto.isAuthentic(m, key: key) else { return .badMAC }
        guard !nonces.contains(m.nonce) else { return .replay }
        nonces.insert(m.nonce)
        return m.text.isEmpty ? .pong : .ok
    }
}

public enum BridgeFraming {
    public static func frame(_ json: Data) -> Data {
        var n = UInt32(json.count).bigEndian
        return Data(bytes: &n, count: 4) + json
    }

    public static func length(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let n = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int(n)
    }

    public static func encode<T: Encodable>(_ v: T) throws -> Data { frame(try JSONEncoder().encode(v)) }
}
