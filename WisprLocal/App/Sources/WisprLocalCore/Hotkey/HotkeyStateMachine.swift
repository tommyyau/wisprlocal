import Foundation

/// Pure, clock-free state machine for the Globe/Fn hotkey.
///
/// Gestures:
/// - **Hold** (push-to-talk): recording starts on Fn-down, commits on Fn-up.
/// - **Double-tap** (hands-free): a short tap followed by a second Fn-down within
///   `doubleTapWindow` of the first release switches to hands-free; recording keeps running
///   until Fn is pressed again (stop happens on that press's key-down).
/// - **Combos are ignored**: any other key or modifier while Fn is held (Fn+arrow, Fn+F-key,
///   Fn+Shift...) cancels the in-flight recording and suppresses until Fn is released.
///   Fn pressed while another modifier is already held is ignored entirely.
///
/// Recording starts on the *first* key-down so speech is never clipped; a lone short tap
/// that is not followed by a second tap is discarded via `.cancelRecording` when the
/// double-tap window expires (the driver calls `timeout(at:)` at `deadline`).
///
/// - **Triple-tap cancels hands-free**: the press that stops hands-free commits at once (no
///   added latency); if it is the first of three taps within `tripleTapWindow` (~0.6 s), the
///   second tap emits `.holdInsertion` (the pipeline waits before typing) and the third
///   `.cancelDictation` (nothing is typed, History records `cancelled`). When the window ends
///   after only two taps, `.releaseInsertion` lets the text through. Tracked in `tripleTap`
///   while `state` is `.idle`/`.stoppingKeyDown`.
/// - **The window never blocks a new dictation**: only quick TAPS count. A follow-up press still
///   held after `tapMaxDuration` (or when the window ends) is an ordinary hold-to-talk: the held
///   text is released and recording starts (`.releaseInsertion, .startRecording`). The warm mic's
///   300 ms pre-roll (`MicWarmPolicy.preRoll`, on by default) covers that wait, so no word is lost.
public struct HotkeyStateMachine: Sendable, Equatable {
    public enum Input: Sendable, Equatable {
        /// Fn/Globe went down. `otherModifiers` = any of Cmd/Ctrl/Opt/Shift held at that moment.
        case fnDown(otherModifiers: Bool)
        case fnUp
        /// A non-Fn key-down, or a change in another modifier.
        case otherKey
    }

    public enum Action: Sendable, Equatable {
        case startRecording
        /// Stop and process (transcribe + insert).
        case commitRecording
        /// Stop and discard.
        case cancelRecording
        /// Recording continues; the user will stop it with another Fn press.
        case enterHandsFree
        /// Triple-tap, 2nd tap: hold the just-committed dictation's insertion for a moment.
        case holdInsertion
        /// Triple-tap window ended after two taps: type the held dictation after all.
        case releaseInsertion
        /// Triple-tap (or Esc): discard the dictation in flight; nothing is typed.
        case cancelDictation
    }

    /// Taps counted after the press that stopped hands-free.
    public struct TripleTap: Sendable, Equatable {
        public var firstDownAt: TimeInterval
        public var taps: Int
        public var keyDown: Bool
        /// Press time of the latest follow-up tap (a press held past `tapMaxDuration` dictates).
        public var lastDownAt: TimeInterval

        public init(firstDownAt: TimeInterval, taps: Int, keyDown: Bool, lastDownAt: TimeInterval? = nil) {
            self.firstDownAt = firstDownAt; self.taps = taps; self.keyDown = keyDown
            self.lastDownAt = lastDownAt ?? firstDownAt
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        /// Fn held, recording. `downAt` = press time.
        case holding(downAt: TimeInterval)
        /// Released after a short tap; recording still running, waiting for a possible 2nd tap.
        case awaitingSecondTap(releasedAt: TimeInterval)
        /// Second press of a double-tap is still down.
        case handsFreeKeyDown
        /// Hands-free recording, Fn up.
        case handsFree
        /// Hands-free was stopped on key-down; waiting for the key-up.
        case stoppingKeyDown
        /// A combo was detected (or Fn pressed with modifiers); ignore everything until Fn-up.
        case suppressed
    }

    /// A press shorter than this counts as a "tap" (candidate for double-tap).
    public var tapMaxDuration: TimeInterval
    /// Max gap between the first tap's release and the second press.
    public var doubleTapWindow: TimeInterval

    /// Three taps within this window (first press = the one that stopped hands-free) cancel.
    public var tripleTapWindow: TimeInterval

    public private(set) var state: State = .idle
    public private(set) var tripleTap: TripleTap?

    public init(tapMaxDuration: TimeInterval = 0.3, doubleTapWindow: TimeInterval = 0.4, tripleTapWindow: TimeInterval = 0.6) {
        self.tapMaxDuration = tapMaxDuration
        self.doubleTapWindow = doubleTapWindow
        self.tripleTapWindow = tripleTapWindow
    }

