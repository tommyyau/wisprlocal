import Foundation
import Synchronization

/// Monotonic time source + sleeper used by the recording-cap countdown. Injected so tests can
/// drive time by hand (`ManualClock`) instead of racing the wall clock. Times are `Duration`s
/// since an arbitrary epoch.
public protocol PipelineClock: Sendable {
    var now: Duration { get }
    /// Suspends until `now >= deadline`. Throws `CancellationError` if the task is cancelled.
    func sleep(until deadline: Duration) async throws
}

/// Production clock: `ContinuousClock`, epoch = first use.
public struct SystemPipelineClock: PipelineClock {
    private static let epoch = ContinuousClock.now
    public init() {}
    public var now: Duration { Self.epoch.duration(to: .now) }
    public func sleep(until deadline: Duration) async throws {
        try await Task.sleep(until: Self.epoch.advanced(by: deadline), clock: .continuous)
    }
}

/// Deterministic clock: time moves only when `advance(by:)` is called, and nothing here depends on
/// scheduling luck (no yields, no real sleeps).
///
/// - `advance(by:)` moves `now` to the target FIRST, then resumes exactly the sleepers already
///   registered with a deadline at or before it (in deadline order). It does not wait for the
///   woken tasks: a woken task sees the new `now`, and a sleep it registers for a deadline that has
///   already passed returns at once.
/// - To step a loop that sleeps again after each wake-up (e.g. a once-a-second countdown), await
///   `waitForSleepers(count:)` / `waitForSleeper(until:)` between advances: they suspend until the
///   woken task has run and registered its next sleep, so every tick is observed.
public final class ManualClock: PipelineClock, @unchecked Sendable {
    private struct Waiter { let id: UInt64; let deadline: Duration; let k: CheckedContinuation<Void, Error> }
    /// A test parked in `waitUntil` until the set of pending deadlines satisfies `isMet`.
    private struct Watch { let isMet: @Sendable ([Duration]) -> Bool; let k: CheckedContinuation<Void, Never> }
    private struct State {
        var now: Duration = .zero
        var nextID: UInt64 = 0
        var waiters: [Waiter] = []
        var watches: [Watch] = []
        /// Removes and returns the watches satisfied by the current sleepers (resume outside the lock).
        mutating func takeMetWatches() -> [Watch] {
            guard !watches.isEmpty else { return [] }
            let deadlines = waiters.map(\.deadline)
            var met: [Watch] = [], rest: [Watch] = []
            for w in watches { if w.isMet(deadlines) { met.append(w) } else { rest.append(w) } }
            watches = rest
            return met
        }
    }
    private let state = Mutex(State())
    public init() {}

    public var now: Duration { state.withLock { $0.now } }
    /// Number of tasks currently suspended in `sleep(until:)`.
    public var sleeperCount: Int { state.withLock { $0.waiters.count } }
    /// Earliest pending wake-up time, if anything is sleeping.
    public var nextDeadline: Duration? { state.withLock { $0.waiters.map(\.deadline).min() } }

    public func sleep(until deadline: Duration) async throws {
        let id = state.withLock { s -> UInt64 in s.nextID += 1; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let (ready, met) = state.withLock { s -> (Bool, [Watch]) in
                    if Task.isCancelled { return (true, []) }
                    if deadline <= s.now { return (true, []) }
                    s.waiters.append(Waiter(id: id, deadline: deadline, k: k))
                    return (false, s.takeMetWatches())
                }
                for w in met { w.k.resume() }
                if ready { Task.isCancelled ? k.resume(throwing: CancellationError()) : k.resume() }
            }
        } onCancel: {
            let (w, met) = state.withLock { s -> (Waiter?, [Watch]) in
                guard let i = s.waiters.firstIndex(where: { $0.id == id }) else { return (nil, []) }
                let w = s.waiters.remove(at: i)
                return (w, s.takeMetWatches())
            }
            w?.k.resume(throwing: CancellationError())
            for m in met { m.k.resume() }
        }
    }

    /// Moves time forward by `d` and wakes the sleepers ALREADY registered whose deadline is now
    /// due, in deadline order. Never waits on the woken tasks (see the type comment).
    public func advance(by d: Duration) async {
        let (due, met) = state.withLock { s -> ([Waiter], [Watch]) in
            s.now = max(s.now, s.now + d)
            let target = s.now
            let due = s.waiters.filter { $0.deadline <= target }
                .sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
            s.waiters.removeAll { $0.deadline <= target }
            return (due, s.takeMetWatches())
        }
        for w in due { w.k.resume() }
        for m in met { m.k.resume() }
    }

    /// Suspends until exactly `count` tasks are sleeping on this clock (checked on every sleep,
    /// wake and cancel; returns at once if already true). Test hook: await this before `advance`
    /// so the task under test is provably asleep, and after it to know a woken loop slept again.
    public func waitForSleepers(count: Int) async {
        await waitUntil { $0.count == count }
    }

    /// Suspends until some task is sleeping until exactly `deadline`.
    public func waitForSleeper(until deadline: Duration) async {
        await waitUntil { $0.contains(deadline) }
    }

    private func waitUntil(_ isMet: @escaping @Sendable ([Duration]) -> Bool) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if isMet(s.waiters.map(\.deadline)) { return true }
                s.watches.append(Watch(isMet: isMet, k: k)); return false
            }
            if now { k.resume() }
        }
    }
}
