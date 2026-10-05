import Foundation

/// The user re-spelled something WisprLocal typed: `misheard` (what we inserted) → `correct`.
/// In memory only until the user accepts it (or "Add automatically" is on).
public struct Correction: Sendable, Equatable, Hashable {
    public var misheard: String
    public var correct: String
    public init(misheard: String, correct: String) { self.misheard = misheard; self.correct = correct }
}

/// Pure diff: did the user replace one inserted word (or a 2–3 word phrase) with a different
/// spelling? Everything else — edits outside the inserted text, appended text, unrelated
/// rewrites, common-word swaps ("their" → "there") — is NOT a correction.
public enum CorrectionDetector {
    public static let maxWords = 3
    /// Looser than snapping: the user typed this on purpose, but it must still sound alike.
    public static let maxNormalisedDistance = 0.6

    /// `before` = the field right after our paste (contains `inserted`), `after` = the field now.
    public static func detect(inserted: String, before: String, after: String,
                              lexicon: EnglishLexicon = SystemEnglishLexicon.shared) -> Correction? {
        let ins = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ins.isEmpty, let span = before.range(of: ins, options: .backwards) else { return nil }
        let lo = before.distance(from: before.startIndex, to: span.lowerBound)
        let hi = before.distance(from: before.startIndex, to: span.upperBound)
        return detect(spanOffsets: lo..<hi, before: before, after: after, lexicon: lexicon)
    }

