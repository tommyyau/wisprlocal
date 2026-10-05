import AppKit
import Foundation
import Testing
@testable import WisprLocalCore

/// BUG C (2026-10-03): a long paste into the Codex desktop app (Electron) was recorded as
/// inserted but nothing appeared. Guards: adaptive clipboard restore, clean Cmd-V flags, wait
/// for 🌐 up, AX verification + one retry, Electron path, evidence in history, re-paste.
@MainActor @Suite(.serialized) struct PasteReliabilityTests {
    func board() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("wl-paste-\(UUID().uuidString)"))
        pb.clearContents(); pb.setString("user clipboard", forType: .string)
        return pb
    }

    final class FakeVerifier: PasteVerifying {
        var states: [FocusedFieldState?]
        var reads = 0
        init(_ s: [FocusedFieldState?]) { states = s }
        func read(pid: Int32) -> FocusedFieldState? {
            defer { reads += 1 }
            return states[min(reads, states.count - 1)]
        }
    }

    static let native = PasteTarget(pid: 42, bundleID: "com.apple.TextEdit", isElectron: false)
    static let codex = PasteTarget(pid: 43, bundleID: "com.openai.codex", isElectron: true)
    static let field = FocusedFieldState(characterCount: 10, selectionLocation: 10)

    // MARK: restore policy

    @Test func restoreWaitsAtLeastTheMinimumAndAdaptsToLength() {
        typealias P = PasteRestorePolicy
        #expect(P.minimum == .milliseconds(1_500))
        #expect(P.delay(textLength: 5, electron: false, verified: nil) >= P.minimum)
        #expect(P.delay(textLength: 1_000, electron: false, verified: nil) == .milliseconds(2_500))
        #expect(P.delay(textLength: 2_000, electron: false, verified: nil) > P.delay(textLength: 500, electron: false, verified: nil))
        #expect(P.delay(textLength: 566, electron: true, verified: nil) == .milliseconds(4_132), "the Codex case")
        #expect(P.delay(textLength: 50_000, electron: true, verified: nil) == P.maximum)
        #expect(P.delay(textLength: 5_000, electron: true, verified: true) == P.minimum, "verified → minimum only")
        #expect(P.delay(textLength: 300, electron: false, verified: false) > P.minimum)
    }

    @Test func inserterSchedulesTheAdaptiveRestore() async throws {
        let pb = board(), clock = ManualClock()
        let ins = PasteInserter(pasteboard: pb, postPaste: {}, clock: clock, target: { Self.codex })
        let text = String(repeating: "a", count: 566)
        try await ins.insert(text)
        await clock.waitForSleepers(count: 1)
        #expect(clock.nextDeadline == .milliseconds(4_132))
        await clock.advance(by: .milliseconds(4_000))
        #expect(pb.string(forType: .string) == text, "still ours while Electron may be reading it")
        await clock.advance(by: .milliseconds(132))
        await ins.waitForRestore()
        #expect(pb.string(forType: .string) == "user clipboard")
        #expect(ins.lastPasteReport?.restoreDelay == .milliseconds(4_132))
    }

    @Test func clipboardChangedMeanwhileIsNeverRestoredOver() async throws {
        let pb = board(), clock = ManualClock()
        let ins = PasteInserter(pasteboard: pb, postPaste: {}, clock: clock, target: { Self.codex })
        try await ins.insert("dictated")
        pb.clearContents(); pb.setString("copied by the user", forType: .string)   // changeCount moves
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: PasteRestorePolicy.maximum)
        await ins.waitForRestore()
        #expect(pb.string(forType: .string) == "copied by the user")
    }

    // MARK: keystroke

    @Test func cmdVCarriesExactlyCommandNoSecondaryFn() {
        let evs = PasteKeystroke.events(key: 9)
        #expect(evs.count == 2)
        for e in evs {
            #expect(e.flags == .maskCommand)
            #expect(!e.flags.contains(.maskSecondaryFn) && !e.flags.contains(.maskShift)
                    && !e.flags.contains(.maskAlternate) && !e.flags.contains(.maskControl))
            #expect(e.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.value)
            #expect(e.getIntegerValueField(.keyboardEventKeycode) == 9)
        }
        #expect(PasteKeystroke.conflictingModifiers.contains(.maskSecondaryFn))
    }

    @Test func waitsForGlobeToComeUpBeforePasting() async throws {
        var heldPolls = 0, heldAtPost: Bool?
        var held = true
        let ins = PasteInserter(pasteboard: board(), restoreDelay: .milliseconds(1),
                                postPaste: { heldAtPost = held }, clock: SystemPipelineClock(),
                                target: { Self.codex },
                                modifiersHeld: { heldPolls += 1; if heldPolls >= 4 { held = false }; return held })
        try await ins.insert("dictated")
        #expect(heldAtPost == false, "Cmd-V must not be posted while 🌐 is down (hands-free stop commits on key-down)")
        #expect(heldPolls >= 4)
    }

    @Test func givesUpWaitingAfterTheBound() async throws {
        var posted = 0
        let ins = PasteInserter(pasteboard: board(), restoreDelay: .milliseconds(1), postPaste: { posted += 1 },
                                clock: SystemPipelineClock(), target: { Self.codex }, modifiersHeld: { true })
        ins.maxModifierWait = .milliseconds(60)
        try await ins.insert("dictated")
        #expect(posted == 1, "a stuck modifier delays the paste, never drops it")
    }

    // MARK: verification

    @Test func verifiedUnchangedFieldIsRetriedOnce() async throws {
        var posted = 0
        let v = FakeVerifier([Self.field])                    // never changes
        let ins = PasteInserter(pasteboard: board(), postPaste: { posted += 1 }, clock: SystemPipelineClock(),
                                verifier: v, target: { Self.native })
        ins.verifyDelay = .milliseconds(1)
        try await ins.insert("dictated")
        #expect(posted == 2)
        let r = try #require(ins.lastPasteReport)
        #expect(r.retried && r.verified == false)
        #expect(r.restoreDelay > PasteRestorePolicy.minimum)
    }

    @Test func landedPasteIsVerifiedAndNotRetried() async throws {
        var posted = 0
        let v = FakeVerifier([Self.field, FocusedFieldState(characterCount: 18, selectionLocation: 18)])
        let ins = PasteInserter(pasteboard: board(), postPaste: { posted += 1 }, clock: SystemPipelineClock(),
                                verifier: v, target: { Self.native })
        ins.verifyDelay = .milliseconds(1)
        try await ins.insert("dictated")
        #expect(posted == 1)
        #expect(ins.lastPasteReport?.verified == true && ins.lastPasteReport?.retried == false)
        #expect(ins.lastPasteReport?.restoreDelay == PasteRestorePolicy.minimum)
    }

    @Test func retryLandingCountsAsVerified() async throws {
        var posted = 0
        let v = FakeVerifier([Self.field, Self.field, FocusedFieldState(characterCount: 18, selectionLocation: 18)])
        let ins = PasteInserter(pasteboard: board(), postPaste: { posted += 1 }, clock: SystemPipelineClock(),
                                verifier: v, target: { Self.native })
        ins.verifyDelay = .milliseconds(1)
        try await ins.insert("dictated")
        #expect(posted == 2 && ins.lastPasteReport?.verified == true && ins.lastPasteReport?.retried == true)
    }

    @Test func electronSkipsVerification() async throws {
        var posted = 0
        let v = FakeVerifier([Self.field])
        let ins = PasteInserter(pasteboard: board(), postPaste: { posted += 1 }, clock: SystemPipelineClock(),
                                verifier: v, target: { Self.codex })
        try await ins.insert("dictated")
        #expect(v.reads == 0, "AX is not read for Electron apps")
        #expect(posted == 1 && ins.lastPasteReport?.verified == nil)
        #expect(ins.lastPasteReport?.restoreDelay == PasteRestorePolicy.delay(textLength: 8, electron: true, verified: nil))
    }

    @Test func unreadableFieldIsUnknownNotRetried() async throws {
        var posted = 0
        let ins = PasteInserter(pasteboard: board(), postPaste: { posted += 1 }, clock: SystemPipelineClock(),
                                verifier: FakeVerifier([nil]), target: { Self.native })
        try await ins.insert("dictated")
        #expect(posted == 1 && ins.lastPasteReport?.verified == nil)
    }

    @Test func electronDetection() throws {
        #expect(ElectronApps.isElectron(bundleID: "com.openai.codex", bundleURL: nil))
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("E-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        #expect(!ElectronApps.isElectron(bundleID: "com.example.native", bundleURL: app))
        FileManager.default.createFile(atPath: app.appendingPathComponent("Contents/Resources/app.asar").path, contents: Data())
        #expect(ElectronApps.isElectron(bundleID: "com.example.renamed", bundleURL: app), "renamed framework, app.asar present")
    }

    // MARK: pipeline: evidence, safety net, re-paste

    @Test(arguments: [Optional<Bool>.none, true, false])
    func pipelineRecordsEvidenceAndOnlyWarnsForFailedVerification(verified: Bool?) async {
        let pb = board()
        let target = verified == nil ? Self.codex : Self.native
        let states: [FocusedFieldState?] = verified == true
            ? [Self.field, FocusedFieldState(characterCount: 18, selectionLocation: 18)] : [Self.field]
        let paste = PasteInserter(pasteboard: pb, postPaste: {}, clock: SystemPipelineClock(),
                                 verifier: FakeVerifier(states), target: { target })
        paste.verifyDelay = .milliseconds(1)
        let front = FrontmostApp(pid: target.pid, bundleID: target.bundleID!)
        let (e, p) = await makeEnv(text: "Hello there.")
        let p2 = DictationPipeline(audio: FakeAudio(), trimmer: FakeTrimmer(), transcriber: FakeTranscriber(text: "Hello there."),
                                   dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                   gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
                                   secureInput: e.secure, clipboard: e.clipboard,
                                   inserterFor: { _ in (paste, .paste) }, history: e.history,
                                   frontmostApp: { front },
                                   caretReader: e.caret, debugRecordings: nil, autoFormatter: .none)
        _ = p
        var notices: [String] = []
        p2.onNotice = { notices.append($0) }
        await p2.prepareModels()
        let h = await p2.process(samples: ZeroGateDetectorTests.tone(16_000), target: front,
                                 warmStart: true)
        #expect(h.outcome == .inserted)
        #expect(h.pasteVerified == verified && h.pasteRetried == (verified == false))
        #expect(h.pasteRestoreDelayMs == PasteRestorePolicy.delay(textLength: "Hello there.".count,
                                                                 electron: target.isElectron, verified: verified).ms)
        #expect(notices == (verified == false ? [PipelineNotice.pasteNotConfirmed] : []))
        // Re-paste: the same text, again.
        pb.clearContents()
        #expect(await p2.pasteLastAgain())
        #expect(pb.string(forType: .string) == "Hello there.")
    }

    @Test func pasteLastAgainRepastesThroughTheGates() async {
        let (e, p) = await makeEnv(text: "Hello there.")
        #expect(await p.pasteLastAgain() == false)
        #expect(e.notices == [PipelineNotice.nothingToPasteAgain])
        _ = await p.process(samples: e.audio.samples, target: e.front)
        #expect(e.inserter.inserted == ["Hello there."])
        #expect(await p.pasteLastAgain())
        #expect(e.inserter.inserted == ["Hello there.", "Hello there."])
        e.secure.active = true
        #expect(await p.pasteLastAgain() == false, "secure input blocks a re-paste too")
        e.secure.active = false
        e.apps = [PipelineTests.wispr]
        #expect(await p.pasteLastAgain() == false, "Wispr Flow priority blocks a re-paste too")
        #expect(e.inserter.inserted.count == 2)
    }

    @Test func pasteAgainShortcutMatchesOnlyTheExactChord() {
        let v: CGKeyCode = 9
        #expect(PasteAgainShortcut.matches(keyCode: 9, flags: [.maskControl, .maskAlternate, .maskCommand], pasteKeyCode: v))
        #expect(!PasteAgainShortcut.matches(keyCode: 9, flags: [.maskCommand], pasteKeyCode: v), "plain ⌘V untouched")
        #expect(!PasteAgainShortcut.matches(keyCode: 9, flags: [.maskCommand, .maskShift], pasteKeyCode: v), "⌘⇧V untouched")
        #expect(!PasteAgainShortcut.matches(keyCode: 9, flags: [.maskCommand, .maskAlternate], pasteKeyCode: v), "⌥⌘V untouched")
        #expect(!PasteAgainShortcut.matches(keyCode: 9, flags: [.maskControl, .maskAlternate, .maskCommand, .maskShift], pasteKeyCode: v))
        #expect(!PasteAgainShortcut.matches(keyCode: 8, flags: [.maskControl, .maskAlternate, .maskCommand], pasteKeyCode: v))
    }
}

