import Foundation
import Network

/// Network.framework plumbing shared by `BridgeClient` and `BridgeServer`. This folder is the
/// ONLY place in WisprLocalCore allowed to touch the network (OfflineGuardTests).
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?

    func install(_ c: CheckedContinuation<T, Error>) {
        let r: Result<T, Error>? = lock.withLock {
            if let p = pendingResult { pendingResult = nil; return p }
            cont = c; return nil
        }
        if let r { c.resume(with: r) }
    }

    /// First call wins (returns true); later calls are ignored.
    @discardableResult
    func resume(_ r: Result<T, Error>) -> Bool {
        let (c, won): (CheckedContinuation<T, Error>?, Bool) = lock.withLock {
            if done { return (nil, false) }
            done = true
            if let c = cont { cont = nil; return (c, true) }
            pendingResult = r
            return (nil, true)
        }
        c?.resume(with: r)
        return won
    }
    private var done = false
}

enum BridgeIOError: Error { case timeout, closed, failed(String), tooLarge }

enum BridgeIO {
    static let queue = DispatchQueue(label: "com.tommyyau.wisprlocal.bridge")

    /// Runs `body` (which registers callbacks that resume the one-shot) with a deadline; on
    /// timeout the connection is cancelled.
    static func run<T: Sendable>(_ conn: NWConnection, timeout: Duration,
                                 _ body: @escaping @Sendable (OneShot<T>) -> Void) async throws -> T {
        let shot = OneShot<T>()
        let ms = Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        queue.asyncAfter(deadline: .now() + .milliseconds(ms)) {
            if shot.resume(.failure(BridgeIOError.timeout)) { conn.cancel() }
        }
        return try await withCheckedThrowingContinuation { c in
            shot.install(c)
            body(shot)
        }
    }

    /// The readiness verdict for one connection state: `.success` on ready, a failure the moment
    /// the connection fails, is waiting (no route / refused: we never sit out the deadline for a
    /// peer that is not there), or is cancelled; nil while still setting up.
    static func readiness(_ state: NWConnection.State) -> Result<Void, Error>? {
        switch state {
        case .ready: return .success(())
        case .failed(let e): return .failure(BridgeIOError.failed("\(e)"))
        case .waiting(let e): return .failure(BridgeIOError.failed("\(e)"))
        case .cancelled: return .failure(BridgeIOError.closed)
        default: return nil
        }
    }

    /// Starts `conn` and returns once it is ready; throws on the first failure state or timeout.
    /// (A failure resumes the continuation with an error, so `try await` rethrows it; there is
    /// no success value to inspect.)
    static func waitReady(_ conn: NWConnection, timeout: Duration) async throws {
        try await run(conn, timeout: timeout) { (shot: OneShot<Void>) in
            conn.stateUpdateHandler = { state in
                if let verdict = readiness(state) { shot.resume(verdict) }
            }
            conn.start(queue: queue)
        }
    }

    static func send(_ conn: NWConnection, _ data: Data, timeout: Duration) async throws {
        _ = try await run(conn, timeout: timeout) { (shot: OneShot<Bool>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { shot.resume(.failure(BridgeIOError.failed("\(err)"))) } else { shot.resume(.success(true)) }
            })
        }
    }

    static func receiveExactly(_ conn: NWConnection, _ n: Int, timeout: Duration) async throws -> Data {
        try await run(conn, timeout: timeout) { (shot: OneShot<Data>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, err in
                if let err { shot.resume(.failure(BridgeIOError.failed("\(err)"))); return }
                guard let data, data.count == n else {
                    shot.resume(.failure(isComplete ? BridgeIOError.closed : BridgeIOError.failed("short read"))); return
                }
                shot.resume(.success(data))
            }
        }
    }

    /// Reads one length-prefixed frame (≤ `BridgeLimits.maxFrameBytes`).
    static func receiveFrame(_ conn: NWConnection, timeout: Duration) async throws -> Data {
        let header = try await receiveExactly(conn, 4, timeout: timeout)
        guard let n = BridgeFraming.length(header), n > 0 else { throw BridgeIOError.failed("bad header") }
        guard n <= BridgeLimits.maxFrameBytes else { throw BridgeIOError.tooLarge }
        return try await receiveExactly(conn, n, timeout: timeout)
    }

    /// "a.b.c.d" / "fd7a:..." of a connection endpoint, or nil.
    static func host(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return TailnetAddress.normalize("\(a)")
        case .ipv6(let a): return TailnetAddress.normalize("\(a)")
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }
}
