import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import WisprLocalCore

/// Fake bridge: reachable → `.ok`, else throws the given error.
final class FakeBridge: RemoteBridgeSending {
    let outcome: BridgeClientError?
    let sent = Mutex<[(String, BridgeEndpoint)]>([])
    init(failing: BridgeClientError? = nil) { outcome = failing }
    func send(_ text: String, key: SymmetricKey, to: BridgeEndpoint, connectTimeout: Duration) async throws -> BridgeStatus {
        if let outcome { throw outcome }
        sent.withLock { $0.append((text, to)) }
        return .ok
    }
}

@MainActor @Suite struct RemoteRouterTests {
    static let mini = PairedReceiver(names: ["Studio Mac", "studio-mac.local"], host: "100.90.1.2", port: 47_655, fingerprint: "AAAA-BBBB")
    static let studio = PairedReceiver(names: ["Studio"], host: "100.90.1.3", port: 47_655, fingerprint: "CCCC-DDDD")

    func makeRemote(bridge: FakeBridge, fallback: FakeInserter, receivers: [PairedReceiver] = [mini],
                    title: String? = "Studio Mac", defaultID: UUID? = nil) -> RemoteInserter {
        RemoteInserter(config: { RemoteConfig(defaultReceiverID: defaultID) },
                       receivers: { receivers },
                       keyFor: { _ in SymmetricKey(data: Data(repeating: 1, count: 32)) },
                       sender: bridge,
                       windowTitle: { title },
                       // A fixed target: the live FocusProbe would follow whatever app is frontmost while the
                       // suite runs, and the pre-fallback recheck would then (correctly) refuse to type.
                       focus: { FocusToken(pid: 1, windowTitle: title) },
                       fallbackFor: { _, _ in fallback })
    }

    @Test func localAppGetsPaste() {
        let paste = FakeInserter(name: "paste")
        let ri = RoutingInserter(router: InsertionRouter(), paste: paste, typing: FakeInserter(name: "typing"),
                                 remoteStrategy: FakeInserter(name: "remote"))
        #expect(ri.inserter(forBundleID: "com.apple.TextEdit") === paste)
        #expect(ri.inserter(forBundleID: nil) === paste)
    }

