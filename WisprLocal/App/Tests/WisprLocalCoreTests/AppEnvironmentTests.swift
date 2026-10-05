import Testing
import Foundation
@testable import WisprLocalCore

/// `WISPRLOCAL_*` env vars with the pre-rename `WISPRLITE_*` names as a fallback.
@Suite struct AppEnvironmentTests {
    static let new = AppEnvironment.prefix + "MODELS_DIR"
    static let old = AppEnvironment.legacyPrefix + "MODELS_DIR"

    @Test func newNameWinsOverLegacy() {
        #expect(AppEnvironment.value("MODELS_DIR", in: [Self.new: "/new", Self.old: "/old"]) == "/new")
    }

    @Test func legacyNameIsFallback() {
        #expect(AppEnvironment.value("MODELS_DIR", in: [Self.old: "/old"]) == "/old")
        #expect(AppEnvironment.value("MODELS_DIR", in: [Self.new: "/new"]) == "/new")
        #expect(AppEnvironment.value("MODELS_DIR", in: [:]) == nil)
    }

    @Test func flagNeedsExactlyOneAndHonoursPrecedence() {
        let n = AppEnvironment.prefix + "FM_BENCH", o = AppEnvironment.legacyPrefix + "FM_BENCH"
        #expect(AppEnvironment.flag("FM_BENCH", in: [o: "1"]))
        #expect(AppEnvironment.flag("FM_BENCH", in: [n: "1", o: "0"]))
        #expect(!AppEnvironment.flag("FM_BENCH", in: [n: "0", o: "1"]))   // new name wins
        #expect(!AppEnvironment.flag("FM_BENCH", in: [n: "true"]))
        #expect(!AppEnvironment.flag("FM_BENCH", in: [:]))
    }

    @Test func modelLocatorHonoursBothNames() {
        let std = ModelLocator.standard(bundle: .main, environment: [Self.old: "/legacy-models"])
        #expect(std.searchRoots.first?.path == "/legacy-models")
        let both = ModelLocator.standard(bundle: .main, environment: [Self.new: "/new-models", Self.old: "/legacy-models"])
        #expect(both.searchRoots.first?.path == "/new-models")
        #expect(!both.searchRoots.contains { $0.path == "/legacy-models" })
    }

    // MARK: - Hygiene: legacy names are read ONLY through AppEnvironment

    static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Swift files (relative to the app root) containing a string literal that starts with the
    /// legacy prefix. Pure, so the rule itself is unit-tested below.
    static func legacyLiteralOffenders(_ files: [(path: String, text: String)]) -> [String] {
        let needle = "\"" + AppEnvironment.legacyPrefix
        return files.filter { $0.path != "Sources/WisprLocalCore/Support/AppEnvironment.swift" && $0.text.contains(needle) }
            .map(\.path)
    }

    @Test func noSwiftSourceReadsLegacyNameDirectly() throws {
        var files: [(path: String, text: String)] = []
        for dir in ["Sources", "Tests", "Tools"] {
            let base = Self.appRoot.appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                let rel = dir + url.path.dropFirst(base.path.count)
                files.append((rel, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        #expect(files.count > 50)
        #expect(files.contains { $0.path == "Sources/WisprLocalCore/Support/AppEnvironment.swift" })
        let bad = Self.legacyLiteralOffenders(files)
        #expect(bad.isEmpty, "read env vars via AppEnvironment.value/flag, not a legacy-prefixed literal: \(bad)")
    }

    @Test func legacyLiteralRuleBites() {
        let lit = "\"" + AppEnvironment.legacyPrefix + "X\""
        let bad = Self.legacyLiteralOffenders([
            ("Sources/WisprLocalCore/Foo.swift", "env[\(lit)]"),
            ("Sources/WisprLocalCore/Support/AppEnvironment.swift", "let p = \(lit)"),
            ("Tests/Ok.swift", "AppEnvironment.value(\"X\")"),
        ])
        #expect(bad == ["Sources/WisprLocalCore/Foo.swift"])
    }
}
