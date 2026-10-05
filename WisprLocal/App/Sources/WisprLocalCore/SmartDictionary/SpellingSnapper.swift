import Foundation

/// Snaps transcript words to the spelling of a dictionary term or a context name, using
/// `PhoneticMatcher`. Deterministic and conservative (STRUCTURAL false-positive guards):
///
/// 0. REAL WORDS ARE NEVER REWRITTEN (R2): a single heard word is snapped only when it is NOT a
///    valid English word per the offline system lexicon (`EnglishLexicon`, asked in lowercase),
///    and never when it is a weekday, month or number word (`ClosedClassWords`). "the cloud"
///    stays, "claud"… also stays (the lexicon knows it); "kubernetties" snaps. That includes
///    case-only fixes: "some slack" never becomes "some Slack", "kubernetes" → "Kubernetes" is
///    fine because "kubernetes" is not an English word. A phrase snaps fuzzily only when at
///    least one of its words is not an English word ("post gress" → "Postgres"; "pie torch"
///    stays); a phrase whose JOINED form is exactly a term ("tail scale" → "Tailscale",
///    "get user by id" → `getUserById`) always may.
/// 1. A single COMMON word ("their", "mark", "new") is never rewritten (`CommonWords`).
/// 2. A window of only common words ("get user by id", "tail scale") snaps only on an EXACT
///    joined-key match, and only to a dictionary term or (in a code app) an identifier — never
///    to a context name ("new man" never becomes "Newman").
/// 3. Exactly ONE distinct candidate must match a window; two or more → no change.
/// 4. Identifiers (CamelCase, snake_case) snap only in code apps, and only on an exact key.
/// 5. @handles snap only after a spoken "at", on an exact key ("at sam lee" → "@sam_lee").
/// 6. Context candidates that are themselves common words are never offered.
/// 7. Text already spelled like a candidate is left alone (and its words aren't re-matched).
/// 8. Tombstones (`learning.json`): a deleted term is never offered, and a heard form the user
///    deleted a rule for ("cloud" after deleting cloud → Claude) is never snapped.
///
/// Matching is indexed (P2): candidates are bucketed by exact key and by loose phonetic code
/// (a strong match REQUIRES identical loose codes), so each window costs one or two hash
/// lookups instead of a scan of every candidate.
public struct SpellingSnapper: Sendable {
    public struct Result: Sendable, Equatable {
        public var text: String
        public var vocabularySnaps: Int
        public var contextSnaps: Int
    }

    struct Candidate: Sendable {
        var surface: String
        var key: String
        var loose: String
        var fromContext: Bool
        var kind: ContextCandidate.Kind
    }

