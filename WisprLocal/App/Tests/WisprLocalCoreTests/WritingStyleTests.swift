import Testing
import Foundation
@testable import WisprLocalCore

/// Per-app styles: the category × style × input matrix, defaults, and the meaning-safety
/// property (a style never adds, removes or changes a word).
@Suite struct WritingStyleTests {
    static let names = FixedNames(["Sam", "Alex", "London"])

    struct Case: CustomTestStringConvertible, Sendable {
        let category: AppCategory, style: WritingStyle, input: String, expected: String
        var testDescription: String { "\(category.rawValue)/\(style.rawValue): \(input)" }
    }

    static let matrix: [Case] = [
        // Formal (Email, Docs, Browser, Other by default)
        Case(category: .email, style: .formal, input: "see you at 3", expected: "See you at 3."),
        Case(category: .email, style: .formal, input: "See you at 3.", expected: "See you at 3."),
        Case(category: .email, style: .formal, input: "Is that ok?", expected: "Is that ok?"),
        Case(category: .docs, style: .formal, input: "thanks, Sam", expected: "Thanks, Sam."),
        Case(category: .docs, style: .formal, input: "iPhone sales are up", expected: "iPhone sales are up."),
        Case(category: .docs, style: .formal, input: "Wait…", expected: "Wait…"),
        Case(category: .docs, style: .formal, input: "first item\nsecond item", expected: "First item\nsecond item"),
        Case(category: .browser, style: .formal, input: "great work!", expected: "Great work!"),
        Case(category: .other, style: .formal, input: "He said \"hi\"", expected: "He said \"hi\"."),
        Case(category: .other, style: .formal, input: "3 people came", expected: "3 people came."),
        // Casual (Messages, AI tools by default)
        Case(category: .messages, style: .casual, input: "See you at 3.", expected: "See you at 3"),
        Case(category: .messages, style: .casual, input: "see you at 3.", expected: "see you at 3"),
        Case(category: .messages, style: .casual, input: "Running late. See you at 3.", expected: "Running late. See you at 3."),
        Case(category: .messages, style: .casual, input: "Are you coming?", expected: "Are you coming?"),
        Case(category: .messages, style: .casual, input: "Meet at 9 a.m.", expected: "Meet at 9 a.m."),
        Case(category: .messages, style: .casual, input: "Version 6.1 is out.", expected: "Version 6.1 is out"),
        Case(category: .ai, style: .casual, input: "Summarise this, e.g. the intro.", expected: "Summarise this, e.g. the intro"),
        Case(category: .ai, style: .casual, input: "Write a haiku.", expected: "Write a haiku"),
        Case(category: .ai, style: .casual, input: "Okay...", expected: "Okay..."),
        // Very casual (opt-in)
        Case(category: .messages, style: .veryCasual, input: "See you at 3.", expected: "see you at 3"),
        Case(category: .messages, style: .veryCasual, input: "I think so.", expected: "I think so"),
        Case(category: .messages, style: .veryCasual, input: "I'm in.", expected: "I'm in"),
        Case(category: .messages, style: .veryCasual, input: "Sam is here.", expected: "Sam is here"),
        Case(category: .messages, style: .veryCasual, input: "NASA called.", expected: "NASA called"),
        Case(category: .messages, style: .veryCasual, input: "Kubernetes is down.", expected: "Kubernetes is down"),
        Case(category: .messages, style: .veryCasual, input: "Tuesday works.", expected: "Tuesday works"),
        Case(category: .messages, style: .veryCasual, input: "Sounds good! See you.", expected: "sounds good! See you"),
        Case(category: .messages, style: .veryCasual, input: "Really?", expected: "really?"),
        // Code (Xcode, VS Code, Terminal by default)
        Case(category: .code, style: .code, input: "Rename the variable.", expected: "rename the variable"),
        Case(category: .code, style: .code, input: "git status", expected: "git status"),
        Case(category: .code, style: .code, input: "UserDefaults is slow.", expected: "UserDefaults is slow"),
        Case(category: .code, style: .code, input: "Foo_bar should be renamed.", expected: "Foo_bar should be renamed"),
        Case(category: .code, style: .code, input: "Call foo.bar.", expected: "call foo.bar"),
        Case(category: .code, style: .code, input: "Why does this fail?", expected: "why does this fail?"),
        Case(category: .code, style: .code, input: "I fixed it.", expected: "I fixed it"),
        Case(category: .code, style: .code, input: "Use README.md.", expected: "use README.md"),
    ]

    @Test(arguments: matrix)
    func styleMatrix(_ c: Case) {
        let out = c.style.apply(c.input, vocabulary: ["Kubernetes"], names: Self.names)
        #expect(out == c.expected)
    }

