import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
@testable import WisprLocalCore

@Suite struct BridgeVerifierTests {
    static let key = SymmetricKey(data: Data(repeating: 7, count: 32))
    static let now: Int64 = 1_800_000_000_000

    @Test func acceptsGenuineMessageAndPing() {
        var v = BridgeVerifier(key: Self.key)
        #expect(v.verify(BridgeCrypto.seal(text: "hello £5 — café 😀", key: Self.key, ts: Self.now), nowMs: Self.now) == .ok)
        #expect(v.verify(BridgeCrypto.seal(text: "", key: Self.key, ts: Self.now), nowMs: Self.now) == .pong)
    }

    @Test func rejectsTamperedText() {
        var v = BridgeVerifier(key: Self.key)
        var m = BridgeCrypto.seal(text: "transfer 10", key: Self.key, ts: Self.now)
        m.text = "transfer 1000"
        #expect(v.verify(m, nowMs: Self.now) == .badMAC)
        var m2 = BridgeCrypto.seal(text: "x", key: Self.key, ts: Self.now)
        m2.ts += 1
        #expect(v.verify(m2, nowMs: Self.now) == .badMAC)
        var m3 = BridgeCrypto.seal(text: "x", key: Self.key, ts: Self.now)
        m3.mac = "not base64!"
        #expect(v.verify(m3, nowMs: Self.now) == .badMAC)
    }

    @Test func rejectsWrongKey() {
        var v = BridgeVerifier(key: Self.key)
        let other = SymmetricKey(data: Data(repeating: 8, count: 32))
        #expect(v.verify(BridgeCrypto.seal(text: "hi", key: other, ts: Self.now), nowMs: Self.now) == .badMAC)
    }

    @Test func rejectsStaleOrFutureTimestamps() {
        var v = BridgeVerifier(key: Self.key)
        #expect(v.verify(BridgeCrypto.seal(text: "a", key: Self.key, ts: Self.now - 30_001), nowMs: Self.now) == .stale)
        #expect(v.verify(BridgeCrypto.seal(text: "a", key: Self.key, ts: Self.now + 30_001), nowMs: Self.now) == .stale)
        #expect(v.verify(BridgeCrypto.seal(text: "a", key: Self.key, ts: Self.now - 29_000), nowMs: Self.now) == .ok)
    }

    @Test func rejectsReplayedNonce() {
        var v = BridgeVerifier(key: Self.key)
        let m = BridgeCrypto.seal(text: "once", key: Self.key, ts: Self.now)
        #expect(v.verify(m, nowMs: Self.now) == .ok)
        #expect(v.verify(m, nowMs: Self.now) == .replay)
    }

    @Test func nonceLRUIsBoundedAt1000() {
        var lru = NonceLRU(capacity: BridgeLimits.nonceCapacity)
        for i in 0..<1500 { lru.insert("n\(i)") }
        #expect(lru.count == 1000)
        #expect(!lru.contains("n0"))
        #expect(lru.contains("n1499"))
        #expect(lru.contains("n500"))
    }

    @Test func forgedNonceIsNotRecorded() {
        var v = BridgeVerifier(key: Self.key)
        var forged = BridgeCrypto.seal(text: "x", key: Self.key, ts: Self.now, nonce: "N1")
        forged.text = "y"
        #expect(v.verify(forged, nowMs: Self.now) == .badMAC)
        #expect(v.verify(BridgeCrypto.seal(text: "x", key: Self.key, ts: Self.now, nonce: "N1"), nowMs: Self.now) == .ok)
    }

    @Test func rejectsOversizeText() {
        var v = BridgeVerifier(key: Self.key)
        let big = String(repeating: "a", count: BridgeLimits.maxTextBytes + 1)
        #expect(v.verify(BridgeCrypto.seal(text: big, key: Self.key, ts: Self.now), nowMs: Self.now) == .tooLarge)
        let exact = String(repeating: "a", count: BridgeLimits.maxTextBytes)
        #expect(v.verify(BridgeCrypto.seal(text: exact, key: Self.key, ts: Self.now), nowMs: Self.now) == .ok)
        // 20 KB is bytes, not characters: 7000 × "€" (3 bytes) = 21 000 bytes.
        let euros = String(repeating: "€", count: 7000)
        #expect(v.verify(BridgeCrypto.seal(text: euros, key: Self.key, ts: Self.now), nowMs: Self.now) == .tooLarge)
    }

