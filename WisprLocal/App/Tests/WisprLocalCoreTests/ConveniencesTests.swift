import Testing
import Foundation
import CoreGraphics
@testable import WisprLocalCore

// Track A conveniences: Esc / triple-tap cancel, mouse-button trigger, feedback sounds that are
// never captured, hide-for-1h, Shift-Return auto-send, history retention.

// MARK: - Esc state machine

@Suite struct EscapeCancelTests {
    @Test func passesThroughWhenNoDictationIsActive() {
        var m = EscapeCancel()
        #expect(m.escape(at: 0, dictationSeconds: nil, isRepeat: false) == .passThrough)
        #expect(!EscapeCancel.Decision.passThrough.consumesKey)
        #expect(m.escape(at: 1, dictationSeconds: nil, isRepeat: true) == .passThrough)
    }

    @Test func shortDictationCancelsAtOnce() {
        var m = EscapeCancel()
        #expect(m.escape(at: 0, dictationSeconds: 5, isRepeat: false) == .cancel)
        #expect(m.escape(at: 0, dictationSeconds: 30, isRepeat: false) == .cancel)  // 30 s exactly: no confirm
        #expect(m.confirmUntil == nil)
    }

    @Test func longDictationAsksThenSecondEscWithinThreeSecondsCancels() {
        var m = EscapeCancel()
        #expect(m.escape(at: 100, dictationSeconds: 42.2, isRepeat: false) == .confirm(seconds: 42))
        #expect(m.escape(at: 100.2, dictationSeconds: 42.4, isRepeat: true) == .consume)  // key repeat never confirms
        #expect(m.escape(at: 102.9, dictationSeconds: 45, isRepeat: false) == .cancel)
        #expect(m.confirmUntil == nil)
    }

    @Test func confirmationExpiresAfterThreeSeconds() {
        var m = EscapeCancel()
        #expect(m.escape(at: 0, dictationSeconds: 60, isRepeat: false) == .confirm(seconds: 60))
        #expect(m.escape(at: 3.5, dictationSeconds: 63.5, isRepeat: false) == .confirm(seconds: 64))  // asks again
        // The dictation ended meanwhile: Esc goes back to the app and the prompt is forgotten.
        #expect(m.escape(at: 4, dictationSeconds: nil, isRepeat: false) == .passThrough)
        #expect(m.confirmUntil == nil)
    }

    @Test func noticeCopy() {
        #expect(PipelineNotice.escapeAgain(seconds: 42) == "Press Esc again to discard 42 s")
        #expect(PipelineNotice.escapeAgain(seconds: 42).hasPrefix(PipelineNotice.escapeAgainPrefix))
        #expect(PipelineNotice.cancelled == "Cancelled")
    }
}

// MARK: - Esc in the event tap

@MainActor @Suite struct EscapeTapTests {
    final class Queue { var work: [@MainActor () -> Void] = [] }
    final class Box { var actions: [HotkeyStateMachine.Action] = [] }

    func esc(repeat isRepeat: Bool = false, flags: CGEventFlags = []) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        e.flags = flags
        if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return e
    }

    func fn(down: Bool) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? .maskSecondaryFn : []
        return e
    }

    func make() -> (GlobeKeyMonitor, Queue, Box) {
        let q = Queue(), box = Box()
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) })
        m.onAction = { box.actions.append($0) }
        return (m, q, box)
    }

    @Test func escIsPassedThroughWhenIdle() {
        let (m, _, _) = make()
        var asked = 0
        m.onEscape = { _ in asked += 1; return false }
        #expect(m.handle(type: .keyDown, event: esc()))  // passed on to the app
        #expect(asked == 1)
        m.onEscape = nil
        #expect(m.handle(type: .keyDown, event: esc()))
    }

    @Test func escIsConsumedWhileDictatingAndNeverCancelsAsACombo() {
        let (m, q, box) = make()
        _ = m.handle(type: .flagsChanged, event: fn(down: true))
        var repeats: [Bool] = []
        m.onEscape = { r in repeats.append(r); return true }
        #expect(!m.handle(type: .keyDown, event: esc()))
        #expect(!m.handle(type: .keyDown, event: esc(repeat: true)))
        #expect(repeats == [false, true])
        // Not fed to the gesture machine as "another key": the recording is still held.
        #expect(m.stateForTestingDownAt >= 0, "still holding")
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording])
    }

    @Test func commandEscIsLeftAlone() {
        let (m, _, _) = make()
        var asked = 0
        m.onEscape = { _ in asked += 1; return true }
        #expect(m.handle(type: .keyDown, event: esc(flags: .maskCommand)))
        #expect(asked == 0)
    }
}