    @Test func matrixCoversEnoughCases() { #expect(Self.matrix.count >= 30) }

    @Test func liveExampleOnTheCards() {
        let n = FixedNames()
        #expect(WritingStyle.formal.apply("see you at 3", names: n) == "See you at 3.")
        #expect(WritingStyle.casual.apply(WritingStyle.exampleInput, names: n) == "See you at 3")
        #expect(WritingStyle.formal.apply(WritingStyle.exampleInput, names: n) == "See you at 3.")
    }

    @Test func defaultsPerCategory() {
        #expect(WritingStyle.defaultStyle(for: .email) == .formal)
        #expect(WritingStyle.defaultStyle(for: .docs) == .formal)
        #expect(WritingStyle.defaultStyle(for: .browser) == .formal)
        #expect(WritingStyle.defaultStyle(for: .messages) == .casual)
        #expect(WritingStyle.defaultStyle(for: .ai) == .casual)
        #expect(WritingStyle.defaultStyle(for: .code) == .code)
        // Very casual is opt-in only: never a default.
        #expect(!AppCategory.allCases.contains { WritingStyle.defaultStyle(for: $0) == .veryCasual })
    }

    @Test func configurationResolvesOverridesFirst() {
        var c = StyleConfiguration()
        #expect(c.style(forBundleID: "com.apple.dt.Xcode") == .code)
        #expect(c.style(forBundleID: "com.tinyspeck.slackmacgap") == .casual)
        #expect(c.style(forBundleID: "com.apple.mail") == .formal)
        #expect(c.style(forBundleID: nil) == .formal)
        #expect(c.style(forBundleID: "com.microsoft.VSCode") == .code)
        #expect(c.style(forBundleID: "com.apple.Terminal") == .code)
        #expect(c.style(forBundleID: "com.todesktop.230313mzl4w4u92") == .code)  // Cursor
        #expect(c.style(forBundleID: "com.openai.chat") == .casual)
        c.categories[.messages] = .veryCasual
        #expect(c.style(forBundleID: "com.tinyspeck.slackmacgap") == .veryCasual)
        c.appOverrides["com.tinyspeck.slackmacgap"] = .formal
        #expect(c.style(forBundleID: "com.tinyspeck.slackmacgap") == .formal)
        c.enabled = false
        #expect(c.style(forBundleID: "com.apple.dt.Xcode") == nil)
    }

    @MainActor @Test func settingsPersistAndDefaultOn() throws {
        let suite = "styles-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let s = StyleSettingsStore(defaults: d)
        #expect(s.configuration.enabled)
        #expect(!s.backtrackEnabled)
        s.setStyle(.veryCasual, for: .messages)
        s.setOverride(.code, forBundleID: "com.example.app")
        let again = StyleSettingsStore(defaults: d)
        #expect(again.configuration.style(for: .messages) == .veryCasual)
        #expect(again.configuration.appOverrides["com.example.app"] == .code)
        again.setOverride(nil, forBundleID: "com.example.app")
        #expect(StyleSettingsStore(defaults: d).configuration.appOverrides.isEmpty)
    }

    // MARK: meaning safety (property test)

    static let vocabulary = ["the", "a", "see", "you", "at", "3", "meeting", "Sam", "I", "NASA", "iPhone", "foo_bar",
                             "is", "ready", "tomorrow", "6.1", "e.g.", "a.m.", "why", "not", "ok", "London", "we", "ship",
                             "Kubernetes", "\"quoted\"", "(aside)", "x.y", "Über", "ß", "it's", "U.S."]
    static let ends = ["", ".", "?", "!", "...", "…", ".\"", ")", ". "]

    /// Words with their case folded on the first letter of the first word and a single trailing
    /// full stop on the last word removed: these, and only these, may differ.
    static func words(_ s: String) -> [String] {
        var w = s.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !w.isEmpty else { return w }
        if let f = w[0].firstIndex(where: \.isLetter) {
            w[0].replaceSubrange(f...f, with: w[0][f].lowercased())
        }
        // One full stop at the end of the last word, before any closing quotes/brackets.
        var last = w[w.count - 1]
        var closing = ""
        while let c = last.last, "\"”’)".contains(c) { closing = String(c) + closing; last.removeLast() }
        if last.hasSuffix("."), !last.hasSuffix("..") { last.removeLast() }
        w[w.count - 1] = last + closing
        if w[w.count - 1].isEmpty { w.removeLast() }
        return w
    }

    @Test func everyStyleKeepsEveryWord() {
        var rng = SeededGenerator(seed: 0x5717E5)
        var checked = 0
        for _ in 0..<600 {
            let n = Int.random(in: 1...9, using: &rng)
            var parts = (0..<n).map { _ in Self.vocabulary.randomElement(using: &rng)! }
            if Bool.random(using: &rng) { parts[0] = parts[0].prefix(1).uppercased() + parts[0].dropFirst() }
            if n > 3, Bool.random(using: &rng) { parts[n / 2] += "." }
            let sentence = parts.joined(separator: " ") + Self.ends.randomElement(using: &rng)!
            for style in WritingStyle.allCases {
                let out = style.apply(sentence, vocabulary: ["Kubernetes"], names: FixedNames(["Sam", "London"]))
                #expect(Self.words(out) == Self.words(sentence), "\(style): \(sentence) → \(out)")
                // Whitespace layout is untouched, and only the edges may change.
                #expect(out.filter(\.isWhitespace) == sentence.filter(\.isWhitespace))
                #expect(abs(out.count - sentence.count) <= 1)
                checked += 1
            }
        }
        #expect(checked == 600 * WritingStyle.allCases.count)
    }

    /// R4: Formal's full stop goes OUTSIDE closing brackets and quotes, and is skipped after a
    /// code-like token, a URL, an emoji or an existing terminal mark. Never inside `foo(bar)`.
    static let formalStops: [(String, String)] = [
        ("see the doc (attached)", "See the doc (attached)."),
        ("He said \"hi\"", "He said \"hi\"."),
        ("she wrote “done”", "She wrote “done”."),
        ("it's the 'beta'", "It's the 'beta'."),
        ("check the list [below]", "Check the list [below]."),
        ("nested (see [this])", "Nested (see [this])."),
        ("with a space after (aside) ", "With a space after (aside). "),
        ("call foo(bar)", "Call foo(bar)"),
        ("run print(\"hi\")", "Run print(\"hi\")"),
        ("then call self.reload()", "Then call self.reload()"),
        ("open https://example.com", "Open https://example.com"),
        ("go to www.example.com", "Go to www.example.com"),
        ("edit README.md", "Edit README.md"),
        ("set foo_bar", "Set foo_bar"),
        ("use x==y", "Use x==y"),
        ("it costs $5", "It costs $5."),
        ("upgrade to 6.1", "Upgrade to 6.1."),
        ("meet at 3:30", "Meet at 3:30."),
        ("ping @sam", "Ping @sam"),
        ("tag #release", "Tag #release"),
        ("run `make`", "Run `make`"),
        ("see ~/notes", "See ~/notes"),
        ("great work 🎉", "Great work 🎉"),
        ("love it 👍🏽", "Love it 👍🏽"),
        ("(see the doc.)", "(See the doc.)"),
        ("\"Is it?\"", "\"Is it?\""),
        ("he shouted \"go!\"", "He shouted \"go!\""),
        ("note:", "Note:"),
        ("wait…", "Wait…"),
        ("see you at 3", "See you at 3."),
        ("iPhone sales are up", "iPhone sales are up."),
        ("meet in Q3", "Meet in Q3."),
    ]

    @Test func formalStopGoesOutsideClosersAndSkipsCode() {
        for (input, expected) in Self.formalStops {
            let out = WritingStyle.formal.apply(input, names: FixedNames())
            #expect(out == expected, "\(input) → \(out)")
            #expect(WritingStyle.formal.apply(out, names: FixedNames()) == out, "idempotent: \(input)")
        }
    }

    /// Formal never puts a new full stop directly before a closing bracket or quote.
    @Test func formalNeverAddsAStopBeforeACloser() {
        var rng = SeededGenerator(seed: 0xC105E5)
        for _ in 0..<400 {
            let n = Int.random(in: 1...6, using: &rng)
            let parts = (0..<n).map { _ in Self.vocabulary.randomElement(using: &rng)! }
            let sentence = parts.joined(separator: " ") + Self.ends.randomElement(using: &rng)!
            let out = WritingStyle.formal.apply(sentence, names: FixedNames())
            for closer in [")", "]", "\"", "”", "’", "'"] {
                #expect(out.components(separatedBy: "." + closer).count <= sentence.components(separatedBy: "." + closer).count,
                        "\(sentence) → \(out)")
            }
        }
    }

    @Test func styleIsIdempotent() {
        for s in WritingStyle.allCases {
            for input in ["see you at 3", "See you at 3.", "Running late. See you at 3.", "git status", "I'm in."] {
                let once = s.apply(input, names: FixedNames())
                #expect(s.apply(once, names: FixedNames()) == once, "\(s): \(input)")
            }
        }
    }
}

/// Deterministic PRNG (SplitMix64) for property tests.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
