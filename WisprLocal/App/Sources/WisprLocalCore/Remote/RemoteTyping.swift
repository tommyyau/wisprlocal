import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Identity of "where keystrokes are going": frontmost app + its focused viewer window/title.
public struct FocusToken: Equatable, Sendable {
    public var pid: Int32?
    public var windowTitle: String?
    public var window: AXIdentity? = nil
    public init(pid: Int32?, windowTitle: String?) { self.pid = pid; self.windowTitle = windowTitle }

    /// Unknown AX identity/title at capture time permits the configured default/fallback route.
    func matches(_ target: FocusToken) -> Bool {
        pid == target.pid && (target.window == nil || window == target.window)
            && (target.windowTitle == nil || windowTitle == target.windowTitle)
    }
}

/// Reads the current focus. `full == false` is the cheap per-keystroke check (pid only);
/// `full == true` also asks Accessibility for the focused window title.
public enum FocusProbe {
    @MainActor public static func current(full: Bool) async -> FocusToken {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard full, let pid else { return FocusToken(pid: pid, windowTitle: nil) }
        return await boundedRead(pid: pid) { readWindow(pid: pid) }
    }

    /// Includes queue waiting time: a stalled AX provider cannot hold up the main actor.
    static func boundedRead(pid: Int32, provider: @escaping @Sendable () -> FocusToken) async -> FocusToken {
        let shot = OneShot<FocusToken>()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            shot.resume(.success(FocusToken(pid: pid, windowTitle: nil)))
        }
        return (try? await withCheckedThrowingContinuation { continuation in
            shot.install(continuation)
            AXQueue.queue.async { shot.resume(.success(provider())) }
        }) ?? FocusToken(pid: pid, windowTitle: nil)
    }

    private static func readWindow(pid: Int32) -> FocusToken {
        var result = FocusToken(pid: pid, windowTitle: nil)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return result }
        let window = w as! AXUIElement
        result.window = AXIdentity(window)
        AXUIElementSetMessagingTimeout(window, 0.04)
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success {
            result.windowTitle = title as? String
        }
        return result
    }

    @MainActor public static func frontmostWindowTitle() async -> String? { await current(full: true).windowTitle }
}

/// Carries the gate-time viewer identity through the complete fallback strategy.
@MainActor public protocol RemoteTargetInserter: TextInserter {
    func insert(_ text: String, target: FocusToken, prePostCheck: @escaping @MainActor () throws -> Void) async throws
}

@MainActor private func checkRemoteTarget(_ now: FocusToken, target: FocusToken,
                                        prePostCheck: @MainActor () throws -> Void, typed: Int, total: Int) throws {
    try Task.checkCancellation()
    try prePostCheck()
    guard now.matches(target) else { throw RemoteTypingError.focusChanged(typed: typed, of: total) }
}

/// One synthesized keyboard action for remote typing.
public enum TypingStep: Equatable, Sendable {
    case stroke(KeyStroke)
    case unicode([UInt16])
}

public enum RemoteTypingError: Error, LocalizedError, Equatable {
    case focusChanged(typed: Int, of: Int)
    public var errorDescription: String? {
        switch self {
        case .focusChanged(let typed, let total):
            return "Focus changed while typing — stopped after \(typed) of \(total) keystrokes."
        }
    }
}

/// A local safety refusal after a remote typing prefix has already been posted.
public struct RemoteTypingBlocked: Error {
    public enum Reason: Sendable { case secureInput, conflict(String) }
    public let reason: Reason
    public let typed: Int
    public let total: Int
}

/// Pure planner (unit-tested). One step per character, so a remote viewer never sees a
/// multi-character event. Newline → **Shift+Return** (a bare Return SENDS in chat apps).
/// Keycode mode uses the layout map; characters it cannot produce go as Unicode, per char.
public enum RemoteTypingPlanner {
    public enum Mode: Sendable { case unicode, keycode }
    public static let shiftReturn = KeyStroke(keyCode: UInt16(kVK_Return), flags: .maskShift)
    public static let tab = KeyStroke(keyCode: UInt16(kVK_Tab), flags: [])

    public static func plan(_ text: String, mode: Mode, map: [Character: KeyStroke] = [:]) -> [TypingStep] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.map { ch -> TypingStep in
            if ch == "\n" { return .stroke(shiftReturn) }
            if ch == "\t" { return .stroke(tab) }
            if mode == .keycode, let s = map[ch] { return .stroke(s) }
            return .unicode(Array(String(ch).utf16))
        }
    }
}

/// Types into a remote viewer: Unicode or keycode mode, 4 ms per character, aborts (throws)
/// the moment the frontmost app / focused window changes.
@MainActor
public final class PacedTypingInserter: RemoteTargetInserter {
    public static let defaultInterval: Duration = .milliseconds(4)
    public let mode: RemoteTypingPlanner.Mode
    public var interval: Duration
    public var name: String { mode == .unicode ? "remote-unicode" : "remote-keycode" }
    private let focus: @MainActor (Bool) async -> FocusToken
    private let post: @MainActor (TypingStep) throws -> Void
    private let map: @MainActor () -> [Character: KeyStroke]

