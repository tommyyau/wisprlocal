import Foundation
import Observation

/// Settings › Writing: per-app writing styles (default ON) and backtrack (default OFF).
/// Persisted in UserDefaults, apart from `AppSettings` so the feature stays self-contained.
@MainActor
@Observable
public final class StyleSettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// Per-app styles: master switch, category styles and per-app overrides.
    public var configuration: StyleConfiguration { didSet { save() } }
    /// "Fix “actually” corrections" (backtrack). OFF unless the user turns it on.
    public var backtrackEnabled: Bool { didSet { defaults.set(backtrackEnabled, forKey: Keys.backtrack) } }

    public static let backtrackDefault = false

    enum Keys {
        static let styles = "writingStyles"
        static let backtrack = "backtrackEnabled"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: Keys.styles).flatMap { try? JSONDecoder().decode(StyleConfiguration.self, from: $0) }
            ?? StyleConfiguration()
        backtrackEnabled = defaults.object(forKey: Keys.backtrack) as? Bool ?? Self.backtrackDefault
    }

    private func save() {
        if let d = try? JSONEncoder().encode(configuration) { defaults.set(d, forKey: Keys.styles) }
    }

    public func setStyle(_ s: WritingStyle, for c: AppCategory) { configuration.categories[c] = s }
    public func setOverride(_ s: WritingStyle?, forBundleID id: String) { configuration.appOverrides[id] = s }
}
