import AppKit
import Testing
import Foundation
import CryptoKit
import Synchronization
@testable import WisprLocalCore

/// SEC-4 (STRUCTURAL): the receiver refuses while ITS Mac has Secure Event Input on, and the
/// sender never overrides a receiver refusal by typing the same text via Screen Sharing.
@MainActor @Suite struct RemoteSecureInputTests {
    final class InsertSpy { var calls: [String] = [] }

    @Test func receiverRefusesWhileSecureInputIsOnWithoutTouchingThePasteboard() async {
        let spy = InsertSpy()
        let s = await ReceiverDeliveryPolicy.deliver("hunter2", secureInputActive: { true }, accessibilityTrusted: { true },
                                                     insert: { spy.calls.append($0) })
        #expect(s == .secureInput)
        #expect(spy.calls.isEmpty)
    }

    @Test func receiverSecureInputRaceReportsRefusal() async {
        let status = await ReceiverDeliveryPolicy.deliver("private", secureInputActive: { false },
                                                        accessibilityTrusted: { true },
                                                        insert: { _ in throw PasteGateError.secureInput })
        #expect(status == .secureInput)
        #expect(BridgeClientError.rejected(status).isRemoteSecureInput)
    }

    @Test func receiverPolicyTable() async {
        let spy = InsertSpy()
        #expect(await ReceiverDeliveryPolicy.deliver("a", secureInputActive: { false }, accessibilityTrusted: { false },
                                                      insert: { spy.calls.append($0) }) == .insertFailed)
        #expect(await ReceiverDeliveryPolicy.deliver("b", secureInputActive: { false }, accessibilityTrusted: { true },
                                                      insert: { _ in throw InjectedInsertError() }) == .insertFailed)
        #expect(await ReceiverDeliveryPolicy.deliver("c", secureInputActive: { false }, accessibilityTrusted: { true },
                                                      insert: { spy.calls.append($0) }) == .ok)
        // Secure input is checked FIRST, even when Accessibility is missing.
        #expect(await ReceiverDeliveryPolicy.deliver("d", secureInputActive: { true }, accessibilityTrusted: { false },
                                                      insert: { spy.calls.append($0) }) == .secureInput)
        #expect(spy.calls == ["c"])
    }

    @Test func fallBackOnlyWhenNothingReachedTheReceiver() {
        #expect(BridgeClientError.unreachable.safeToFallBack)
        #expect(BridgeClientError.notTunnel.safeToFallBack)
        #expect(BridgeClientError.notTailnet.safeToFallBack)
        #expect(!BridgeClientError.unconfirmed.safeToFallBack)
        let statuses: [BridgeStatus] = [.secureInput, .insertFailed, .badMAC, .stale, .replay, .tooLarge,
                                        .malformed, .badVersion, .forbiddenPeer]
        for s in statuses { #expect(!BridgeClientError.rejected(s).safeToFallBack, "\(s)") }
        #expect(BridgeClientError.rejected(.secureInput).isRemoteSecureInput)
    }

    func remote(_ bridge: FakeBridge, _ fallback: FakeInserter) -> RemoteInserter {
        RemoteInserter(config: { RemoteConfig() }, receivers: { [RemoteRouterTests.studio] },
                       keyFor: { _ in SymmetricKey(data: Data(repeating: 1, count: 32)) },
                       sender: bridge, windowTitle: { "Studio" }, focus: { FocusToken(pid: 1, windowTitle: "Studio") },
                       fallbackFor: { _, _ in fallback })
    }

    @Test func senderDoesNotTypeWhenReceiverReportsSecureInput() async {
        let fallback = FakeInserter(name: "typing")
        let r = remote(FakeBridge(failing: .rejected(.secureInput)), fallback)
        await #expect(throws: RemoteInsertionError.remoteSecureInput("Studio")) { try await r.insert("hunter2") }
        #expect(fallback.inserted.isEmpty, "typing fallback must not override the remote refusal")
        #expect(r.lastRoute == "receiver-secure-input")
    }

    @Test func senderDoesNotTypeWhenReceiverFailedToInsert() async {
        let fallback = FakeInserter(name: "typing")
        let r = remote(FakeBridge(failing: .rejected(.insertFailed)), fallback)
        await #expect(throws: BridgeClientError.rejected(.insertFailed)) { try await r.insert("x") }
        #expect(fallback.inserted.isEmpty)
    }

    @Test func senderTypesOnlyWhenUnreachable() async throws {
        for e in [BridgeClientError.unreachable, .notTunnel] {
            let fallback = FakeInserter(name: "typing")
            try await remote(FakeBridge(failing: e), fallback).insert("x")
            #expect(fallback.inserted == ["x"], "\(e)")
        }
    }

    @Test func remoteSecureInputMessage() {
        #expect(PipelineNotice.remoteSecureInput == "Remote Mac has a password field focused — not inserted")
        #expect(RemoteInsertionError.remoteSecureInput("x").errorDescription == PipelineNotice.remoteSecureInput)
    }

    /// Over real loopback sockets: the receiver's `.secureInput` reaches the sender as a refusal.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISPRLOCAL_NO_SOCKETS"] == nil))
    func secureInputStatusCrossesTheWire() async throws {
        let receipts = Mutex<[BridgeStatus]>([])
        let s = BridgeServer(bindHost: "127.0.0.1", port: 0, key: BridgeLoopbackTests.key,
                             bindPolicy: BridgeLoopbackTests.loopback, peerPolicy: BridgeLoopbackTests.loopback) { _ in
            .secureInput
        }
        s.onReceipt = { st in receipts.withLock { $0.append(st) } }
        let port = try await s.start()
        defer { s.stop() }
        let client = BridgeClient(policy: BridgeLoopbackTests.loopback)
        await #expect(throws: BridgeClientError.rejected(.secureInput)) {
            try await client.send("hunter2", key: BridgeLoopbackTests.key, to: BridgeEndpoint(host: "127.0.0.1", port: port),
                                  connectTimeout: .seconds(2))
        }
        #expect(receipts.withLock { $0 } == [.secureInput])
    }
}

