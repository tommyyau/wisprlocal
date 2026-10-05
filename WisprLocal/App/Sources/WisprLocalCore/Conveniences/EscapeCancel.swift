import Foundation

/// Esc cancels the active dictation (pure, clock-free; `GlobeKeyMonitor.onEscape` drives it).
///
/// - No WisprLocal dictation active → `.passThrough`: Esc reaches the app untouched.
/// - Active and the dictation is 30 s or shorter → `.cancel` at once.
/// - Active and longer than 30 s → the first Esc asks (`.confirm`, "Press Esc again to discard
///   42 s", for 3 s); a second Esc inside those 3 s → `.cancel`.
/// - Auto-repeat while active → `.consume` (swallowed, never counts as the confirming press).
public struct EscapeCancel: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case passThrough
        /// Swallow the key, do nothing.
        case consume
        case cancel
        /// Ask for a second Esc; `seconds` = the dictation length shown.
        case confirm(seconds: Int)

        public var consumesKey: Bool { self != .passThrough }
    }

    /// Dictations longer than this ask before discarding.
    public static let confirmAbove: TimeInterval = 30
    /// How long the "Press Esc again" prompt waits for the second Esc.
    public static let confirmWindow: TimeInterval = 3

    public private(set) var confirmUntil: TimeInterval?

    public init() {}

    /// `dictationSeconds`: nil when no dictation is active (not recording, nothing processing).
    public mutating func escape(at t: TimeInterval, dictationSeconds: Double?, isRepeat: Bool) -> Decision {
        guard let seconds = dictationSeconds else { confirmUntil = nil; return .passThrough }
        if isRepeat { return .consume }
        guard seconds > Self.confirmAbove else { confirmUntil = nil; return .cancel }
        if let until = confirmUntil, t <= until {
            confirmUntil = nil
            return .cancel
        }
        confirmUntil = t + Self.confirmWindow
        return .confirm(seconds: Int(seconds.rounded()))
    }

    /// The dictation ended or was cancelled another way: forget a pending confirmation.
    public mutating func reset() { confirmUntil = nil }
}

/// HUD notices for the conveniences (shown through the same notice component as every other).
extension PipelineNotice {
    public static let cancelled = "Cancelled"
    public static let escapeAgainPrefix = "Press Esc again to discard "
    public static func escapeAgain(seconds: Int) -> String { "\(escapeAgainPrefix)\(seconds) s" }
}

/// Hold Shift as you let go → Return is pressed after the paste ("auto-send"). STRUCTURAL: every
/// condition lives here, and the pipeline asks this ONE function.
public enum AutoSendPolicy {
    /// - `enabled`: Settings › General (default ON).
    /// - `shiftHeldAtRelease`: Shift was down on the event that committed the dictation.
    /// - Never in remote mode (Screen Sharing / paired receiver) and never while secure input
    ///   (a password field) is active.
    /// - Only after a real insertion whose paste was not seen to fail (`pasteVerified != false`):
    ///   a Return after a paste that didn't land would send the wrong thing.
    public static func shouldPressReturn(enabled: Bool, shiftHeldAtRelease: Bool, outcome: HistoryEntry.Outcome,
                                         strategy: InsertionStrategy?, secureInputActive: Bool, pasteVerified: Bool?) -> Bool {
        enabled && shiftHeldAtRelease && outcome == .inserted && strategy != .remote && strategy != nil
            && !secureInputActive && pasteVerified != false
    }

    /// R3, checked right before Return: the SAME focused element in the SAME window (CFEqual) as
    /// when the recording started. Unknown on either side (no AX) → false: never send blind.
    public static func focusUnchanged(atStart: FocusSnapshot?, now: FocusSnapshot?) -> Bool {
        guard let atStart, let now else { return false }
        return atStart.isSameFocus(as: now)
    }
}

extension PipelineNotice {
    /// Esc / triple-tap after the paste was already posted (R1): nothing more happens — no Return,
    /// no Undo, no learning — and History keeps the dictation as inserted.
    public static let alreadyTyped = "Already typed"
    public static let alreadyTypedNotSent = "Already typed · not sent"
}