    @Test func allDefaultViewersRouteRemote() {
        let r = InsertionRouter()
        for id in RemoteConfig.defaultViewerBundleIDs { #expect(r.strategy(forBundleID: id) == .remote, "\(id)") }
        #expect(r.strategy(forBundleID: "com.tinyspeck.slackmacgap") == .paste)
    }

    @Test func defaultRoutingInserterUsesRemoteInserter() {
        let ri = RoutingInserter(router: InsertionRouter(), paste: FakeInserter(), typing: FakeInserter())
        #expect(ri.inserter(forBundleID: "com.apple.ScreenSharing") is RemoteInserter)
    }

    @Test func screenSharingWithReachableReceiverUsesReceiver() async throws {
        let bridge = FakeBridge(), fallback = FakeInserter(name: "typing")
        let remote = makeRemote(bridge: bridge, fallback: fallback)
        let ri = RoutingInserter(router: InsertionRouter(), paste: FakeInserter(), typing: FakeInserter(), remoteStrategy: remote)
        try await ri.inserter(forBundleID: "com.apple.ScreenSharing").insert("hello")
        #expect(bridge.sent.withLock { $0.map(\.0) } == ["hello"])
        #expect(bridge.sent.withLock { $0.first?.1 } == Self.mini.endpoint)
        #expect(fallback.inserted.isEmpty)
        #expect(remote.lastRoute == "receiver:Studio Mac")
    }

    @Test func unreachableReceiverFallsBackToTyping() async throws {
        let fallback = FakeInserter(name: "typing")
        let remote = makeRemote(bridge: FakeBridge(failing: .unreachable), fallback: fallback)
        try await remote.insert("hello")
        #expect(fallback.inserted == ["hello"])
    }

    /// SEC-4: a receiver's answer is final — only "nothing reached it" falls back.
    @Test func rejectedMessageDoesNotFallBackAndNeitherDoesUnconfirmed() async throws {
        let f1 = FakeInserter()
        await #expect(throws: BridgeClientError.rejected(.badMAC)) {
            try await makeRemote(bridge: FakeBridge(failing: .rejected(.badMAC)), fallback: f1).insert("a")
        }
        #expect(f1.inserted.isEmpty)
        let f2 = FakeInserter()
        await #expect(throws: BridgeClientError.unconfirmed) {
            try await makeRemote(bridge: FakeBridge(failing: .unconfirmed), fallback: f2).insert("a")
        }
        #expect(f2.inserted.isEmpty, "no double insertion")
    }

    @Test func noPairedReceiverTypesDirectly() async throws {
        let bridge = FakeBridge(), fallback = FakeInserter()
        try await makeRemote(bridge: bridge, fallback: fallback, receivers: []).insert("x")
        #expect(fallback.inserted == ["x"])
        #expect(bridge.sent.withLock { $0.isEmpty })
    }

    @Test func unmatchedTitleUsesDefaultReceiverElseTyping() async throws {
        let bridge = FakeBridge(), fallback = FakeInserter()
        try await makeRemote(bridge: bridge, fallback: fallback, receivers: [Self.mini, Self.studio],
                             title: "Some other Mac", defaultID: Self.studio.id).insert("x")
        #expect(bridge.sent.withLock { $0.first?.1 } == Self.studio.endpoint)
        let f2 = FakeInserter()
        try await makeRemote(bridge: FakeBridge(), fallback: f2, receivers: [Self.mini, Self.studio],
                             title: "Some other Mac", defaultID: nil).insert("y")
        #expect(f2.inserted == ["y"])
    }

    @Test func titleMatching() {
        let all = [Self.mini, Self.studio]
        #expect(ReceiverMatcher.match(windowTitle: "Studio Mac", receivers: all, defaultID: nil) == Self.mini)
        #expect(ReceiverMatcher.match(windowTitle: "studio-mac.local", receivers: all, defaultID: nil) == Self.mini)
        #expect(ReceiverMatcher.match(windowTitle: "100.90.1.3", receivers: all, defaultID: nil) == Self.studio)
        #expect(ReceiverMatcher.match(windowTitle: "Studio — Screen Sharing", receivers: all, defaultID: Self.mini.id) == Self.studio)
        #expect(ReceiverMatcher.match(windowTitle: nil, receivers: all, defaultID: Self.mini.id) == Self.mini)
        #expect(ReceiverMatcher.match(windowTitle: "Laptop", receivers: all, defaultID: nil) == nil)
        // An IP's first octet is not a token ("100" must not match everything).
        let ipNamed = PairedReceiver(names: ["100.90.1.9"], host: "100.90.1.9", port: 1, fingerprint: "")
        #expect(ReceiverMatcher.match(windowTitle: "100.90.1.2", receivers: [ipNamed], defaultID: nil) == nil)
    }

    @Test func configDefaultsAndPersistence() {
        #expect(RemoteConfig.defaultTypingFallback == .unicode)
        #expect(RemoteConfig().clipboardDelayMs == 1500)
        let d = UserDefaults(suiteName: "RemoteConfig-\(UUID())")!
        let s = RemoteConfigStore(defaults: d)
        s.config.typingFallback = .keycode
        s.config.viewerBundleIDs.append("com.example.viewer")
        let again = RemoteConfigStore(defaults: d)
        #expect(again.config.typingFallback == .keycode)
        #expect(again.config.viewerBundleIDs.contains("com.example.viewer"))
    }
}

