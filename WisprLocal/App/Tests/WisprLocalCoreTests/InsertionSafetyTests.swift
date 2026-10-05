import AppKit
import Foundation
import Testing
@testable import WisprLocalCore

/// FABLE_REVIEW_2 R1 / R3: a cancel is honoured at every stage of the insertion (no Return ever
/// follows it; HUD and History agree), and auto-send presses Return only into the SAME focused
/// element (CFEqual) and window as at recording start.
@MainActor @Suite(.serialized) struct CancelDuringInsertionTests {
    func env(autoSend: Bool = true) async -> (PipelineEnv, DictationPipeline, ReturnSpy) {
        let (e, p) = await makeEnv()
        let spy = ReturnSpy(inserter: e.inserter)
        p.returnKey = spy
        p.autoSendRequested = { autoSend }
        return (e, p, spy)
    }

    /// A pipeline whose inserter waits at a gate (`GatedInserter`).
    func gatedEnv(pasteFirst: Bool) async -> (PipelineEnv, DictationPipeline, GatedInserter, ReturnSpy) {
        let env = PipelineEnv(text: "Send the report now.", speech: true, transcriber: nil)
        let gated = GatedInserter(pasteFirst: pasteFirst)
        let p = DictationPipeline(audio: env.audio, trimmer: FakeTrimmer(), transcriber: env.transcriber,
                                  dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                  gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
                                  secureInput: env.secure, clipboard: env.clipboard,
                                  inserterFor: { _ in (gated, .paste) }, history: env.history,
                                  frontmostApp: { FrontmostApp(pid: 42, bundleID: "com.apple.TextEdit") },
                                  caretReader: env.caret, debugRecordings: nil, autoFormatter: .none)
        p.onNotice = { [unowned env] in env.notices.append($0) }
        p.focusProbe = env.focus
        p.captureTail = .zero
        p.autoSendDelay = .zero
        await p.prepareModels()
        let spy = ReturnSpy(inserter: env.inserter)
        p.returnKey = spy
        p.autoSendRequested = { true }
        return (env, p, gated, spy)
    }

    @Test func escAfterThePasteNeverPressesReturn() async {
        for viaTripleTap in [false, true] {
            let (e, p, spy) = await env()
            let clock = ManualClock()
            p.pipelineClock = clock
            p.autoSendDelay = .milliseconds(120)
            var watched = 0
            p.onInserted = { _ in watched += 1 }
            p.handle(.startRecording)
            p.handle(.commitRecording)
            let done = Task { await p.drain() }
            await clock.waitForSleeper(until: clock.now + p.autoSendDelay)  // pasted, about to press Return
            #expect(e.inserter.inserted.count == 1)
            if viaTripleTap { p.handle(.cancelDictation) } else { #expect(p.cancelDictation()) }
            await clock.advance(by: p.autoSendDelay)
            await done.value
            #expect(spy.presses.isEmpty, "no Return after a cancel")
            let h = e.history.entries.last!
            #expect(h.outcome == .inserted, "the text is in the field: History says so")
            #expect(h.note?.contains("Return not pressed") == true)
            #expect(e.notices.contains(PipelineNotice.alreadyTypedNotSent))
            #expect(!e.notices.contains(PipelineNotice.cancelled), "the HUD agrees with History")
            #expect(watched == 0, "nothing is learned from a cancelled dictation")
            #expect(p.pendingCorrection == nil)
        }
    }

    @Test func escBeforeCmdVIsPostedTypesNothing() async {
        let (e, p, gated, spy) = await gatedEnv(pasteFirst: false)
        p.handle(.startRecording)
        p.handle(.commitRecording)
        let done = Task { await p.drain() }
        #expect(await eventually { gated.waiting })
        #expect(p.cancelDictation())
        gated.release()
        await done.value
        #expect(gated.inserted.isEmpty, "the paste was stopped")
        #expect(spy.presses.isEmpty)
        let h = e.history.entries.last!
        #expect(h.outcome == .cancelled)
        #expect(h.raw.isEmpty && h.final.isEmpty)
        #expect(e.notices == [PipelineNotice.cancelled])
    }

    @Test func escWhileThePasteIsBeingVerifiedSaysAlreadyTyped() async {
        let (e, p, gated, spy) = await gatedEnv(pasteFirst: true)
        p.backtrackEnabled = { true }
        p.handle(.startRecording)
        p.handle(.commitRecording)
        let done = Task { await p.drain() }
        #expect(await eventually { gated.waiting })
        #expect(p.cancelDictation())
        gated.release()
        await done.value
        #expect(gated.inserted.count == 1)
        #expect(spy.presses.isEmpty)
        #expect(e.history.entries.last?.outcome == .inserted)
        #expect(e.notices == [PipelineNotice.alreadyTypedNotSent])
    }

    // MARK: R3 — same focused element at Return time

    @Test func focusPolicyTable() {
        let a = FocusSnapshot(element: AXIdentity("field-1" as NSString), window: AXIdentity("w1" as NSString))
        let sameButNewObject = FocusSnapshot(element: AXIdentity(NSString(string: "field-1")), window: AXIdentity(NSString(string: "w1")))
        let otherField = FocusSnapshot(element: AXIdentity("field-2" as NSString), window: AXIdentity("w1" as NSString))
        let otherWindow = FocusSnapshot(element: AXIdentity("field-1" as NSString), window: AXIdentity("w2" as NSString))
        #expect(AutoSendPolicy.focusUnchanged(atStart: a, now: sameButNewObject), "CFEqual, not pointer identity")
        #expect(!AutoSendPolicy.focusUnchanged(atStart: a, now: otherField))
        #expect(!AutoSendPolicy.focusUnchanged(atStart: a, now: otherWindow))
        #expect(!AutoSendPolicy.focusUnchanged(atStart: nil, now: a), "unknown at start: never send blind")
        #expect(!AutoSendPolicy.focusUnchanged(atStart: a, now: nil))
    }

    @Test func autoSendSkipsReturnWhenTheFieldChanged() async {
        let (e, p, spy) = await env()
        p.autoSendDelay = .zero
        p.handle(.startRecording)
        #expect(await eventually { e.focus.reads >= 1 })  // the start-of-recording focus was read
        e.focus.element = "field-2"  // the user switched conversation while it processed
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.count == 1)
        #expect(spy.presses.isEmpty)
        #expect(e.notices.isEmpty, "no recurring paste-again reminder")
    }

