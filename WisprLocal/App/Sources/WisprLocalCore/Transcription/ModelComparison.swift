import Foundation

/// Word-level diff (LCS) for the dev A/B command: which words differ between two transcripts.
/// Case and trailing punctuation are ignored when matching, so "Hello," vs "hello" is equal.
public enum WordDiff {
    public enum Op: Equatable, Sendable { case same(String), onlyA(String), onlyB(String) }

    static func key(_ w: Substring) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    public static func diff(_ a: String, _ b: String) -> [Op] {
        pairs(a, b).map {
            switch $0 {
            case .same(let w, _): return .same(w)
            case .onlyA(let w): return .onlyA(w)
            case .onlyB(let w): return .onlyB(w)
            }
        }
    }

    /// Like `diff`, but a matched word carries BOTH spellings (`a`'s and `b`'s), so each side can
    /// be shown with its own case and punctuation (History › details).
    public enum Pair: Equatable, Sendable { case same(a: String, b: String), onlyA(String), onlyB(String) }

    public static func pairs(_ a: String, _ b: String) -> [Pair] {
        let x = a.split(whereSeparator: \.isWhitespace), y = b.split(whereSeparator: \.isWhitespace)
        let kx = x.map(key), ky = y.map(key)
        var l = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                l[i][j] = kx[i] == ky[j] ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
            }
        }
        var ops: [Pair] = [], i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, kx[i] == ky[j] { ops.append(.same(a: String(x[i]), b: String(y[j]))); i += 1; j += 1 }
            else if j < y.count, i == x.count || l[i][j + 1] >= l[i + 1][j] { ops.append(.onlyB(String(y[j]))); j += 1 }
            else { ops.append(.onlyA(String(x[i]))); i += 1 }
        }
        return ops
    }

    /// True when the transcripts match word for word (ignoring case and punctuation).
    public static func equivalent(_ a: String, _ b: String) -> Bool {
        diff(a, b).allSatisfy { if case .same = $0 { return true } else { return false } }
    }

    /// The two sides with differing words highlighted: `mark(word)` wraps a word only one side has.
    public static func highlighted(_ a: String, _ b: String, mark: (String) -> String = { "[\($0)]" }) -> (String, String) {
        var left: [String] = [], right: [String] = []
        for op in diff(a, b) {
            switch op {
            case .same(let w): left.append(w); right.append(w)
            case .onlyA(let w): left.append(mark(w))
            case .onlyB(let w): right.append(mark(w))
            }
        }
        return (left.joined(separator: " "), right.joined(separator: " "))
    }
}

/// `WisprLocalReplay --compare-all`: one clip transcribed by two models, and the summary.
public struct ModelComparison: Sendable {
    public struct Result: Sendable {
        public var text: String
        public var ms: Double
        public var error: String?
        public init(text: String, ms: Double, error: String? = nil) { self.text = text; self.ms = ms; self.error = error }
        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public struct Clip: Sendable {
        public var name: String
        /// Voice processing at capture (debug-recording sidecar); nil = unknown.
        public var voiceProcessing: Bool?
        public var a: Result
        public var b: Result
        public init(name: String, voiceProcessing: Bool?, a: Result, b: Result) {
            self.name = name; self.voiceProcessing = voiceProcessing; self.a = a; self.b = b
        }
    }

    public struct Summary: Sendable, Equatable {
        public var clips = 0, identical = 0, different = 0
        public var nonEnglishA = 0, nonEnglishB = 0
        public var emptyA = 0, emptyB = 0
        public var avgMsA = 0.0, avgMsB = 0.0
    }

    /// "Non-English" uses the same rule as the app's English-only cleanup gate.
    public static func summarize(_ clips: [Clip], detector: LanguageDetecting) -> Summary {
        var s = Summary()
        s.clips = clips.count
        func nonEnglish(_ t: String) -> Bool { !CleanupLanguagePolicy.decide(t, detector: detector).0.allowsCleanup }
        for c in clips {
            if WordDiff.equivalent(c.a.text, c.b.text) { s.identical += 1 } else { s.different += 1 }
            if nonEnglish(c.a.text) { s.nonEnglishA += 1 }
            if nonEnglish(c.b.text) { s.nonEnglishB += 1 }
            if c.a.isEmpty { s.emptyA += 1 }
            if c.b.isEmpty { s.emptyB += 1 }
        }
        if !clips.isEmpty {
            s.avgMsA = clips.map(\.a.ms).reduce(0, +) / Double(clips.count)
            s.avgMsB = clips.map(\.b.ms).reduce(0, +) / Double(clips.count)
        }
        return s
    }

    /// Transcribe every clip with `a`, then every clip with `b` (one model resident at a time:
    /// `a` is unloaded before `b` loads). Latency excludes the model load (warm-up call first).
    public static func run(clips: [(name: String, samples: [Float], voiceProcessing: Bool?)],
                           a: Transcriber, b: Transcriber) async -> [Clip] {
        func pass(_ t: Transcriber) async -> [Result] {
            do { try await t.prepare() } catch {
                return clips.map { _ in Result(text: "", ms: 0, error: error.localizedDescription) }
            }
            var out: [Result] = []
            for c in clips {
                let start = ContinuousClock.now
                do {
                    let text = try await t.transcribe(c.samples, vocabularyHints: [])
                    out.append(Result(text: text, ms: durationMs(ContinuousClock.now - start)))
                } catch {
                    out.append(Result(text: "", ms: durationMs(ContinuousClock.now - start), error: error.localizedDescription))
                }
            }
            await t.unload()
            return out
        }
        let ra = await pass(a)
        let rb = await pass(b)
        return clips.indices.map { Clip(name: clips[$0].name, voiceProcessing: clips[$0].voiceProcessing, a: ra[$0], b: rb[$0]) }
    }
}
