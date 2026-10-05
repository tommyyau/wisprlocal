import Foundation
import Observation

/// The small conveniences (Settings › General), persisted in UserDefaults under their own
/// keys so `AppSettings` stays untouched: an extra mouse-button trigger, start/stop sounds,
/// Shift-on-release auto-send, history retention and "hide the indicator for 1 hour".
@MainActor
@Observable
public final class ConvenienceSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Extra push-to-talk button. Default `.none` (no mouse tap is installed at all).
    public var mouseTrigger: MouseTrigger { didSet { defaults.set(mouseTrigger.rawValue, forKey: Keys.mouseTrigger) } }
    /// Quiet start/stop sounds. Default OFF.
    public var feedbackSounds: Bool { didSet { defaults.set(feedbackSounds, forKey: Keys.feedbackSounds) } }
    /// Hold Shift when you let go to press Return after the paste. Default ON (it only fires when
    /// Shift is actually held at release).
    public var shiftReturnAutoSend: Bool { didSet { defaults.set(shiftReturnAutoSend, forKey: Keys.shiftReturn) } }
    /// Keep history forever (default), 30 days, 7 days or 24 hours.
    public var historyRetention: HistoryRetention { didSet { defaults.set(historyRetention.rawValue, forKey: Keys.historyRetention) } }
    /// The recording pill is hidden until this moment (nil = shown). Persisted, so it survives a
    /// relaunch within the hour.
    public private(set) var indicatorHiddenUntil: Date? {
        didSet {
            if let d = indicatorHiddenUntil { defaults.set(d.timeIntervalSinceReferenceDate, forKey: Keys.indicatorHiddenUntil) }
            else { defaults.removeObject(forKey: Keys.indicatorHiddenUntil) }
        }
    }

    enum Keys {
        static let mouseTrigger = "mouseTrigger"
        static let feedbackSounds = "feedbackSounds"
        static let shiftReturn = "shiftReturnAutoSend"
        static let historyRetention = "historyRetention"
        static let indicatorHiddenUntil = "indicatorHiddenUntil"
    }

    /// How long "Hide Indicator for 1 Hour" lasts.
    public static let hideDuration: TimeInterval = 3_600

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mouseTrigger = defaults.string(forKey: Keys.mouseTrigger).flatMap(MouseTrigger.init(rawValue:)) ?? .none
        feedbackSounds = defaults.object(forKey: Keys.feedbackSounds) as? Bool ?? false
        shiftReturnAutoSend = defaults.object(forKey: Keys.shiftReturn) as? Bool ?? true
        historyRetention = defaults.string(forKey: Keys.historyRetention).flatMap(HistoryRetention.init(rawValue:)) ?? .forever
        indicatorHiddenUntil = (defaults.object(forKey: Keys.indicatorHiddenUntil) as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
    }

    /// The pill is hidden right now. Expiry is evaluated against `now` (no timer needed: the HUD
    /// and the menu ask whenever they render).
    public func isIndicatorHidden(now: Date) -> Bool {
        guard let until = indicatorHiddenUntil else { return false }
        return now < until
    }

    public func hideIndicator(now: Date) { indicatorHiddenUntil = now.addingTimeInterval(Self.hideDuration) }
    public func showIndicator() { indicatorHiddenUntil = nil }
}

/// Settings › General › "Mouse button".
public enum MouseTrigger: String, CaseIterable, Sendable, Identifiable {
    case none, middle, button4, button5

    public var id: String { rawValue }

    /// `CGEvent` `.mouseEventButtonNumber` for an `otherMouseDown/Up` (0 left, 1 right, 2 middle,
    /// 3 = "button 4", 4 = "button 5"). nil = no extra trigger.
    public var buttonNumber: Int64? {
        switch self {
        case .none: return nil
        case .middle: return 2
        case .button4: return 3
        case .button5: return 4
        }
    }

    /// The selected trigger for a raw button number (never left or right).
    public static func matching(buttonNumber n: Int64, selected: MouseTrigger) -> Bool {
        guard let b = selected.buttonNumber else { return false }
        return n == b
    }

    public var title: String {
        switch self {
        case .none: return "None"
        case .middle: return "Middle button"
        case .button4: return "Button 4 (back)"
        case .button5: return "Button 5 (forward)"
        }
    }
}

/// Settings › Privacy › "Keep history".
public enum HistoryRetention: String, CaseIterable, Sendable, Identifiable {
    case forever, days30, days7, hours24

    public var id: String { rawValue }

    public var maxAge: TimeInterval? {
        switch self {
        case .forever: return nil
        case .days30: return 30 * 86_400
        case .days7: return 7 * 86_400
        case .hours24: return 86_400
        }
    }

    /// Entries strictly older than this are pruned (nil = keep everything).
    public func cutoff(now: Date) -> Date? { maxAge.map { now.addingTimeInterval(-$0) } }

    /// Splits entries into the ones kept and the ones pruned.
    public func partition(_ entries: [HistoryEntry], now: Date) -> (kept: [HistoryEntry], pruned: [HistoryEntry]) {
        guard let cutoff = cutoff(now: now) else { return (entries, []) }
        var kept: [HistoryEntry] = [], pruned: [HistoryEntry] = []
        for e in entries { if e.timestamp < cutoff { pruned.append(e) } else { kept.append(e) } }
        return (kept, pruned)
    }

    public var title: String {
        switch self {
        case .forever: return "Forever"
        case .days30: return "30 days"
        case .days7: return "7 days"
        case .hours24: return "24 hours"
        }
    }

    /// How often the app re-checks while running (it also prunes at launch).
    public static let pruneInterval: TimeInterval = 3_600

    /// U3: shortening "Keep history" deletes right away, so it asks first. The question when
    /// `count` dictations would go ("Delete 123 dictations older than 7 days?"); nil = nothing
    /// would be deleted, apply at once.
    public func deleteConfirmation(count: Int) -> String? {
        guard count > 0, maxAge != nil else { return nil }
        return "Delete \(count) dictation\(count == 1 ? "" : "s") older than \(title)?"
    }

    public static let deleteConfirmationDetail = "They and their recordings are deleted now. This can't be undone."
}