    /// When non-nil, the driver must call `timeout(at:)` at (or after) this time.
    public var deadline: TimeInterval? {
        if case .awaitingSecondTap(let releasedAt) = state { return releasedAt + doubleTapWindow }
        if let tt = tripleTap {
            let windowEnd = tt.firstDownAt + tripleTapWindow
            return tt.taps >= 2 && tt.keyDown ? min(windowEnd, tt.lastDownAt + tapMaxDuration) : windowEnd
        }
        return nil
    }

    /// True when the Fn event that produced this transition should be swallowed
    /// (so the emoji picker / input-source switch doesn't fire). We swallow every Fn event
    /// except while suppressed (a combo the user meant for the system).
    public var isSuppressed: Bool { state == .suppressed }

    public mutating func handle(_ input: Input, at t: TimeInterval) -> [Action] {
        // Lazily resolve an expired double-tap window before handling the new input.
        var actions = timeout(at: t)

        // Follow-up taps after a hands-free stop (see the type comment).
        if var tt = tripleTap, state == .idle || state == .stoppingKeyDown {
            switch input {
            case .fnDown:
                if tt.keyDown { return actions }
                tt.taps += 1
                tt.keyDown = true
                tt.lastDownAt = t
                if tt.taps >= 3 {
                    tripleTap = nil
                    state = .stoppingKeyDown  // the third tap's key-up returns to idle
                    return actions + [.cancelDictation]
                }
                tripleTap = tt
                state = .idle
                return actions + [.holdInsertion]
            case .fnUp:
                tt.keyDown = false
                tripleTap = tt
                state = .idle
                return actions
            case .otherKey:
                tripleTap = nil
                return actions + (tt.taps >= 2 ? [.releaseInsertion] : [])
            }
        }

        switch (state, input) {
        case (.idle, .fnDown(let mods)):
            if mods { state = .suppressed } else {
                state = .holding(downAt: t)
                actions.append(.startRecording)
            }
        case (.idle, _):
            break

        case (.holding(let downAt), .fnUp):
            if t - downAt < tapMaxDuration {
                state = .awaitingSecondTap(releasedAt: t)
            } else {
                state = .idle
                actions.append(.commitRecording)
            }
        case (.holding, .otherKey):
            state = .suppressed
            actions.append(.cancelRecording)
        case (.holding, .fnDown):
            break  // duplicate down; ignore

        case (.awaitingSecondTap, .fnDown(let mods)):
            if mods {
                state = .suppressed
                actions.append(.cancelRecording)
            } else {
                state = .handsFreeKeyDown
                actions.append(.enterHandsFree)
            }
        case (.awaitingSecondTap, .otherKey):
            // User started typing right after a tap: it was not a dictation gesture.
            state = .idle
            actions.append(.cancelRecording)
        case (.awaitingSecondTap, .fnUp):
            break

        case (.handsFreeKeyDown, .fnUp):
            state = .handsFree
        case (.handsFreeKeyDown, .otherKey):
            state = .suppressed
            actions.append(.cancelRecording)
        case (.handsFreeKeyDown, .fnDown):
            break

        case (.handsFree, .fnDown):
            state = .stoppingKeyDown
            tripleTap = TripleTap(firstDownAt: t, taps: 1, keyDown: true)
            actions.append(.commitRecording)
        case (.handsFree, _):
            break  // normal typing during hands-free is allowed

        case (.stoppingKeyDown, .fnUp):
            state = .idle
        case (.stoppingKeyDown, _):
            break

        case (.suppressed, .fnUp):
            state = .idle
        case (.suppressed, _):
            break
        }
        return actions
    }

    /// Resolve the double-tap window. Returns `.cancelRecording` if a lone tap expired.
    public mutating func timeout(at t: TimeInterval) -> [Action] {
        if case .awaitingSecondTap(let releasedAt) = state, t >= releasedAt + doubleTapWindow {
            state = .idle
            return [.cancelRecording]
        }
        if let tt = tripleTap, tt.taps >= 2, tt.keyDown,
           t >= min(tt.firstDownAt + tripleTapWindow, tt.lastDownAt + tapMaxDuration) {
            // A held follow-up press is a new hold-to-talk dictation, never a blocked one.
            tripleTap = nil
            state = .holding(downAt: tt.lastDownAt)
            return [.releaseInsertion, .startRecording]
        }
        if let tt = tripleTap, t >= tt.firstDownAt + tripleTapWindow {
            tripleTap = nil
            return tt.taps >= 2 ? [.releaseInsertion] : []
        }
        return []
    }

    /// Force back to idle (e.g. the recorder hit its max duration or failed).
    public mutating func reset() { state = .idle; tripleTap = nil }

    /// The event tap was disabled by the system (timeout / user input). We may have missed the
    /// Fn-up, so any in-flight recording is discarded (never inserted) and state resets.
    public mutating func tapDisabled() -> [Action] {
        let wasRecording: Bool
        switch state {
        case .holding, .awaitingSecondTap, .handsFreeKeyDown, .handsFree: wasRecording = true
        case .idle, .stoppingKeyDown, .suppressed: wasRecording = false
        }
        let held = (tripleTap?.taps ?? 0) >= 2
        reset()
        return (wasRecording ? [.cancelRecording] : []) + (held ? [.releaseInsertion] : [])
    }
}