    /// Same, with the inserted span given as character offsets into `before`.
    public static func detect(spanOffsets span: Range<Int>, before: String, after: String,
                              lexicon: EnglishLexicon = SystemEnglishLexicon.shared) -> Correction? {
        guard before != after else { return nil }
        let b = Array(before), a = Array(after)
        guard span.lowerBound >= 0, span.upperBound <= b.count else { return nil }
        var p = 0
        while p < b.count, p < a.count, b[p] == a[p] { p += 1 }
        var s = 0
        while s < b.count - p, s < a.count - p, b[b.count - 1 - s] == a[a.count - 1 - s] { s += 1 }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" || c == "-" || c == "_" }
        // Grow the changed region to whole words (the shared prefix/suffix is identical in both).
        while p > 0, isWord(b[p - 1]) { p -= 1 }
        while s > 0, isWord(b[b.count - s]) { s -= 1 }
        let oldRange = p..<(b.count - s), newRange = p..<(a.count - s)
        // The edit must sit entirely inside what we inserted.
        guard oldRange.lowerBound >= span.lowerBound, oldRange.upperBound <= span.upperBound else { return nil }
        let oldText = String(b[oldRange]), newText = String(a[newRange])
        return judge(old: oldText, new: newText, lexicon: lexicon)
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    /// The safeguards, in one place (`CorrectionDetectionTests`).
    static func judge(old: String, new: String, lexicon: EnglishLexicon = SystemEnglishLexicon.shared) -> Correction? {
        let ow = words(old), nw = words(new)
        guard (1...maxWords).contains(ow.count), (1...maxWords).contains(nw.count) else { return nil }
        let misheard = ow.joined(separator: " "), correct = nw.joined(separator: " ")
        guard misheard != correct else { return nil }
        let mk = Phonetics.key(misheard), ck = Phonetics.key(correct)
        guard mk.count >= 3, ck.count >= 3 else { return nil }
        // Appending or trimming ("test" → "tests", "test" → "test and more") is editing, not a fix.
        let ol = misheard.lowercased(), nl = correct.lowercased()
        if mk != ck, nl.hasPrefix(ol) || nl.hasSuffix(ol) || ol.hasPrefix(nl) || ol.hasSuffix(nl) { return nil }
        // Never learn to rewrite common words ("their" → "there", "new man" → "Newman").
        if CommonWords.allCommon(misheard) { return nil }
        // The correct form must be worth keeping: not itself a plain common word.
        if nw.count == 1, CommonWords.contains(correct), correct == correct.lowercased() { return nil }
        guard isPlausible(misheardKey: mk, correctKey: ck) else { return nil }
        guard isMishearing(ow, misheardKey: mk, correctKey: ck, lexicon: lexicon) else { return nil }
        return Correction(misheard: misheard, correct: correct)
    }

    /// R8 — a change of mind is not a mishearing ("Tuesday" → "Thursday", "fifteen" → "fifty"
    /// sound alike but were never misheard). On top of sounding alike (`isPlausible`):
    /// - no weekday, month or number word on the misheard side (`ClosedClassWords`);
    /// - one word: it must NOT be an English word (offline lexicon, asked in lowercase);
    /// - a phrase: some word in it is not an English word, or its joined form is close to the
    ///   replacement ("pie torch" → "PyTorch", "whisker flow" → "Wispr Flow").
    static let maxPhraseDistance = 0.34

    static func isMishearing(_ words: [String], misheardKey mk: String, correctKey ck: String, lexicon: EnglishLexicon) -> Bool {
        let lower = words.map { $0.lowercased() }
        if lower.contains(where: ClosedClassWords.contains) { return false }
        if lower.count == 1 { return !lexicon.isWord(lower[0]) }
        if lower.contains(where: { !lexicon.isWord($0) }) { return true }
        return Phonetics.normalisedDistance(mk.lowercased(), ck.lowercased()) <= maxPhraseDistance
    }

    /// Sounds alike AND is spelled reasonably close (an unrelated rewrite fails one or both).
    public static func isPlausible(misheardKey mk: String, correctKey ck: String) -> Bool {
        if mk == ck { return true }   // casing / spacing only ("kubernetes" → "Kubernetes", "tail scale" → "Tailscale")
        let ratio = Double(min(mk.count, ck.count)) / Double(max(mk.count, ck.count))
        guard ratio >= 0.5 else { return false }
        let mc = Phonetics.looseCode(mk), cc = Phonetics.looseCode(ck)
        guard !mc.isEmpty, !cc.isEmpty, mc.first == cc.first else { return false }
        let codeDistance = Phonetics.normalisedDistance(mc, cc)
        return codeDistance <= 0.34 && Phonetics.normalisedDistance(mk, ck) <= maxNormalisedDistance
    }
}

/// What the watcher sees of the focused field: a bounded WINDOW around what we pasted, never the
/// whole field (S1). It stays in memory for ≤ 15 s; only the diff result (`Correction`) leaves.
public struct FieldSnapshot: Sendable, Equatable {
    public var elementID: Int?
    /// The text of the window that was read (the whole field only when it is that short).
    public var text: String
    public var isSecure: Bool
    /// An address / URL bar: never watched (the same rule as context names).
    public var isExcluded: Bool
    public var selectionLength: Int
    /// UTF-16 offset of `text` in the field, and the field's length (nil: unknown, e.g. fakes).
    public var windowLocation: Int
    public var totalLength: Int?
    public init(elementID: Int?, text: String, isSecure: Bool = false, selectionLength: Int = 0,
                isExcluded: Bool = false, windowLocation: Int = 0, totalLength: Int? = nil) {
        self.elementID = elementID; self.text = text; self.isSecure = isSecure; self.selectionLength = selectionLength
        self.isExcluded = isExcluded; self.windowLocation = windowLocation; self.totalLength = totalLength
    }
}

/// Which part of the focused field the watcher reads (UTF-16 offsets, as AX uses).
public enum FieldWindow: Sendable, Equatable {
    /// First read, right after the paste (the caret sits at its end): `before` characters
    /// before the caret and `after` after it.
    case aroundCaret(before: Int, after: Int)
    /// Later reads: the same start; the length follows the field's growth since `baseTotal`.
    case tracking(location: Int, length: Int, baseTotal: Int)
}

/// One watch after one paste, as a pure state machine (`CorrectionWatcher` drives it with AX
/// reads every second, off the main actor). Stops on: focus change, a secure or URL field, a
/// huge window/selection, the inserted text not being found, the user undoing the paste (R9),
/// 15 s, or the first stable correction. When it stops it drops everything it read.
public struct CorrectionWatchSession: Sendable {
    public enum Step: Sendable, Equatable { case keepWatching, stop, found(Correction) }

