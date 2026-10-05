import Testing
import Foundation

/// STRUCTURAL style lint (DESIGN.md: "Theme.swift is the single source of truth"). Every app
/// screen takes its colours, type, corner radii and paddings from `Theme` tokens; a literal
/// anywhere else is how one screen quietly drifts from the others. Scans
/// `Sources/WisprLocal/**/*.swift` (the app target) except `Theme.swift` and fails on:
/// - hard-coded colours: `Color(red:`, `Color(.sRGB`, `Color(hex:`, `NSColor(`, hex literals;
/// - literal font sizes: `.system(size:` (use a `Theme.Typo` token);
/// - literal corner radii: `cornerRadius: 8` (use `Theme.Radius`);
/// - literal paddings: `.padding(12)`, `.padding(.horizontal, 10)` (use `Theme.Space`).
/// Proportional geometry (`size * 0.13`) is not a literal. Comments are ignored.
/// Exceptions are explicit, each with its reason, and must still match something (no stale entries).
@Suite struct DesignTokenLintTests {
    struct Exception {
        let file: String
        /// The exact source fragment allowed on a line of `file`.
        let fragment: String
        let reason: String
    }

    static let exceptions: [Exception] = [
        Exception(file: "MenuMock.swift", fragment: ".system(size: 13",
                  reason: "Mock of the macOS menu bar menu: it must match the system menu font, not WisprLocal's type scale."),
        Exception(file: "MenuMock.swift", fragment: ".system(size: 11",
                  reason: "Mock of the macOS menu: the system's keyboard-shortcut glyph size."),
        Exception(file: "MenuMock.swift", fragment: ".system(size: 10, weight: .semibold)",
                  reason: "Mock of the macOS menu: the system's submenu chevron size."),
        Exception(file: "UIPreview.swift", fragment: ".padding(.top, topic == .speechModel ? 196 : 142)",
                  reason: "Preview harness: pins the info popover under its ⓘ button in a screenshot (a position, not spacing)."),
        Exception(file: "UIPreview.swift", fragment: ".padding(.leading, topic == .speechModel ? 310 : 370)",
                  reason: "Preview harness: pins the info popover under its ⓘ button in a screenshot (a position, not spacing)."),
    ]

    static var appSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WisprLocal")
    }

    struct Violation: CustomStringConvertible {
        let file: String, line: Int, rule: String, text: String
        var description: String { "\(file):\(line) [\(rule)] \(text.trimmingCharacters(in: .whitespaces))" }
    }

    static let rules: [(name: String, regex: NSRegularExpression)] = [
        ("colour", try! NSRegularExpression(pattern: ##"Color\(\s*red:|Color\(\s*\.sRGB|Color\(\s*hex:|NSColor\(|\b0x[0-9A-Fa-f]{6}\b|"#[0-9A-Fa-f]{6}""##)),
        ("font size", try! NSRegularExpression(pattern: #"\.system\(\s*size:"#)),
        ("corner radius", try! NSRegularExpression(pattern: #"cornerRadius:\s*-?\d"#)),
    ]
    static let number = try! NSRegularExpression(pattern: #"(?<![\w.])\d+(?:\.\d+)?(?![\w.])"#)

    /// `.padding(...)` arguments holding a non-zero numeric literal that isn't part of a
    /// proportional product (`size * 0.13`).
    static func literalPaddings(_ line: String) -> [String] {
        var out: [String] = []
        var search = line[...]
        while let r = search.range(of: ".padding(") {
            var depth = 1, i = r.upperBound
            while i < line.endIndex, depth > 0 {
                if line[i] == "(" { depth += 1 } else if line[i] == ")" { depth -= 1 }
                i = line.index(after: i)
            }
            let args = String(line[r.upperBound..<(depth == 0 ? line.index(before: i) : i)])
            search = line[i...]
            for m in number.matches(in: args, range: NSRange(args.startIndex..., in: args)) {
                let range = Range(m.range, in: args)!
                let n = Double(args[range]) ?? 0
                let before = args[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let after = args[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if n == 0 || before.hasSuffix("*") || after.hasPrefix("*") { continue }
                out.append(".padding(\(args))")
                break
            }
        }
        return out
    }

    /// Strips `//` comments (outside string literals, good enough for this codebase).
    static func code(_ line: String) -> String {
        var inString = false, prev: Character = " "
        var out = ""
        for c in line {
            if c == "\"" && prev != "\\" { inString.toggle() }
            if !inString && c == "/" && prev == "/" { out.removeLast(); break }
            out.append(c); prev = c
        }
        return out
    }

    static func scan(_ text: String, file: String) -> [Violation] {
        var out: [Violation] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = code(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var hits: [(String, String)] = literalPaddings(line).map { ("padding", $0) }
            for (name, re) in rules {
                for m in re.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    hits.append((name, String(line[Range(m.range, in: line)!])))
                }
            }
            for (name, hit) in hits where !exceptions.contains(where: { $0.file == file && line.contains($0.fragment) }) {
                out.append(Violation(file: file, line: i + 1, rule: name, text: hit))
            }
        }
        return out
    }

    static func files() throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        let e = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "Theme.swift" else { continue }
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    @Test func appUsesOnlyThemeTokens() throws {
        let files = try Self.files()
        #expect(files.count > 25, "scanned \(files.count) files under \(Self.appSources.path)")
        let violations = files.flatMap { Self.scan($0.text, file: $0.name) }
        let list = violations.map(\.description).joined(separator: "\n")
        #expect(violations.isEmpty, "hard-coded style outside Theme.swift (\(violations.count)):\n\(list)")
    }

    @Test func everyExceptionIsStillNeeded() throws {
        let files = Dictionary(try Self.files().map { ($0.name, $0.text) }, uniquingKeysWith: { a, _ in a })
        for x in Self.exceptions {
            #expect(files[x.file]?.contains(x.fragment) == true, "stale lint exception: \(x.file) \(x.fragment)")
            #expect(!x.reason.isEmpty)
        }
    }

    /// The lint itself catches what it should and leaves tokens alone.
    @Test func lintCatchesLiteralsAndAllowsTokens() {
        let bad = """
        Text("a").font(.system(size: 12, weight: .medium))
        RoundedRectangle(cornerRadius: 8, style: .continuous)
        x.padding(12)
        x.padding(.horizontal, 10).padding(.top, -5)
        Color(red: 1, green: 0, blue: 0)
        Color(hex: 0x7CF5D4)
        let c = NSColor(white: 1, alpha: 1)
        """
        let hits = Self.scan(bad, file: "X.swift")
        let rules = hits.map(\.rule)
        #expect(rules.filter { $0 == "font size" }.count == 1)
        #expect(rules.filter { $0 == "corner radius" }.count == 1)
        #expect(rules.filter { $0 == "padding" }.count == 3)  // 12, 10 and -5
        #expect(Set(hits.filter { $0.rule == "colour" }.map(\.line)) == [5, 6, 7])
        let good = """
        Text("a").font(Theme.Typo.caption) // .font(.system(size: 12)) in a comment is fine
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        x.padding(Theme.Space.s).padding(.horizontal, Theme.Space.xs).padding(.top, -Theme.Space.xxs)
        x.padding(.top, size * 0.11).padding(label == nil ? 0 : size * 0.13)
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        Text("Pay #1234567 now")
        """
        #expect(Self.scan(good, file: "X.swift").isEmpty, "\(Self.scan(good, file: "X.swift"))")
    }
}