    @Test func rejectsWrongVersion() {
        var v = BridgeVerifier(key: Self.key)
        var m = BridgeCrypto.seal(text: "a", key: Self.key, ts: Self.now)
        m.v = 2
        #expect(v.verify(m, nowMs: Self.now) == .badVersion)
    }

    @Test func macFieldsAreUnambiguous() {
        // nonce "ab" + text "c" must not MAC like nonce "a" + text "bc".
        let a = BridgeCrypto.mac(key: Self.key, v: 1, nonce: "ab", ts: 5, text: "c")
        let b = BridgeCrypto.mac(key: Self.key, v: 1, nonce: "a", ts: 5, text: "bc")
        #expect(a != b)
    }

    @Test func framingRoundTrip() throws {
        let f = BridgeFraming.frame(Data("{}".utf8))
        #expect(BridgeFraming.length(f.prefix(4)) == 2)
        #expect(f.dropFirst(4) == Data("{}".utf8))
    }
}

@Suite struct TailnetAddressTests {
    @Test func ipv4Range() {
        for ok in ["100.64.0.0", "100.64.0.1", "100.100.100.100", "100.127.255.255", "100.101.102.103"] {
            #expect(TailnetAddress.isTailnet(ok), "\(ok)")
        }
        for bad in ["100.63.255.255", "100.128.0.0", "100.0.0.1", "10.0.0.1", "192.168.1.10", "127.0.0.1",
                    "0.0.0.0", "8.8.8.8", "101.64.0.1", "", "localhost", "macmini.tail1234.ts.net",
                    "100.64.0", "100.64.0.1.5", "100.64.0.256"] {
            #expect(!TailnetAddress.isTailnet(bad), "\(bad)")
        }
    }

    @Test func ipv6Range() {
        #expect(TailnetAddress.isTailnet("fd7a:115c:a1e0::1"))
        #expect(TailnetAddress.isTailnet("fd7a:115c:a1e0:ab12:4843:cd96:6258:b240"))
        #expect(TailnetAddress.isTailnet("[fd7a:115c:a1e0::1]"))
        #expect(TailnetAddress.isTailnet("fd7a:115c:a1e0::1%utun4"))
        for bad in ["fd7a:115c:a1e1::1", "fd7a:115c::1", "::1", "fe80::1", "2001:db8::1", "::ffff:100.64.0.1"] {
            #expect(!TailnetAddress.isTailnet(bad), "\(bad)")
        }
    }

    @Test func policy() {
        #expect(AddressPolicy.tailnetOnly.permits("100.70.1.2"))
        #expect(!AddressPolicy.tailnetOnly.permits("127.0.0.1"))
        #expect(!AddressPolicy.tailnetOnly.permits("192.168.0.2"))
    }
}

@Suite struct PairingCodeTests {
    static let info = PairingInfo(names: ["Studio Mac", "studio-mac.local"], host: "100.101.102.103",
                                  port: 47_655, key: Data((0..<32).map { UInt8($0 * 7 & 0xFF) }))

    @Test func roundTrip() throws {
        let code = PairingCode.encode(Self.info)
        #expect(code.hasPrefix("WL1-"))
        #expect(try PairingCode.decode(code) == Self.info)
        // Tolerant of case, whitespace, line breaks.
        let messy = "  " + code.lowercased().replacingOccurrences(of: "-", with: " - \n") + "\n"
        #expect(try PairingCode.decode(messy.replacingOccurrences(of: "wl1 - \n", with: "WL1-")) == Self.info)
    }

    @Test func ipv6RoundTrip() throws {
        var i = Self.info
        i.host = "fd7a:115c:a1e0::1234"
        #expect(try PairingCode.decode(PairingCode.encode(i)) == i)
    }

