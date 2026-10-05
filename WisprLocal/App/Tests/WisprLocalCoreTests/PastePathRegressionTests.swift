import AppKit
import Foundation
import Testing
@testable import WisprLocalCore

@MainActor @Suite struct PastePathRegressionTests {
    final class State {
        var front = FrontmostApp(pid: 42, bundleID: "com.example.editor")
        var held = true
        var posts = 0
        var apps: [RunningAppInfo] = []
        var conflictNotices = 0
    }

    @Test(arguments: ["focus", "secure", "conflict", "cancel"])
    func gatesRecheckedAfterModifierWait(change: String) async {
        let state = State(), clock = ManualClock(), secure = FakeSecureInput()
        let clipboard = FakeClipboard()
        let target = state.front
        let paste = PasteInserter(pasteboard: NSPasteboardShim.make(), postPaste: { state.posts += 1 }, clock: clock,
                                 modifiersHeld: { state.held })
        let pipeline = DictationPipeline(audio: FakeAudio(), trimmer: FakeTrimmer(), transcriber: FakeTranscriber(text: "Hello there."),
                                         dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                         gate: ConflictDetector(runningApps: { state.apps }, fnUsageReader: { 0 }),
                                         secureInput: secure, clipboard: clipboard, inserterFor: { _ in (paste, .paste) },
                                         history: MemoryHistory(), frontmostApp: { state.front },
                                         caretReader: FakeCaretReader(), debugRecordings: nil, autoFormatter: .none)
        pipeline.onBlockedByConflict = { state.conflictNotices += 1 }
        await pipeline.prepareModels()
        let task = Task { await pipeline.process(samples: ZeroGateDetectorTests.tone(16_000), target: target) }
        await clock.waitForSleepers(count: 1)
        switch change {
        case "focus": state.front = FrontmostApp(pid: 43, bundleID: "com.example.other")
        case "secure": secure.active = true
        case "conflict": state.apps = [PipelineTests.wispr]
        default: task.cancel()
        }
        state.held = false
        await clock.advance(by: .milliseconds(20))
        let entry = await task.value
        #expect(state.posts == 0)
        let expected: HistoryEntry.Outcome = change == "focus" ? .focusChanged : change == "secure" ? .blockedBySecureInput
            : change == "conflict" ? .blockedByConflict : .cancelled
        #expect(entry.outcome == expected)
        #expect(entry.raw.isEmpty && entry.final.isEmpty)
        #expect(state.conflictNotices == 0)
        if change == "focus" { #expect(clipboard.strings == ["Hello there."]) }
        else { #expect(clipboard.strings.isEmpty) }
        if change == "conflict" { #expect(entry.note != nil) }
        // Clear the refusal environment: rejected text must never become recovery text.
        secure.active = false
        state.apps = []
        state.front = target
        #expect(await pipeline.pasteLastAgain() == (change == "focus"))
        #expect(state.posts == (change == "focus" ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func failedInsertionCopiesAndRepastesLatestText(remote: Bool) async {
        let (env, pipeline) = await makeEnv(text: "Latest dictation.", strategy: remote ? .remote : .paste)
        env.inserter.failWith = remote ? BridgeClientError.unconfirmed : InsertionError.eventCreationFailed
        let entry = await pipeline.process(samples: env.audio.samples, target: env.front)
        #expect(entry.outcome == .insertFailed)
        #expect(entry.raw.isEmpty && entry.final.isEmpty)
        #expect(env.clipboard.strings == ["Latest dictation."])
        #expect(entry.note == PipelineNotice.insertionFailed(env.inserter.failWith!.localizedDescription))
        #expect(env.notices.isEmpty, "AppController flashes entry.note once")
        env.inserter.failWith = nil
        #expect(await pipeline.pasteLastAgain())
        #expect(env.inserter.inserted == ["Latest dictation."])
    }

    @Test func insertionFailurePunctuationHasOneFullStop() {
        for reason in ["No confirmation arrived", "No confirmation arrived.", "No confirmation arrived. "] {
            #expect(PipelineNotice.insertionFailed(reason) == "No confirmation arrived. — text copied to clipboard")
        }
    }

    @Test func lateConflictKeepsCapturedReasonEvenAfterConflictClears() async {
        let (env, pipeline) = await makeEnv()
        env.inserter.failWith = PasteGateError.conflict("Captured conflict reason")
        let entry = await pipeline.process(samples: env.audio.samples, target: env.front)
        #expect(env.detector.insertionBlockReason() == nil)
        #expect(entry.outcome == .blockedByConflict && entry.note == "Captured conflict reason")
        #expect(entry.raw.isEmpty && entry.final.isEmpty)
    }

    @Test func typingCancellationIsOutcomeOnlyAndShowsProgress() async {
        let (env, pipeline) = await makeEnv(text: "Private words.", strategy: .remote)
        env.inserter.failWith = TypingCancellation(typed: 8, total: 300)
        let entry = await pipeline.process(samples: env.audio.samples, target: env.front)
        #expect(entry.outcome == .cancelled)
        #expect(entry.raw.isEmpty && entry.final.isEmpty)
        #expect(env.notices.contains("Cancelled — typed 8 of 300 characters"))
    }

    @Test func privateWritesCarryMarkers() async throws {
        let pb = NSPasteboardShim.make()
        func expectMarkers(autoGenerated: Bool) {
            let types = Set((pb.types ?? []).map(\.rawValue))
            #expect(Set(PrivatePasteboard.markerTypes).isSubset(of: types))
            #expect(types.contains("org.nspasteboard.AutoGeneratedType") == autoGenerated)
            #expect(types.contains(PrivatePasteboard.dictationMarker) == autoGenerated)
        }
        SystemClipboard(pasteboard: pb).setString("Persistent recovery")
        expectMarkers(autoGenerated: false)
        let paste = PasteInserter(pasteboard: pb, postPaste: {})
        try await paste.insert("Local dictation")
        expectMarkers(autoGenerated: true)
        let remote = ClipboardDelayInserter(delay: .zero, pasteboard: pb,
                                            focus: { _ in FocusToken(pid: 1, windowTitle: nil) }, postPaste: {})
        try await remote.insert("Remote dictation")
        expectMarkers(autoGenerated: true)
        let clear = SecretPasteboard.write("Pairing secret", to: pb, clearAfter: .seconds(60))
        expectMarkers(autoGenerated: false)
        // Don't let the temporary tasks linger or restore over the next test write.
        pb.clearContents()
        clear.cancel()
        _ = await clear.value
    }

    @Test func allOwnedWritePathsDeclareClipboardSyncPolicy() throws {
        let root = OfflineGuardTests.sourcesRoot
        // Enumerate the callers: local paste, remote delay, pairing, and SystemClipboard
        // (focus/failed insertion recovery and every copy-original branch in the pipeline).
        let paths = ["WisprLocalCore/Insertion/Insertion.swift", "WisprLocalCore/Remote/RemoteTyping.swift",
                     "WisprLocalCore/RemoteBridge/SecretPasteboard.swift", "WisprLocalCore/Pipeline/PipelineEnvironment.swift"]
        for path in paths {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let calls = source.components(separatedBy: "\n").filter { $0.contains("PrivatePasteboard.write(") }
            #expect(calls.count == 1)
            let sync = path.contains("Remote/RemoteTyping") || path.contains("RemoteBridge/SecretPasteboard")
            #expect(calls.allSatisfy { $0.contains("currentHostOnly: \(sync ? "false" : "true")") })
            if !path.contains("Insertion/Insertion") {
                #expect(!source.contains("item.setString("))
                #expect(!source.contains("pb.setString("))
            }
        }
        let allCalls = try OfflineGuardTests.allSwiftFiles().flatMap {
            try String(contentsOf: $0, encoding: .utf8).components(separatedBy: "\n")
                .filter { $0.contains("PrivatePasteboard.write(") }
        }
        #expect(allCalls.count == 4)
        #expect(allCalls.filter { $0.contains("currentHostOnly: false") }.count == 2)
        #expect(allCalls.filter { $0.contains("currentHostOnly: true") }.count == 2)
        let helper = try String(contentsOf: root.appendingPathComponent(paths[0]), encoding: .utf8)
        #expect(helper.contains("prepareForNewContents(with: currentHostOnly ? .currentHostOnly : [])"))
        let pipeline = try String(contentsOf: root.appendingPathComponent("WisprLocalCore/Pipeline/DictationPipeline.swift"), encoding: .utf8)
        #expect(pipeline.components(separatedBy: "clipboard.setString(").count - 1 == 6)
        // The receiver delegates its clipboard writes to PasteInserter and SecretPasteboard.
        let receiver = try String(contentsOf: root.appendingPathComponent("WisprLocalReceiver/main.swift"), encoding: .utf8)
        #expect(!receiver.contains(".setString("))
    }
}

extension PastePathRegressionTests {
    @Test func localUnicodeCancellationStopsTheNextChunk() async {
        let state = State()
        let typing = UnicodeTypingInserter(post: { _ in state.posts += 1 })
        typing.interKeyDelay = .seconds(10)
        let task = Task { try await typing.insert(String(repeating: "x", count: 300)) }
        await eventually { state.posts == 1 }
        task.cancel()
        await #expect(throws: TypingCancellation(typed: 20, total: 300)) { try await task.value }
        #expect(state.posts == 1)
    }
}

private actor TwoDictations: Transcriber {
    nonisolated let engineName = "fake"
    private var calls = 0
    func prepare() async throws {}
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String {
        calls += 1
        return calls == 1 ? "Earlier dictation." : "Latest dictation."
    }
}

extension PastePathRegressionTests {
    @Test func failureSupersedesPreviousSuccessfulRepaste() async {
        let env = PipelineEnv(text: "", speech: true, transcriber: nil)
        let pipeline = DictationPipeline(audio: env.audio, trimmer: FakeTrimmer(), transcriber: TwoDictations(),
                                         dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                         gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
                                         secureInput: env.secure, clipboard: env.clipboard,
                                         inserterFor: { _ in (env.inserter, .paste) }, history: env.history,
                                         frontmostApp: { env.front }, caretReader: env.caret,
                                         debugRecordings: nil, autoFormatter: .none)
        await pipeline.prepareModels()
        _ = await pipeline.process(samples: env.audio.samples, target: env.front)
        env.inserter.failWith = InsertionError.eventCreationFailed
        let failed = await pipeline.process(samples: env.audio.samples, target: env.front)
        #expect(failed.outcome == .insertFailed && failed.raw.isEmpty && failed.final.isEmpty)
        env.inserter.failWith = nil
        #expect(await pipeline.pasteLastAgain())
        #expect(env.inserter.inserted == ["Earlier dictation.", "Latest dictation."])
    }
}

extension PastePathRegressionTests {
    @Test(arguments: ["secure", "conflict", "cancel"])
    func earlyRefusalPreservesPreviousSuccessfulRecovery(change: String) async {
        let env = PipelineEnv(text: "", speech: true, transcriber: nil)
        let pipeline = DictationPipeline(audio: env.audio, trimmer: FakeTrimmer(), transcriber: TwoDictations(),
                                         dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                         gate: ConflictDetector(runningApps: { env.apps }, fnUsageReader: { 0 }),
                                         secureInput: env.secure, clipboard: env.clipboard,
                                         inserterFor: { _ in (env.inserter, .paste) }, history: env.history,
                                         frontmostApp: { env.front }, caretReader: env.caret,
                                         debugRecordings: nil, autoFormatter: .none)
        await pipeline.prepareModels()
        _ = await pipeline.process(samples: env.audio.samples, target: env.front)
        if change == "secure" { env.secure.active = true }
        if change == "conflict" { env.apps = [PipelineTests.wispr] }
        if change == "cancel" { env.inserter.failWith = CancellationError() }
        let entry = await pipeline.process(samples: env.audio.samples, target: env.front)
        #expect(entry.outcome == (change == "secure" ? .blockedBySecureInput : change == "conflict" ? .blockedByConflict : .cancelled))
        #expect(env.clipboard.strings.isEmpty)
        env.secure.active = false; env.apps = []; env.inserter.failWith = nil
        #expect(await pipeline.pasteLastAgain())
        #expect(env.inserter.inserted == ["Earlier dictation.", "Earlier dictation."])
    }

    @Test func secureInputLateRefusalLeavesOriginalClipboardUntouched() async {
        let (env, pipeline) = await makeEnv(text: "Spoken password.")
        env.clipboard.setString("User clipboard")
        env.inserter.failWith = PasteGateError.secureInput
        let entry = await pipeline.process(samples: env.audio.samples, target: env.front)
        #expect(entry.outcome == .blockedBySecureInput)
        #expect(entry.raw.isEmpty && entry.final.isEmpty)
        #expect(env.clipboard.strings == ["User clipboard"])
        #expect(env.notices == [PipelineNotice.secureInput])
        env.inserter.failWith = nil
        #expect(await pipeline.pasteLastAgain() == false)
    }

    @Test func zeroTypedCancellationShowsPlainCancelled() async {
        let (env, pipeline) = await makeEnv(text: "Private words.")
        env.inserter.failWith = TypingCancellation(typed: 0, total: 14)
        _ = await pipeline.process(samples: env.audio.samples, target: env.front)
        #expect(env.notices == [PipelineNotice.cancelled])
        #expect(await pipeline.pasteLastAgain() == false)
    }
}

extension PastePathRegressionTests {
    @Test(arguments: ["secure", "focus", "conflict"])
    func gateRefusalAfterFirstPostStaysInsertedAndWarns(change: String) async {
        let state = State(), clock = ManualClock(), secure = FakeSecureInput()
        let front = state.front, clipboard = FakeClipboard(), history = MemoryHistory()
        let pb = NSPasteboardShim.make()
        let paste = PasteInserter(pasteboard: pb, postPaste: { state.posts += 1 }, clock: clock,
                                 verifier: PasteReliabilityTests.FakeVerifier([PasteReliabilityTests.field]),
                                 target: { PasteReliabilityTests.native })
        let pipeline = DictationPipeline(audio: FakeAudio(), trimmer: FakeTrimmer(), transcriber: FakeTranscriber(text: "Hello there."),
                                         dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                         gate: ConflictDetector(runningApps: { state.apps }, fnUsageReader: { 0 }),
                                         secureInput: secure, clipboard: clipboard, inserterFor: { _ in (paste, .paste) },
                                         history: history, frontmostApp: { state.front },
                                         caretReader: FakeCaretReader(), debugRecordings: nil, autoFormatter: .none)
        var notices: [String] = []
        pipeline.onNotice = { notices.append($0) }
        await pipeline.prepareModels()
        let task = Task { await pipeline.process(samples: ZeroGateDetectorTests.tone(16_000), target: front) }
        await clock.waitForSleepers(count: 1)
        if change == "secure" { secure.active = true }
        if change == "focus" { state.front = FrontmostApp(pid: 43, bundleID: "com.other") }
        if change == "conflict" { state.apps = [PipelineTests.wispr] }
        await clock.advance(by: paste.verifyDelay)
        let entry = await task.value
        #expect(state.posts == 1)
        #expect(entry.outcome == .inserted && entry.pasteVerified == false && entry.pasteRetried == false)
        #expect(history.entries.last?.outcome == .inserted)
        #expect(notices == [PipelineNotice.pasteNotConfirmed])
        #expect(clipboard.strings.isEmpty)
        await clock.advance(by: PasteRestorePolicy.maximum)
        await paste.waitForRestore()
    }
}

extension PastePathRegressionTests {
    @Test(arguments: ["secure", "conflict", "focus", "window"], [0, 16])
    func remoteRecheckPreservesSafetyRefusals(change: String, stopAt: Int) async {
        let state = State(), secure = FakeSecureInput(), clipboard = FakeClipboard(), history = MemoryHistory()
        let target = state.front
        var window = "Viewer"
        let typing = PacedTypingInserter(mode: .unicode, interval: .zero, focus: { _ in
            FocusToken(pid: state.front.pid, windowTitle: window)
        }, post: { _ in state.posts += 1 })
        let remote = RemoteInserter(config: { RemoteConfig() }, receivers: { [] }, focus: {
            let captured = FocusToken(pid: target.pid, windowTitle: "Viewer")
            if stopAt == 0 { changeEnvironment() }
            return captured
        }, fallbackFor: { _, _ in typing })
        func changeEnvironment() {
            switch change {
            case "secure": secure.active = true
            case "conflict": state.apps = [PipelineTests.wispr]
            case "focus": state.front = FrontmostApp(pid: 43, bundleID: "com.other")
            default: window = "Other window"
            }
        }
        // The next full AX read simulates a change during the chunk's awaited check.
        let paced = PacedTypingInserter(mode: .unicode, interval: .zero, focus: { full in
            if full && state.posts == stopAt { changeEnvironment() }
            return FocusToken(pid: state.front.pid, windowTitle: window)
        }, post: { _ in state.posts += 1 })
        let guardedRemote = stopAt == 0 ? remote : RemoteInserter(config: { RemoteConfig() }, receivers: { [] },
            focus: { FocusToken(pid: target.pid, windowTitle: "Viewer") }, fallbackFor: { _, _ in paced })
        let pipeline = DictationPipeline(audio: FakeAudio(), trimmer: FakeTrimmer(),
            transcriber: FakeTranscriber(text: "Private dictation with enough characters."), dictionary: tempDictionary(),
            cleaner: RuleCleaner(), gate: ConflictDetector(runningApps: { state.apps }, fnUsageReader: { 0 }),
            secureInput: secure, clipboard: clipboard, inserterFor: { _ in (guardedRemote, .remote) },
            history: history, frontmostApp: { state.front }, caretReader: FakeCaretReader(), debugRecordings: nil, autoFormatter: .none)
        var notices: [String] = []
        pipeline.onNotice = { notices.append($0) }
        await pipeline.prepareModels()
        let entry = await pipeline.process(samples: ZeroGateDetectorTests.tone(16_000), target: target)
        #expect(state.posts == stopAt)
        #expect(entry.outcome == (change == "secure" ? .blockedBySecureInput : change == "conflict" ? .blockedByConflict : .focusChanged))
        #expect(entry.raw.isEmpty && entry.final.isEmpty)
        #expect(history.entries.last?.raw.isEmpty == true && history.entries.last?.final.isEmpty == true)
        if change == "secure" || change == "conflict" {
            #expect(clipboard.strings.isEmpty)
            if stopAt > 0 { #expect(notices.last?.contains("stopped after typing 16 of") == true) }
            #expect(!notices.joined().contains("Private dictation"))
            secure.active = false; state.apps = []
            #expect(await pipeline.pasteLastAgain() == false)
        } else { #expect(clipboard.strings == ["Private dictation with enough characters."]) }
    }
}
