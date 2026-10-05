import Testing
import CoreGraphics
import Foundation
@testable import WisprLocalCore

/// Wispr Flow priority: fully passive while it runs (unless overridden), resume when it quits.
@MainActor @Suite struct WisprFlowCoexistenceTests {
    static let wispr = RunningAppInfo(bundleID: WisprFlowMatcher.bundleID, bundlePath: "/Applications/Wispr Flow.app", pid: 500)
    static let wisprRelaunched = RunningAppInfo(bundleID: WisprFlowMatcher.bundleID, bundlePath: "/Applications/Wispr Flow.app", pid: 501)

    final class Spy {
        var apps: [RunningAppInfo] = []
        var queries = 0
        var now: TimeInterval = 1000
        var notices = 0
        var resets = 0
    }

    func detector(_ spy: Spy) -> ConflictDetector {
        ConflictDetector(runningApps: { spy.queries += 1; return spy.apps }, fnUsageReader: { 0 }, clock: { spy.now })
    }

    func fnEvent(down: Bool) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? .maskSecondaryFn : []
        return e
    }

    func monitor(_ flag: HoldOffFlag, queue: GlobeKeyMonitorTests.Queue) -> GlobeKeyMonitor {
        GlobeKeyMonitor(schedule: { queue.work.append($0) }, holdingOff: { flag.isHoldingOff })
    }

    // MARK: event tap

    @Test func tapPassesGlobeThroughUnmodifiedWhileHoldingOff() {
        let spy = Spy(); spy.apps = [Self.wispr]
        let d = detector(spy); d.refresh()
        #expect(d.holdingOff && d.flag.isHoldingOff)
        let q = GlobeKeyMonitorTests.Queue()
        let m = monitor(d.flag, queue: q)
        var actions: [HotkeyStateMachine.Action] = [], heldOff = 0
        m.onAction = { actions.append($0) }
        m.onHeldOffPress = { heldOff += 1 }

        let down = fnEvent(down: true)
        let result = m.process(type: .flagsChanged, event: down)
        #expect(result != nil)                                   // NOT consumed
        #expect(result?.takeUnretainedValue() === down)          // the very same event
        #expect(down.flags.contains(.maskSecondaryFn))           // unmodified
        #expect(down.getIntegerValueField(.keyboardEventKeycode) == 63)
        #expect(heldOff == 0)                                    // nothing ran inside the tap
        let up = fnEvent(down: false)
        #expect(m.process(type: .flagsChanged, event: up)?.takeUnretainedValue() === up)
        #expect(!m.isPollingForTesting)
        q.work.forEach { $0() }
        #expect(actions.isEmpty)                                 // state machine never fed
        #expect(heldOff == 1)                                    // one callback per press
        #expect(m.stateForTesting == .idle)
    }

    @Test func tapConsumesGlobeWhenNotHoldingOff() {
        let spy = Spy()
        let d = detector(spy); d.refresh()
        let q = GlobeKeyMonitorTests.Queue()
        let m = monitor(d.flag, queue: q)
        var actions: [HotkeyStateMachine.Action] = []
        m.onAction = { actions.append($0) }
        #expect(m.process(type: .flagsChanged, event: fnEvent(down: true)) == nil)
        q.work.forEach { $0() }
        #expect(actions == [.startRecording])
        #expect(m.process(type: .flagsChanged, event: fnEvent(down: false)) == nil)
    }

    /// STRUCTURAL: the tap path only reads the lock-free flag; it never asks for running apps.
    @Test func tapPathNeverQueriesRunningApps() {
        let spy = Spy(); spy.apps = [Self.wispr]
        let d = detector(spy); d.refresh()
        let before = spy.queries
        let q = GlobeKeyMonitorTests.Queue()
        let m = monitor(d.flag, queue: q)
        for _ in 0..<10 {
            _ = m.process(type: .flagsChanged, event: fnEvent(down: true))
            _ = m.process(type: .flagsChanged, event: fnEvent(down: false))
        }
        spy.apps = []; d.refresh()                               // not holding off: consuming path too
        let afterRefresh = spy.queries
        for _ in 0..<5 {
            _ = m.process(type: .flagsChanged, event: fnEvent(down: true))
            _ = m.process(type: .flagsChanged, event: fnEvent(down: false))
        }
        #expect(spy.queries == afterRefresh)
        #expect(afterRefresh == before + 1)                      // only the explicit refresh
    }

    // MARK: pipeline

    @Test func noMicAndNoTranscriptionWhileHoldingOff() async {
        let (e, p) = await makeEnv()
        var blocked = 0, resets = 0
        p.onBlockedByConflict = { blocked += 1 }
        p.onGestureReset = { resets += 1 }
        e.apps = [Self.wispr]                                    // live check at key-down, no notification
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.audio.started == 0)
        #expect(e.transcriber.callCount == 0)
        #expect(!p.status.isRecording)
        #expect(e.history.entries.isEmpty)
        #expect(e.inserter.inserted.isEmpty)
        #expect(blocked == 1 && resets == 1)
    }

    @Test func useAnywayOverrideDictatesNormally() async {
        let (e, p) = await makeEnv()
        e.apps = [Self.wispr]
        e.detector.refresh()
        #expect(e.detector.holdingOff)
        e.detector.useAnyway = true
        #expect(!e.detector.holdingOff && !e.detector.flag.isHoldingOff)
        p.handle(.startRecording)
        #expect(e.audio.started == 1)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["Please open Wispr Flow now."])
    }

    @Test func differentShortcutSettingDictatesNormally() async {
        let (e, p) = await makeEnv()
        e.apps = [Self.wispr]
        e.detector.differentShortcut = true
        e.detector.refresh()
        #expect(e.detector.wisprFlowRunning && !e.detector.holdingOff && !e.detector.flag.isHoldingOff)
        p.handle(.startRecording)
        #expect(e.audio.started == 1)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.history.entries.last?.outcome == .inserted)
        e.detector.differentShortcut = false                     // setting turned off again
        #expect(e.detector.holdingOff && e.detector.flag.isHoldingOff)
    }

    @Test func differentShortcutSettingPersistsDefaultOff() {
        let defaults = UserDefaults(suiteName: "wfc-\(UUID().uuidString)")!
        #expect(!AppSettings(defaults: defaults).wisprFlowUsesDifferentShortcut)
        AppSettings(defaults: defaults).wisprFlowUsesDifferentShortcut = true
        #expect(AppSettings(defaults: defaults).wisprFlowUsesDifferentShortcut)
    }

    @Test func resumesWhenWisprFlowQuits() async {
        let (e, p) = await makeEnv()
        e.apps = [Self.wispr]
        e.detector.refresh()
        p.handle(.startRecording)
        #expect(e.audio.started == 0)
        e.apps = []                                              // quits
        e.detector.refresh()                                     // terminate notification
        #expect(!e.detector.holdingOff && !e.detector.flag.isHoldingOff)
        p.handle(.startRecording)
        #expect(e.audio.started == 1)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.count == 1)
    }

    @Test func useAnywayResetsOnQuitAndOnRelaunch() {
        let spy = Spy(); spy.apps = [Self.wispr]
        let d = detector(spy); d.refresh()
        d.useAnyway = true
        spy.apps = []; d.refresh()
        #expect(!d.useAnyway)
        spy.apps = [Self.wispr]; d.refresh()
        #expect(d.holdingOff)                                    // back to holding off
        d.useAnyway = true
        d.refresh()
        #expect(d.useAnyway)                                     // same process: still overridden
        spy.apps = [Self.wisprRelaunched]; d.refresh()           // relaunch, terminate not seen
        #expect(!d.useAnyway && d.holdingOff)
    }

    // MARK: coordinator

    func coordinator(_ e: PipelineEnv, warm: WarmMicController, spy: Spy) -> WisprFlowCoexistence {
        WisprFlowCoexistence(conflicts: e.detector, warmMic: warm, pipeline: e.pipeline,
                             resetGesture: { spy.resets += 1 }, showNotice: { spy.notices += 1 })
    }

    @Test func warmMicIsDroppedWhenWisprFlowAppearsAndReArmsAfterItQuits() async {
        let (e, _) = await makeEnv()
        let audio = WarmAudioSpy()
        let d = e.detector!
        let warm = WarmMicController(audio: audio, keepReady: { true }, alwaysReady: { false },
                                     isConflictActive: { d.holdingOff })
        let spy = Spy()
        let c = coordinator(e, warm: warm, spy: spy)
        c.install(monitor: GlobeKeyMonitor(schedule: { _ in }))
        defer { withExtendedLifetime(c) {} }
        warm.dictationFinished()
        #expect(warm.isWarm && audio.warm)
        e.apps = [Self.wispr]
        d.refresh()                                              // launch notification
        #expect(!warm.isWarm && !audio.warm)                     // engine off, ring zeroed (leaveWarm)
        #expect(audio.leaves >= 1 && warm.lastDrop == .conflict)
        let enters = audio.enters
        warm.dictationFinished()                                 // no arming while holding off
        warm.tick()
        #expect(!warm.isWarm && audio.enters == enters)
        e.apps = []
        d.refresh()                                              // Wispr Flow quits
        #expect(!warm.isWarm)                                    // not re-armed by the quit itself
        warm.dictationFinished()                                 // next dictation re-arms normally
        #expect(warm.isWarm && audio.enters == enters + 1)
    }

    @Test func recordingInFlightIsCancelledWhenWisprFlowAppears() async {
        let (e, p) = await makeEnv()
        let warm = WarmMicController(audio: WarmAudioSpy(), keepReady: { false }, alwaysReady: { false })
        let spy = Spy()
        let c = coordinator(e, warm: warm, spy: spy)
        c.install(monitor: GlobeKeyMonitor(schedule: { _ in }))
        defer { withExtendedLifetime(c) {} }
        p.handle(.startRecording)
        #expect(p.status.isRecording)
        e.apps = [Self.wispr]
        e.detector.refresh()
        #expect(!p.status.isRecording)
        #expect(e.audio.cancelled == 1 && spy.resets == 1)
        await p.drain()
        #expect(e.transcriber.callCount == 0)
        #expect(spy.notices == 1)
    }

    @Test func holdOffNoticeIsDebounced() async {
        let (e, p) = await makeEnv()
        let spy = Spy()
        let d = ConflictDetector(runningApps: { [unowned e] in e.apps }, fnUsageReader: { 0 }, clock: { spy.now })
        let warm = WarmMicController(audio: WarmAudioSpy(), keepReady: { false }, alwaysReady: { false })
        let c = WisprFlowCoexistence(conflicts: d, warmMic: warm, pipeline: p,
                                     resetGesture: {}, showNotice: { spy.notices += 1 })
        let q = GlobeKeyMonitorTests.Queue()
        let m = monitor(d.flag, queue: q)
        c.install(monitor: m)
        defer { withExtendedLifetime(c) {} }
        e.apps = [Self.wispr]
        d.refresh()                                              // appears: one notice
        #expect(spy.notices == 1)
        for _ in 0..<5 {                                         // rapid presses inside the cooldown
            _ = m.process(type: .flagsChanged, event: fnEvent(down: true))
            _ = m.process(type: .flagsChanged, event: fnEvent(down: false))
            spy.now += 1
        }
        q.work.forEach { $0() }
        #expect(spy.notices == 1)
        spy.now += ConflictDetector.noticeCooldown
        q.work.removeAll()
        _ = m.process(type: .flagsChanged, event: fnEvent(down: true))
        _ = m.process(type: .flagsChanged, event: fnEvent(down: false))
        q.work.forEach { $0() }
        #expect(spy.notices == 2)                                // at most one per press
    }

    @Test func heldOffPressResumesIfWisprFlowQuitUnnoticed() async {
        let (e, p) = await makeEnv()
        let spy = Spy()
        let warm = WarmMicController(audio: WarmAudioSpy(), keepReady: { false }, alwaysReady: { false })
        let c = coordinator(e, warm: warm, spy: spy)
        e.apps = [Self.wispr]; e.detector.refresh()
        #expect(e.detector.flag.isHoldingOff)
        e.apps = []                                              // terminate notification missed
        c.heldOffPress()                                         // live check at key-down
        #expect(!e.detector.flag.isHoldingOff)
        _ = p
    }

    @Test func copy() {
        #expect(WisprFlowCopy.useAnyway == "Use WisprLocal anyway")
        #expect(WisprFlowCopy.useAnywayConfirmation ==
                "Both apps may type the same words. Quit Wispr Flow or change its shortcut to avoid this.")
        #expect(InfoTopic.wisprFlowShortcut.sentences.joined(separator: " ") ==
                "Turn this on if you've moved Wispr Flow off the 🌐 key. WisprLocal will then work normally even while Wispr Flow is running.")
    }
}
