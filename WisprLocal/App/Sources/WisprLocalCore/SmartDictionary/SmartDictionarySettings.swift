import Foundation
import Observation

/// "Learn words from my corrections".
public enum LearnMode: String, CaseIterable, Sendable, Identifiable {
    /// Default: a HUD chip asks "Always write “Y” as “X”?" (Add = the Word + a Replacement).
    case suggest
    /// Adds the word and the fix straight away (the HUD says so).
    case automatic
    /// Never watches a field after a paste.
    case off

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .suggest: "Suggest"
        case .automatic: "Add automatically"
        case .off: "Off"
        }
    }
}

/// Smart dictionary settings, persisted in UserDefaults under their own keys (separate from
/// `AppSettings` so the feature stays self-contained).
@MainActor
@Observable
public final class SmartDictionarySettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var learnMode: LearnMode { didSet { defaults.set(learnMode.rawValue, forKey: Keys.learnMode) } }
    /// Settings › Writing › "Names and terms near your cursor" — OFF by default (opt-in).
    public var contextNamesEnabled: Bool { didSet { defaults.set(contextNamesEnabled, forKey: Keys.contextNames) } }
    /// Apps never read for context names (bundle ids). Editable; password managers by default.
    /// Finance-category apps (banking) are excluded on top of this list, always.
    public var contextDenylist: [String] { didSet { defaults.set(contextDenylist, forKey: Keys.denylist) } }

    public static let learnModeDefault: LearnMode = .suggest
    public static let contextNamesDefault = false

    enum Keys {
        static let learnMode = "smartDictionary.learnMode"
        static let contextNames = "smartDictionary.contextNames"
        static let denylist = "smartDictionary.contextDenylist"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        learnMode = defaults.string(forKey: Keys.learnMode).flatMap(LearnMode.init(rawValue:)) ?? Self.learnModeDefault
        contextNamesEnabled = defaults.object(forKey: Keys.contextNames) as? Bool ?? Self.contextNamesDefault
        contextDenylist = defaults.stringArray(forKey: Keys.denylist) ?? ContextPolicy.defaultDenylist
    }

    /// Adds a bundle id to the denylist (deduplicated). Returns false when already listed.
    @discardableResult
    public func deny(_ bundleID: String) -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !contextDenylist.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return false }
        contextDenylist.append(id)
        return true
    }

    public func allow(_ bundleID: String) { contextDenylist.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame } }

    public func resetDenylist() { contextDenylist = ContextPolicy.defaultDenylist }
}