    public static let maxDuration: TimeInterval = 15
    public static let pollInterval: Duration = .seconds(1)
    /// Characters read on each side of the inserted text (S1).
    public static let margin = 200
    /// Windows (or selections) larger than this are never diffed.
    public static let maxChars = 20_000
    /// The same correction must be seen this many polls in a row (≈ 2 s): mid-typing states
    /// ("Kubern…") don't count.
    public static let stablePolls = 3

    public let inserted: String
    public let elementID: Int?
    /// What the paste replaced (the selection; "" = none; nil = unknown).
    public let replaced: String?
    private let lexicon: EnglishLexicon
    private var baseline: String?
    private var baseLocation = 0
    private var baseTotal: Int?
    private var span: Range<Int>?
    private var reverted: String?
    private var last: Correction?
    private var seen = 0
    public private(set) var finished = false

    public init(inserted: String, elementID: Int?, replaced: String? = nil,
                lexicon: EnglishLexicon = SystemEnglishLexicon.shared) {
        self.inserted = inserted; self.elementID = elementID; self.replaced = replaced; self.lexicon = lexicon
    }

    /// The window the next read must cover.
    public var window: FieldWindow {
        guard let baseline else {
            return .aroundCaret(before: inserted.utf16.count + Self.margin, after: Self.margin)
        }
        let length = baseline.utf16.count
        return .tracking(location: baseLocation, length: length, baseTotal: baseTotal ?? length)
    }

    public mutating func observe(_ snap: FieldSnapshot?, elapsed: TimeInterval) -> Step {
        guard !finished else { return .stop }
        guard elapsed <= Self.maxDuration, let snap, !snap.isSecure, !snap.isExcluded else { return stop() }
        if let elementID, snap.elementID != elementID { return stop() }                        // focus moved
        guard snap.text.count <= Self.maxChars, snap.selectionLength <= Self.maxChars else { return stop() }
        // An address bar the reader couldn't label: a lone URL is never watched.
        if ContextPolicy.isURLField(identifier: nil, description: nil, value: snap.text) { return stop() }
        guard let baseline else {
            let ins = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ins.isEmpty, let r = snap.text.range(of: ins, options: .backwards) else { return stop() }
            self.baseline = snap.text
            baseLocation = snap.windowLocation
            baseTotal = snap.totalLength
            let lo = snap.text.distance(from: snap.text.startIndex, to: r.lowerBound)
            span = lo..<(lo + snap.text.distance(from: r.lowerBound, to: r.upperBound))
            if let replaced {
                reverted = Self.normalised(String(snap.text[..<r.lowerBound]) + replaced + String(snap.text[r.upperBound...]))
            }
            return .keepWatching
        }
        // R9: the user undid the paste (⌘Z after select-and-dictate): the field holds what was
        // there before. That is not a correction, and nothing after it is ours to learn from.
        if let reverted, Self.normalised(snap.text) == reverted { return stop() }
        guard let span, let c = CorrectionDetector.detect(spanOffsets: span, before: baseline, after: snap.text, lexicon: lexicon) else {
            last = nil; seen = 0
            return .keepWatching
        }
        if c == last { seen += 1 } else { last = c; seen = 1 }
        if seen >= Self.stablePolls { _ = stop(); return .found(c) }
        return .keepWatching
    }

    /// Ends the watch and forgets every bit of field text it held.
    private mutating func stop() -> Step {
        finished = true
        baseline = nil; reverted = nil; span = nil; last = nil
        return .stop
    }

    /// Whitespace runs collapsed and trimmed: an undo may restore a space the join added.
    static func normalised(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