extension PasteReliabilityTests {
    // AppController constructs RoutingInserter with its default paste dependency. Recreate
    // that construction, then use an isolated board/event sink for the actual policy check.
    @Test func productionRoutingKeepsAdaptivePolicy() async throws {
        let routing = RoutingInserter()
        let production = try #require(routing.paste as? PasteInserter)
        #expect(production.restoreDelay == nil)
        let paste = PasteInserter(pasteboard: board(), restoreDelay: production.restoreDelay,
                                 postPaste: {}, target: { Self.codex })
        try await paste.insert(String(repeating: "x", count: 566))
        #expect(paste.lastReport?.restoreDelay == .milliseconds(4_132))
    }

    @Test func newCopyBetweenPastesBecomesTheRestoreSnapshot() async throws {
        let pb = board(), clock = ManualClock()
        let paste = PasteInserter(pasteboard: pb, restoreDelay: .milliseconds(20), postPaste: {}, clock: clock)
        try await paste.insert("A")
        pb.clearContents(); pb.setString("B", forType: .string)
        try await paste.insert("C")
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(20))
        await paste.waitForRestore()
        #expect(pb.string(forType: .string) == "B")
    }

    @Test func newCopyDuringVerificationSkipsRetry() async throws {
        let pb = board(), clock = ManualClock()
        var posts = 0
        let paste = PasteInserter(pasteboard: pb, postPaste: { posts += 1 }, clock: clock,
                                 verifier: FakeVerifier([Self.field]), target: { Self.native })
        let task = Task { try await paste.insert("A") }
        await clock.waitForSleepers(count: 1)
        pb.clearContents(); pb.setString("B", forType: .string)
        await clock.advance(by: paste.verifyDelay)
        try await task.value
        #expect(posts == 1)
        #expect(paste.lastReport?.retried == false)
        await clock.advance(by: PasteRestorePolicy.maximum)
        await paste.waitForRestore()
        #expect(pb.string(forType: .string) == "B")
    }

    @Test(arguments: [PasteGateError.focusChanged, .secureInput, .conflict("Conflict captured at paste")])
    func gateChangeBeforeRetryStopsTheSecondPost(reason: PasteGateError) async throws {
        let pb = board(), clock = ManualClock()
        var posts = 0
        let blocked = LiveValue(false)
        let paste = PasteInserter(pasteboard: pb, postPaste: { posts += 1 }, clock: clock,
                                 verifier: FakeVerifier([Self.field]), target: { Self.native })
        let task = Task { try await paste.insert("A", prePostCheck: { if blocked.value { throw reason } }) }
        await clock.waitForSleepers(count: 1)
        blocked.set(true)
        await clock.advance(by: paste.verifyDelay)
        try await task.value
        #expect(paste.lastReport?.verified == false && paste.lastReport?.retried == false)
        #expect(posts == 1)
        await clock.advance(by: PasteRestorePolicy.maximum)
        await paste.waitForRestore()
        #expect(pb.string(forType: .string) == "user clipboard")
    }

    @Test func retryPostingFailureIsReportedWithoutClaimingARetry() async throws {
        var posts = 0
        let paste = PasteInserter(pasteboard: board(), postPaste: {
            posts += 1
            if posts == 2 { throw InsertionError.eventCreationFailed }
        }, verifier: FakeVerifier([Self.field]), target: { Self.native })
        paste.verifyDelay = .milliseconds(1)
        try await paste.insert("A")
        #expect(posts == 2)
        #expect(paste.lastReport?.retried == false)
        #expect(paste.lastReport?.verified == false)
    }
}