extension GlobeKeyMonitor {
    /// The current hold's press time (tests).
    var stateForTestingDownAt: TimeInterval {
        if case .holding(let t) = stateForTesting { return t }
        return -1
    }
}

// MARK: - Pipeline cancel

@MainActor @Suite(.serialized) struct CancelPipelineTests {
    @Test func escWhileRecordingDiscardsAndRecordsCancelled() async {
        let (e, p) = await makeEnv()
        let clock = ManualClock()
        p.pipelineClock = clock
        var entries: [HistoryEntry] = []
        p.onEntry = { entries.append($0) }
        #expect(!p.isDictationActive && p.activeDictationSeconds == nil)
        p.handle(.startRecording)
        await clock.advance(by: .seconds(12))
        #expect(p.isDictationActive)
        #expect(p.activeDictationSeconds == 12)
        #expect(p.cancelDictation())
        await p.drain()
        #expect(e.audio.cancelled == 1 && e.audio.stopped == 0)  // mic stopped, audio discarded
        #expect(e.inserter.inserted.isEmpty)
        #expect(p.status == .ready)
        let h = e.history.entries.last!
        #expect(h.outcome == .cancelled)
        #expect(h.raw.isEmpty && h.final.isEmpty)
        #expect(h.audioDuration == 12)
        #expect(entries.map(\.outcome) == [.cancelled])
        #expect(e.notices == [PipelineNotice.cancelled])
        #expect(!p.cancelDictation())  // nothing left to cancel
    }

    @Test func escWhileProcessingNeverInsertsAndKeepsNoAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DebugRecordingStore(directory: dir, limit: 20, isEnabled: { true })
        let hang = FakeTranscriber(text: "Send the report now.", hangCalls: 1)
        let (e, p) = await makeEnv(transcriber: hang, debugRecordings: store)
        p.handle(.startRecording)
        p.handle(.commitRecording)
        #expect(p.status == .processing)
        #expect(p.isDictationActive)
        // Let the job reach the (hung) transcriber, then cancel.
        for _ in 0..<50 { await Task.yield() }
        #expect(p.cancelDictation())
        hang.release()
        await p.drain()
        await p.flushDebugRecordings()
        #expect(e.inserter.inserted.isEmpty)
        let h = e.history.entries.last!
        #expect(h.outcome == .cancelled)
        #expect(h.raw.isEmpty && h.final.isEmpty)
        #expect(store.clipIDs().isEmpty, "a cancelled dictation keeps no audio")
        #expect(!p.isDictationActive)
        // The next dictation is not affected.
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["Send the report now."])
    }

    @Test func cancelledOutcomeKeepsNeitherTextNorAudio() {
        #expect(!HistoryEntry.Outcome.cancelled.retainsContent)
        #expect(!HistoryEntry.Outcome.cancelled.mayKeepDebugAudio)
        #expect(!HistoryEntry.Outcome.cancelled.isSafetyRefusal)
        var entry = HistoryEntry(outcome: .cancelled)
        var c = HistoryContent(); c.raw = "secret"; c.final = "secret"
        c.attach(to: &entry)
        #expect(entry.raw.isEmpty && entry.final.isEmpty)
    }
}

// MARK: - Triple-tap

@Suite struct TripleTapTests {
    typealias M = HotkeyStateMachine

    /// Double-tap into hands-free; returns the machine in `.handsFree`.
    static func handsFree() -> M {
        var m = M()
        _ = m.handle(.fnDown(otherModifiers: false), at: 0)
        _ = m.handle(.fnUp, at: 0.1)
        _ = m.handle(.fnDown(otherModifiers: false), at: 0.3)
        _ = m.handle(.fnUp, at: 0.4)
        return m
    }

    @Test func threeTapsInHandsFreeCancel() {
        var m = Self.handsFree()
        #expect(m.state == .handsFree)
        #expect(m.handle(.fnDown(otherModifiers: false), at: 5.0) == [.commitRecording])  // stops at once
        #expect(m.handle(.fnUp, at: 5.08).isEmpty)
        #expect(m.handle(.fnDown(otherModifiers: false), at: 5.2) == [.holdInsertion])  // never a new recording
        #expect(m.handle(.fnUp, at: 5.28).isEmpty)
        #expect(m.handle(.fnDown(otherModifiers: false), at: 5.4) == [.cancelDictation])
        #expect(m.handle(.fnUp, at: 5.48).isEmpty)
        #expect(m.state == .idle && m.tripleTap == nil && m.deadline == nil)
        #expect(m.timeout(at: 9).isEmpty)
    }