    @Test func detectsDamage() {
        let code = PairingCode.encode(Self.info)
        var chars = Array(code)
        let idx = chars.count / 2
        chars[idx] = chars[idx] == "A" ? "B" : "A"
        #expect(throws: PairingCode.DecodeError.self) { try PairingCode.decode(String(chars)) }
        #expect(throws: PairingCode.DecodeError.self) { try PairingCode.decode(String(code.dropLast(5))) }
        #expect(throws: PairingCode.DecodeError.notAPairingCode) { try PairingCode.decode("hello") }
    }

    @Test func refusesNonTailnetHost() {
        var i = Self.info
        i.host = "192.168.1.5"
        #expect(throws: PairingCode.DecodeError.notTailnet) { try PairingCode.decode(PairingCode.encode(i)) }
    }

    @Test func fingerprintIs8HexChars() {
        let f = PairingCode.fingerprint(key: Self.info.key)
        #expect(f.count == 9 && f.contains("-"))
        #expect(f.replacingOccurrences(of: "-", with: "").allSatisfy { $0.isHexDigit })
        #expect(f == Self.info.fingerprint)
        #expect(f != PairingCode.fingerprint(key: Data(repeating: 0, count: 32)))
    }

    @Test func base32RFCVectors() {
        #expect(Base32.encode(Data("foobar".utf8)) == "MZXW6YTBOI")
        #expect(Base32.decode("MZXW6YTBOI") == Data("foobar".utf8))
        #expect(Base32.decode("mzxw-6ytb oi") == Data("foobar".utf8))
        #expect(Base32.decode("MZ1") == nil)
    }

    @MainActor @Test func storeKeepsKeyInSecretStoreOnly() throws {
        let defaults = UserDefaults(suiteName: "PairingCodeTests-\(UUID())")!
        let secrets = InMemorySecretStore()
        let store = PairedReceiverStore(defaults: defaults, secrets: secrets)
        let config = RemoteConfigStore(defaults: defaults)
        #expect(config.config.defaultReceiverID == nil)
        let r = try store.pair(code: PairingCode.encode(Self.info))
        #expect(config.config.defaultReceiverID == nil)
        #expect(ReceiverMatcher.match(windowTitle: "Unpaired viewer", receivers: store.receivers, defaultID: config.config.defaultReceiverID) == nil)
        #expect(store.receivers.count == 1)
        #expect(store.key(for: r.id) != nil)
        // Re-pairing the same address replaces, not duplicates.
        _ = try store.pair(code: PairingCode.encode(Self.info))
        #expect(store.receivers.count == 1)
        // The persisted list never contains the key bytes.
        let persisted = defaults.data(forKey: PairedReceiverStore.defaultsKey)!
        #expect(persisted.range(of: Self.info.key) == nil)
        #expect(!String(decoding: persisted, as: UTF8.self).contains(Self.info.key.base64EncodedString()))
        // Reload from defaults.
        let again = PairedReceiverStore(defaults: defaults, secrets: secrets)
        #expect(again.receivers == store.receivers)
        store.unpair(r.id)
        #expect(store.receivers.isEmpty)
        #expect(secrets.read(account: r.id.uuidString) == nil)
    }

    @Test func receiverKeyGeneratedOnceThen32Bytes() throws {
        let s = InMemorySecretStore()
        let k1 = try ReceiverIdentity.loadOrCreateKey(store: s)
        let k2 = try ReceiverIdentity.loadOrCreateKey(store: s)
        #expect(k1.count == 32 && k1 == k2)
        let k3 = try ReceiverIdentity.regenerate(store: s)
        #expect(k3 != k1)
    }
}

/// Loopback integration: real `BridgeClient` → real `BridgeServer`, in-process, over
/// 127.0.0.1 with a TEST-ONLY address policy (production only has `.tailnetOnly`).
/// Disabled under scripts/test_offline.sh, whose sandbox denies all sockets.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WISPRLOCAL_NO_SOCKETS"] == nil))
struct BridgeLoopbackTests {
    static let key = SymmetricKey(data: Data(repeating: 3, count: 32))
    static let loopback = AddressPolicy { $0 == "127.0.0.1" }

    final class Sink: Sendable {
        let texts = Mutex<[String]>([])
        let receipts = Mutex<[BridgeStatus]>([])
    }

