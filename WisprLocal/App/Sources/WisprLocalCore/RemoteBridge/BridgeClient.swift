import CryptoKit
import Foundation
import Network

public struct BridgeEndpoint: Sendable, Equatable, Hashable {
    public var host: String
    public var port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

public enum BridgeClientError: Error, LocalizedError, Equatable {
    /// Nothing reached the receiver — safe to fall back to typing.
    case notTailnet
    /// The route to the receiver is not a tunnel (utun) interface — nothing was sent (SEC-3).
    case notTunnel
    case unreachable
    case rejected(BridgeStatus)
    /// The message WAS sent but no ack arrived: it may have been inserted. Do NOT fall back
    /// (that could insert twice).
    case unconfirmed

    /// Only failures before transmission permit fallback.
    /// `notTailnet` / `notTunnel` refuse before any byte is sent.
    /// A sent-but-unacknowledged message never falls back. Any answer from the
    /// receiver — `secureInput`, `insertFailed`, `badMAC`, … — is final: typing the same text
    /// via Screen Sharing would override the remote Mac's refusal.
    public var safeToFallBack: Bool {
        switch self {
        case .unreachable, .notTailnet, .notTunnel: return true
        case .rejected, .unconfirmed: return false
        }
    }

    /// The receiver refused because a password field is focused on the remote Mac.
    public var isRemoteSecureInput: Bool { self == .rejected(.secureInput) }

    public var errorDescription: String? {
        switch self {
        case .notTailnet: return "Receiver address is not a Tailscale address (refused)."
        case .notTunnel: return "The route to the receiver does not go through Tailscale (refused)."
        case .unreachable: return "Receiver not reachable."
        case .rejected(.secureInput): return "The remote Mac has a password field focused — not inserted."
        case .rejected(let s): return "Receiver rejected the message (\(s.rawValue))."
        case .unconfirmed: return "Sent to the receiver but no confirmation arrived."
        }
    }
}

/// What `RemoteInserter` needs from the bridge (faked in router tests).
public protocol RemoteBridgeSending: Sendable {
    /// Returns `.ok` (inserted) or `.pong` (ping). Throws `BridgeClientError`.
    func send(_ text: String, key: SymmetricKey, to: BridgeEndpoint, connectTimeout: Duration) async throws -> BridgeStatus
}

/// Sender side. Connects ONLY to tailnet IP literals (`AddressPolicy.tailnetOnly`), enforced
/// here before any socket is created. Never logs the key or the text.
///
/// SEC-3 (STRUCTURAL): the connection must also go via a tunnel interface. After `ready`, and
/// before a single byte is sent, the established path's primary interface must be a `utun*`
/// (`pathIsTunnel`); otherwise the connection is cancelled with `.notTunnel`. So a 100.64/10
/// destination that the routing table sends over the LAN/ISP (CGNAT on en0) never receives text.
///
/// Network.framework semantics (checked, see TailscaleInterfaceTests):
///  - `requiredInterfaceType = .other` is a NO-OP: `.other` is the default value (0, "no
///    requirement"), so it cannot express "utun only".
///  - `prohibitedInterfaceTypes = [.wifi, .wiredEthernet]` is NOT used: a VPN path is evaluated
///    with its delegate (physical) interface, so prohibiting Wi-Fi would also refuse Tailscale
///    running over Wi-Fi. Only `.loopback` is prohibited (Tailscale never routes via lo0).
/// Residual risk: the check is by interface NAME; another VPN's utun that routes 100.64/10 (or
/// fd7a:115c:a1e0::/48) would pass it — the HMAC key must still match the paired receiver, and
/// confidentiality of the text on such a path relies on that VPN (see REMOTE.md).
public struct BridgeClient: RemoteBridgeSending {
    public static let defaultConnectTimeout: Duration = .milliseconds(300)
    let policy: AddressPolicy
    let replyTimeout: Duration
    /// false only for the in-process loopback tests.
    let requireTunnel: Bool

    public init() { self.init(policy: .tailnetOnly) }
    init(policy: AddressPolicy, replyTimeout: Duration = .seconds(3), requireTunnel: Bool? = nil) {
        self.policy = policy; self.replyTimeout = replyTimeout
        self.requireTunnel = requireTunnel ?? (policy.isTailnetOnly)
    }

    /// TCP parameters for the sender (`requireTunnel`: never loopback; the utun requirement is
    /// enforced on the established path by `pathIsTunnel`, see the type comment).
    static func parameters(requireTunnel: Bool) -> NWParameters {
        let params = NWParameters.tcp
        params.preferNoProxies = true
        if requireTunnel { params.prohibitedInterfaceTypes = [.loopback] }
        return params
    }

    /// The established path's primary interface is a tunnel (`utun*`).
    static func pathIsTunnel(interfaceNames: [String]) -> Bool {
        guard let first = interfaceNames.first else { return false }
        return first.hasPrefix("utun")
    }

    public func send(_ text: String, key: SymmetricKey, to ep: BridgeEndpoint,
                     connectTimeout: Duration = BridgeClient.defaultConnectTimeout) async throws -> BridgeStatus {
        guard policy.permits(ep.host),
              TailnetAddress.ipv4Bytes(ep.host) != nil || TailnetAddress.ipv6Bytes(ep.host) != nil,
              let port = NWEndpoint.Port(rawValue: ep.port) else { throw BridgeClientError.notTailnet }
        guard text.utf8.count <= BridgeLimits.maxTextBytes else { throw BridgeClientError.rejected(.tooLarge) }
        let msg = BridgeCrypto.seal(text: text, key: key)
        let frame = try BridgeFraming.encode(msg)

        let params = Self.parameters(requireTunnel: requireTunnel)
        let conn = NWConnection(host: NWEndpoint.Host(TailnetAddress.normalize(ep.host)), port: port, using: params)
        defer { conn.cancel() }
        do { try await BridgeIO.waitReady(conn, timeout: connectTimeout) } catch { throw BridgeClientError.unreachable }
        if requireTunnel {
            let names = conn.currentPath?.availableInterfaces.map(\.name) ?? []
            guard Self.pathIsTunnel(interfaceNames: names) else { throw BridgeClientError.notTunnel }
        }
        try await transmit { try await BridgeIO.send(conn, frame, timeout: replyTimeout) }
        let ack: BridgeAck
        do {
            let body = try await BridgeIO.receiveFrame(conn, timeout: replyTimeout)
            ack = try JSONDecoder().decode(BridgeAck.self, from: body)
        } catch {
            throw BridgeClientError.unconfirmed
        }
        guard ack.nonce == msg.nonce else { throw BridgeClientError.unconfirmed }
        switch ack.status {
        case .ok, .pong: return ack.status
        default: throw BridgeClientError.rejected(ack.status)
        }
    }

    /// Once handed to the connection, even a failed send may have delivered text.
    func transmit(_ send: () async throws -> Void) async throws {
        do { try await send() } catch { throw BridgeClientError.unconfirmed }
    }

    /// Authenticated reachability check (empty text → `pong`; nothing inserted).
    public func ping(key: SymmetricKey, to ep: BridgeEndpoint, timeout: Duration = .seconds(1)) async -> Result<Void, BridgeClientError> {
        do {
            let s = try await send("", key: key, to: ep, connectTimeout: timeout)
            return s == .pong ? .success(()) : .failure(.rejected(s))
        } catch let e as BridgeClientError {
            return .failure(e)
        } catch {
            return .failure(.unreachable)
        }
    }
}