    @Test func twoTapsReleaseTheHeldTextWhenTheWindowEnds() {
        var m = Self.handsFree()
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.0)
        _ = m.handle(.fnUp, at: 5.1)
        #expect(m.handle(.fnDown(otherModifiers: false), at: 5.25) == [.holdInsertion])
        _ = m.handle(.fnUp, at: 5.3)
        #expect(m.deadline == 5.6)
        #expect(m.timeout(at: 5.5).isEmpty)
        #expect(m.timeout(at: 5.6) == [.releaseInsertion])
        #expect(m.state == .idle)
    }

    @Test func aNormalStopAddsNothing() {
        var m = Self.handsFree()
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.0)
        _ = m.handle(.fnUp, at: 5.1)
        #expect(m.timeout(at: 5.6).isEmpty)
        // After the window a press is an ordinary new dictation.
        #expect(m.handle(.fnDown(otherModifiers: false), at: 7.0) == [.startRecording])
    }

    @Test func tapsOutsideTheWindowStartAFreshDictation() {
        var m = Self.handsFree()
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.0)
        _ = m.handle(.fnUp, at: 5.1)
        // Second tap late: the lazily resolved window yields nothing to release, then starts recording.
        #expect(m.handle(.fnDown(otherModifiers: false), at: 5.7) == [.startRecording])
    }

    @Test func typingAfterTheSecondTapReleases() {
        var m = Self.handsFree()
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.0)
        _ = m.handle(.fnUp, at: 5.1)
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.2)
        _ = m.handle(.fnUp, at: 5.3)
        #expect(m.handle(.otherKey, at: 5.35) == [.releaseInsertion])
        #expect(m.tripleTap == nil)
    }

    /// The window never blocks a new dictation: a follow-up press held past a tap is hold-to-talk.
    @Test func aHeldSecondPressStartsANewDictation() {
        var m = Self.handsFree()
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.0)
        _ = m.handle(.fnUp, at: 5.08)
        #expect(m.handle(.fnDown(otherModifiers: false), at: 5.2) == [.holdInsertion])
        #expect(m.deadline == 5.5)  // tapMaxDuration after the press, inside the 0.6 s window
        #expect(m.timeout(at: 5.45).isEmpty)
        #expect(m.timeout(at: 5.5) == [.releaseInsertion, .startRecording])
        #expect(m.state == .holding(downAt: 5.2) && m.tripleTap == nil)
        #expect(m.handle(.fnUp, at: 7.0) == [.commitRecording])
    }

    @Test func aPressStillDownWhenTheWindowEndsDictates() {
        var m = Self.handsFree()
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.0)
        _ = m.handle(.fnUp, at: 5.1)
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.5)
        #expect(m.deadline == 5.6)  // the window ends before the press counts as held
        #expect(m.timeout(at: 5.6) == [.releaseInsertion, .startRecording])
        #expect(m.state == .holding(downAt: 5.5))
        // Lazily resolved too: the key-up after a long hold commits the new dictation.
        var n = Self.handsFree()
        _ = n.handle(.fnDown(otherModifiers: false), at: 5.0)
        _ = n.handle(.fnUp, at: 5.1)
        _ = n.handle(.fnDown(otherModifiers: false), at: 5.2)
        #expect(n.handle(.fnUp, at: 6.4) == [.releaseInsertion, .startRecording, .commitRecording])
    }

    @Test func tapDisabledWhileHeldReleases() {
        var m = Self.handsFree()
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.0)
        _ = m.handle(.fnUp, at: 5.1)
        _ = m.handle(.fnDown(otherModifiers: false), at: 5.2)
        #expect(m.tapDisabled() == [.releaseInsertion])
    }
}

@MainActor @Suite(.serialized) struct TripleTapPipelineTests {
    @Test func heldInsertionWaitsAndTheThirdTapCancels() async throws {
        let (e, p) = await makeEnv()
        p.handle(.startRecording)
        p.handle(.enterHandsFree)
        p.handle(.commitRecording)          // 1st tap
        p.handle(.holdInsertion)            // 2nd tap
        let done = Task { await p.drain() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(e.inserter.inserted.isEmpty, "held: nothing typed yet")
        p.handle(.cancelDictation)          // 3rd tap
        await done.value
        #expect(e.inserter.inserted.isEmpty)
        #expect(e.history.entries.last?.outcome == .cancelled)
        #expect(!p.insertionHeld)
    }

    @Test func releaseLetsTheHeldTextThrough() async throws {
        let (e, p) = await makeEnv()
        p.handle(.startRecording)
        p.handle(.commitRecording)
        p.handle(.holdInsertion)
        let done = Task { await p.drain() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(e.inserter.inserted.isEmpty)
        p.handle(.releaseInsertion)
        await done.value
        #expect(e.inserter.inserted == ["Please open Wispr Flow now."])
    }

    @Test func holdHasABackstop() async {
        let (e, p) = await makeEnv()
        let clock = ManualClock()
        p.pipelineClock = clock
        p.handle(.startRecording)
        p.handle(.commitRecording)
        p.handle(.holdInsertion)
        let done = Task { await p.drain() }
        await clock.waitForSleeper(until: p.insertionHoldLimit)   // the backstop is asleep
        #expect(e.inserter.inserted.isEmpty)
        await clock.advance(by: p.insertionHoldLimit)
        await done.value
        #expect(e.inserter.inserted.count == 1)
    }
}

// MARK: - Mouse-button trigger

@MainActor @Suite struct MouseTriggerTests {
    final class Queue { var work: [@MainActor () -> Void] = [] }
    final class Box { var actions: [HotkeyStateMachine.Action] = [] }
    final class Clock { var t: TimeInterval = 0 }

    func mouse(_ type: CGEventType, button: Int64) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center)!
        e.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return e
    }

