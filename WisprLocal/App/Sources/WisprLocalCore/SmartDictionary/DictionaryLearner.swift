import Foundation

/// Learning state beside the dictionary: `<dictionary folder>/learning.json`, owner-only (0600).
/// `{ "schemaVersion": 1, "tombstones": [String], "learned": [String] }`
/// - `tombstones`: lowercased Words the user DELETED, and the heard forms of deleted Replacements
///   (plus their replacement when it is no longer a Word). Never suggested, auto-added or
///   snapped again (`SpellingSnapper` gets them through `DictationPipeline.snapperTombstones`).
/// - `learned`: spellings added by learning (from corrections or History "Fix a Word…"), for the
///   "Words learned: N" stat.
/// It holds only dictionary words, never dictated text.
public final class LearningStore: @unchecked Sendable {
    public struct State: Codable, Sendable, Equatable {
        public var schemaVersion = 1
        public var tombstones: [String] = []
        public var learned: [String] = []
        public init() {}
    }

    public let url: URL
    private let lock = NSLock()
    private var state: State

    public init(url: URL) {
        self.url = url
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State()
    }

    /// `learning.json` next to the dictionary file.
    public convenience init(besideDictionary dictionaryURL: URL) {
        self.init(url: dictionaryURL.deletingLastPathComponent().appendingPathComponent("learning.json"))
    }

    public var snapshot: State { lock.withLock { state } }

    static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func isTombstoned(_ s: String) -> Bool {
        let n = Self.norm(s)
        return lock.withLock { state.tombstones.contains(n) }
    }

    public func tombstone(_ items: [String]) {
        let new = items.map(Self.norm).filter { !$0.isEmpty && !isTombstoned($0) }
        guard !new.isEmpty else { return }
        mutate { s in for n in new where !s.tombstones.contains(n) { s.tombstones.append(n) } }
    }

    /// An explicit "Fix a Word…" overrides an earlier deletion.
    public func lift(_ s: String) {
        let n = Self.norm(s)
        guard isTombstoned(n) else { return }
        mutate { $0.tombstones.removeAll { $0 == n } }
    }

    public func recordLearned(_ term: String) {
        let n = Self.norm(term)
        mutate { s in if !n.isEmpty, !s.learned.contains(n) { s.learned.append(n) } }
    }

    /// Learned spellings still in the dictionary's Words.
    public func learnedCount(in d: UserDictionary) -> Int {
        let vocab = Set(d.vocabulary.map(Self.norm))
        return snapshot.learned.filter(vocab.contains).count
    }

    private func mutate(_ f: (inout State) -> Void) {
        let s: State = lock.withLock { f(&state); return state }
        try? AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? AppPaths.writePrivate(data, to: url) }
    }

    /// Tombstones whatever the user removes from `store` and lifts the tombstone of anything
    /// added back (editing a row briefly removes it). A deleted Word is tombstoned; a deleted
    /// Replacement tombstones its heard form, and its replacement only when that is no longer a
    /// Word (deleting "whisperflow → Wispr Flow" must not block the Word "Wispr Flow", R13).
    public func observeChanges(of store: DictionaryStore) {
        store.onChange = { [weak self, weak store] change in
            guard let self else { return }
            let words = Set((store?.dictionary.vocabulary ?? []).map(Self.norm))
            let removed = change.removedTerms + change.removedRules.flatMap { r in
                words.contains(Self.norm(r.to)) ? [r.from] : [r.from, r.to]
            }
            let added = Set((change.addedTerms + change.addedRules.flatMap { [$0.to, $0.from] }).map(Self.norm))
            self.tombstone(removed.filter { !added.contains(Self.norm($0)) })
            for a in added { self.lift(a) }
        }
    }
}

/// What `DictionaryLearner.consider` decided.
public enum LearnDecision: Sendable, Equatable {
    public enum Reason: String, Sendable { case off, tombstoned, alreadyKnown }
    case ignored(Reason)
    /// Suggest mode: ask with a HUD chip.
    case suggest(Correction)
    /// Automatic mode: already added.
    case added(Correction)
}

public enum LearnError: Error, LocalizedError, Equatable {
    case empty, same, commonWord(String), tooManyWords
    public var errorDescription: String? {
        switch self {
        case .empty: "Type the correct spelling."
        case .same: "That's already how it was written."
        case .commonWord(let w): "“\(w)” is a common word, so changing it everywhere would cause mistakes. Add the spelling under Words instead."
        case .tooManyWords: "Pick up to three words."
        }
    }
}

/// Turns corrections into dictionary entries: a replacement rule (misheard → correct) plus a
/// vocabulary term. Honours the mode (suggest / automatic / off) and the tombstones.
@MainActor public final class DictionaryLearner {
    public let dictionary: DictionaryStore
    public let store: LearningStore
    private let mode: @MainActor () -> LearnMode