@MainActor @Suite struct RemoteTypingTests {
    @Test func unicodePlanOneCharPerStepShiftReturn() {
        let steps = RemoteTypingPlanner.plan("a😀\nb\r\nc", mode: .unicode)
        #expect(steps == [.unicode(Array("a".utf16)), .unicode(Array("😀".utf16)), .stroke(RemoteTypingPlanner.shiftReturn),
                          .unicode(Array("b".utf16)), .stroke(RemoteTypingPlanner.shiftReturn), .unicode(Array("c".utf16))])
        #expect(RemoteTypingPlanner.shiftReturn == KeyStroke(keyCode: UInt16(kVK_Return), flags: .maskShift))
    }

    @Test func keycodePlanFallsBackToUnicodePerChar() {
        let map: [Character: KeyStroke] = ["a": KeyStroke(keyCode: 0, flags: []), "A": KeyStroke(keyCode: 0, flags: .maskShift)]
        let steps = RemoteTypingPlanner.plan("aA—\n", mode: .keycode, map: map)
        #expect(steps == [.stroke(KeyStroke(keyCode: 0, flags: [])), .stroke(KeyStroke(keyCode: 0, flags: .maskShift)),
                          .unicode(Array("—".utf16)), .stroke(RemoteTypingPlanner.shiftReturn)])
    }

    @Test func pacedTypingPostsEveryStep() async throws {
        var posted: [TypingStep] = []
        let t = PacedTypingInserter(mode: .unicode, interval: .milliseconds(0),
                                    focus: { _ in FocusToken(pid: 1, windowTitle: "w") }, post: { posted.append($0) })
        try await t.insert("hi\nyo")
        #expect(posted.count == 5)
        #expect(PacedTypingInserter.defaultInterval == .milliseconds(4))
    }

    @Test func pacedTypingAbortsWhenFocusChanges() async {
        var posted = 0
        let t = PacedTypingInserter(mode: .unicode, interval: .milliseconds(0),
                                    focus: { _ in FocusToken(pid: posted >= 1 ? 2 : 1, windowTitle: nil) },
                                    post: { _ in posted += 1 })
        await #expect(throws: RemoteTypingError.focusChanged(typed: 1, of: 10)) { try await t.insert("0123456789") }
        #expect(posted == 1)
    }

    @Test func pacedTypingAbortsWhenWindowTitleChanges() async {
        var posted = 0
        let t = PacedTypingInserter(mode: .unicode, interval: .milliseconds(0),
                                    focus: { full in FocusToken(pid: 1, windowTitle: full ? (posted > 0 ? "other" : "mini") : nil) },
                                    post: { _ in posted += 1 })
        let text = String(repeating: "x", count: 40)
        await #expect(throws: RemoteTypingError.focusChanged(typed: 16, of: 40)) { try await t.insert(text) }
    }

    @Test func clipboardDelayPastesAfterDelayAndAbortsOnFocusChange() async throws {
        let pb = NSPasteboardShim.make()
        pb.clearContents(); pb.setString("user clip", forType: .string)
        var pasted = 0
        let clock = ManualClock()
        let c = ClipboardDelayInserter(delay: .milliseconds(20), restoreAfter: .milliseconds(10), pasteboard: pb,
                                       focus: { _ in FocusToken(pid: 1, windowTitle: "w") }, postPaste: { pasted += 1 }, clock: clock)
        let first = Task { @MainActor in try await c.insert("dictated") }
        await clock.waitForSleepers(count: 1)          // waiting out the sync delay
        #expect(pasted == 0)
        await clock.advance(by: .milliseconds(20))
        try await first.value
        #expect(pasted == 1)
        #expect(pb.string(forType: .string) == "dictated")
        await clock.advance(by: .milliseconds(10))            // restore deadline
        await eventually { pb.string(forType: .string) == "user clip" }

        let state = RemoteFocusState()
        let c2 = ClipboardDelayInserter(delay: .milliseconds(10), pasteboard: pb,
                                        focus: { _ in FocusToken(pid: state.pid, windowTitle: nil) },
                                        postPaste: { pasted += 1 }, clock: clock)
        let second = Task { @MainActor in try await c2.insert("x") }
        await clock.waitForSleepers(count: 1)
        state.pid = 2
        await clock.advance(by: .milliseconds(10))
        await #expect(throws: RemoteTypingError.self) { try await second.value }
        #expect(pasted == 1)
        #expect(pb.string(forType: .string) == "user clip")
    }
}

enum NSPasteboardShim {
    static func make() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("WisprLocalTests-\(UUID().uuidString)")) }
}