    @Test func autoSendSkipsReturnWhenTheWindowChanged() async {
        let (e, p, spy) = await env()
        p.autoSendDelay = .zero
        p.handle(.startRecording)
        #expect(await eventually { e.focus.reads >= 1 })  // the start-of-recording focus was read
        e.focus.window = "window-2"
        p.handle(.commitRecording)
        await p.drain()
        #expect(spy.presses.isEmpty)
    }

    @Test func autoSendSkipsReturnWithoutAX() async {
        let (e, p, spy) = await env()
        p.autoSendDelay = .zero
        e.focus.element = nil
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.count == 1)
        #expect(spy.presses.isEmpty)
        #expect(e.notices.isEmpty)
    }

    @Test func autoSendPressesReturnIntoTheSameField() async {
        let (e, p, spy) = await env()
        p.autoSendDelay = .zero
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(spy.presses == [1])
        #expect(e.notices.isEmpty)
    }
}

/// R5 / R6 / R14 / R15: Undo sends ⌘Z only where it provably removes our paste.
@MainActor @Suite(.serialized) struct UndoSafetyTests {
    func env(text: String = "Coffee at 2, actually 3.") async -> (PipelineEnv, DictationPipeline, () -> Int) {
        let (e, p) = await makeEnv(text: text)
        p.backtrackEnabled = { true }
        p.undoSettle = .zero
        var undos = 0
        p.postUndo = { undos += 1 }
        return (e, p, { undos })
    }

    func dictate(_ p: DictationPipeline) async {
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
    }

    @Test func policyTable() {
        func ok(_ id: String?, verified: Bool? = true, retried: Bool = false, report: Bool = true, ax: Bool = true) -> Bool {
            UndoPolicy.mayOfferUndo(bundleID: id, pasteVerified: verified, pasteRetried: retried, hasReport: report, axVerified: ax)
        }
        #expect(ok("com.apple.TextEdit"))
        for t in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"] {
            #expect(!ok(t), "\(t): ⌘Z isn't a text undo")
        }
        #expect(ok("com.apple.dt.Xcode"), "Code category with an AX-verified field")
        #expect(!ok("com.apple.dt.Xcode", ax: false), "Code category without AX verification")
        #expect(!ok("com.apple.TextEdit", ax: false))
        #expect(!ok("com.apple.TextEdit", verified: nil), "unverifiable paste (Electron)")
        #expect(!ok("com.apple.TextEdit", verified: false))
        #expect(!ok("com.apple.TextEdit", retried: true), "retried paste: ⌘Z may remove only one copy")
        #expect(ok("com.apple.TextEdit", verified: nil, report: false), "no report (typing fakes): AX decides")

