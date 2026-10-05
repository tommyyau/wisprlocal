import CryptoKit
import Foundation
import Network
import Synchronization

/// Receiver side: an `NWListener` bound to ONE local address (the Tailscale 100.x IP in
/// production — refused otherwise), one message per connection, verified by `BridgeVerifier`,
/// then handed to `deliver`. Peers outside the tailnet ranges are dropped before reading.
/// Never logs the key or the text.
public final class BridgeServer: @unchecked Sendable {
    public enum StartError: Error, LocalizedError {
        case bindAddressNotAllowed, listenerFailed(String)
        public var errorDescription: String? {
            switch self {
            case .bindAddressNotAllowed: return "Refusing to listen on a non-Tailscale address."
            case .listenerFailed(let s): return "Could not start listening: \(s)"
            }
        }
    }

    /// Result of every received message (status only — no text), for receipt counters.
    public var onReceipt: (@Sendable (BridgeStatus) -> Void)?

    private let bindHost: String
    private let requestedPort: UInt16
    private let bindPolicy: AddressPolicy
    private let peerPolicy: AddressPolicy
    private let deliver: @Sendable (String) async -> BridgeStatus
    private let verifier: Mutex<BridgeVerifier>
    private struct Lifecycle {
        var listener: NWListener?
        var generation = 0
        var running = false
        var connections: [UUID: NWConnection] = [:]
    }
    private let lifecycle = Mutex(Lifecycle())
    private let guardedDeliver: (@Sendable (String, @escaping @Sendable () -> Bool) async -> BridgeStatus)?
    /// Deterministic suspension point for the loopback generation regression test.
    private let beforeDelivery: (@Sendable () async -> Void)?
    static let maxConcurrent = 8

    /// `deliver(text)` inserts the text and returns `.ok`, `.insertFailed` or `.secureInput`
    /// (see `ReceiverDeliveryPolicy`); any other status is reported as `.insertFailed`.
    public convenience init(bindHost: String, port: UInt16 = BridgeLimits.defaultPort, key: SymmetricKey,
                            deliver: @escaping @Sendable (String) async -> BridgeStatus) {
        self.init(bindHost: bindHost, port: port, key: key, bindPolicy: .tailnetOnly, peerPolicy: .tailnetOnly, deliver: deliver)
    }

    public convenience init(bindHost: String, port: UInt16 = BridgeLimits.defaultPort, key: SymmetricKey,
                            guardedDeliver: @escaping @Sendable (String, @escaping @Sendable () -> Bool) async -> BridgeStatus) {
        self.init(bindHost: bindHost, port: port, key: key, bindPolicy: .tailnetOnly, peerPolicy: .tailnetOnly,
                  guardedDeliver: guardedDeliver, deliver: { _ in .insertFailed })
    }

    init(bindHost: String, port: UInt16, key: SymmetricKey, bindPolicy: AddressPolicy, peerPolicy: AddressPolicy,
         beforeDelivery: (@Sendable () async -> Void)? = nil,
         guardedDeliver: (@Sendable (String, @escaping @Sendable () -> Bool) async -> BridgeStatus)? = nil,
         deliver: @escaping @Sendable (String) async -> BridgeStatus) {
        self.bindHost = TailnetAddress.normalize(bindHost)
        self.requestedPort = port
        self.bindPolicy = bindPolicy
        self.peerPolicy = peerPolicy
        self.deliver = deliver
        self.guardedDeliver = guardedDeliver
        self.beforeDelivery = beforeDelivery
        self.verifier = Mutex(BridgeVerifier(key: key))
    }

    /// Starts listening; returns the bound port.
    public func start() async throws -> UInt16 {
        guard bindPolicy.permits(bindHost) else { throw StartError.bindAddressNotAllowed }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost),
                                                 port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let l: NWListener
        do { l = try NWListener(using: params) } catch { throw StartError.listenerFailed("\(error)") }
        stop()
        let generation = lifecycle.withLock { state in
            state.listener = l
            state.generation += 1; state.running = true
            return state.generation
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn, generation: generation) }
        let shot = OneShot<UInt16>()
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: shot.resume(.success(l.port?.rawValue ?? 0))
            case .failed(let e): shot.resume(.failure(StartError.listenerFailed("\(e)")))
            case .waiting(let e): shot.resume(.failure(StartError.listenerFailed("\(e)")))
            case .cancelled: shot.resume(.failure(StartError.listenerFailed("cancelled")))
            default: break
            }
        }
        l.start(queue: BridgeIO.queue)
        do {
            let port = try await withCheckedThrowingContinuation { shot.install($0) }
            guard isCurrent(generation) else { throw StartError.listenerFailed("cancelled") }
            return port
        } catch {
            stop(generation: generation)
            throw error
        }
    }

    public func stop() { stop(generation: nil) }

    private func stop(generation: Int?) {
        let stopped = lifecycle.withLock { state -> (NWListener?, [NWConnection]) in
            if let generation, state.generation != generation { return (nil, []) }
            state.running = false; state.generation += 1
            let stopped = (state.listener, Array(state.connections.values))
            state.listener = nil
            state.connections.removeAll()
            return stopped
        }
        stopped.0?.cancel()
        for connection in stopped.1 { connection.cancel() }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lifecycle.withLock { $0.running && $0.generation == generation }
    }

    var acceptedConnectionCount: Int { lifecycle.withLock { $0.connections.count } }

    private func accept(_ conn: NWConnection, generation: Int) {
        guard let peer = BridgeIO.host(of: conn.endpoint), peerPolicy.permits(peer) else {
            conn.cancel(); onReceipt?(.forbiddenPeer); return
        }
        let id = UUID()
        let admitted = lifecycle.withLock { state -> Bool in
            guard state.running, state.generation == generation,
                  state.connections.count < Self.maxConcurrent else { return false }
            state.connections[id] = conn
            return true
        }
        guard admitted else { conn.cancel(); return }
        Task { [self] in
            await self.handle(conn, generation: generation)
            _ = self.lifecycle.withLock { $0.connections.removeValue(forKey: id) }
        }
    }

    private func handle(_ conn: NWConnection, generation: Int) async {
        defer { conn.cancel() }
        do { try await BridgeIO.waitReady(conn, timeout: .seconds(2)) } catch { return }
        let status: BridgeStatus
        var nonce = ""
        do {
            let body = try await BridgeIO.receiveFrame(conn, timeout: .seconds(5))
            if let msg = try? JSONDecoder().decode(BridgeMessage.self, from: body) {
                nonce = msg.nonce
                let verdict = verifier.withLock { $0.verify(msg) }
                if verdict == .ok {
                    await beforeDelivery?()
                    guard isCurrent(generation) else { onReceipt?(.insertFailed); return }
                    let result: BridgeStatus
                    if let guardedDeliver {
                        result = await guardedDeliver(msg.text, { [self] in isCurrent(generation) })
                    } else {
                        result = await deliver(msg.text)
                    }
                    switch result {
                    case .ok: status = .ok
                    case .secureInput: status = .secureInput
                    default: status = .insertFailed
                    }
                } else {
                    status = verdict
                }
            } else {
                status = .malformed
            }
        } catch BridgeIOError.tooLarge {
            status = .tooLarge
        } catch {
            return  // timeout / closed: nothing to ack
        }
        onReceipt?(status)
        let ack = BridgeAck(v: BridgeLimits.version, nonce: nonce, status: status)
        if let frame = try? BridgeFraming.encode(ack) {
            try? await BridgeIO.send(conn, frame, timeout: .seconds(2))
        }
    }
}