    /// FNV-1a over bytes: the index is keyed by hashes so a window that matches nothing costs no
    /// string at all. Every bucket hit is re-checked against the real key / loose code.
    static let fnvSeed: UInt64 = 0xcbf2_9ce4_8422_2325
    @inline(__always) static func fnv(_ h: UInt64, _ b: UInt8) -> UInt64 { (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
    static func fnv(_ bytes: [UInt8]) -> UInt64 {
        var h = fnvSeed
        for b in bytes { h = fnv(h, b) }
        return h
    }
    static func fnv(_ s: String) -> UInt64 { fnv(Array(s.utf8)) }

    /// Longest window tried (identifiers like "get user by id"); fuzzy matching stops at 3.
    static let maxWindow = 4
    static let maxFuzzyWindow = 3

    private final class Base: Sendable {
        let value: SpellingSnapper
        init(_ value: SpellingSnapper) { self.value = value }
    }
    private var base: Base? = nil
    private let candidates: [Candidate]
    private let surfaces: Set<String>
    private let byKey: [UInt64: [Int]]
    private let byLoose: [UInt64: [Int]]
    private let tombstoneKeys: Set<String>
    private let lexicon: EnglishLexicon

    /// `tombstones`: lowercased forms the user deleted (`LearningStore`); `lexicon`: the real-word
    /// guard (the offline system spell checker by default).
    public init(vocabulary: [String], context: ContextSnapshot? = nil, tombstones: Set<String> = [],
                lexicon: EnglishLexicon = SystemEnglishLexicon.shared) {
        let dead = Set(tombstones.map { Phonetics.key($0) }.filter { !$0.isEmpty })
        var out: [Candidate] = []
        var seen = Set<String>()
        func add(_ surface: String, key: String, fromContext: Bool, kind: ContextCandidate.Kind) {
            out.append(Candidate(surface: surface, key: key, loose: Phonetics.looseCode(key), fromContext: fromContext, kind: kind))
        }
        for term in vocabulary {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = Phonetics.key(t)
            guard !k.isEmpty, !dead.contains(k), seen.insert(t.lowercased()).inserted else { continue }
            add(t, key: k, fromContext: false, kind: .name)
        }
        if let context {
            for c in context.candidates {
                if c.kind == .identifier && !context.isCodeApp { continue }
                let body = c.kind == .handle ? String(c.surface.dropFirst()) : c.surface
                let k = Phonetics.key(body)
                guard !k.isEmpty, !dead.contains(k), !(c.kind == .name && CommonWords.contains(body)),
                      seen.insert(c.surface.lowercased()).inserted else { continue }
                add(c.surface, key: k, fromContext: true, kind: c.kind)
            }
        }
        candidates = out
        surfaces = Set(out.map { $0.surface.lowercased() })
        var byKey: [UInt64: [Int]] = [:], byLoose: [UInt64: [Int]] = [:]
        for (i, c) in out.enumerated() {
            byKey[Self.fnv(c.key), default: []].append(i)
            if c.kind != .identifier, c.kind != .handle, c.loose.count >= 2 { byLoose[Self.fnv(c.loose), default: []].append(i) }
        }
        self.byKey = byKey
        self.byLoose = byLoose
        tombstoneKeys = dead
        self.lexicon = lexicon
    }

    /// Reuse the vocabulary's immutable arrays and hash tables; only cursor names form an
    /// overlay. Pool indices address the base first, then the small context overlay.
    init(vocabularyIndex: SpellingSnapper, context: ContextSnapshot?, tombstones: Set<String>) {
        var context = context
        context?.candidates.removeAll { vocabularyIndex.surfaces.contains($0.surface.lowercased()) }
        self.init(vocabulary: [], context: context, tombstones: tombstones, lexicon: vocabularyIndex.lexicon)
        base = Base(vocabularyIndex)
    }

    private var baseCount: Int { base?.value.candidates.count ?? 0 }
    private func candidate(_ i: Int) -> Candidate {
        if let base, i < baseCount { return base.value.candidates[i] }
        return candidates[i - baseCount]
    }
    private func pool(_ hash: UInt64, loose: Bool = false) -> [Int]? {
        let local = (loose ? byLoose[hash] : byKey[hash]) ?? []
        let inherited = base.flatMap { loose ? $0.value.byLoose[hash] : $0.value.byKey[hash] } ?? []
        let result = (inherited + local.map { $0 + baseCount }).filter { !tombstoneKeys.contains(candidate($0).key) }
        return result.isEmpty ? nil : result
    }

    public var isEmpty: Bool { candidates.isEmpty && (base?.value.isEmpty ?? true) }

    struct Token {
        var range: Range<String.Index>
        var lead: Substring
        var core: Substring
        var trail: Substring
        var hasInnerPunct: Bool { !lead.isEmpty || !trail.isEmpty }
    }

    static func tokenize(_ text: String) -> [Token] {
        var out: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            let word = text[i..<j]
            let coreStart = word.firstIndex(where: { $0.isLetter || $0.isNumber }) ?? word.endIndex
            var coreEnd = word.lastIndex(where: { $0.isLetter || $0.isNumber }).map { word.index(after: $0) } ?? coreStart
            if coreEnd < coreStart { coreEnd = coreStart }
            var core = word[coreStart..<coreEnd]
            // Possessive stays outside the snapped core: "Sean's" → core "Sean", trail "'s".
            for suffix in ["'s", "\u{2019}s"] where core.count > 2 && core.hasSuffix(suffix) {
                coreEnd = word.index(coreEnd, offsetBy: -2)
                core = word[coreStart..<coreEnd]
            }
            out.append(Token(range: i..<j, lead: word[word.startIndex..<coreStart], core: core, trail: word[coreEnd..<word.endIndex]))
            i = j
        }
        return out
    }

    public func apply(_ text: String) -> Result {
        var result = Result(text: text, vocabularySnaps: 0, contextSnaps: 0)
        guard !isEmpty else { return result }
        let tokens = Self.tokenize(text)
        // Per-token work done once (not once per window): core, key bytes, common, has a digit.
        let cores = tokens.map { String($0.core) }
        let keys = cores.map(Phonetics.key)
        let keyBytes = keys.map { Array($0.utf8) }
        let common = keys.map { CommonWords.set.contains($0) }
        let numeric = cores.map { $0.contains(where: \.isNumber) }
        var edits: [(Range<String.Index>, String)] = []
        // Reused buffers: window hashes, the window's letters (uppercase) and its phonetic code.
        var hashes: [UInt64] = [], bodyHashes: [UInt64] = [], lengths: [Int] = []
        var letters: [UInt8] = [], code: [UInt8] = []
        var i = 0
        outer: while i < tokens.count {
            // Valid windows at i (they nest: once one breaks, every longer one does), hashed
            // incrementally; `bodyHashes` skip the first word (handles: "at <body>").
            hashes.removeAll(keepingCapacity: true); bodyHashes.removeAll(keepingCapacity: true)
            lengths.removeAll(keepingCapacity: true)
            var h = Self.fnvSeed, bh = Self.fnvSeed, len = 0
            for size in 1...min(Self.maxWindow, tokens.count - i) {
                let j = i + size - 1
                guard !cores[j].isEmpty else { break }
                // Inner punctuation breaks a phrase ("kuber, netties" is two things).
                if size > 1, !tokens[j].lead.isEmpty || !tokens[j - 1].trail.isEmpty { break }
                for b in keyBytes[j] { h = Self.fnv(h, b); if size > 1 { bh = Self.fnv(bh, b) } }
                len += keyBytes[j].count
                hashes.append(h); bodyHashes.append(bh); lengths.append(len)
            }
            // Already spelled like a candidate: leave it (and its words) alone (guard 7).
            for size in stride(from: hashes.count, through: 1, by: -1) {
                guard let same = pool(hashes[size - 1]) else { continue }
                let phrase = cores[i..<(i + size)].joined(separator: " ")
                if same.contains(where: { candidate($0).surface == phrase }) { i += size; continue outer }
            }
            // Smallest window first, so a match never swallows a neighbouring word
            // ("kubernetties is" must not become "Kubernetes").
            letters.removeAll(keepingCapacity: true)
            for n in hashes.indices {
                let r = i..<(i + n + 1)
                for b in keyBytes[i + n] where b >= 97 { letters.append(b - 32) }       // letters only, uppercase
                let allCommon = r.allSatisfy { common[$0] }
                if n == 0, allCommon { continue }                                          // guard 1
                if r.contains(where: { numeric[$0] }) { continue }
                var exactPool = pool(hashes[n]) ?? []
                var loosePool: [Int] = []
                // Fuzzy only from a window of ≤ 3 words with some uncommon word (guard 2).
                if !allCommon, n < Self.maxFuzzyWindow, lengths[n] >= PhoneticMatcher.minKeyLength {
                    Phonetics.codeBytes(letters, into: &code)
                    Phonetics.loosen(&code)
                    if code.count >= 2, let bucket = pool(Self.fnv(code), loose: true) {
                        loosePool = bucket.filter { candidate($0).loose.utf8.elementsEqual(code) }
                    }
                }
                var handlePool: [Int] = []
                if n > 0, keys[i] == "at", let bucket = pool(bodyHashes[n]) {
                    let body = keys[(i + 1)...(i + n)].joined()
                    handlePool = bucket.filter { candidate($0).kind == .handle && candidate($0).key == body }
                }
                guard !exactPool.isEmpty || !loosePool.isEmpty || !handlePool.isEmpty else { continue }
                let key = keys[r].joined()
                if tombstoneKeys.contains(key) { continue }                                // guard 8
                exactPool.removeAll { candidate($0).key != key }
                guard let match = resolve(words: cores[r], key: key, allCommon: allCommon, exact: exactPool,
                                          loose: loosePool, handles: handlePool) else { continue }
                let last = i + n
                let replacement = String(tokens[i].lead) + match.surface + String(tokens[last].trail)
                edits.append((tokens[i].range.lowerBound..<tokens[last].range.upperBound, replacement))
                if match.fromContext { result.contextSnaps += 1 } else { result.vocabularySnaps += 1 }
                i = last + 1
                continue outer
            }
            i += 1
        }
        guard !edits.isEmpty else { return result }
        var out = text
        for (range, replacement) in edits.reversed() { out.replaceSubrange(range, with: replacement) }
        result.text = out
        return result
    }

    /// The single candidate this window may become, or nil (none, ambiguous, or a real word).
    /// `exact`: candidates whose key IS the window key; `loose`: same loose phonetic code (a
    /// strong match requires it); `handles`: "at <body>" with an exact body key.
    func resolve(words: ArraySlice<String>, key: String, allCommon: Bool, exact: [Int], loose: [Int], handles: [Int]) -> Candidate? {
        let size = words.count
        var hits: [Candidate] = handles.map { candidate($0) }
        var exactHit = !hits.isEmpty
        for i in (exact + loose.filter { !exact.contains($0) }).sorted() {
            let c = candidate(i)
            guard c.kind != .handle else { continue }
            let isExact = c.key == key
            switch c.kind {
            case .identifier:
                guard isExact, size >= 2 else { continue }                                   // guard 4
            case .name, .handle:
                if allCommon && (c.fromContext || !isExact) { continue }                     // guard 2
                if !isExact {
                    guard size <= Self.maxFuzzyWindow, !c.key.contains(where: \.isNumber),
                          PhoneticMatcher.isStrongMatch(heardKey: key, candidateKey: c.key, candidateLoose: c.loose) else { continue }
                }
            }
            if isExact { exactHit = true }
            hits.append(c)
        }
        guard let hit = hits.first, hits.allSatisfy({ $0.surface == hit.surface }) else { return nil }   // guard 3
        if words.joined(separator: " ") == hit.surface { return nil }
        return realWordGuardAllows(words: Array(words), exact: exactHit) ? hit : nil      // guard 0
    }

    /// Guard 0 (R2): may these heard words be rewritten at all?
    func realWordGuardAllows(words: [String], exact: Bool) -> Bool {
        let lower = words.map { $0.lowercased() }
        if lower.contains(where: ClosedClassWords.contains) { return false }
        if lower.count == 1 { return !lexicon.isWord(lower[0]) }
        // A phrase whose joined form IS the term ("tail scale" → "Tailscale"): always allowed.
        if exact { return true }
        // A fuzzy phrase: at least one of its words must not be an English word.
        return lower.contains { !lexicon.isWord($0) }
    }
}