    func make(holdingOff: Bool = false) -> (MouseButtonMonitor, GlobeKeyMonitor, Queue, Box, Clock) {
        let q = Queue(), box = Box(), clock = Clock()
        let g = GlobeKeyMonitor(schedule: { q.work.append($0) }, holdingOff: { holdingOff }, clock: { clock.t })
        g.onAction = { box.actions.append($0) }
        return (MouseButtonMonitor(globe: g), g, q, box, clock)
    }

    @Test func mapping() {
        #expect(MouseTrigger.none.buttonNumber == nil)
        #expect(MouseTrigger.middle.buttonNumber == 2)
        #expect(MouseTrigger.button4.buttonNumber == 3)
        #expect(MouseTrigger.button5.buttonNumber == 4)
        #expect(MouseTrigger.matching(buttonNumber: 3, selected: .button4))
        #expect(!MouseTrigger.matching(buttonNumber: 4, selected: .button4))
        #expect(!MouseTrigger.matching(buttonNumber: 2, selected: .none))
        // Left and right can never be selected.
        for t in MouseTrigger.allCases {
            #expect(!MouseTrigger.matching(buttonNumber: 0, selected: t) && !MouseTrigger.matching(buttonNumber: 1, selected: t))
        }
        #expect(ConvenienceSettings(defaults: freshDefaults()).mouseTrigger == .none)
    }

    @Test func selectedButtonIsHoldToTalkAndConsumed() {
        let (m, _, q, box, clock) = make()
        m.trigger = .button4
        #expect(!m.handle(type: .otherMouseDown, event: mouse(.otherMouseDown, button: 3)))  // consumed
        clock.t = 2
        #expect(!m.handle(type: .otherMouseUp, event: mouse(.otherMouseUp, button: 3)))
        #expect(box.actions.isEmpty, "never delivered inside the tap")
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .commitRecording])
    }

    @Test func otherButtonsAndNonePassThrough() {
        let (m, _, q, box, _) = make()
        m.trigger = .button4
        #expect(m.handle(type: .otherMouseDown, event: mouse(.otherMouseDown, button: 2)))
        #expect(m.handle(type: .otherMouseUp, event: mouse(.otherMouseUp, button: 2)))
        m.trigger = .none
        #expect(m.handle(type: .otherMouseDown, event: mouse(.otherMouseDown, button: 3)))
        q.work.forEach { $0() }
        #expect(box.actions.isEmpty)
    }

    @Test func doubleClickEntersHandsFree() {
        let (m, _, q, box, clock) = make()
        m.trigger = .middle
        _ = m.handle(type: .otherMouseDown, event: mouse(.otherMouseDown, button: 2))
        clock.t = 0.1
        _ = m.handle(type: .otherMouseUp, event: mouse(.otherMouseUp, button: 2))
        clock.t = 0.3
        _ = m.handle(type: .otherMouseDown, event: mouse(.otherMouseDown, button: 2))
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .enterHandsFree])
    }

    @Test func passedThroughWhileHoldingOffForWisprFlow() {
        let (m, _, q, box, _) = make(holdingOff: true)
        m.trigger = .button5
        #expect(m.handle(type: .otherMouseDown, event: mouse(.otherMouseDown, button: 4)))
        #expect(m.handle(type: .otherMouseUp, event: mouse(.otherMouseUp, button: 4)))
        q.work.forEach { $0() }
        #expect(box.actions.isEmpty)
    }

    @Test func lostTapDiscardsTheRecording() {
        let (m, _, q, box, _) = make()
        m.trigger = .button4
        _ = m.handle(type: .otherMouseDown, event: mouse(.otherMouseDown, button: 3))
        _ = m.handle(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!)
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .cancelRecording])
    }
}