    public init(mode: RemoteTypingPlanner.Mode, interval: Duration = PacedTypingInserter.defaultInterval,
                focus: (@MainActor (Bool) -> FocusToken)? = nil,
                post: (@MainActor (TypingStep) throws -> Void)? = nil,
                map: (@MainActor () -> [Character: KeyStroke])? = nil) {
        self.mode = mode
        self.interval = interval
        if let focus { self.focus = { focus($0) } }
        else { self.focus = { await FocusProbe.current(full: $0) } }
        self.post = post ?? { step in
            switch step {
            case .stroke(let s): try KeyEventPoster.postKey(CGKeyCode(s.keyCode), flags: s.flags)
            case .unicode(let u): try KeyEventPoster.postUnicode(u)
            }
        }
        self.map = map ?? { KeyStrokeMap.shared.current }
    }

    public func insert(_ text: String) async throws {
        try await insert(text, target: await focus(true), prePostCheck: {})
    }

    public func insert(_ text: String, target: FocusToken,
                       prePostCheck: @escaping @MainActor () throws -> Void) async throws {
        let steps = RemoteTypingPlanner.plan(text, mode: mode, map: mode == .keycode ? map() : [:])
        guard !steps.isEmpty else { return }
        for (i, step) in steps.enumerated() {
            if Task.isCancelled { throw TypingCancellation(typed: i, total: steps.count) }
            do {
                let fullFocus = i % 16 == 0 ? await focus(true) : nil
                // No AX calls: catch an app switch during the full read or between chunks.
                let now = await focus(false)
                try Task.checkCancellation()
                try prePostCheck()
                guard now.pid == target.pid else {
                    throw RemoteTypingError.focusChanged(typed: i, of: steps.count)
                }
                if let fullFocus {
                    try checkRemoteTarget(fullFocus, target: target, prePostCheck: {}, typed: i, total: steps.count)
                }
            } catch is CancellationError {
                throw TypingCancellation(typed: i, total: steps.count)
            } catch let reason as PasteGateError {
                guard i > 0 else { throw reason }
                switch reason {
                case .focusChanged: throw reason
                case .secureInput: throw RemoteTypingBlocked(reason: .secureInput, typed: i, total: steps.count)
                case .conflict(let message): throw RemoteTypingBlocked(reason: .conflict(message), typed: i, total: steps.count)
                }
            }
            try post(step)
            do { try await Task.sleep(for: interval) }
            catch { throw TypingCancellation(typed: i + 1, total: steps.count) }
            if Task.isCancelled { throw TypingCancellation(typed: i + 1, total: steps.count) }
        }
    }
}

/// Local pasteboard → wait `delay` (Screen Sharing syncs the clipboard late) → Cmd-V →
/// restore the previous clipboard `restoreAfter` later (only if nobody changed it meanwhile).
@MainActor
public final class ClipboardDelayInserter: RemoteTargetInserter {
    public var name: String { "remote-clipboard" }
    public var delay: Duration
    public var restoreAfter: Duration
    private let pasteboard: NSPasteboard
    private let focus: @MainActor (Bool) async -> FocusToken
    private let postPaste: @MainActor () throws -> Void
    private let clock: PipelineClock

    public init(delay: Duration = .milliseconds(RemoteConfig.defaultClipboardDelayMs),
                restoreAfter: Duration = .milliseconds(1500), pasteboard: NSPasteboard = .general,
                focus: (@MainActor (Bool) -> FocusToken)? = nil,
                postPaste: (@MainActor () throws -> Void)? = nil,
                clock: PipelineClock = SystemPipelineClock()) {
        self.clock = clock
        self.delay = delay
        self.restoreAfter = restoreAfter
        self.pasteboard = pasteboard
        if let focus { self.focus = { focus($0) } }
        else { self.focus = { await FocusProbe.current(full: $0) } }
        self.postPaste = postPaste ?? { try KeyEventPoster.postKey(KeyboardLayoutMap.shared.pasteKeyCode, flags: .maskCommand) }
    }

    public func insert(_ text: String) async throws {
        try await insert(text, target: await focus(true), prePostCheck: {})
    }

    public func insert(_ text: String, target: FocusToken,
                       prePostCheck: @escaping @MainActor () throws -> Void) async throws {
        guard !text.isEmpty else { return }
        try checkRemoteTarget(await focus(true), target: target, prePostCheck: prePostCheck, typed: 0, total: 1)
        try Task.checkCancellation()
        let snapshot = ClipboardRestore.take(pasteboard).snapshot
        let ours = PrivatePasteboard.write(text, to: pasteboard, currentHostOnly: false, autoGenerated: true)
        ClipboardRestore.hold(snapshot, on: pasteboard, ourChange: ours)
        do {
            try await clock.sleep(until: clock.now + delay)
            try Task.checkCancellation()
        } catch {
            ClipboardRestore.restoreNow(snapshot, on: pasteboard, ourChange: ours)
            throw error
        }
        do {
            let now = await focus(true)
            guard await focus(false).pid == target.pid else { throw RemoteTypingError.focusChanged(typed: 0, of: 1) }
            try checkRemoteTarget(now, target: target, prePostCheck: prePostCheck, typed: 0, total: 1)
        } catch {
            ClipboardRestore.restoreNow(snapshot, on: pasteboard, ourChange: ours)
            throw error
        }
        do { try postPaste() } catch {
            ClipboardRestore.restoreNow(snapshot, on: pasteboard, ourChange: ours); throw error
        }
        ClipboardRestore.schedule(snapshot, on: pasteboard, ourChange: ours, delay: restoreAfter, clock: clock)
    }

    public func waitForRestore() async { await ClipboardRestore.wait(pasteboard) }
}