@MainActor @Suite struct KeyStrokeMapTests {
    @Test func currentLayoutMapping() throws {
        guard let data = KeyboardLayoutMap.layoutData() else { return }  // no layout data (CI)
        let map = KeyStrokeMap.build(layoutData: data)
        var missing: [Character] = []
        for v in 0x20...0x7E {
            let c = Character(UnicodeScalar(UInt8(v)))
            if map[c] == nil { missing.append(c) }
        }
        #expect(missing.count <= 9, "unmapped ASCII: \(missing)")
        #expect(map[" "]?.keyCode == 49)
        #expect(map["\t"]?.keyCode == UInt16(kVK_Tab))
        for c in "ABCXYZ" {
            guard let upper = map[c], let lower = map[Character(c.lowercased())] else { Issue.record("missing \(c)"); continue }
            #expect(upper.flags.contains(.maskShift))
            #expect(!lower.flags.contains(.maskShift))
            #expect(upper.keyCode == lower.keyCode)
        }
        // Fewest modifiers win: no plain letter needs Option.
        #expect(map["a"]?.flags == [])
    }

    @Test func sharedMapIsCachedAndInvalidates() {
        let m = KeyStrokeMap()
        let a = m.current
        m.invalidate()
        #expect(m.current == a)
    }
}

extension RemoteTypingTests {
    @Test func cancellationStopsAtTheTypedPrefix() async {
        var posts = 0
        let typing = PacedTypingInserter(mode: .unicode, interval: .seconds(10),
                                        focus: { _ in FocusToken(pid: 1, windowTitle: nil) },
                                        post: { _ in posts += 1 })
        let task = Task { try await typing.insert(String(repeating: "x", count: 300)) }
        await eventually { posts == 1 }
        task.cancel()
        await #expect(throws: TypingCancellation(typed: 1, total: 300)) { try await task.value }
        #expect(posts == 1)
    }

    @Test func cancellationDuringClipboardDelayDoesNotPaste() async {
        let pb = NSPasteboardShim.make(), clock = ManualClock()
        pb.clearContents(); pb.setString("user clipboard", forType: .string)
        var posts = 0
        let paste = ClipboardDelayInserter(pasteboard: pb, focus: { _ in FocusToken(pid: 1, windowTitle: nil) },
                                          postPaste: { posts += 1 }, clock: clock)
        let task = Task { try await paste.insert("A") }
        await clock.waitForSleepers(count: 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(posts == 0)
        #expect(pb.string(forType: .string) == "user clipboard")
    }
}

private struct CancellingBridge: RemoteBridgeSending {
    func send(_ text: String, key: SymmetricKey, to: BridgeEndpoint, connectTimeout: Duration) async throws -> BridgeStatus {
        withUnsafeCurrentTask { $0?.cancel() }
        throw BridgeClientError.unreachable
    }
}

extension RemoteRouterTests {
    @Test func cancelledBridgeAttemptNeverFallsBack() async {
        let fallback = FakeInserter()
        let remote = RemoteInserter(config: { RemoteConfig() }, receivers: { [Self.mini] },
                                    keyFor: { _ in SymmetricKey(data: Data(repeating: 1, count: 32)) },
                                    sender: CancellingBridge(), windowTitle: { "Studio Mac" },
                                    focus: { FocusToken(pid: 1, windowTitle: "Studio Mac") },
                                    fallbackFor: { _, _ in fallback })
        let task = Task { try await remote.insert("dictated") }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fallback.inserted.isEmpty)
    }
}

@MainActor private final class RemoteFocusState { var pid: Int32 = 1 }

private struct SuspendedBridge: RemoteBridgeSending {
    let entered: OneShot<Bool>
    let release: OneShot<Bool>
    func send(_ text: String, key: SymmetricKey, to: BridgeEndpoint, connectTimeout: Duration) async throws -> BridgeStatus {
        entered.resume(.success(true))
        _ = try await withCheckedThrowingContinuation { release.install($0) }
        throw BridgeClientError.unreachable
    }
}

