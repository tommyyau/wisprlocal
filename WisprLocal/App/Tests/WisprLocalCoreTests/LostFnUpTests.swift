import Testing
import CoreGraphics
import Foundation
@testable import WisprLocalCore

/// CC-7 (STRUCTURAL): a lost Fn-up never keeps the mic on. Synthetic CGEvents (never posted) +
/// an injected modifier-flags provider and clock.
@MainActor @Suite struct LostFnUpTests {
    final class Env {
        var flags: CGEventFlags = .maskSecondaryFn
        var t: TimeInterval = 100
        var actions: [HotkeyStateMachine.Action] = []
    }

    func fn(_ down: Bool) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? .maskSecondaryFn : []
        return e
    }

    func make(pollInterval: TimeInterval = 10) -> (GlobeKeyMonitor, Env) {
        let env = Env()
        let m = GlobeKeyMonitor(schedule: { $0() }, flagsProvider: { env.flags }, clock: { env.t },
                                pollInterval: pollInterval)
        m.onAction = { env.actions.append($0) }
        return (m, env)
    }

    @Test func lostFnUpDuringHoldCommitsAsIfReleased() {
        let (m, env) = make()
        _ = m.handle(type: .flagsChanged, event: fn(true))
        #expect(env.actions == [.startRecording])
        #expect(m.isPollingForTesting)
        m.pollFnState()                      // sighted: the poll sees Fn held → armed
        #expect(m.pollStatus == .armed)
        env.t += 2; env.flags = []           // Fn physically released; the tap never saw it
        m.pollFnState()
        #expect(env.actions == [.startRecording], "one stale read must not cut a hold short")
        m.pollFnState()
        #expect(env.actions == [.startRecording, .commitRecording])
        #expect(m.stateForTesting == .idle)
        #expect(!m.isPollingForTesting)
    }

    @Test func heldFnKeepsRecordingAndASingleMissIsForgiven() {
        let (m, env) = make()
        _ = m.handle(type: .flagsChanged, event: fn(true))
        for _ in 0..<20 { env.t += 0.25; m.pollFnState() }
        env.flags = []; m.pollFnState()        // one glitch
        env.flags = .maskSecondaryFn; m.pollFnState()
        env.flags = []; m.pollFnState()        // another isolated glitch
        #expect(env.actions == [.startRecording])
        #expect(m.isPollingForTesting)
    }

    @Test func realReleaseStopsPolling() {
        let (m, env) = make()
        _ = m.handle(type: .flagsChanged, event: fn(true))
        env.t += 2
        _ = m.handle(type: .flagsChanged, event: fn(false))
        #expect(env.actions == [.startRecording, .commitRecording])
        #expect(!m.isPollingForTesting)
        env.flags = []; m.pollFnState(); m.pollFnState()
        #expect(env.actions == [.startRecording, .commitRecording], "no second commit")
    }

    /// Verified behaviour: a tap disable mid-recording stops and DISCARDS (never inserts).
    @Test func tapDisableMidRecordingDiscardsAndStopsPolling() {
        let (m, env) = make()
        _ = m.handle(type: .flagsChanged, event: fn(true))
        env.t += 3
        _ = m.handle(type: .tapDisabledByUserInput, event: CGEvent(source: nil)!)
        #expect(env.actions == [.startRecording, .cancelRecording])
        #expect(!m.isPollingForTesting)
        env.flags = []; m.pollFnState(); m.pollFnState()
        #expect(env.actions == [.startRecording, .cancelRecording])
    }

    @Test func pollTimerFiresOnTheMainRunLoop() async {
        let (m, env) = make(pollInterval: 0.01)
        _ = m.handle(type: .flagsChanged, event: fn(true))
        m.pollFnState()                      // arm
        env.t += 2; env.flags = []
        await eventually { env.actions.contains(.commitRecording) }   // real RunLoop timer
        #expect(env.actions == [.startRecording, .commitRecording])
        m.stop()
    }

    /// Fail-safe: a provider that never reports Fn (blind) never stops a 30 s hold.
    @Test func blindProviderNeverStopsAHold() {
        let (m, env) = make()
        env.flags = []                         // blind from the start
        _ = m.handle(type: .flagsChanged, event: fn(true))
        for _ in 0..<120 { env.t += 0.25; m.pollFnState() }   // 30 s of polls
        #expect(env.actions == [.startRecording])
        #expect(m.stateForTesting == .holding(downAt: 100))
        #expect(m.pollStatus == .blind)
        env.t += 0.1
        _ = m.handle(type: .flagsChanged, event: fn(false))   // the real release still commits
        #expect(env.actions == [.startRecording, .commitRecording])
    }

    @Test func sightedProviderDetectsReleaseAfterTwoMissedPolls() {
        let (m, env) = make()
        _ = m.handle(type: .flagsChanged, event: fn(true))
        env.t += 1; m.pollFnState()
        env.flags = []
        env.t += 0.25; m.pollFnState()
        #expect(env.actions == [.startRecording])
        env.t += 0.25; m.pollFnState()
        #expect(env.actions == [.startRecording, .commitRecording])
    }

    @Test func sightedProviderForgivesASingleGlitch() {
        let (m, env) = make()
        _ = m.handle(type: .flagsChanged, event: fn(true))
        m.pollFnState()
        env.flags = []; m.pollFnState()
        env.flags = .maskSecondaryFn
        for _ in 0..<10 { m.pollFnState() }
        #expect(env.actions == [.startRecording])
        #expect(m.isPollingForTesting)
    }

    @Test func armedIsFinalAndBlindUpgradesToArmed() {
        let (m, env) = make()
        env.flags = []
        _ = m.handle(type: .flagsChanged, event: fn(true))
        for _ in 0..<GlobeKeyMonitor.pollsBeforeBlind { m.pollFnState() }
        #expect(m.pollStatus == .blind)
        env.flags = .maskSecondaryFn; m.pollFnState()
        #expect(m.pollStatus == .armed)
    }

    @Test func defaultPollIsQuarterSecondOnCombinedSessionState() {
        #expect(GlobeKeyMonitor.defaultPollInterval == 0.25)
        #expect(GlobeKeyMonitor().pollInterval == 0.25)
    }

    // MARK: recording caps (pipeline)

    @Test func capDefaults() {
        #expect(DictationPipeline.defaultHoldRecordingLimit == .seconds(300))
        #expect(DictationPipeline.defaultHandsFreeRecordingLimit == .seconds(600))
    }

    /// Fully deterministic: the test only advances time while the limit task is provably asleep
    /// (`waitForSleepers`), and waits for the commit itself (`onGestureReset`), never for a
    /// scheduling window. Every countdown tick 15…1 is observed.
    @Test func holdCapCountsDownThenCommits() async {
        let (e, p) = await makeEnv()
        let clock = ManualClock(); p.pipelineClock = clock
        var resets = 0
        let (resetSignal, resetCont) = AsyncStream.makeStream(of: Void.self)
        p.onGestureReset = { resets += 1; resetCont.yield() }
        p.holdRecordingLimit = .seconds(300)
        p.recordingLimitWarning = .seconds(15)
        p.handle(.startRecording)
        await clock.waitForSleeper(until: .seconds(285))      // the cap task sleeps until the warning
        await clock.advance(by: .seconds(284))
        #expect(p.status.isRecording && e.notices.isEmpty, "no countdown before the warning window")
        for left in stride(from: 15, through: 1, by: -1) {
            await clock.advance(by: .seconds(1))
            await clock.waitForSleeper(until: .seconds(301 - left))   // posted `left`, sleeps to the next tick
            #expect(e.notices.last == PipelineNotice.recordingStopsIn(left))
            #expect(p.status.isRecording)
        }
        #expect(e.notices == (1...15).reversed().map { PipelineNotice.recordingStopsIn($0) })
        await clock.advance(by: .seconds(1))                  // 300 s: the cap commits
        var it = resetSignal.makeAsyncIterator()
        _ = await it.next()
        await p.drain()
        #expect(!p.status.isRecording)
        #expect(e.audio.stopped == 1)
        #expect(e.history.entries.last?.outcome == .inserted)
        #expect(e.notices.allSatisfy { $0.hasPrefix(PipelineNotice.recordingLimitPrefix) })
        #expect(resets == 1)
    }

    @Test func handsFreeGetsTheLongerCap() async {
        let (e, p) = await makeEnv()
        let clock = ManualClock(); p.pipelineClock = clock
        let (resetSignal, resetCont) = AsyncStream.makeStream(of: Void.self)
        p.onGestureReset = { resetCont.yield() }
        p.holdRecordingLimit = .seconds(150)
        p.handsFreeRecordingLimit = .seconds(700)
        p.recordingLimitWarning = .seconds(100)
        p.handle(.startRecording)
        p.handle(.enterHandsFree)
        await clock.waitForSleeper(until: .seconds(600))      // re-armed for hands-free (hold would be 50)
        #expect(clock.sleeperCount == 1)
        await clock.advance(by: .seconds(350))
        #expect(p.status == .recording(handsFree: true), "hold cap must not apply in hands-free")
        await clock.advance(by: .seconds(349))                // 699: wakes the 600 s warning once
        await clock.waitForSleeper(until: .seconds(700))      // it counted down and sleeps to the cap
        #expect(p.status.isRecording)
        await clock.advance(by: .seconds(1))
        var it = resetSignal.makeAsyncIterator()
        _ = await it.next()
        await p.drain()
        #expect(!p.status.isRecording)
        #expect(e.audio.stopped == 1)
    }

    @Test func releaseOrCancelDisarmsTheCap() async {
        let (e, p) = await makeEnv()
        let clock = ManualClock(); p.pipelineClock = clock
        p.holdRecordingLimit = .seconds(200)
        p.recordingLimitWarning = .seconds(150)
        p.handle(.startRecording)
        await clock.waitForSleepers(count: 1)
        p.handle(.cancelRecording)
        await clock.waitForSleepers(count: 0)
        await clock.advance(by: .seconds(500))
        #expect(e.audio.stopped == 0 && e.audio.cancelled == 1)
        #expect(!e.notices.contains { $0.hasPrefix(PipelineNotice.recordingLimitPrefix) })
        #expect(e.history.entries.isEmpty, "a cancelled recording is discarded, never recorded")
    }
}
