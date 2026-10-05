import AppKit
import Carbon.HIToolbox
import Foundation
import Synchronization

/// The app that should receive the text: captured when recording STARTS.
public struct FrontmostApp: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    public init(pid: Int32, bundleID: String?) { self.pid = pid; self.bundleID = bundleID }

    @MainActor public static func current() -> FrontmostApp? {
        NSWorkspace.shared.frontmostApplication.map { FrontmostApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) }
    }
}

/// Secure Event Input (password fields, some terminals). While on, we neither record nor insert.
public protocol SecureInputChecking: Sendable {
    var isSecureInputActive: Bool { get }
}

public struct SystemSecureInput: SecureInputChecking {
    public init() {}
    public var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
}

/// Where the text goes when we must not paste (focus changed).
@MainActor public protocol ClipboardWriting: AnyObject {
    func setString(_ s: String)
}

@MainActor public final class SystemClipboard: ClipboardWriting {
    private let pasteboard: NSPasteboard
    public convenience init() { self.init(pasteboard: .general) }
    public init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    public func setString(_ s: String) {
        PrivatePasteboard.write(s, to: pasteboard, currentHostOnly: true)
    }
}

public struct TimeoutError: Error, LocalizedError {
    public var after: Duration
    public var errorDescription: String? { "Timed out after \(after)" }
}

/// Races `op` against `timeout` WITHOUT structured concurrency, so a non-cooperative hung `op`
/// can't block the caller (a task group would wait for the hung child). The loser is cancelled.
public func raceTimeout<T: Sendable>(_ timeout: Duration,
                                     clock: PipelineClock = SystemPipelineClock(),
                                     _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = ResumeOnce<T>()
    let deadline = clock.now + timeout   // fixed now, not whenever the timer task first runs
    let timer = TimeoutTaskBox()
    return try await withCheckedThrowingContinuation { (k: CheckedContinuation<T, Error>) in
        once.c.withLock { $0 = k }
        let work = Task {
            do { _ = once.resume(.success(try await op())) } catch { _ = once.resume(.failure(error)) }
            timer.task.withLock { $0 }?.cancel()   // op finished first: don't leave the timer sleeping
        }
        let t = Task {
            do { try await clock.sleep(until: deadline) } catch { return }
            if once.resume(.failure(TimeoutError(after: timeout))) { work.cancel() }
        }
        timer.task.withLock { $0 = t }
    }
}

/// Reference capture keeps the timer mutex transferable on Swift 6.2 too.
final class TimeoutTaskBox: Sendable {
    let task = Mutex<Task<Void, Never>?>(nil)
}

/// Resumes a continuation at most once (first caller wins).
final class ResumeOnce<T: Sendable>: Sendable {
    let c = Mutex<CheckedContinuation<T, Error>?>(nil)
    func resume(_ r: Result<T, Error>) -> Bool {
        guard let k = c.withLock({ v -> CheckedContinuation<T, Error>? in let k = v; v = nil; return k }) else { return false }
        k.resume(with: r); return true
    }
}

/// Duration → milliseconds.
public func durationMs(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