extension RemoteRouterTests {
    @Test func appSwitchDuringBridgeWaitPostsNothing() async throws {
        let entered = OneShot<Bool>(), release = OneShot<Bool>()
        let state = RemoteFocusState()
        var posts = 0
        let typing = PacedTypingInserter(mode: .unicode, focus: { _ in FocusToken(pid: state.pid, windowTitle: "viewer") },
                                        post: { _ in posts += 1 })
        let remote = RemoteInserter(config: { RemoteConfig() }, receivers: { [Self.mini] },
                                    keyFor: { _ in SymmetricKey(data: Data(repeating: 1, count: 32)) },
                                    sender: SuspendedBridge(entered: entered, release: release), windowTitle: { "Studio Mac" },
                                    focus: { FocusToken(pid: state.pid, windowTitle: "viewer") }, fallbackFor: { _, _ in typing })
        let task = Task { try await remote.insert("hello") }
        _ = try await withCheckedThrowingContinuation { entered.install($0) }
        state.pid = 2
        release.resume(.success(true))
        await #expect(throws: RemoteTypingError.focusChanged(typed: 0, of: 5)) { try await task.value }
        #expect(posts == 0)
    }

    @Test func unknownBridgeErrorNeverFallsBack() async {
        struct FailedBridge: RemoteBridgeSending {
            func send(_ text: String, key: SymmetricKey, to: BridgeEndpoint, connectTimeout: Duration) async throws -> BridgeStatus {
                throw CocoaError(.fileReadUnknown)
            }
        }
        let fallback = FakeInserter()
        let remote = RemoteInserter(config: { RemoteConfig() }, receivers: { [Self.mini] },
                                    keyFor: { _ in SymmetricKey(data: Data(repeating: 1, count: 32)) },
                                    sender: FailedBridge(), windowTitle: { "Studio Mac" },
                                    focus: { FocusToken(pid: 1, windowTitle: "Studio Mac") }, fallbackFor: { _, _ in fallback })
        await #expect(throws: CocoaError.self) { try await remote.insert("hello") }
        #expect(fallback.inserted.isEmpty)
    }
}

extension RemoteTypingTests {
    @Test func perChunkGateStopsSecureInputAndConflict() async {
        for error: PasteGateError in [.secureInput, .conflict("Another dictation app is active")] {
            var posts = 0
            let target = FocusToken(pid: 1, windowTitle: "viewer")
            let typing = PacedTypingInserter(mode: .unicode, interval: .zero, focus: { _ in target }, post: { _ in posts += 1 })
            await #expect(throws: RemoteTypingBlocked.self) {
                try await typing.insert("hello", target: target, prePostCheck: { if posts > 0 { throw error } })
            }
            #expect(posts == 1)
        }
    }

    @Test func suppliedOriginalWindowIsCheckedBeforeFirstChunk() async {
        var posts = 0
        let typing = PacedTypingInserter(mode: .unicode, focus: { _ in FocusToken(pid: 1, windowTitle: "other") },
                                        post: { _ in posts += 1 })
        await #expect(throws: RemoteTypingError.focusChanged(typed: 0, of: 5)) {
            try await typing.insert("hello", target: FocusToken(pid: 1, windowTitle: "viewer"), prePostCheck: {})
        }
        #expect(posts == 0)
    }

    @Test func slowAXProviderTimesOutWithoutWaitingForProvider() async {
        let release = DispatchSemaphore(value: 0)
        let finished = Mutex(false)
        defer { release.signal() }
        let token = await FocusProbe.boundedRead(pid: 1) {
            release.wait()
            finished.withLock { $0 = true }
            return FocusToken(pid: 1, windowTitle: "late title")
        }
        // The deadline returns while the fake AX call remains blocked on another queue.
        #expect(token == FocusToken(pid: 1, windowTitle: nil))
        #expect(!finished.withLock { $0 })
    }
}


