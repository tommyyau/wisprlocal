import Foundation

/// HUD copy for the smart dictionary (one chip component, same placement as every chip).
public enum SmartDictionaryCopy {
    /// U1: the chip names BOTH halves of what Add does — the Word and the rewrite rule:
    /// "Always write “kuber netties” as “Kubernetes”?" (buttons Add / Not now).
    public static let suggestionPrefix = "Always write “"
    public static let suggestionMiddle = "” as “"
    public static let suggestionSuffix = "”?"
    public static func suggestion(_ c: Correction) -> String { suggestionPrefix + c.misheard + suggestionMiddle + c.correct + suggestionSuffix }
    public static func isSuggestion(_ s: String) -> Bool {
        s.hasPrefix(suggestionPrefix) && s.hasSuffix(suggestionSuffix) && s.contains(suggestionMiddle)
    }
    public static func added(_ term: String) -> String { "Added “\(term)” to your dictionary" }
    public static let addedPrefix = "Added “"
}

/// Chip copy that has no other home.
public enum ChipCopy {
    /// Confirmation after "Hide Indicator for 1 Hour" (the pill's right-click menu).
    public static let indicatorHidden = "Indicator hidden for 1 hour"
}

/// What a chip's buttons do. The app maps each to its button (`HUDButton`); the titles live here
/// so the verb style is one list: one word where possible, sentence case ("Not now").
public enum HUDChipAction: String, CaseIterable, Sendable {
    case seeWhy, micSettings, undoCorrection, copyOriginal, addWord, notNow, showIndicator

    public var title: String {
        switch self {
        case .seeWhy: return "See why"
        case .micSettings: return "Settings"
        case .undoCorrection: return "Undo"
        case .copyOriginal: return "Copy original"
        case .addWord: return "Add"
        case .notNow: return "Not now"
        case .showIndicator: return "Undo"
        }
    }

    /// The secondary (outlined) button; everything else is primary.
    public var isPrimary: Bool { self != .notNow }
}

/// Which chip wins when two want the pill at once. Higher wins; see `HUDChipQueue`.
public enum HUDChipPriority: Int, Comparable, Sendable, CaseIterable {
    /// Status and confirmations ("Cancelled", "Recording stops in 9 s", "Indicator hidden…").
    case info = 0
    /// "Always write “Y” as “X”?" and "Added “X”…".
    case suggestion = 1
    /// "Corrected" with Undo (or Copy original).
    case undo = 2
    /// Something happened to your words or the mic: never hidden behind anything else.
    case alert = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// HUD chip rules (STRUCTURAL; DESIGN.md › "HUD chips"): one component, one chip at a time, one
/// priority order (alert > undo > suggestion > info) and one timing rule (8 s with a button,
/// 3 s without). Every transient HUD message goes through `classify`.
public enum HUDChipPolicy {
    public static let secondsWithButtons: Double = 8
    public static let secondsInformational: Double = 3
    /// A chip that was interrupted comes back only if at least this much of its time is left
    /// (less would only flicker).
    public static let minimumRemaining: Double = 1.5
    /// A chip that has waited this long behind others is stale and dropped.
    public static let maximumWait: Double = 10

    public static func seconds(actions: [HUDChipAction]) -> Double { actions.isEmpty ? secondsInformational : secondsWithButtons }

    public static func actions(for text: String) -> [HUDChipAction] {
        if text.hasPrefix(PipelineNotice.didntCatchPrefix) { return [.seeWhy] }
        if text == PipelineNotice.micCuttingOut { return [.micSettings] }
        if text == PipelineNotice.corrected { return [.undoCorrection] }
        if text == PipelineNotice.correctedCopyOnly { return [.copyOriginal] }
        if SmartDictionaryCopy.isSuggestion(text) { return [.addWord, .notNow] }
        if text == ChipCopy.indicatorHidden { return [.showIndicator] }
        return []
    }

    static let alertTexts: Set<String> = [
        PipelineNotice.captureInterrupted, PipelineNotice.focusChanged, PipelineNotice.secureInput, PipelineNotice.remoteSecureInput,
        PipelineNotice.asrTimedOut, PipelineNotice.pasteNotConfirmed,
        PipelineNotice.micCuttingOut,
    ]
    static let alertPrefixes = [PipelineNotice.didntCatchPrefix, "Speech model unavailable", "Transcription failed"]

    public static func priority(for text: String) -> HUDChipPriority {
        if alertTexts.contains(text) || alertPrefixes.contains(where: text.hasPrefix) { return .alert }
        if text == PipelineNotice.corrected || text == PipelineNotice.correctedCopyOnly { return .undo }
        if SmartDictionaryCopy.isSuggestion(text) || text.hasPrefix(SmartDictionaryCopy.addedPrefix) { return .suggestion }
        return .info
    }