        let f = FocusSnapshot(element: AXIdentity("f" as NSString), window: nil, preceding: "Hi. Coffee at 3.")
        var typed = f; typed.preceding = "Hi. Coffee at 3.x"
        let other = FocusSnapshot(element: AXIdentity("g" as NSString), window: nil, preceding: "Coffee at 3.")
        #expect(UndoPolicy.maySendUndo(inserted: "Coffee at 3.", atInsert: f, now: f))
        #expect(!UndoPolicy.maySendUndo(inserted: "Coffee at 3.", atInsert: f, now: typed))
        #expect(!UndoPolicy.maySendUndo(inserted: "Coffee at 3.", atInsert: f, now: other))
        #expect(!UndoPolicy.maySendUndo(inserted: "Coffee at 3.", atInsert: nil, now: f))
        #expect(!UndoPolicy.maySendUndo(inserted: "Coffee at 3.", atInsert: f, now: nil))
    }

    @Test func undoRefusesAfterTheUserTyped() async {
        let (e, p, undos) = await env()
        await dictate(p)
        #expect(e.notices.last == PipelineNotice.corrected)
        e.focus.preceding = { "Coffee at 3.x" }  // one character typed after our paste
        #expect(await p.undoLastCorrection() == false)
        #expect(undos() == 0, "no ⌘Z: it would remove the user's own typing")
        #expect(e.clipboard.strings.last == "Coffee at 2, actually 3.")
        #expect(e.notices.last == PipelineNotice.undoNotSafe)
        #expect(e.inserter.inserted == ["Coffee at 3."])
    }

    @Test func undoRefusesInAnotherFieldOfTheSameApp() async {
        let (e, p, undos) = await env()
        await dictate(p)
        e.focus.element = "field-2"  // another channel / tab, same app
        #expect(await p.undoLastCorrection() == false)
        #expect(undos() == 0)
        #expect(e.clipboard.strings.last == "Coffee at 2, actually 3.")
    }

    @Test func noUndoWithoutAXOnlyCopyOriginal() async {
        let (e, p, undos) = await env()
        e.focus.element = nil
        await dictate(p)
        #expect(e.notices.last == PipelineNotice.correctedCopyOnly)
        #expect(HUDChipPolicy.actions(for: PipelineNotice.correctedCopyOnly) == [.copyOriginal])
        #expect(p.pendingCorrection?.undoable == false)
        #expect(await p.undoLastCorrection() == false)
        #expect(undos() == 0)
        // The chip's button.
        await dictate(p)
        #expect(p.copyOriginalOfLastCorrection())
        #expect(e.clipboard.strings.last == "Coffee at 2, actually 3.")
        #expect(e.notices.last == PipelineNotice.originalCopied)
        #expect(!p.copyOriginalOfLastCorrection(), "once")
    }

    @Test func noUndoInTerminals() async {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"] {
            let (e, p, undos) = await env()
            e.front = FrontmostApp(pid: 42, bundleID: id)
            await dictate(p)
            #expect(e.notices.last == PipelineNotice.correctedCopyOnly, "\(id)")
            #expect(await p.undoLastCorrection() == false)
            #expect(undos() == 0, "\(id)")
        }
    }

    /// R14: a real `PasteInserter` whose paste is unverifiable (Electron) or was retried.
    @Test func noUndoAfterAnUnverifiedOrRetriedPaste() async {
        final class Verifier: PasteVerifying {
            var states: [FocusedFieldState?]
            var reads = 0
            init(_ s: [FocusedFieldState?]) { states = s }
            func read(pid: Int32) -> FocusedFieldState? { defer { reads += 1 }; return states[min(reads, states.count - 1)] }
        }
        let field = FocusedFieldState(characterCount: 0, selectionLocation: 0)
        let landed = FocusedFieldState(characterCount: 12, selectionLocation: 12)
        let cases: [(String, PasteTarget, [FocusedFieldState?])] = [
            ("electron", PasteTarget(pid: 42, bundleID: "com.tinyspeck.slackmacgap", isElectron: true), [field]),
            ("retried", PasteTarget(pid: 42, bundleID: "com.apple.TextEdit", isElectron: false), [field, field, landed]),
            ("verified", PasteTarget(pid: 42, bundleID: "com.apple.TextEdit", isElectron: false), [field, landed]),
        ]
        for (label, target, states) in cases {
            let env = PipelineEnv(text: "Coffee at 2, actually 3.", speech: true, transcriber: nil)
            let pb = NSPasteboard(name: NSPasteboard.Name("wl-undo-\(UUID().uuidString)"))
            let paste = PasteInserter(pasteboard: pb, restoreDelay: .zero, postPaste: {}, clock: InstantClock(),
                                      verifier: Verifier(states), target: { target })
            paste.verifyDelay = .zero
            let p = DictationPipeline(audio: env.audio, trimmer: FakeTrimmer(), transcriber: env.transcriber,
                                      dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                      gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
                                      secureInput: env.secure, clipboard: env.clipboard,
                                      inserterFor: { _ in (paste, .paste) }, history: env.history,
                                      frontmostApp: { FrontmostApp(pid: 42, bundleID: target.bundleID) },
                                      caretReader: env.caret, debugRecordings: nil, autoFormatter: .none)
            p.onNotice = { [unowned env] in env.notices.append($0) }
            env.focus.preceding = { "Coffee at 3." }
            p.focusProbe = env.focus
            p.captureTail = .zero
            p.backtrackEnabled = { true }
            await p.prepareModels()
            await dictate(p)
            let undoable = p.pendingCorrection?.undoable
            #expect(undoable == (label == "verified"), "\(label)")
            #expect(env.notices.last == (label == "verified" ? PipelineNotice.corrected : PipelineNotice.correctedCopyOnly), "\(label)")
        }
    }

    /// R15: the re-pasted original joins the text before it exactly like the inserted text did.
    @Test func repastedOriginalKeepsTheJoinSpacing() async {
        let (e, p, undos) = await env()
        e.caret.context = .unavailable  // AX can't read the caret (fallback join on our last insertion)
        e.focus.preceding = { e.inserter.inserted.joined() }
        p.backtrackEnabled = { false }
        await dictate(p)                // "Coffee at 2, actually 3."
        p.backtrackEnabled = { true }
        await dictate(p)
        #expect(e.inserter.inserted.last == " Coffee at 3.")
        #expect(await p.undoLastCorrection())
        #expect(undos() == 1)
        #expect(e.inserter.inserted.last == " Coffee at 2, actually 3.", "same leading space as the inserted text")
    }
}