@Suite struct PasteProductionGuardTests {
    @Test func appNeverOverridesAdaptiveRestore() throws {
        let files = OfflineGuardTests.allSwiftFiles().filter {
            OfflineGuardTests.relativePath($0).hasPrefix("WisprLocal/") || OfflineGuardTests.relativePath($0).hasPrefix("WisprLocalCore/")
        }
        #expect(!files.isEmpty)
        // A fixed production override silently disables BUG C's adaptive restore policy.
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // The policy implementation declares/stores the override and records the computed delay.
            // Remove those exact definitions; every other assignment or initializer argument is forbidden.
            var scanned = source
            if OfflineGuardTests.relativePath(file) == "WisprLocalCore/Insertion/Insertion.swift" {
                for allowed in ["public var restoreDelay: Duration", "public var restoreDelay: Duration?",
                                "restoreDelay: Duration? = nil", "self.restoreDelay = restoreDelay",
                                "restoreDelay: delay"] {
                    scanned = scanned.replacingOccurrences(of: allowed, with: "")
                }
            }
            #expect(scanned.range(of: #"\brestoreDelay\s*[:=]"#, options: .regularExpression) == nil,
                    "Fixed restore assignment or initializer in \(file.lastPathComponent)")
        }
    }
}

extension PasteReliabilityTests {
    @Test func overlappingInsertsRestoreOriginalClipboardOnceAtEnd() async throws {
        let pb = board(), clock = ManualClock()
        var posts: [String] = []
        let paste = PasteInserter(pasteboard: pb, restoreDelay: .seconds(1),
                                 postPaste: { posts.append(pb.string(forType: .string) ?? "") }, clock: clock,
                                 verifier: FakeVerifier([Self.field]), target: { Self.native })
        let first = Task { try await paste.insert("First") }
        await clock.waitForSleepers(count: 1)
        let second = Task { try await paste.insert("Second") }
        await Task.yield()
        #expect(posts == ["First"])
        await clock.advance(by: paste.verifyDelay)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: paste.verifyDelay)
        try await first.value
        await eventually { posts.contains("Second") }
        await clock.advance(by: paste.verifyDelay)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: paste.verifyDelay)
        try await second.value
        let beforeRestore = pb.changeCount
        await clock.advance(by: .seconds(1))
        await paste.waitForRestore()
        #expect(pb.string(forType: .string) == "user clipboard")
        #expect(pb.changeCount == beforeRestore + 1, "exactly one new pasteboard generation restores the original")
    }

    @Test func anotherAppsGeneratedCopySurvivesNextDictation() async throws {
        let pb = board(), clock = ManualClock()
        let paste = PasteInserter(pasteboard: pb, restoreDelay: .seconds(1), postPaste: {}, clock: clock)
        try await paste.insert("First")
        let item = NSPasteboardItem()
        item.setString("Another app's copy", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.clearContents(); pb.writeObjects([item])
        try await paste.insert("Second")
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        await paste.waitForRestore()
        #expect(pb.string(forType: .string) == "Another app's copy")
    }

    @Test func overlappingRemoteClipboardWriteRestoresOriginal() async throws {
        let pb = board(), clock = ManualClock()
        let original = PasteboardSnapshot.capture(pb)
        let paste = PasteInserter(pasteboard: pb, restoreDelay: .seconds(1), postPaste: {}, clock: clock)
        try await paste.insert("Local dictation")
        await clock.waitForSleepers(count: 1)
        var posts: [String] = []
        let remote = ClipboardDelayInserter(delay: .milliseconds(1500), restoreAfter: .seconds(1), pasteboard: pb,
                                            focus: { _ in FocusToken(pid: 1, windowTitle: nil) },
                                            postPaste: { posts.append(pb.string(forType: .string) ?? "") }, clock: clock)
        let insertion = Task { try await remote.insert("Remote dictation") }
        await eventually { pb.string(forType: .string) == "Remote dictation" }
        await clock.waitForSleepers(count: 1)
        let remoteChange = pb.changeCount
        await clock.advance(by: .seconds(1))
        await Task.yield()
        #expect(pb.string(forType: .string) == "Remote dictation", "local deadline must not overwrite the remote write")
        #expect(pb.changeCount == remoteChange && posts.isEmpty)
        await clock.advance(by: .milliseconds(500))
        try await insertion.value
        #expect(posts == ["Remote dictation"])
        #expect(pb.changeCount == remoteChange)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        await remote.waitForRestore()
        #expect(PasteboardSnapshot.capture(pb).items == original.items)
        #expect(pb.changeCount == remoteChange + 1, "the remote owner restores the original exactly once")
        #expect(!paste.restorePending)
    }

    @Test func remoteHandoffCapturesFreshClipboardAfterInterveningWrite() async throws {
        let pb = board(), clock = ManualClock()
        let paste = PasteInserter(pasteboard: pb, restoreDelay: .seconds(1), postPaste: {}, clock: clock)
        try await paste.insert("Local dictation")
        // Even our marker is not proof of ownership once the change count changes.
        PrivatePasteboard.write("New copy", to: pb, currentHostOnly: true, autoGenerated: true)
        let fresh = PasteboardSnapshot.capture(pb)
        let remote = ClipboardDelayInserter(delay: .zero, restoreAfter: .seconds(1), pasteboard: pb,
                                            focus: { _ in FocusToken(pid: 1, windowTitle: nil) }, postPaste: {}, clock: clock)
        try await remote.insert("Remote dictation")
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        await remote.waitForRestore()
        #expect(PasteboardSnapshot.capture(pb).items == fresh.items)
    }

    @Test func localRestoreDoesNotOverwriteUnownedMarkedClipboard() async throws {
        let pb = board(), clock = ManualClock()
        let paste = PasteInserter(pasteboard: pb, restoreDelay: .seconds(1), postPaste: {}, clock: clock)
        try await paste.insert("Local dictation")
        PrivatePasteboard.write("New copy", to: pb, currentHostOnly: false, autoGenerated: true)
        let change = pb.changeCount
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        await paste.waitForRestore()
        #expect(pb.string(forType: .string) == "New copy" && pb.changeCount == change)
    }

    @Test func generatedChangeDuringWaitIsNotCapturedAsUserCopy() async throws {
        let pb = board(), clock = ManualClock()
        let held = LiveValue(false)
        let paste = PasteInserter(pasteboard: pb, restoreDelay: .seconds(1), postPaste: {}, clock: clock,
                                 modifiersHeld: { held.value })
        try await paste.insert("First")
        held.set(true)
        let task = Task { try await paste.insert("Second") }
        await clock.waitForSleepers(count: 1)
        PrivatePasteboard.write("Generated", to: pb, currentHostOnly: true, autoGenerated: true)
        held.set(false)
        await clock.advance(by: .milliseconds(20))
        try await task.value
        await clock.advance(by: .seconds(1))
        await paste.waitForRestore()
        #expect(pb.string(forType: .string) == "user clipboard")
    }
}
