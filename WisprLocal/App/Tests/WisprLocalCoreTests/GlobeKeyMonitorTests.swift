import Testing
import CoreGraphics
import Foundation
import Darwin
@testable import WisprLocalCore

/// Feeds synthetic CGEvents (created, NEVER posted) straight into the tap handler.
@MainActor @Suite struct GlobeKeyMonitorTests {
    final class Queue { var work: [@MainActor () -> Void] = [] }

    func fnEvent(down: Bool, flags extra: CGEventFlags = []) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? extra.union(.maskSecondaryFn) : extra
        return e
    }

    @Test func revokedPermissionsDiscardActiveGestureOnHealthProbe() {
        let box = Box()
        let clock = DeliveryClock()
        let m = GlobeKeyMonitor(schedule: { $0() }, clock: { clock.now }, permissionsGranted: { false })
        m.onAction = { box.actions.append($0) }
        defer { m.stop() }
        _ = m.handle(type: .flagsChanged, event: fnEvent(down: true), at: 100)
        #expect(!m.start())
        #expect(!m.isRunning)
        #expect(!box.actions.contains(.cancelRecording))
        clock.now = 108.9
        #expect(!m.start())
        #expect(!box.actions.contains(.cancelRecording))
        clock.now = 109
        #expect(!m.start())
        #expect(box.actions.contains(.cancelRecording))
    }

    func make() -> (GlobeKeyMonitor, Queue, Box) {
        let q = Queue(), box = Box()
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) })
        m.onAction = { box.actions.append($0) }
        return (m, q, box)
    }
    final class Box { var actions: [HotkeyStateMachine.Action] = [] }
    @MainActor final class DeliveryClock { var now: TimeInterval = 100 }

    @Test(arguments: [true, false])
    func globeReleaseCompanionPreservesDoubleAndTripleTap(consume: Bool) {
        let q = Queue(), box = Box(), clock = DeliveryClock()
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) }, clock: { clock.now })
        m.consumeGlobeEvents = consume
        m.onAction = { box.actions.append($0) }
        defer { m.stop() }
        func fn(_ down: Bool, at time: TimeInterval) {
            clock.now = time
            _ = m.handle(type: .flagsChanged, event: fnEvent(down: down))
        }
        func releaseCompanion(at time: TimeInterval) {
            clock.now = time
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 179, keyDown: true)!
            e.flags = CGEventFlags(rawValue: 256)
            #expect(m.handle(type: .keyDown, event: e) == !consume)
        }
        // This Mac emits keycode 179 immediately after each quick Fn flagsChanged release.
        fn(true, at: 100); fn(false, at: 100.074); releaseCompanion(at: 100.075)
        fn(true, at: 100.183); fn(false, at: 100.227); releaseCompanion(at: 100.228)
        q.work.forEach { $0() }; q.work.removeAll()
        #expect(box.actions == [.startRecording, .enterHandsFree])
        #expect(m.stateForTesting == .handsFree)
        fn(true, at: 103); fn(false, at: 103.08); releaseCompanion(at: 103.081)
        fn(true, at: 103.18); fn(false, at: 103.26); releaseCompanion(at: 103.261)
        fn(true, at: 103.35); fn(false, at: 103.43); releaseCompanion(at: 103.431)
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .enterHandsFree, .commitRecording,
                                .holdInsertion, .cancelDictation])
        #expect(m.stateForTesting == .idle)
    }

    @Test func releaseCompanionDoesNotHideTypingOrUnrelatedKeys() {
        let q = Queue(), box = Box(), clock = DeliveryClock()
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) }, clock: { clock.now })
        m.onAction = { box.actions.append($0) }
        defer { m.stop() }
        _ = m.handle(type: .flagsChanged, event: fnEvent(down: true))
        clock.now = 100.08
        _ = m.handle(type: .flagsChanged, event: fnEvent(down: false))
        let typing = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
        #expect(m.handle(type: .keyDown, event: typing))
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .cancelRecording])
        let standalone = CGEvent(keyboardEventSource: nil, virtualKey: 179, keyDown: true)!
        clock.now = 101
        #expect(m.handle(type: .keyDown, event: standalone), "An unrelated event passes through")
    }

    @Test func releaseCompanionPassesThroughWhileHoldingOff() {
        let q = Queue(), clock = DeliveryClock()
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) }, holdingOff: { true }, clock: { clock.now })
        defer { m.stop() }
        #expect(m.handle(type: .flagsChanged, event: fnEvent(down: true)))
        clock.now = 100.08
        #expect(m.handle(type: .flagsChanged, event: fnEvent(down: false)))
        let companion = CGEvent(keyboardEventSource: nil, virtualKey: 179, keyDown: true)!
        #expect(m.handle(type: .keyDown, event: companion))
        #expect(m.stateForTesting == .idle)
    }

    @Test func realGlobeClockUnitsAreConvertedToUptimeSeconds() {
        let stamp: UInt64 = 151_650_579_461
        let seconds = GlobeKeyMonitor.eventTime(stamp, deliveredAt: 6318.775215833333,
                                               nanosecondsPerTick: 125.0 / 3)
        #expect(abs((seconds ?? 0) - 6318.774144208333) < 0.000001)
        // Posted events retain the documented nanosecond representation on the same Mac.
        let posted = GlobeKeyMonitor.eventTime(6_318_774_144_208, deliveredAt: 6318.775215833333,
                                              nanosecondsPerTick: 125.0 / 3)
        #expect(abs((posted ?? 0) - 6318.774144208) < 0.000001)
        #expect(GlobeKeyMonitor.eventTime(0, deliveredAt: 100) == nil)
    }

    @Test func hardwareClockHoldCommitsAtRelease() {
        let q = Queue(), box = Box(), clock = DeliveryClock()
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        let ticksPerSecond = 1_000_000_000 * Double(base.denom) / Double(base.numer)
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) }, clock: { clock.now })
        m.onAction = { box.actions.append($0) }
        defer { m.stop() }
        func send(_ down: Bool, at time: TimeInterval) {
            clock.now = time + 0.001
            let e = fnEvent(down: down); e.timestamp = UInt64(time * ticksPerSecond)
            _ = m.process(type: .flagsChanged, event: e)
        }
        send(true, at: 100); send(false, at: 104.568)
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .commitRecording])
        #expect(m.stateForTesting == .idle)
    }

    @Test func queuedDoubleTapUsesPhysicalTimesDespiteColdMicDelay() {
        let q = Queue(), box = Box()
        var deliveredAt = 100.0
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) }, clock: { deliveredAt })
        m.onAction = { box.actions.append($0) }
        defer { m.stop() }
        func send(down: Bool, pressedAt: TimeInterval, delivered: TimeInterval) {
            deliveredAt = delivered
            let e = fnEvent(down: down)
            e.timestamp = UInt64(pressedAt * 1_000_000_000)
            _ = m.process(type: .flagsChanged, event: e)
        }
        send(down: true, pressedAt: 100, delivered: 100)
        // These events queued while starting the cold microphone on the main queue.
        send(down: false, pressedAt: 100.08, delivered: 100.65)
        send(down: true, pressedAt: 100.22, delivered: 100.66)
        send(down: false, pressedAt: 100.30, delivered: 100.67)
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .enterHandsFree])
        #expect(m.stateForTesting == .handsFree)
        #expect(!m.isFnDown && !m.isPollingForTesting)
        q.work.removeAll()
        send(down: true, pressedAt: 172, delivered: 172.1)
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .enterHandsFree, .commitRecording])
    }

    @Test func delayedLongHoldStillCommitsAndLateSecondTapStaysSeparate() {
        let q = Queue(), box = Box()
        var deliveredAt = 100.0
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) }, clock: { deliveredAt })
        m.onAction = { box.actions.append($0) }
        defer { m.stop() }
        func send(_ down: Bool, at time: TimeInterval) {
            deliveredAt = time + 0.7
            let e = fnEvent(down: down); e.timestamp = UInt64(time * 1_000_000_000)
            _ = m.process(type: .flagsChanged, event: e)
        }
        send(true, at: 100); send(false, at: 102)
        send(true, at: 103); send(false, at: 103.08)
        send(true, at: 104)
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .commitRecording, .startRecording, .cancelRecording, .startRecording])
        #expect(m.stateForTesting == .holding(downAt: 104))
    }

    @Test func delayedReleaseDoesNotExpireBeforeTheQueuedSecondTap() async throws {
        let q = Queue(), box = Box()
        let clock = DeliveryClock()
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) }, clock: { clock.now })
        m.onAction = { box.actions.append($0) }
        defer { m.stop() }
        func send(_ down: Bool, at time: TimeInterval) {
            let e = fnEvent(down: down); e.timestamp = UInt64(time * 1_000_000_000)
            _ = m.process(type: .flagsChanged, event: e)
            q.work.forEach { $0() }; q.work.removeAll()
        }
        send(true, at: 100)
        clock.now = 100.65
        send(false, at: 100.08)
        // Give an incorrectly scheduled zero-delay timeout a chance to fire.
        try await Task.sleep(for: .milliseconds(50))
        #expect(box.actions == [.startRecording])
        #expect(m.stateForTesting == .awaitingSecondTap(releasedAt: 100.08))
        clock.now = 100.70; send(true, at: 100.22)
        clock.now = 100.71; send(false, at: 100.30)
        #expect(box.actions == [.startRecording, .enterHandsFree])
        #expect(m.stateForTesting == .handsFree)
    }

    // STRUCTURAL (item 1): no work inside the tap callback
    @Test func actionsAreNeverDeliveredSynchronously() {
        let (m, q, box) = make()
        let pass = m.handle(type: .flagsChanged, event: fnEvent(down: true))
        #expect(!pass)                       // Globe swallowed
        #expect(box.actions.isEmpty)         // nothing ran inside the callback
        #expect(q.work.count == 1)
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording])
    }

    @Test func tapDisableReEnablesResetsAndCancels() {
        let (m, q, box) = make()
        _ = m.handle(type: .flagsChanged, event: fnEvent(down: true))
        let dummy = CGEvent(source: nil)!
        _ = m.handle(type: .tapDisabledByTimeout, event: dummy)
        #expect(m.stateForTesting == .idle)
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording, .cancelRecording])
        // Missed Fn-up doesn't wedge: next Fn-down starts fresh.
        q.work.removeAll(); box.actions.removeAll()
        _ = m.handle(type: .flagsChanged, event: fnEvent(down: true))
        q.work.forEach { $0() }
        #expect(box.actions == [.startRecording])
    }

    @Test func fnWithCommandIsPassedThroughAndIgnored() {
        let (m, q, box) = make()
        let pass = m.handle(type: .flagsChanged, event: fnEvent(down: true, flags: .maskCommand))
        #expect(pass)
        q.work.forEach { $0() }
        #expect(box.actions.isEmpty)
    }

    /// BUG C safety net: ⌃⌥⌘V in the tap is consumed and scheduled (never run inline); plain
    /// ⌘V and other chords pass through untouched.
    @Test func pasteAgainChordIsConsumedAndScheduled() {
        let (m, q, box) = make()
        var fired = 0
        m.onPasteAgain = { fired += 1 }
        m.pasteKeyCode = { 9 }
        func key(_ flags: CGEventFlags) -> CGEvent {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!; e.flags = flags; return e
        }
        #expect(!m.handle(type: .keyDown, event: key([.maskControl, .maskAlternate, .maskCommand])))
        #expect(fired == 0, "not inside the tap callback")
        q.work.forEach { $0() }
        #expect(fired == 1 && box.actions.isEmpty)
        q.work.removeAll()
        #expect(m.handle(type: .keyDown, event: key([.maskCommand])), "plain ⌘V passes")
        q.work.forEach { $0() }
        #expect(fired == 1)
    }

    @Test func timestampSanityBoundsIncludeNormalDeliveryDelays() {
        func time(_ seconds: TimeInterval) -> TimeInterval? {
            GlobeKeyMonitor.eventTime(UInt64(seconds * 1_000_000_000), deliveredAt: 10_000,
                                      nanosecondsPerTick: 1)
        }
        #expect(time(9_997) == 9_997)
        #expect(time(10_000.05) == 10_000.05)
        #expect(time(9_996.999) == 10_000)
        #expect(time(10_000.051) == 10_000)
    }

    @Test(arguments: [-7_200.0, 7_200.0])
    func implausibleTimestampsDoNotBreakDoubleTap(offset: TimeInterval) {
        let q = Queue(), box = Box(), clock = DeliveryClock()
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) }, clock: { clock.now })
        m.onAction = { box.actions.append($0) }
        defer { m.stop() }
        func send(_ down: Bool, at time: TimeInterval) {
            clock.now = time
            let e = fnEvent(down: down)
            e.timestamp = UInt64((time + offset) * 1_000_000_000)
            #expect(GlobeKeyMonitor.eventTime(e.timestamp, deliveredAt: time, nanosecondsPerTick: 1) == time)
            _ = m.process(type: .flagsChanged, event: e)
            q.work.forEach { $0() }; q.work.removeAll()
        }
        send(true, at: 10_000); send(false, at: 10_000.08)
        send(true, at: 10_000.22); send(false, at: 10_000.30)
        #expect(box.actions == [.startRecording, .enterHandsFree])
        #expect(m.stateForTesting == .handsFree)
        #expect(!m.isFnDown && !m.isPollingForTesting)
    }

    @Test(arguments: [-7_200.0, 7_200.0])
    func implausibleReleaseDoesNotExtendDoubleTapWindow(offset: TimeInterval) {
        let q = Queue(), box = Box(), clock = DeliveryClock()
        let m = GlobeKeyMonitor(schedule: { q.work.append($0) }, clock: { clock.now })
        m.onAction = { box.actions.append($0) }
        defer { m.stop() }
        func send(_ down: Bool, at time: TimeInterval, offset: TimeInterval = 0) {
            clock.now = time
            let e = fnEvent(down: down)
            e.timestamp = UInt64((time + offset) * 1_000_000_000)
            _ = m.process(type: .flagsChanged, event: e)
            q.work.forEach { $0() }; q.work.removeAll()
        }
        send(true, at: 10_000); send(false, at: 10_000.08, offset: offset)
        #expect(m.stateForTesting == .awaitingSecondTap(releasedAt: 10_000.08))
        // A later press starts a new dictation, even if the previous timestamp was far ahead.
        send(true, at: 10_001)
        #expect(box.actions == [.startRecording, .cancelRecording, .startRecording])
        #expect(m.stateForTesting == .holding(downAt: 10_001))
    }
}

@MainActor @Suite struct EventTapRecoveryTests {
    @Test func disabledTapIsReenabledBeforeRecreation() {
        var enabled = false
        var recreations = 0
        #expect(EventTapRecovery.ensure(isEnabled: { enabled }, enable: { enabled = true },
                                       recreate: { recreations += 1; return false }))
        #expect(recreations == 0)
    }
    @Test(arguments: [true, false]) func failedReenableRecreatesBeforeReportingFailure(_ recreated: Bool) {
        var steps: [String] = []
        let running = EventTapRecovery.ensure(isEnabled: { false }, enable: { steps.append("enable") },
                                             recreate: { steps.append("recreate"); return recreated })
        #expect(steps == ["enable", "recreate"])
        #expect(running == recreated)
        var machine = PermissionStateMachine()
        #expect(machine.update(accessibility: true, inputMonitoring: true, tapRunning: running)
                == (recreated ? .ready : .stalePermission))
    }
}