/// `PasteInserter` honours the cancellation of its task (R1).
@MainActor @Suite(.serialized) struct PasteCancellationTests {
    final class Box { var task: Task<Void, Error>?; var posts = 0 }

    @Test func cancelBeforeCmdVPostsNothingAndKeepsTheClipboard() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("wl-cancel-\(UUID().uuidString)"))
        pb.clearContents(); pb.setString("user clipboard", forType: .string)
        let box = Box()
        let ins = PasteInserter(pasteboard: pb, restoreDelay: .zero, postPaste: { box.posts += 1 }, clock: InstantClock(),
                                modifiersHeld: { box.task?.cancel(); return false })  // Esc while 🌐 is released
        box.task = Task { @MainActor in try await ins.insert("dictated") }
        let result = await box.task!.result
        #expect(box.posts == 0)
        #expect((try? result.get()) == nil)
        #expect(pb.string(forType: .string) == "user clipboard")
    }

    @Test func cancelAfterCmdVSkipsTheRetry() async {
        final class Unchanged: PasteVerifying {
            func read(pid: Int32) -> FocusedFieldState? { FocusedFieldState(characterCount: 3, selectionLocation: 3) }
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("wl-cancel-\(UUID().uuidString)"))
        let box = Box()
        let ins = PasteInserter(pasteboard: pb, restoreDelay: .zero, postPaste: { box.posts += 1; box.task?.cancel() },
                                clock: InstantClock(), verifier: Unchanged(),
                                target: { PasteTarget(pid: 42, bundleID: "com.apple.TextEdit", isElectron: false) })
        ins.verifyDelay = .zero
        box.task = Task { @MainActor in try await ins.insert("dictated") }
        _ = await box.task!.result
        #expect(box.posts == 1, "no second Cmd-V after a cancel")
        #expect(ins.lastPasteReport?.retried == false)
    }
}

/// A clock whose sleeps return at once (only zero-length waits are used with it).
struct InstantClock: PipelineClock {
    var now: Duration { .zero }
    func sleep(until deadline: Duration) async throws { try Task.checkCancellation() }
}