func freshDefaults() -> UserDefaults {
    let name = "wisprlocal-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: - Feedback sounds are never captured

/// A shared "world" timeline of mic samples on the pipeline's ManualClock: speech everywhere
/// (0.1), and whatever the speaker plays lands in it 20 ms later (0.9). Captures are read from
/// it exactly as the recorder would: [press − pre-roll (warm only), stop).
@MainActor final class LoopbackAudio: AudioCapturing {
    static let speech: Float = 0.1, tone: Float = 0.9
    var onLevel: ((Float) -> Void)?
    var onMaxDurationReached: (() -> Void)?
    let clock: ManualClock
    var world = [Float](repeating: speech, count: 16_000 * 10)
    var warm = false
    var lastStartWasWarm: Bool { warm }
    private var pressIndex = 0
    var stopped = 0
    init(clock: ManualClock) { self.clock = clock }
    func index(_ d: Duration) -> Int { Int((Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 16_000) }
    func start() throws { pressIndex = index(clock.now); onLevel?(Self.speech * 8) }
    func stop(tail: Duration) async -> [Float] {
        stopped += 1
        let from = pressIndex - (warm ? MicWarmPolicy.samples(MicWarmPolicy.preRoll) : 0)
        return Array(world[from..<index(clock.now)])
    }
    func cancel() {}
    /// The speaker plays `length` now; the mic hears it after 20 ms of latency.
    func speakerPlays(_ length: Duration) {
        let a = index(clock.now + .milliseconds(20)), b = index(clock.now + .milliseconds(20) + length)
        for i in a..<b { world[i] = Self.tone }
    }
}

@MainActor final class SoundSpy: FeedbackSoundPlaying {
    let duration: Duration = .milliseconds(70)
    let audio: LoopbackAudio
    var played: [(FeedbackSound, stopsSoFar: Int)] = []
    init(audio: LoopbackAudio) { self.audio = audio }
    func play(_ sound: FeedbackSound) {
        played.append((sound, audio.stopped))
        audio.speakerPlays(duration)
    }
}

final class TrimSpy: SpeechTrimmer, @unchecked Sendable {
    private let lock = NSLock()
    private var _inputs: [[Float]] = []
    var inputs: [[Float]] { lock.withLock { _inputs } }
    func prepare() async throws {}
    func trim(_ samples: [Float]) async throws -> [Float]? { lock.withLock { _inputs.append(samples) }; return samples }
}

@MainActor @Suite(.serialized) struct FeedbackSoundTests {
    func make() async -> (DictationPipeline, LoopbackAudio, SoundSpy, TrimSpy, ManualClock) {
        let clock = ManualClock()
        let audio = LoopbackAudio(clock: clock)
        let trim = TrimSpy()
        let inserter = FakeInserter()
        let p = DictationPipeline(audio: audio, trimmer: trim, transcriber: FakeTranscriber(text: "Hello there."),
                                  dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                  gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
                                  secureInput: FakeSecureInput(), clipboard: FakeClipboard(),
                                  inserterFor: { _ in (inserter, .paste) }, history: MemoryHistory(),
                                  frontmostApp: { FrontmostApp(pid: 42, bundleID: "com.apple.TextEdit") },
                                  caretReader: FakeCaretReader(), debugRecordings: nil, autoFormatter: .none)
        p.captureTail = .zero
        p.pipelineClock = clock
        await clock.advance(by: .seconds(1))  // room for a pre-roll before the first press
        await p.prepareModels()
        let spy = SoundSpy(audio: audio)
        p.feedbackSounds = spy
        return (p, audio, spy, trim, clock)
    }

    @Test func startSoundIsCutFromTheCapture() async {
        let (p, audio, spy, trim, clock) = await make()
        p.handle(.startRecording)
        #expect(spy.played.map(\.0) == [.start])
        await clock.advance(by: .seconds(1))
        p.handle(.commitRecording)
        await p.drain()
        let got = trim.inputs[0]
        #expect(audio.world.contains(LoopbackAudio.tone), "the spy really put the tone into the mic signal")
        #expect(!got.contains(LoopbackAudio.tone), "the start sound reached the transcriber")
        #expect(got.allSatisfy { $0 == LoopbackAudio.speech })
        // Only the sound window (70 ms + 80 ms margin) was cut, not the dictation.
        #expect(got.count == 16_000 - MicWarmPolicy.samples(.milliseconds(150)))
    }

    @Test func stopSoundPlaysOnlyAfterCaptureAndStaysOutOfTheNextPreRoll() async {
        let (p, audio, spy, trim, clock) = await make()
        p.handle(.startRecording)
        await clock.advance(by: .seconds(1))
        p.handle(.commitRecording)
        await p.drain()
        #expect(spy.played.map(\.0) == [.start, .stop])
        #expect(spy.played[1].stopsSoFar == 1, "stop sound must play after the capture ended")
        #expect(!trim.inputs[0].contains(LoopbackAudio.tone))
        // Warm mic: the next dictation 0.2 s later prepends 300 ms of pre-roll, which holds the stop sound.
        audio.warm = true
        await clock.advance(by: .milliseconds(200))
        p.handle(.startRecording)
        await clock.advance(by: .seconds(1))
        p.handle(.commitRecording)
        await p.drain()
        #expect(!trim.inputs[1].contains(LoopbackAudio.tone), "a sound reached the transcriber through the pre-roll")
        #expect(trim.inputs[1].count > 16_000 - MicWarmPolicy.samples(.milliseconds(400)))
    }

    @Test func noSoundsNoCuts() async {
        let (p, _, _, trim, clock) = await make()
        p.feedbackSounds = nil
        p.handle(.startRecording)
        await clock.advance(by: .seconds(1))
        p.handle(.commitRecording)
        await p.drain()
        #expect(trim.inputs[0].count == 16_000)
    }

    @Test func exclusionRangesAreClampedAndMerged() {
        let x = SoundExclusion(pressAt: .seconds(10), liveStartIndex: 4_800,
                               windows: [.seconds(9)...(.milliseconds(9_750)), .milliseconds(9_740)...(.milliseconds(9_800)),
                                         .seconds(10)...(.milliseconds(10_150))])
        // 9.0–9.8 s overlaps the pre-roll only from 9.7 s (index 0), merged; 10.0–10.15 s live.
        #expect(x.ranges(count: 16_000) == [0..<1_600, 4_800..<7_200])
        #expect(x.apply([Float](repeating: 1, count: 16_000)).count == 16_000 - 1_600 - 2_400)
    }

    @Test func toneIsSoftAndShort() {
        let s = ToneFeedbackSounds.samples(from: 660, to: 880)
        #expect(s.count == Int(0.07 * 44_100))
        #expect((s.map(abs).max() ?? 1) <= 0.6)
        #expect(abs(s.first!) < 0.01 && abs(s.last!) < 0.01, "no click at either end")
        #expect(ToneFeedbackSounds.volume <= 0.2)
        #expect(ConvenienceSettings(defaults: freshDefaults()).feedbackSounds == false)
    }
}

// MARK: - Hide the indicator for 1 hour

@MainActor @Suite struct HideIndicatorTests {
    @Test func hiddenForExactlyOneHourThenBack() {
        let d = freshDefaults()
        let s = ConvenienceSettings(defaults: d)
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(!s.isIndicatorHidden(now: t0))
        s.hideIndicator(now: t0)
        #expect(s.isIndicatorHidden(now: t0.addingTimeInterval(59 * 60)))
        #expect(!s.isIndicatorHidden(now: t0.addingTimeInterval(60 * 60)))
        // Survives a relaunch within the hour.
        #expect(ConvenienceSettings(defaults: d).isIndicatorHidden(now: t0.addingTimeInterval(30 * 60)))
        s.showIndicator()
        #expect(!s.isIndicatorHidden(now: t0.addingTimeInterval(60)))
        #expect(!ConvenienceSettings(defaults: d).isIndicatorHidden(now: t0.addingTimeInterval(60)))
    }

    @Test func menuShowsAnIndicatorHiddenRowWithShow() {
        let a = MenuAttention.resolve(MenuSnapshot(indicatorHidden: true))
        #expect(a == .indicatorHidden)
        #expect(a?.label == "Indicator Hidden — Show")
        #expect(a?.action == .showIndicator)
        // Recording outranks it; it outranks the mic-ready countdown.
        #expect(MenuAttention.resolve(MenuSnapshot(recording: true, indicatorHidden: true)) == .recording)
        #expect(MenuAttention.resolve(MenuSnapshot(micReady: .always, indicatorHidden: true)) == .indicatorHidden)
        let e = MenuModel.entries(MenuSnapshot(indicatorHidden: true), noisyRoom: false)
        #expect(e.first == .attention(.indicatorHidden))
        #expect(e.filter { $0.title.contains("Indicator") } == [.attention(.indicatorHidden)])
    }
}

// MARK: - Shift-Return auto-send

@MainActor final class ReturnSpy: ReturnKeyPosting {
    var presses: [Int] = []  // texts inserted so far, at each press
    let inserter: FakeInserter
    init(inserter: FakeInserter) { self.inserter = inserter }
    func pressReturn() throws { presses.append(inserter.inserted.count) }
}

@MainActor @Suite(.serialized) struct AutoSendTests {
    @Test func policyConditions() {
        func ok(enabled: Bool = true, shift: Bool = true, outcome: HistoryEntry.Outcome = .inserted,
                strategy: InsertionStrategy? = .paste, secure: Bool = false, verified: Bool? = true) -> Bool {
            AutoSendPolicy.shouldPressReturn(enabled: enabled, shiftHeldAtRelease: shift, outcome: outcome,
                                             strategy: strategy, secureInputActive: secure, pasteVerified: verified)
        }
        #expect(ok())
        #expect(ok(verified: nil), "unverifiable paste (Electron) still sends")
        #expect(ok(strategy: .unicodeTyping))
        #expect(!ok(enabled: false))
        #expect(!ok(shift: false))
        #expect(!ok(strategy: .remote), "never in remote mode")
        #expect(!ok(strategy: nil))
        #expect(!ok(secure: true), "never into a password field")
        #expect(!ok(verified: false), "not after a paste that didn't land")
        for o: HistoryEntry.Outcome in [.focusChanged, .blockedBySecureInput, .insertFailed, .cancelled, .noSpeech] {
            #expect(!ok(outcome: o))
        }
        #expect(ConvenienceSettings(defaults: freshDefaults()).shiftReturnAutoSend == true)
    }

    func env(strategy: InsertionStrategy = .paste) async -> (PipelineEnv, DictationPipeline, ReturnSpy) {
        let (e, p) = await makeEnv()
        let spy = ReturnSpy(inserter: e.inserter)
        p.returnKey = spy
        p.autoSendDelay = .zero
        return (e, p, spy)
    }

    @Test func shiftAtReleasePressesReturnAfterThePaste() async {
        let (e, p, spy) = await env()
        p.autoSendRequested = { true }
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.count == 1)
        #expect(spy.presses == [1], "Return only after the paste was posted")
    }

    @Test func noShiftNoReturn() async {
        let (e, p, spy) = await env()
        p.autoSendRequested = { false }
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.count == 1)
        #expect(spy.presses.isEmpty)
    }

    @Test func remoteModeNeverSends() async {
        let env = PipelineEnv(text: "Hi.", speech: true, transcriber: nil)
        let inserter = env.inserter
        let p = DictationPipeline(audio: env.audio, trimmer: FakeTrimmer(), transcriber: env.transcriber,
                                  dictionary: tempDictionary(), cleaner: RuleCleaner(),
                                  gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
                                  secureInput: env.secure, clipboard: env.clipboard,
                                  inserterFor: { _ in (inserter, .remote) }, history: env.history,
                                  frontmostApp: { FrontmostApp(pid: 42, bundleID: "com.apple.ScreenSharing") },
                                  caretReader: env.caret, debugRecordings: nil, autoFormatter: .none)
        p.captureTail = .zero
        await p.prepareModels()
        let spy = ReturnSpy(inserter: inserter)
        p.returnKey = spy
        p.autoSendDelay = .zero
        p.autoSendRequested = { true }
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(inserter.inserted.count == 1)
        #expect(spy.presses.isEmpty)
    }

    @Test func secureFieldNeverSends() async {
        let (e, p, spy) = await env()
        p.autoSendRequested = { true }
        p.handle(.startRecording)
        e.secure.active = true
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.isEmpty)
        #expect(spy.presses.isEmpty)
    }

    @Test func recordingCapNeverSends() async {
        let (e, p, spy) = await env()
        var asked = 0
        p.autoSendRequested = { asked += 1; return true }
        p.handle(.startRecording)
        e.audio.onMaxDurationReached?()  // the recorder's cap, not a release
        await p.drain()
        #expect(e.inserter.inserted.count == 1)
        #expect(spy.presses.isEmpty && asked == 0)
    }

    @Test func returnEventIsPlainReturnFromUs() {
        let evs = SystemReturnKey.events()
        #expect(evs.count == 2)
        for e in evs {
            #expect(e.getIntegerValueField(.keyboardEventKeycode) == 36)
            #expect(e.flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty)
            #expect(e.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.value)
        }
    }

    // The tap side: Shift while 🌐 is held must not cancel, and is seen at release.
    func fn(down: Bool, flags: CGEventFlags = []) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? flags.union(.maskSecondaryFn) : flags
        return e
    }

    func shift(down: Bool) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? [.maskShift, .maskSecondaryFn] : .maskSecondaryFn
        return e
    }

    @Test func shiftDuringAHoldIsTheReleaseModifier() {
        var actions: [HotkeyStateMachine.Action] = []
        let t = MouseTriggerTests.Clock()
        let m = GlobeKeyMonitor(schedule: { $0() }, clock: { t.t })
        m.onAction = { actions.append($0) }
        m.shiftIsReleaseModifier = true
        _ = m.handle(type: .flagsChanged, event: fn(down: true))
        t.t = 1
        _ = m.handle(type: .flagsChanged, event: shift(down: true))
        t.t = 2
        _ = m.handle(type: .flagsChanged, event: fn(down: false, flags: .maskShift))
        #expect(actions == [.startRecording, .commitRecording])
        #expect(m.lastTriggerFlags.contains(.maskShift))
    }

    @Test func withAutoSendOffShiftStillCancelsAsBefore() {
        var actions: [HotkeyStateMachine.Action] = []
        let m = GlobeKeyMonitor(schedule: { $0() }, clock: { 0 })
        m.onAction = { actions.append($0) }
        _ = m.handle(type: .flagsChanged, event: fn(down: true))
        _ = m.handle(type: .flagsChanged, event: shift(down: true))
        #expect(actions == [.startRecording, .cancelRecording])
    }
}

