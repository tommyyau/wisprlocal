import Foundation

/// The ONE place Swift code reads WisprLocal's own environment variables. Variables are named
/// `WISPRLOCAL_<suffix>`; the pre-rename `WISPRLITE_<suffix>` is still honoured as a fallback.
/// The new name wins when both are set. `RepoHygieneTests` fails if any other Swift file reads a
/// legacy-prefixed string literal, so new code cannot bypass the alias.
public enum AppEnvironment {
    public static let prefix = "WISPRLOCAL_"
    public static let legacyPrefix = "WISPRLITE_"

    /// `WISPRLOCAL_<suffix>`, else `WISPRLITE_<suffix>`, else nil. An empty value counts as set
    /// (callers that treat empty as unset check `isEmpty` themselves).
    public static func value(_ suffix: String,
                             in env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        env[prefix + suffix] ?? env[legacyPrefix + suffix]
    }

    /// True when the variable (new or legacy name) is exactly "1".
    public static func flag(_ suffix: String,
                            in env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        value(suffix, in: env) == "1"
    }
}
