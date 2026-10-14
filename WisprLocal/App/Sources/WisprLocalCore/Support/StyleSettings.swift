import Foundation
import Observation

/// Settings › Writing: per-app writing styles (default ON) and backtrack (default ON for Light/Medium).
/// Persisted in UserDefaults, apart from `AppSettings` so the feature stays self-contained.
@MainActor
@Observable
public final class StyleSettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// Per-app styles: master switch, category styles and per-app overrides.
    public var configuration: StyleConfiguration { didSet { save() } }
    /// "Fix “actually” corrections" (backtrack). ON for Light/Medium unless explicitly disabled.
    public var backtrackEnabled: Bool { didSet { defaults.set(backtrackEnabled, forKey: Keys.backtrack) } }

    public var useOnDeviceAI: Bool { didSet { defaults.set(useOnDeviceAI, forKey: Keys.ai) } }
    public var cleanupLevel: CleanupLevel { didSet { defaults.set(cleanupLevel.rawValue, forKey: Keys.level) } }
    public var spokenPunctuationEnabled: Bool { didSet { defaults.set(spokenPunctuationEnabled, forKey: Keys.punctuation) } }

    public static let backtrackDefault = true

    enum Keys {
        static let ai = "useOnDeviceAI"
        static let level = "cleanupLevel"
        static let punctuation = "spokenPunctuationEnabled"
        static let styles = "writingStyles"
        static let backtrack = "backtrackEnabled"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Preserve explicit OFF choices, including the pre-formatting legacy key. Never infer
        // OFF from bool(forKey:): an absent key means the new Light default.
        let stored = defaults.string(forKey: Keys.level).flatMap(CleanupLevel.init(rawValue:))
        let disabled = (defaults.object(forKey: AppSettings.Keys.previousAIFormatting) as? Bool
            ?? defaults.object(forKey: AppSettings.Keys.previousAICleanup) as? Bool) == false
        let migrated = stored ?? .light
        useOnDeviceAI = defaults.object(forKey: Keys.ai) as? Bool ?? !disabled
        defaults.set(defaults.object(forKey: Keys.ai) as? Bool ?? !disabled, forKey: Keys.ai)
        cleanupLevel = migrated
        defaults.set(migrated.rawValue, forKey: Keys.level)
        spokenPunctuationEnabled = defaults.object(forKey: Keys.punctuation) as? Bool ?? true
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