    func makeServer(_ sink: Sink, accept: Bool = true) -> BridgeServer {
        let s = BridgeServer(bindHost: "127.0.0.1", port: 0, key: Self.key,
                             bindPolicy: Self.loopback, peerPolicy: Self.loopback) { text in
            sink.texts.withLock { $0.append(text) }
            return accept ? .ok : .insertFailed
        }
        s.onReceipt = { st in sink.receipts.withLock { $0.append(st) } }
        return s
    }

    @Test func endToEnd() async throws {
        let sink = Sink()
        let server = makeServer(sink)
        let port = try await server.start()
        defer { server.stop() }
        #expect(port != 0)
        let client = BridgeClient(policy: Self.loopback)
        let ep = BridgeEndpoint(host: "127.0.0.1", port: port)

        let text = "Hello World, it's 10:45!\nLine two £5 — café 😀"
        #expect(try await client.send(text, key: Self.key, to: ep, connectTimeout: .seconds(2)) == .ok)
        #expect(sink.texts.withLock { $0 } == [text])

        // Ping: authenticated, nothing delivered.
        if case .failure(let e) = await client.ping(key: Self.key, to: ep, timeout: .seconds(2)) { Issue.record("ping failed \(e)") }
        #expect(sink.texts.withLock { $0.count } == 1)

        // Wrong key → rejected (safe to fall back), nothing delivered.
        let wrong = SymmetricKey(data: Data(repeating: 9, count: 32))
        await #expect(throws: BridgeClientError.rejected(.badMAC)) {
            try await client.send("nope", key: wrong, to: ep, connectTimeout: .seconds(2))
        }
        #expect(sink.texts.withLock { $0.count } == 1)
        #expect(sink.receipts.withLock { $0 }.contains(.badMAC))
    }

    @Test func insertFailureIsReported() async throws {
        let sink = Sink()
        let server = makeServer(sink, accept: false)
        let port = try await server.start()
        defer { server.stop() }
        let client = BridgeClient(policy: Self.loopback)
        await #expect(throws: BridgeClientError.rejected(.insertFailed)) {
            try await client.send("x", key: Self.key, to: BridgeEndpoint(host: "127.0.0.1", port: port), connectTimeout: .seconds(2))
        }
    }

    @Test func unreachableWhenNothingListens() async throws {
        // Nothing listens on this port (bind+stop gives a free one).
        let sink = Sink()
        let server = makeServer(sink)
        let port = try await server.start()
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let client = BridgeClient(policy: Self.loopback)
        await #expect(throws: BridgeClientError.unreachable) {
            try await client.send("x", key: Self.key, to: BridgeEndpoint(host: "127.0.0.1", port: port))
        }
    }

    /// waitReady must throw as soon as the connection fails, not sit out its deadline.
    @Test func waitReadyThrowsImmediatelyWhenRefused() async throws {
        let server = makeServer(Sink())
        let port = try await server.start()
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { conn.cancel() }
        let start = ContinuousClock.now
        var thrown: Error?
        do { try await BridgeIO.waitReady(conn, timeout: .seconds(10)) } catch { thrown = error }
        let elapsed = ContinuousClock.now - start
        #expect(thrown != nil, "a refused connection must throw")
        if case .timeout? = thrown as? BridgeIOError { Issue.record("threw only at the deadline") }
        #expect(elapsed < .seconds(3), "failure must surface immediately, took \(elapsed)")
    }

    @Test func waitReadySucceedsAgainstAListener() async throws {
        let server = makeServer(Sink())
        let port = try await server.start()
        defer { server.stop() }
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { conn.cancel() }
        try await BridgeIO.waitReady(conn, timeout: .seconds(2))
    }

    @Test func peerOutsidePolicyIsDropped() async throws {
        let sink = Sink()
        // Server bound on loopback but whose PEER policy is tailnet-only: a loopback client is refused.
        let s = BridgeServer(bindHost: "127.0.0.1", port: 0, key: Self.key,
                             bindPolicy: Self.loopback, peerPolicy: .tailnetOnly) { t in
            sink.texts.withLock { $0.append(t) }; return .ok
        }
        let port = try await s.start()
        defer { s.stop() }
        let client = BridgeClient(policy: Self.loopback)
        await #expect(throws: (any Error).self) {
            try await client.send("x", key: Self.key, to: BridgeEndpoint(host: "127.0.0.1", port: port), connectTimeout: .seconds(1))
        }
        #expect(sink.texts.withLock { $0 }.isEmpty)
    }
}