    public init(dictionary: DictionaryStore, store: LearningStore, mode: @escaping @MainActor () -> LearnMode) {
        self.dictionary = dictionary; self.store = store; self.mode = mode
        store.observeChanges(of: dictionary)
    }

    public var learnedCount: Int { store.learnedCount(in: dictionary.dictionary) }

    public func consider(_ c: Correction) -> LearnDecision {
        switch mode() {
        case .off: return .ignored(.off)
        case .suggest, .automatic: break
        }
        if store.isTombstoned(c.correct) || store.isTombstoned(c.misheard) { return .ignored(.tombstoned) }
        let d = dictionary.dictionary
        let hasRule = d.replacements.contains { $0.from.caseInsensitiveCompare(c.misheard) == .orderedSame }
        let hasTerm = d.vocabulary.contains { $0 == c.correct }
        if hasRule || (hasTerm && Phonetics.key(c.misheard) == Phonetics.key(c.correct)) { return .ignored(.alreadyKnown) }
        if mode() == .automatic {
            do { try accept(c); return .added(c) } catch { return .ignored(.alreadyKnown) }
        }
        return .suggest(c)
    }

    public func considerAsync(_ c: Correction) async -> LearnDecision {
        guard mode() == .automatic else { return consider(c) }
        if store.isTombstoned(c.correct) || store.isTombstoned(c.misheard) { return .ignored(.tombstoned) }
        let d = dictionary.dictionary
        let hasRule = d.replacements.contains { $0.from.caseInsensitiveCompare(c.misheard) == .orderedSame }
        let hasTerm = d.vocabulary.contains { $0 == c.correct }
        if hasRule || (hasTerm && Phonetics.key(c.misheard) == Phonetics.key(c.correct)) { return .ignored(.alreadyKnown) }
        do { try await acceptAsync(c); return .added(c) } catch { return .ignored(.alreadyKnown) }
    }

    public func acceptAsync(_ c: Correction) async throws {
        try await dictionary.updateAsync { dictionary in
            dictionary.addTerm(c.correct)
            if c.misheard.lowercased() != c.correct.lowercased() { dictionary.addReplacement(from: c.misheard, to: c.correct) }
        }
        store.recordLearned(c.correct)
    }

    /// "Add": the rule (unless misheard and correct differ only in casing/spacing) and the term.
    public func accept(_ c: Correction) throws {
        let old = dictionary.dictionary
        var d = old
        d.addTerm(c.correct)
        if c.misheard.lowercased() != c.correct.lowercased() { d.addReplacement(from: c.misheard, to: c.correct) }
        try dictionary.enqueueEditorChanges(from: old, to: d).wait()
        store.recordLearned(c.correct)
    }

    /// History "Fix a Word…" (the Electron / unreadable-field fallback): an explicit choice, so
    /// tombstones are lifted and the sound-alike check is skipped — but a single common word is
    /// still refused as the misheard form.
    @discardableResult
    public func fixWord(misheard: String, correct: String) throws -> Correction {
        let correction = try prepareFix(misheard: misheard, correct: correct)
        try accept(correction)
        return correction
    }

    @discardableResult
    public func fixWordAsync(misheard: String, correct: String) async throws -> Correction {
        let correction = try prepareFix(misheard: misheard, correct: correct)
        try await acceptAsync(correction)
        return correction
    }

    private func prepareFix(misheard: String, correct: String) throws -> Correction {
        let m = misheard.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = correct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !c.isEmpty else { throw LearnError.empty }
        guard m != c else { throw LearnError.same }
        guard m.split(whereSeparator: \.isWhitespace).count <= CorrectionDetector.maxWords else { throw LearnError.tooManyWords }
        if CommonWords.allCommon(m), m.lowercased() != c.lowercased() { throw LearnError.commonWord(m) }
        store.lift(c); store.lift(m)
        return Correction(misheard: m, correct: c)
    }

}

/// History "Fix a Word…": the words of an inserted dictation to pick from.
public enum FixAWord {
    /// Words with surrounding punctuation stripped (possessive "'s" kept off).
    public static func words(in text: String) -> [String] {
        SpellingSnapper.tokenize(text).map { String($0.core) }.filter { !$0.isEmpty }
    }

    /// The picked words (a contiguous run of 1–3) as one misheard phrase.
    public static func phrase(_ words: [String], selection: ClosedRange<Int>) -> String? {
        guard selection.lowerBound >= 0, selection.upperBound < words.count,
              selection.count <= CorrectionDetector.maxWords else { return nil }
        return words[selection].joined(separator: " ")
    }
}
