import Foundation

public struct ReplacementRule: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var from: String
    public var to: String
    public var caseInsensitive: Bool
    public var wholeWord: Bool

    public init(id: UUID = UUID(), from: String, to: String, caseInsensitive: Bool = true, wholeWord: Bool = true) {
        self.id = id; self.from = from; self.to = to
        self.caseInsensitive = caseInsensitive; self.wholeWord = wholeWord
    }

    enum CodingKeys: String, CodingKey { case from, to, caseInsensitive, wholeWord }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? true
        wholeWord = try c.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from); try c.encode(to, forKey: .to)
        try c.encode(caseInsensitive, forKey: .caseInsensitive); try c.encode(wholeWord, forKey: .wholeWord)
    }
}

/// Spoken trigger → expansion (multiline allowed). Fires only when the WHOLE utterance equals
/// the trigger (or "insert <trigger>"), case- and punctuation-insensitive — never mid-sentence.
public struct Snippet: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id; self.trigger = trigger; self.expansion = expansion
    }

    enum CodingKeys: String, CodingKey { case trigger, expansion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        trigger = try c.decode(String.self, forKey: .trigger)
        expansion = try c.decode(String.self, forKey: .expansion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trigger, forKey: .trigger); try c.encode(expansion, forKey: .expansion)
    }
}

/// On-disk format (versioned):
/// `{ "schemaVersion": 2, "vocabulary": [String], "replacements": [{from,to,caseInsensitive,wholeWord}],
///    "snippets": [{trigger, expansion}] }`.
/// Version 1 = the P1 file without `schemaVersion`/`snippets` (migrated on read, rewritten as v2 on
/// the next save). A file with a NEWER version than this build understands fails to decode
/// (`DictionaryError.unsupportedVersion`) so the store never overwrites it.
public struct UserDictionary: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var vocabulary: [String]
    public var replacements: [ReplacementRule]
    public var snippets: [Snippet]

    public init(vocabulary: [String] = [], replacements: [ReplacementRule] = [], snippets: [Snippet] = []) {
        self.vocabulary = vocabulary; self.replacements = replacements; self.snippets = snippets
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, vocabulary, replacements, snippets }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= Self.currentSchemaVersion else { throw DictionaryError.unsupportedVersion(version) }
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        replacements = try c.decodeIfPresent([ReplacementRule].self, forKey: .replacements) ?? []
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(vocabulary, forKey: .vocabulary)
        try c.encode(replacements, forKey: .replacements)
        try c.encode(snippets, forKey: .snippets)
    }

    /// Adds a vocabulary term (trimmed, case-insensitive dedupe). Returns false if not added.
    @discardableResult
    public mutating func addTerm(_ term: String) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !vocabulary.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return false }
        vocabulary.append(t); return true
    }

    /// Adds a replacement rule unless one with the same `from` exists (case-insensitive).
    @discardableResult
    public mutating func addReplacement(from: String, to: String) -> Bool {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines), t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty, f != t,
              !replacements.contains(where: { $0.from.caseInsensitiveCompare(f) == .orderedSame }) else { return false }
        replacements.append(ReplacementRule(from: f, to: t)); return true
    }

    public static let seed = UserDictionary(
        vocabulary: ["Wispr Flow", "Tailscale"],
        replacements: [
            ReplacementRule(from: "whisperflow", to: "Wispr Flow"),
            ReplacementRule(from: "whisper flow", to: "Wispr Flow"),
            ReplacementRule(from: "wisper flow", to: "Wispr Flow"),
            // Observed Parakeet Ultra output for "Wispr Flow" in the 2026-10-02 benchmark.
            ReplacementRule(from: "whiskerflow", to: "Wispr Flow"),
            ReplacementRule(from: "whisker flow", to: "Wispr Flow"),
            ReplacementRule(from: "tail scale", to: "Tailscale"),
        ])

    /// Apply replacement rules in order (compiles; prefer `CompiledDictionary` for repeated use).
    public func apply(to text: String) -> String { CompiledDictionary(self).apply(to: text) }
}

/// Replacement rules with their regexes compiled once. Whole-word matching uses letter/digit
/// boundaries, and a space in `from` matches any run of whitespace ("whisper  flow").
public struct CompiledDictionary: @unchecked Sendable {
    private let rules: [(NSRegularExpression, String)]