/// STRUCTURAL (no sockets needed): the production bridge refuses every non-tailnet address.
@Suite struct BridgeRefusesNonTailnetTests {
    @Test func senderRefusesBeforeConnecting() async {
        let client = BridgeClient()
        let key = SymmetricKey(data: Data(repeating: 1, count: 32))
        for host in ["127.0.0.1", "192.168.1.20", "10.0.0.5", "8.8.8.8", "example.com", "macmini.tail1234.ts.net", "::1", "fe80::1"] {
            await #expect(throws: BridgeClientError.notTailnet, "\(host)") {
                try await client.send("x", key: key, to: BridgeEndpoint(host: host, port: 47_655))
            }
        }
    }

    @Test func receiverRefusesToBindOffTailnet() async {
        for host in ["127.0.0.1", "0.0.0.0", "192.168.1.20", "::"] {
            let s = BridgeServer(bindHost: host, key: SymmetricKey(data: Data(repeating: 1, count: 32))) { _ in .ok }
            await #expect(throws: BridgeServer.StartError.self, "\(host)") { _ = try await s.start() }
        }
    }
}

/// No sockets: the connection-state → readiness verdict that waitReady acts on.
@Suite struct BridgeReadinessTests {
    @Test func readyIsSuccess() {
        guard case .success? = BridgeIO.readiness(.ready) else { Issue.record("ready must succeed"); return }
    }

    @Test func everyFailureStateThrowsAtOnce() {
        let refused = NWError.posix(.ECONNREFUSED)
        for state: NWConnection.State in [.failed(refused), .waiting(refused), .cancelled] {
            guard case .failure? = BridgeIO.readiness(state) else { Issue.record("\(state) must fail"); continue }
        }
        if case .failure(let e)? = BridgeIO.readiness(.cancelled) {
            #expect((e as? BridgeIOError).map { if case .closed = $0 { true } else { false } } == true)
        }
    }

    @Test func setupStatesKeepWaiting() {
        for state: NWConnection.State in [.setup, .preparing] {
            if BridgeIO.readiness(state) != nil { Issue.record("\(state) must keep waiting") }
        }
    }

    @Test func cStringDecodingTruncatesAtNul() {
        var buf = [CChar](repeating: 0, count: 46)
        for (i, b) in "100.64.0.1".utf8.enumerated() { buf[i] = CChar(bitPattern: b) }
        buf[20] = CChar(bitPattern: UInt8(ascii: "x"))  // garbage after the NUL is never read
        #expect(TailscaleInterface.decodeCString(buf) == "100.64.0.1")
        #expect(TailscaleInterface.decodeCString([CChar](repeating: 0, count: 4)) == "")
    }
}

@Suite struct BridgeTimestampBoundaryTests {

    static let now: Int64 = 1_800_000_000_000
    static let key = BridgeVerifierTests.key
    @Test(arguments: [Int64.min, Int64.max, now - BridgeLimits.maxClockSkewMs - 1,
                      now + BridgeLimits.maxClockSkewMs + 1])
    func extremeTimestampsRejectBeforeMAC(_ ts: Int64) {
        var verifier = BridgeVerifier(key: Self.key)
        var message = BridgeCrypto.seal(text: "test", key: Self.key, ts: Self.now)
        message.ts = ts; message.mac = "invalid"
        #expect(verifier.verify(message, nowMs: Self.now) == .stale)
    }
    @Test(arguments: [-BridgeLimits.maxClockSkewMs, Int64(0), BridgeLimits.maxClockSkewMs])
    func clockWindowIncludesBoundaries(_ delta: Int64) {
        var verifier = BridgeVerifier(key: Self.key)
        #expect(verifier.verify(BridgeCrypto.seal(text: "test", key: Self.key, ts: Self.now + delta), nowMs: Self.now) == .ok)
    }

}