    public static func chip(_ text: String, priority: HUDChipPriority? = nil) -> HUDChip {
        let a = actions(for: text)
        return HUDChip(text: text, priority: priority ?? self.priority(for: text), actions: a, seconds: seconds(actions: a))
    }
}

public struct HUDChip: Equatable, Sendable {
    public var usesWarningTint: Bool { priority == .alert }
    public var text: String
    public var priority: HUDChipPriority
    public var actions: [HUDChipAction]
    public var seconds: Double
}

/// The single chip slot plus one waiting slot. Pure: the HUD feeds it times (seconds, any
/// monotonic clock) and acts on the returned events.
/// - A chip of the SAME or HIGHER priority replaces the one showing (same tier: latest wins).
///   A LOWER chip that was showing is parked with the time it had left (Undo comes back after
///   an alert).
/// - A LOWER chip waits; only the highest waiting chip is kept (the newer one on a tie).
/// - When the shown chip ends, the waiting one shows: a chip that never showed gets its full
///   time, a parked one what it had left (dropped under `HUDChipPolicy.minimumRemaining`). A chip
///   that waited longer than `HUDChipPolicy.maximumWait` is stale and dropped.
/// - `clear()` (a new recording starts: the pill must show the mic is on) ends everything.
public struct HUDChipQueue: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public var chip: HUDChip
        /// While showing: when it ends. While waiting: unused.
        public var deadline: Double
        /// While waiting: the time it still gets once shown.
        public var remaining: Double
        /// While waiting: since when.
        public var waitingSince: Double
    }
    public enum Event: Equatable, Sendable {
        case show(HUDChip)
        /// Taken down (expired, replaced, dismissed, dropped while waiting or cleared).
        case ended(HUDChip)
    }

    public private(set) var current: Slot?
    public private(set) var waiting: Slot?

    public init() {}

    /// When `tick` must next be called (nil: nothing on a timer).
    public var nextDeadline: Double? {
        guard let cur = current else { return nil }
        guard let w = waiting else { return cur.deadline }
        return min(cur.deadline, w.waitingSince + HUDChipPolicy.maximumWait)
    }

    public mutating func offer(_ chip: HUDChip, now: Double) -> [Event] {
        var events = tick(now: now)
        guard let cur = current else {
            current = Slot(chip: chip, deadline: now + chip.seconds, remaining: chip.seconds, waitingSince: now)
            return events + [.show(chip)]
        }
        guard chip.priority >= cur.chip.priority else {
            return events + park(Slot(chip: chip, deadline: 0, remaining: chip.seconds, waitingSince: now))
        }
        current = Slot(chip: chip, deadline: now + chip.seconds, remaining: chip.seconds, waitingSince: now)
        if cur.chip.text != chip.text {
            if cur.chip.priority == chip.priority {
                events.append(.ended(cur.chip))
            } else {
                events += park(Slot(chip: cur.chip, deadline: 0, remaining: cur.deadline - now, waitingSince: now))
            }
        }
        return events + [.show(chip)]
    }

    /// Puts `slot` in the waiting slot if it outranks (or ties, being newer) what waits there.
    private mutating func park(_ slot: Slot) -> [Event] {
        guard let w = waiting else { waiting = slot; return [] }
        if slot.chip.priority >= w.chip.priority {
            waiting = slot
            return [.ended(w.chip)]
        }
        return [.ended(slot.chip)]
    }

    public mutating func tick(now: Double) -> [Event] {
        var events: [Event] = []
        if let w = waiting, now - w.waitingSince >= HUDChipPolicy.maximumWait {
            waiting = nil
            events.append(.ended(w.chip))
        }
        if let cur = current, now >= cur.deadline {
            current = nil
            events.append(.ended(cur.chip))
            events += promote(now: now)
        }
        return events
    }

    private mutating func promote(now: Double) -> [Event] {
        guard let w = waiting else { return [] }
        waiting = nil
        guard w.remaining >= HUDChipPolicy.minimumRemaining else { return [.ended(w.chip)] }
        current = Slot(chip: w.chip, deadline: now + w.remaining, remaining: w.remaining, waitingSince: now)
        return [.show(w.chip)]
    }

    /// The user acted on the chip (a button) or its subject went away.
    public mutating func dismiss(text: String, now: Double) -> [Event] {
        var events: [Event] = []
        if let w = waiting, w.chip.text == text { waiting = nil; events.append(.ended(w.chip)) }
        if let cur = current, cur.chip.text == text {
            current = nil
            events.append(.ended(cur.chip))
            events += promote(now: now)
        }
        return events
    }

    public mutating func clear() -> [Event] {
        var events: [Event] = []
        if let cur = current { events.append(.ended(cur.chip)) }
        if let w = waiting { events.append(.ended(w.chip)) }
        current = nil; waiting = nil
        return events
    }
}