    public init(_ d: UserDictionary) { self.init(d, compiler: ReplacementCompiler()) }

    init(_ d: UserDictionary, compiler: ReplacementCompiler) {
        rules = d.replacements.compactMap { compiler.compile($0) }
    }

    public var ruleCount: Int { rules.count }

    public func apply(to text: String) -> String {
        var t = text
        for (re, template) in rules {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
        }
        return t
    }
}

/// Cache identity is rule content, so replacing an editor row's UUID doesn't compile again.
final class ReplacementCompiler: @unchecked Sendable {
    struct Key: Hashable { var from: String; var to: String; var insensitive: Bool; var whole: Bool }
    private let lock = NSLock()
    private var cache: [Key: (NSRegularExpression, String)] = [:]
    private var count = 0
    private var compiledOnMain = false
    var compilations: Int { lock.withLock { count } }
    var lastCompilationOnMainThread: Bool { lock.withLock { compiledOnMain } }

    func compile(_ rule: ReplacementRule) -> (NSRegularExpression, String)? {
        lock.withLock {
            let key = Key(from: rule.from, to: rule.to, insensitive: rule.caseInsensitive, whole: rule.wholeWord)
            if let cached = cache[key] { return cached }
            let words = rule.from.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { return nil }
            var pattern = words.joined(separator: "\\s+")
            if rule.wholeWord { pattern = "(?<![\\p{L}\\p{N}])" + pattern + "(?![\\p{L}\\p{N}])" }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: rule.caseInsensitive ? [.caseInsensitive] : []) else { return nil }
            let value = (regex, NSRegularExpression.escapedTemplate(for: rule.to))
            // Bound retained editor versions, while keeping a large unchanged dictionary hot.
            if cache.count >= 8_192 { cache = [:] }
            cache[key] = value; count += 1; compiledOnMain = Thread.isMainThread
            return value
        }
    }
}