@Suite struct PairingDefaultRegressionTests {
    @Test func pairingUILeavesDefaultSelectionExplicit() throws {
        // Pairing UI is in the executable target; guard its production entry point as well as
        // the Core store's behavioural test above.
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: app.appendingPathComponent("Sources/WisprLocal/RemoteSettingsView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func pair()"))
        let end = try #require(source.range(of: "private func unpair", range: start.upperBound..<source.endIndex))
        #expect(!source[start.lowerBound..<end.lowerBound].contains("defaultReceiverID"))
    }
}


extension BridgeReadinessTests {
    @Test func sendFailureAfterHandoffIsUnconfirmed() async {
        let client = BridgeClient(policy: BridgeLoopbackTests.loopback)
        await #expect(throws: BridgeClientError.unconfirmed) {
            try await client.transmit { throw BridgeIOError.closed }
        }
        #expect(!BridgeClientError.unconfirmed.safeToFallBack)
    }
}

extension BridgeLoopbackTests {
    @Test func stopCancelsAcceptedConnectionAndRefusesOldGeneration() async throws {
        let sink = Sink(), entered = OneShot<Bool>(), release = OneShot<Bool>()
        let visits = Mutex(0)
        let server = BridgeServer(bindHost: "127.0.0.1", port: 0, key: Self.key,
                                  bindPolicy: Self.loopback, peerPolicy: Self.loopback, beforeDelivery: {
            let first = visits.withLock { n in n += 1; return n == 1 }
            if first {
                entered.resume(.success(true))
                _ = try? await withCheckedThrowingContinuation { release.install($0) }
            }
        }, deliver: { text in sink.texts.withLock { $0.append(text) }; return .ok })
        let port = try await server.start()
        defer { server.stop() }
        let client = BridgeClient(policy: Self.loopback)
        let sending = Task {
            try await client.send("old generation", key: Self.key,
                                  to: BridgeEndpoint(host: "127.0.0.1", port: port), connectTimeout: .seconds(2))
        }
        _ = try await withCheckedThrowingContinuation { entered.install($0) }
        #expect(server.acceptedConnectionCount == 1)
        server.stop()
        #expect(server.acceptedConnectionCount == 0)
        let newPort = try await server.start()
        release.resume(.success(true))
        await #expect(throws: BridgeClientError.unconfirmed) { try await sending.value }
        #expect(sink.texts.withLock { $0.isEmpty })
        #expect(try await client.send("new generation", key: Self.key,
                                      to: BridgeEndpoint(host: "127.0.0.1", port: newPort), connectTimeout: .seconds(2)) == .ok)
        #expect(sink.texts.withLock { $0 } == ["new generation"])
    }
}


extension BridgeLoopbackTests {
    @Test func deliveryGuardRefusesStopDuringDeliveryWait() async throws {
        let sink = Sink(), entered = OneShot<Bool>(), release = OneShot<Bool>(), finished = OneShot<Bool>()
        let server = BridgeServer(bindHost: "127.0.0.1", port: 0, key: Self.key,
                                  bindPolicy: Self.loopback, peerPolicy: Self.loopback, guardedDeliver: { text, isCurrent in
            entered.resume(.success(true))
            _ = try? await withCheckedThrowingContinuation { release.install($0) }
            defer { finished.resume(.success(true)) }
            guard isCurrent() else { return .insertFailed }
            sink.texts.withLock { $0.append(text) }
            return .ok
        }, deliver: { _ in .insertFailed })
        let port = try await server.start()
        defer { server.stop() }
        let sending = Task {
            try await BridgeClient(policy: Self.loopback).send("old generation", key: Self.key,
                            to: BridgeEndpoint(host: "127.0.0.1", port: port), connectTimeout: .seconds(2))
        }
        _ = try await withCheckedThrowingContinuation { entered.install($0) }
        server.stop()
        release.resume(.success(true))
        _ = try await withCheckedThrowingContinuation { finished.install($0) }
        await #expect(throws: BridgeClientError.unconfirmed) { try await sending.value }
        #expect(sink.texts.withLock { $0.isEmpty })
    }
}