extension RemoteSecureInputTests {
    @Test func liveReceiverPasteGateRaceLeavesClipboardUntouched() async {
        let pb = NSPasteboardShim.make()
        pb.setString("User clipboard", forType: .string)
        var posts = 0
        let paste = PasteInserter(pasteboard: pb, postPaste: { posts += 1 })
        paste.secureInputActive = { true }
        let status = await ReceiverDeliveryPolicy.deliver("Private", secureInputActive: { false },
                                                        accessibilityTrusted: { true },
                                                        insert: { try await paste.insert($0) })
        #expect(status == .secureInput)
        #expect(posts == 0)
        #expect(pb.string(forType: .string) == "User clipboard")
    }
}


extension RemoteSecureInputTests {
    @Test(arguments: ["focus", "secure", "conflict", "window"])
    func remoteFallbackGateChangesKeepCorrectOutcomeOnly(change: String) async {
        let text = "Private words with enough characters."
        let env = PipelineEnv(text: text, speech: true, transcriber: nil)
        env.front = FrontmostApp(pid: 42, bundleID: "com.apple.ScreenSharing")
        var posts = 0
        var title = "Viewer"
        let typing = PacedTypingInserter(mode: .unicode, interval: .zero,
                                        focus: { _ in FocusToken(pid: env.front?.pid, windowTitle: title) },
                                        post: { _ in
            posts += 1
            switch change {
            case "focus": env.front = FrontmostApp(pid: 43, bundleID: "com.example.other")
            case "secure": env.secure.active = true
            case "conflict": env.apps = [PipelineTests.wispr]
            default: title = "Other viewer"
            }
        })
        let remote = RemoteInserter(config: { RemoteConfig() }, receivers: { [] },
                                    focus: { FocusToken(pid: env.front?.pid, windowTitle: title) },
                                    fallbackFor: { _, _ in typing })
        let pipeline = DictationPipeline(audio: env.audio, trimmer: FakeTrimmer(), transcriber: env.transcriber,
                                         dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                         gate: ConflictDetector(runningApps: { env.apps }, fnUsageReader: { 0 }),
                                         secureInput: env.secure, clipboard: env.clipboard,
                                         inserterFor: { _ in (remote, .remote) }, history: env.history,
                                         frontmostApp: { env.front }, caretReader: env.caret,
                                         debugRecordings: nil, autoFormatter: .none)
        pipeline.onNotice = { env.notices.append($0) }
        await pipeline.prepareModels()
        let entry = await pipeline.process(samples: env.audio.samples, target: env.front)
        #expect(posts == (change == "window" ? 16 : 1))
        #expect(entry.outcome == (change == "secure" ? .blockedBySecureInput : change == "conflict" ? .blockedByConflict : .focusChanged))
        #expect(entry.raw.isEmpty && entry.final.isEmpty && entry.cleanupCandidate == nil)
        if change == "secure" || change == "conflict" {
            #expect(env.clipboard.strings.isEmpty)
            #expect(env.notices.last?.contains("stopped after typing 1 of") == true)
        } else {
            #expect(env.clipboard.strings == [text])
            #expect(env.notices.contains(PipelineNotice.focusChanged))
        }
    }
}