/// Loads/saves the user dictionary JSON. Path is configurable (later: iCloud Drive for sync).
public final class DictionaryStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cached: UserDictionary
    private var compiled: CompiledDictionary
    private let compiler = ReplacementCompiler()
    private let updates = DispatchQueue(label: "wisprlocal.dictionary.compile")
    private var vocabularyIndex = SpellingSnapper(vocabulary: [])
    private var snippetIndex: [String: (position: Int, snippet: Snippet)] = [:]
    private var dictionaryRevision = 0
    public var revision: Int { lock.withLock { dictionaryRevision } }
    var compilationCount: Int { compiler.compilations }
    var lastCompilationOnMainThread: Bool { compiler.lastCompilationOnMainThread }

    /// Loads `url`; if missing, writes the seed dictionary there.
    public init(url: URL = AppPaths.defaultDictionaryURL) {
        self.url = url
        compiled = CompiledDictionary(.seed, compiler: compiler)
        if let d = Self.read(url) {
            cached = d
        } else if FileManager.default.fileExists(atPath: url.path) {
            // Present but unreadable: never overwrite the user's file; run with the seed in memory.
            cached = .seed
            if case DictionaryError.unsupportedVersion(let v)? = (Result { try Self.readThrowing(url) }.failureError) {
                loadError = "\(url.lastPathComponent) uses schema v\(v), newer than this build (v\(UserDictionary.currentSchemaVersion)); using built-in defaults (file left untouched)."
            } else {
                loadError = "Could not parse \(url.path); using built-in defaults (file left untouched)."
            }
            readOnly = true
        } else {
            cached = .seed
            try? Self.write(.seed, to: url)
        }
        compiled = CompiledDictionary(cached, compiler: compiler)
        vocabularyIndex = SpellingSnapper(vocabulary: cached.vocabulary)
        snippetIndex = Self.indexSnippets(cached.snippets)
    }

    public private(set) var loadError: String?
    /// True when the on-disk file couldn't be read: saving would destroy it, so `update` refuses.
    public private(set) var readOnly = false

    public var dictionary: UserDictionary { lock.withLock { cached } }

    public func update(_ d: UserDictionary) throws {
        if readOnly { throw DictionaryError.readOnly(loadError ?? url.path) }
        try Self.write(d, to: url)
        let c = CompiledDictionary(d, compiler: compiler)
        let vocabulary = SpellingSnapper(vocabulary: d.vocabulary)
        let snippets = Self.indexSnippets(d.snippets)
        let old = lock.withLock { () -> UserDictionary in
            let old = cached; cached = d; compiled = c; vocabularyIndex = vocabulary
            snippetIndex = snippets; dictionaryRevision &+= 1
            return old
        }
        let change = DictionaryChange(old: old, new: d)
        if !change.isEmpty { onChange?(change) }
    }

    /// Smart dictionary: told what each `update` removed and added (learning tombstones).
    public var onChange: (@Sendable (DictionaryChange) -> Void)? {
        get { lock.withLock { changeObserver } }
        set { lock.withLock { changeObserver = newValue } }
    }
    private var changeObserver: (@Sendable (DictionaryChange) -> Void)?

    public func reload() {
        if let d = Self.read(url) {
            let c = CompiledDictionary(d, compiler: compiler)
            let vocabulary = SpellingSnapper(vocabulary: d.vocabulary), snippets = Self.indexSnippets(d.snippets)
            lock.withLock {
                cached = d; compiled = c; vocabularyIndex = vocabulary; snippetIndex = snippets
                dictionaryRevision &+= 1
            }
            readOnly = false; loadError = nil
        }
    }

    /// Snippet for the whole utterance, if any (see `SnippetMatcher`).
    public func snippet(for utterance: String) -> Snippet? {
        let normalised = SnippetMatcher.normalise(utterance)
        guard !normalised.isEmpty else { return nil }
        return lock.withLock {
            let direct = snippetIndex[normalised]
            let inserted = normalised.hasPrefix("insert ") ? snippetIndex[String(normalised.dropFirst(7))] : nil
            // Original rule order wins, including when both forms match different snippets.
            if let direct, let inserted { return direct.position < inserted.position ? direct.snippet : inserted.snippet }
            return direct?.snippet ?? inserted?.snippet
        }
    }

    /// Enqueue synchronously at the edit site, before a Task can reorder submissions.
    public func enqueueUpdate(_ dictionary: UserDictionary) -> Save {
        let save = Save()
        updates.async {
            do { try self.update(dictionary); save.finish(nil) }
            catch { save.finish(error) }
        }
        return save
    }

    /// Submit only editor changes, merging each changed field into the current revision.
    public func enqueueEditorChanges(from old: UserDictionary, to new: UserDictionary) -> Save {
        let save = Save()
        updates.async {
            var current = self.dictionary
            for term in old.vocabulary where !new.vocabulary.contains(term) {
                current.vocabulary.removeAll { $0 == term }
            }
            for term in new.vocabulary where !old.vocabulary.contains(term) { current.addTerm(term) }
            for row in old.replacements where !new.replacements.contains(where: { $0.id == row.id }) {
                current.replacements.removeAll { $0.id == row.id }
            }
            for row in new.replacements {
                let previous = old.replacements.first { $0.id == row.id }
                if let i = current.replacements.firstIndex(where: { $0.id == row.id }) {
                    if previous?.from != row.from { current.replacements[i].from = row.from }
                    if previous?.to != row.to { current.replacements[i].to = row.to }
                    if previous?.caseInsensitive != row.caseInsensitive { current.replacements[i].caseInsensitive = row.caseInsensitive }
                    if previous?.wholeWord != row.wholeWord { current.replacements[i].wholeWord = row.wholeWord }
                } else if previous == nil || previous?.from.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    if !row.from.trimmingCharacters(in: .whitespaces).isEmpty { current.replacements.append(row) }
                }
            }
            for row in old.snippets where !new.snippets.contains(where: { $0.id == row.id }) {
                current.snippets.removeAll { $0.id == row.id }
            }
            for row in new.snippets {
                let previous = old.snippets.first { $0.id == row.id }
                if let i = current.snippets.firstIndex(where: { $0.id == row.id }) {
                    if previous?.trigger != row.trigger { current.snippets[i].trigger = row.trigger }
                    if previous?.expansion != row.expansion { current.snippets[i].expansion = row.expansion }
                } else if previous == nil || previous?.trigger.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    if !row.trigger.trimmingCharacters(in: .whitespaces).isEmpty { current.snippets.append(row) }
                }
            }
            current.replacements.removeAll { $0.from.trimmingCharacters(in: .whitespaces).isEmpty }
            current.snippets.removeAll { $0.trigger.trimmingCharacters(in: .whitespaces).isEmpty }
            do { try self.update(current); save.finish(nil) }
            catch { save.finish(error) }
        }
        return save
    }

    public final class Save: @unchecked Sendable {
        private let group = DispatchGroup()
        private let lock = NSLock()
        private var error: Error?
        fileprivate init() { group.enter() }
        fileprivate func finish(_ error: Error?) { lock.withLock { self.error = error }; group.leave() }
        /// Synchronous learning callers still submit through the editor's serial mutation queue.
        public func wait() throws {
            group.wait()
            if let error = lock.withLock({ self.error }) { throw error }
        }
        public var value: Void {
            get async throws {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    group.notify(queue: .global(qos: .utility)) {
                        if let error = self.lock.withLock({ self.error }) { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
        }
    }

    public func updateAsync(_ dictionary: UserDictionary) async throws {
        try await enqueueUpdate(dictionary).value
    }

    /// Learning adds to the latest committed revision inside the same serial update queue.
    public func updateAsync(_ transform: @escaping @Sendable (inout UserDictionary) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            updates.async {
                var dictionary = self.dictionary
                transform(&dictionary)
                do { try self.update(dictionary); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func indexSnippets(_ snippets: [Snippet]) -> [String: (position: Int, snippet: Snippet)] {
        var result: [String: (position: Int, snippet: Snippet)] = [:]
        for (position, snippet) in snippets.enumerated() {
            let trigger = SnippetMatcher.normalise(snippet.trigger)
            if !trigger.isEmpty, result[trigger] == nil { result[trigger] = (position, snippet) }
        }
        return result
    }

    public func snapper(context: ContextSnapshot?, tombstones: Set<String>) -> SpellingSnapper {
        lock.withLock {
            SpellingSnapper(vocabularyIndex: vocabularyIndex, context: context, tombstones: tombstones)
        }
    }

    /// Uses the cached compiled rules (rebuilt on update/reload).
    public func apply(to text: String) -> String { lock.withLock { compiled }.apply(to: text) }

    static func read(_ url: URL) -> UserDictionary? { try? readThrowing(url) }

    static func readThrowing(_ url: URL) throws -> UserDictionary {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UserDictionary.self, from: data)
    }

    static func write(_ d: UserDictionary, to url: URL) throws {
        try AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AppPaths.writePrivate(enc.encode(d), to: url)
    }
}

/// What one `DictionaryStore.update` removed and added: Words by text (case-insensitive),
/// Replacement rows by id (so editing a row's text is not a removal).
public struct DictionaryChange: Sendable, Equatable {
    public var removedTerms: [String] = []
    public var addedTerms: [String] = []
    public var removedRules: [ReplacementRule] = []
    public var addedRules: [ReplacementRule] = []
    public var isEmpty: Bool { removedTerms.isEmpty && addedTerms.isEmpty && removedRules.isEmpty && addedRules.isEmpty }

    public init(old: UserDictionary, new: UserDictionary) {
        let oldTerms = Set(old.vocabulary.map { $0.lowercased() }), newTerms = Set(new.vocabulary.map { $0.lowercased() })
        removedTerms = old.vocabulary.filter { !newTerms.contains($0.lowercased()) }
        addedTerms = new.vocabulary.filter { !oldTerms.contains($0.lowercased()) }
        let oldIDs = Set(old.replacements.map(\.id)), newIDs = Set(new.replacements.map(\.id))
        removedRules = old.replacements.filter { !newIDs.contains($0.id) }
        addedRules = new.replacements.filter { !oldIDs.contains($0.id) }
    }
}

public enum DictionaryError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case readOnly(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): return "Dictionary schema v\(v) is newer than this build supports (v\(UserDictionary.currentSchemaVersion))."
        case .readOnly(let why): return "Dictionary not saved — the file on disk couldn't be read and is left untouched. \(why)"
        }
    }
}

extension Result {
    var failureError: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
