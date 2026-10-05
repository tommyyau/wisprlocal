import Testing
@testable import WisprLocalCore

@Suite struct HotkeyStateMachineTests {
    typealias M = HotkeyStateMachine

    @Test func holdIsPushToTalk() {
        var m = M()
        #expect(m.handle(.fnDown(otherModifiers: false), at: 10.0) == [.startRecording])
        #expect(m.handle(.fnUp, at: 12.0) == [.commitRecording])
        #expect(m.state == .idle)
    }

    @Test func longHoldCommitsOnRelease() {
        var m = M()
        _ = m.handle(.fnDown(otherModifiers: false), at: 0)
        #expect(m.timeout(at: 300).isEmpty)  // no deadline while holding
        #expect(m.handle(.fnUp, at: 590) == [.commitRecording])
    }

    @Test func doubleTapEntersHandsFreeAndNextPressStops() {
        var m = M()
        #expect(m.handle(.fnDown(otherModifiers: false), at: 0.00) == [.startRecording])
        #expect(m.handle(.fnUp, at: 0.10).isEmpty)
        #expect(m.deadline == 0.10 + 0.4)
        #expect(m.handle(.fnDown(otherModifiers: false), at: 0.30) == [.enterHandsFree])
        #expect(m.handle(.fnUp, at: 0.40).isEmpty)
        #expect(m.state == .handsFree)
        // Typing while hands-free is fine.
        #expect(m.handle(.otherKey, at: 2.0).isEmpty)
        #expect(m.handle(.fnDown(otherModifiers: false), at: 5.0) == [.commitRecording])
        #expect(m.handle(.fnUp, at: 5.1).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func singleShortTapIsDiscardedAfterWindow() {
        var m = M()
        _ = m.handle(.fnDown(otherModifiers: false), at: 0)
        _ = m.handle(.fnUp, at: 0.1)
        #expect(m.timeout(at: 0.3).isEmpty)
        #expect(m.timeout(at: 0.51) == [.cancelRecording])
        #expect(m.state == .idle)
    }

    @Test func secondTapTooLateStartsFreshRecording() {
        var m = M()
        _ = m.handle(.fnDown(otherModifiers: false), at: 0)
        _ = m.handle(.fnUp, at: 0.1)
        #expect(m.handle(.fnDown(otherModifiers: false), at: 0.9) == [.cancelRecording, .startRecording])
        #expect(m.state == .holding(downAt: 0.9))
    }

    @Test func fnPlusArrowIsIgnored() {
        var m = M()
        _ = m.handle(.fnDown(otherModifiers: false), at: 0)
        #expect(m.handle(.otherKey, at: 0.05) == [.cancelRecording])
        #expect(m.isSuppressed)
        #expect(m.handle(.otherKey, at: 0.1).isEmpty)
        #expect(m.handle(.fnUp, at: 1.0).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func fnWithModifierHeldIsIgnored() {
        var m = M()
        #expect(m.handle(.fnDown(otherModifiers: true), at: 0).isEmpty)
        #expect(m.handle(.fnUp, at: 1).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func typingRightAfterTapCancels() {
        var m = M()
        _ = m.handle(.fnDown(otherModifiers: false), at: 0)
        _ = m.handle(.fnUp, at: 0.1)
        #expect(m.handle(.otherKey, at: 0.2) == [.cancelRecording])
        #expect(m.state == .idle)
    }

    @Test func comboDuringSecondPressCancels() {
        var m = M()
        _ = m.handle(.fnDown(otherModifiers: false), at: 0)
        _ = m.handle(.fnUp, at: 0.1)
        _ = m.handle(.fnDown(otherModifiers: false), at: 0.2)
        #expect(m.handle(.otherKey, at: 0.25) == [.cancelRecording])
        #expect(m.handle(.fnUp, at: 0.3).isEmpty)
        #expect(m.state == .idle)
    }
}

extension HotkeyStateMachineTests {
    @Test func tapDisabledCancelsInFlightRecordingAndResets() {
        var m = M()
        _ = m.handle(.fnDown(otherModifiers: false), at: 0)
        #expect(m.tapDisabled() == [.cancelRecording])
        #expect(m.state == .idle)
        // hands-free too
        _ = m.handle(.fnDown(otherModifiers: false), at: 1.0); _ = m.handle(.fnUp, at: 1.1)
        _ = m.handle(.fnDown(otherModifiers: false), at: 1.2); _ = m.handle(.fnUp, at: 1.3)
        #expect(m.state == .handsFree)
        #expect(m.tapDisabled() == [.cancelRecording])
        #expect(m.tapDisabled().isEmpty)  // idle: nothing to cancel
    }
}