extension RemoteTypingTests {
    @Test func sameTitleDifferentWindowStopsWithinOneChunk() async {
        var target = FocusToken(pid: 1, windowTitle: "Viewer")
        target.window = AXIdentity("first window" as CFString)
        var current = target
        var posts = 0
        let typing = PacedTypingInserter(mode: .unicode, interval: .zero, focus: { _ in current }, post: { _ in
            posts += 1
            current.window = AXIdentity("second window" as CFString)
        })
        await #expect(throws: RemoteTypingError.focusChanged(typed: 16, of: 40)) {
            try await typing.insert(String(repeating: "x", count: 40), target: target, prePostCheck: {})
        }
        #expect(posts == 16)
    }

    @Test func appSwitchDuringFocusReadStopsBeforeFirstChunk() async {
        var pid: Int32 = 1
        var posts = 0
        let typing = PacedTypingInserter(mode: .unicode, focus: { full in
            if full {
                let captured = FocusToken(pid: pid, windowTitle: "Viewer")
                pid = 2  // the AX result belongs to the app that was frontmost before its read
                return captured
            }
            return FocusToken(pid: pid, windowTitle: nil)
        }, post: { _ in posts += 1 })
        await #expect(throws: RemoteTypingError.focusChanged(typed: 0, of: 5)) {
            try await typing.insert("hello", target: FocusToken(pid: 1, windowTitle: "Viewer"), prePostCheck: {})
        }
        #expect(posts == 0)
    }

    @Test(arguments: [PasteGateError.secureInput, .conflict("Another dictation app is active")])
    func clipboardFallbackRechecksGatesAfterDelay(error: PasteGateError) async {
        let clock = ManualClock(), pb = NSPasteboardShim.make()
        pb.setString("User clipboard", forType: .string)
        let target = FocusToken(pid: 1, windowTitle: "Viewer")
        var blocked = false, posts = 0
        let paste = ClipboardDelayInserter(delay: .milliseconds(10), pasteboard: pb, focus: { _ in target },
                                          postPaste: { posts += 1 }, clock: clock)
        let task = Task {
            try await paste.insert("hello", target: target, prePostCheck: { if blocked { throw error } })
        }
        await clock.waitForSleepers(count: 1)
        blocked = true
        await clock.advance(by: .milliseconds(10))
        await #expect(throws: error) { try await task.value }
        #expect(posts == 0)
        #expect(pb.string(forType: .string) == "User clipboard")
    }
}

extension RemoteTypingTests {
    @Test func fullFocusChecksOnlyBeforeEachSixteenKeystrokeChunk() async throws {
        var posts = 0, fullAt: [Int] = [], cheapAt: [Int] = [], gatesAt: [Int] = []
        let target = FocusToken(pid: 1, windowTitle: "Viewer")
        let typing = PacedTypingInserter(mode: .unicode, interval: .zero, focus: { full in
            if full { fullAt.append(posts) } else { cheapAt.append(posts) }
            return target
        }, post: { _ in posts += 1 })
        try await typing.insert(String(repeating: "x", count: 40), target: target, prePostCheck: { gatesAt.append(posts) })
        #expect(fullAt == [0, 16, 32])
        #expect(cheapAt == Array(0..<40))
        #expect(gatesAt == Array(0..<40))
    }

    @Test(arguments: [0, 16])
    func cancellationDuringFullFocusCheckRetainsTypedCount(at: Int) async {
        var posts = 0
        let target = FocusToken(pid: 1, windowTitle: "Viewer")
        let typing = PacedTypingInserter(mode: .unicode, interval: .zero, focus: { full in
            if full && posts == at { withUnsafeCurrentTask { $0?.cancel() } }
            return target
        }, post: { _ in posts += 1 })
        let task = Task { try await typing.insert(String(repeating: "x", count: 40), target: target, prePostCheck: {}) }
        await #expect(throws: TypingCancellation(typed: at, total: 40)) { try await task.value }
        #expect(posts == at)
    }

    @Test func cancellationErrorFromCheckRetainsTypedCount() async {
        var posts = 0
        let target = FocusToken(pid: 1, windowTitle: "Viewer")
        let typing = PacedTypingInserter(mode: .unicode, interval: .zero, focus: { _ in target }, post: { _ in posts += 1 })
        await #expect(throws: TypingCancellation(typed: 16, total: 40)) {
            try await typing.insert(String(repeating: "x", count: 40), target: target, prePostCheck: {
                if posts == 16 { throw CancellationError() }
            })
        }
        #expect(posts == 16)
    }
}
