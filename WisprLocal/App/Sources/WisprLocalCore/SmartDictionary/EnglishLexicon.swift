import AppKit
import Foundation

/// "Is this a real English word?" — the guard that keeps the smart dictionary from rewriting
/// correct words (R2: "the cloud" must never become "the Claude") and from learning a change of
/// mind as a mishearing (R8). Injected so tests can use a fixed word list.
///
/// Callers pass the word LOWERCASED: the macOS lexicon accepts capitalised proper names ("Sean")
/// but flags them in lowercase ("sean"), while ordinary words ("cloud", "slack") pass either way.
/// So "valid lowercase" means "an ordinary English word", which is exactly what must be protected.
public protocol EnglishLexicon: Sendable {
    func isWord(_ lowercased: String) -> Bool
}

/// The macOS system spell checker (`NSSpellChecker`, English). Fully local: the AppleSpell
/// service on this Mac, no network (`scripts/test_offline.sh` runs `SystemLexiconTests` with all
/// network denied). Calls are serialised behind a lock and cached per word (~0.25 ms per new
/// word); the snapper asks only about words that already matched a candidate.
///
/// Fail-safe: if the checker cannot be reached or does not answer like an English lexicon
/// (sanity probe at first use), EVERY word counts as valid — nothing is snapped or learned.
public final class SystemEnglishLexicon: EnglishLexicon, @unchecked Sendable {
    public static let shared = SystemEnglishLexicon()

    private let lock = NSLock()
    private var cache: [String: Bool] = [:]
    private var available: Bool?
    static let maxCache = 20_000

    public init() {}

    public func isWord(_ lowercased: String) -> Bool {
        let w = lowercased
        guard !w.isEmpty else { return true }
        return lock.withLock {
            if available == nil {
                // Probe: a real word passes and gibberish fails, or the lexicon is unusable.
                available = Self.check("the") && !Self.check("qzxvbkjw")
            }
            guard available == true else { return true }
            if let hit = cache[w] { return hit }
            let ok = Self.check(w)
            if cache.count >= Self.maxCache { cache.removeAll(keepingCapacity: true) }
            cache[w] = ok
            return ok
        }
    }

    /// True when the whole string has no misspelling according to the English checker.
    private static func check(_ w: String) -> Bool {
        let r = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                    inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }
}

/// Closed classes the lexicon doesn't protect (it treats lowercase weekday and month names as
/// misspelled proper nouns) and that are never a mishearing to learn or snap: "Tuesday" →
/// "Thursday" is a change of mind; "fifteen" → "fifty" too.
public enum ClosedClassWords {
    public static func contains(_ word: String) -> Bool { set.contains(Phonetics.key(word)) }

    static let set: Set<String> = Set("""
    monday tuesday wednesday thursday friday saturday sunday mon tue tues wed thu thur thurs fri sat sun \
    january february march april may june july august september october november december \
    jan feb mar apr jun jul aug sep sept oct nov dec \
    zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen \
    seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million \
    billion first second third fourth fifth sixth seventh eighth ninth tenth yes no yeah nope
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
}