// MARK: - History retention

@Suite struct HistoryRetentionTests {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func cutoffs() {
        #expect(HistoryRetention.forever.cutoff(now: Self.now) == nil)
        #expect(HistoryRetention.days30.cutoff(now: Self.now) == Self.now.addingTimeInterval(-30 * 86_400))
        #expect(HistoryRetention.days7.cutoff(now: Self.now) == Self.now.addingTimeInterval(-7 * 86_400))
        #expect(HistoryRetention.hours24.cutoff(now: Self.now) == Self.now.addingTimeInterval(-86_400))
        #expect(HistoryRetention.pruneInterval == 3_600)
    }

    @Test func partitionKeepsTheBoundary() {
        let old = HistoryEntry(timestamp: Self.now.addingTimeInterval(-86_401), outcome: .inserted)
        let edge = HistoryEntry(timestamp: Self.now.addingTimeInterval(-86_400), outcome: .inserted)
        let fresh = HistoryEntry(timestamp: Self.now.addingTimeInterval(-60), outcome: .inserted)
        let (kept, pruned) = HistoryRetention.hours24.partition([old, edge, fresh], now: Self.now)
        #expect(kept == [edge, fresh] && pruned == [old])
        #expect(HistoryRetention.forever.partition([old], now: Self.now).pruned.isEmpty)
    }

