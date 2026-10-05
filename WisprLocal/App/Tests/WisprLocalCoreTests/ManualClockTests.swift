import Testing
import Foundation
@testable import WisprLocalCore

/// The test clock itself is deterministic: `advance` wakes only sleepers already registered and
/// moves `now` first; `waitForSleepers` / `waitForSleeper(until:)` replace yield or poll loops.
@MainActor @Suite struct ManualClockTests {
    @Test func advanceWakesRegisteredSleepersAtTheNewTime() async throws {
        let clock = ManualClock()
        let woke = Task { @MainActor in try await clock.sleep(until: .seconds(5)); return clock.now }
        await clock.waitForSleeper(until: .seconds(5))
        await clock.advance(by: .seconds(4))
        #expect(clock.sleeperCount == 1)
        await clock.advance(by: .seconds(3))
        #expect(clock.sleeperCount == 0)
        #expect(try await woke.value == .seconds(7), "a woken task sees the advanced time")
    }

    @Test func aSleepForAPassedDeadlineReturnsAtOnce() async throws {
        let clock = ManualClock()
        await clock.advance(by: .seconds(2))
        try await clock.sleep(until: .seconds(1))
        #expect(clock.sleeperCount == 0)
    }

    @Test func waitForSleepersTracksCancellation() async {
        let clock = ManualClock()
        let t = Task { @MainActor in try? await clock.sleep(until: .seconds(9)) }
        await clock.waitForSleepers(count: 1)
        t.cancel()
        await clock.waitForSleepers(count: 0)
        await t.value
        #expect(clock.now == .zero)
    }

    @Test func steppingALoopObservesEveryTick() async {
        let clock = ManualClock()
        var ticks: [Duration] = []
        let loop = Task { @MainActor in
            for k in 1...3 { try? await clock.sleep(until: .seconds(k)); ticks.append(clock.now) }
        }
        for k in 1...3 {
            await clock.waitForSleeper(until: .seconds(k))
            await clock.advance(by: .seconds(1))
        }
        await loop.value
        #expect(ticks == [.seconds(1), .seconds(2), .seconds(3)])
    }
    @Test func raceTimeoutCancelsSleepingTimerAfterWorkFinishes() async throws {
        let clock = ManualClock()
        let result = Task {
            try await raceTimeout(.seconds(5), clock: clock) {
                try await clock.sleep(until: .seconds(1))
                return 7
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(1))
        #expect(try await result.value == 7)
        await clock.waitForSleepers(count: 0)
        #expect(clock.now == .seconds(1))
    }

    @Test func raceTimeoutCancelsWorkAtTheDeadline() async throws {
        let clock = ManualClock()
        let result = Task {
            try await raceTimeout(.seconds(1), clock: clock) {
                try await clock.sleep(until: .seconds(5))
                return 7
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(1))
        do {
            _ = try await result.value
            Issue.record("Expected timeout")
        } catch let error as TimeoutError {
            #expect(error.after == .seconds(1))
        }
        await clock.waitForSleepers(count: 0)
    }

}