    @Test func pruneDeletesEntriesAndTheirRecordings() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retention-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryStore(directory: dir)
        let clips = DebugRecordingStore(directory: dir.appendingPathComponent("clips"), limit: 20, isEnabled: { true })
        let library = HistoryLibrary(history: history, recordings: clips)
        let ages: [TimeInterval] = [40 * 86_400, 10 * 86_400, 3 * 86_400, 3_600]
        let entries = ages.map { HistoryEntry(timestamp: Self.now.addingTimeInterval(-$0), raw: "x", final: "x", outcome: .inserted) }
        for e in entries {
            history.append(e)
            _ = clips.save(samples: [Float](repeating: 0.1, count: 1_600), entry: e)
        }
        history.flush()
        await library.index.load(now: Self.now)
        #expect(clips.clipIDs().count == 4)

        // U3: shortening asks first, with the count, and counting deletes nothing.
        #expect(await library.index.prunableCount(retention: .days7, now: Self.now) == 2)
        #expect(await library.index.prunableCount(retention: .forever, now: Self.now) == 0)
        #expect((await library.index.allEntries()).count == 4 && clips.clipIDs().count == 4)
        #expect(HistoryRetention.days7.deleteConfirmation(count: 123) == "Delete 123 dictations older than 7 days?")
        #expect(HistoryRetention.hours24.deleteConfirmation(count: 1) == "Delete 1 dictation older than 24 hours?")
        #expect(HistoryRetention.days7.deleteConfirmation(count: 0) == nil, "nothing to delete: no question")
        #expect(HistoryRetention.forever.deleteConfirmation(count: 5) == nil)

        // "Forever" never rewrites anything.
        #expect(await library.index.prune(retention: .forever, now: Self.now) == 0)
        #expect((await library.index.allEntries()).count == 4)

        #expect(await library.index.prune(retention: .days7, now: Self.now) == 2)
        #expect((await library.index.allEntries()).map(\.id) == [entries[2].id, entries[3].id])
        #expect(clips.clipIDs() == [entries[2].id, entries[3].id], "recordings follow their entries")

        // An hour later with 24 hours: one more goes.
        #expect(await library.index.prune(retention: .hours24, now: Self.now) == 1)
        #expect((await library.index.allEntries()).map(\.id) == [entries[3].id])
        #expect(await library.index.prune(retention: .hours24, now: Self.now) == 0)
    }

    @MainActor @Test func settingDefaultsAndPersistence() {
        let d = freshDefaults()
        let s = ConvenienceSettings(defaults: d)
        #expect(s.historyRetention == .forever)
        s.historyRetention = .days30
        s.mouseTrigger = .middle
        s.feedbackSounds = true
        s.shiftReturnAutoSend = false
        let again = ConvenienceSettings(defaults: d)
        #expect(again.historyRetention == .days30 && again.mouseTrigger == .middle)
        #expect(again.feedbackSounds && !again.shiftReturnAutoSend)
    }
}
