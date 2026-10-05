import Testing
import Foundation
@testable import WisprLocalCore

/// Auto-learning dictionary: correction detection from synthetic field strings, the watch
/// session, suggest / automatic / off, tombstones, and History "Fix a Word…".
@Suite struct CorrectionDetectionTests {
    @Test func singleWordRespelled() {
        let c = CorrectionDetector.detect(inserted: "We deploy on kubernetties today.",
                                          before: "Notes: We deploy on kubernetties today.",
                                          after: "Notes: We deploy on Kubernetes today.")
        #expect(c == Correction(misheard: "kubernetties", correct: "Kubernetes"))
    }

    @Test func multiWordPhraseToOneWord() {
        let c = CorrectionDetector.detect(inserted: "we deploy on kuber netties",
                                          before: "we deploy on kuber netties", after: "we deploy on Kubernetes")
        #expect(c == Correction(misheard: "kuber netties", correct: "Kubernetes"))
    }

    @Test func twoWordsToTwoWords() {
        let c = CorrectionDetector.detect(inserted: "Ping whisker flow now.",
                                          before: "Ping whisker flow now.", after: "Ping Wispr Flow now.")
        #expect(c == Correction(misheard: "whisker flow", correct: "Wispr Flow"))
    }

    @Test func nameRespelled() {
        let c = CorrectionDetector.detect(inserted: " Thanks Sean.", before: "Hi all. Thanks Sean.", after: "Hi all. Thanks Shaun.")
        #expect(c == Correction(misheard: "Sean", correct: "Shaun"))
    }

    @Test func casingOnlyIsLearnable() {
        let c = CorrectionDetector.detect(inserted: "use kubernetes", before: "use kubernetes", after: "use Kubernetes")
        #expect(c == Correction(misheard: "kubernetes", correct: "Kubernetes"))
    }

    @Test func unrelatedEditIsNoSuggestion() {
        #expect(CorrectionDetector.detect(inserted: "Let's have a meeting tomorrow.",
                                          before: "Let's have a meeting tomorrow.", after: "Let's have a call tomorrow.") == nil)
        #expect(CorrectionDetector.detect(inserted: "Send the report", before: "Send the report", after: "Send the invoice") == nil)
    }

    @Test func appendingTextIsNoSuggestion() {
        let ins = "We deploy on Kubernetes"
        #expect(CorrectionDetector.detect(inserted: ins, before: ins, after: ins + " and Docker.") == nil)
        #expect(CorrectionDetector.detect(inserted: ins, before: ins, after: ins + "es") == nil)          // "Kubernetes" → "Kuberneteses"
        #expect(CorrectionDetector.detect(inserted: "Send the test", before: "Send the test", after: "Send the tests") == nil)
        #expect(CorrectionDetector.detect(inserted: "Hello", before: "Hello", after: "Hello world, how are you") == nil)
    }

    @Test func editsOutsideTheInsertionAreIgnored() {
        #expect(CorrectionDetector.detect(inserted: "kuber netties", before: "Draft Sean: kuber netties",
                                          after: "Draft Shaun: kuber netties") == nil)
    }

    @Test func commonWordSwapsAreNeverLearned() {
        #expect(CorrectionDetector.detect(inserted: "put it over their", before: "put it over their", after: "put it over there") == nil)
        #expect(CorrectionDetector.detect(inserted: "a new man", before: "a new man", after: "a Newman") == nil)
        #expect(CorrectionDetector.detect(inserted: "the kat sat", before: "the kat sat", after: "the cat sat") == nil)
    }

    @Test func deletionOrTooManyWordsIsNoSuggestion() {
        #expect(CorrectionDetector.detect(inserted: "one two three four five", before: "one two three four five", after: "one five") == nil)
        #expect(CorrectionDetector.detect(inserted: "alpha beta gamma delta epsilon", before: "alpha beta gamma delta epsilon",
                                          after: "alpha bravo charlie delta echo") == nil)
    }
}

@Suite struct CorrectionWatchSessionTests {
    static let ins = "deploy on kuber netties"

    func snap(_ t: String, id: Int? = 7, secure: Bool = false, sel: Int = 0) -> FieldSnapshot {
        FieldSnapshot(elementID: id, text: t, isSecure: secure, selectionLength: sel)
    }

    @Test func findsAStableCorrection() {
        var s = CorrectionWatchSession(inserted: Self.ins, elementID: 7)
        #expect(s.observe(snap("we deploy on kuber netties"), elapsed: 0.5) == .keepWatching)   // baseline
        #expect(s.observe(snap("we deploy on Kuber"), elapsed: 1.0) == .keepWatching)           // mid-typing
        #expect(s.observe(snap("we deploy on Kubernetes"), elapsed: 1.5) == .keepWatching)
        #expect(s.observe(snap("we deploy on Kubernetes"), elapsed: 2.0) == .keepWatching)
        #expect(s.observe(snap("we deploy on Kubernetes"), elapsed: 2.5) == .found(Correction(misheard: "kuber netties", correct: "Kubernetes")))
        #expect(s.observe(snap("we deploy on Kubernetes"), elapsed: 3.0) == .stop)
    }

    @Test func stopsOnFocusChangeSecureFieldHugeFieldAndTimeout() {
        var a = CorrectionWatchSession(inserted: Self.ins, elementID: 7)
        _ = a.observe(snap("deploy on kuber netties"), elapsed: 0.5)
        #expect(a.observe(snap("deploy on Kubernetes", id: 8), elapsed: 1) == .stop)
        var b = CorrectionWatchSession(inserted: Self.ins, elementID: 7)
        #expect(b.observe(snap("", secure: true), elapsed: 0.5) == .stop)
        var c = CorrectionWatchSession(inserted: Self.ins, elementID: 7)
        #expect(c.observe(snap("deploy on kuber netties", sel: 20_001), elapsed: 0.5) == .stop)
        var d = CorrectionWatchSession(inserted: Self.ins, elementID: 7)
        #expect(d.observe(snap(String(repeating: "x", count: 20_001)), elapsed: 0.5) == .stop)
        var e = CorrectionWatchSession(inserted: Self.ins, elementID: 7)
        _ = e.observe(snap("deploy on kuber netties"), elapsed: 0.5)
        #expect(e.observe(snap("deploy on Kubernetes"), elapsed: 15.5) == .stop)
        var f = CorrectionWatchSession(inserted: Self.ins, elementID: 7)
        #expect(f.observe(nil, elapsed: 0.5) == .stop)                                       // unreadable
        var g = CorrectionWatchSession(inserted: Self.ins, elementID: 7)
        #expect(g.observe(snap("something else entirely"), elapsed: 0.5) == .stop)          // paste not there
    }
}

/// Fake AX field reader for the watcher (called off the main actor, so it locks).
final class FakeFieldReader: FocusedFieldReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _script: [FieldSnapshot?] = []
    private var _reads = 0
    private var _windows: [FieldWindow] = []
    private var _onMain: [Bool] = []
    var script: [FieldSnapshot?] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }
    var reads: Int { lock.withLock { _reads } }
    /// The window asked for on each read.
    var windows: [FieldWindow] { lock.withLock { _windows } }
    /// Whether each read ran on the main thread.
    var onMain: [Bool] { lock.withLock { _onMain } }
    func read(pid: Int32, window: FieldWindow) -> FieldSnapshot? {
        let main = Thread.isMainThread
        return lock.withLock {
            defer { _reads += 1 }
            _windows.append(window); _onMain.append(main)
            return _reads < _script.count ? _script[_reads] : _script.last ?? nil
        }
    }
}

@MainActor @Suite struct CorrectionWatcherTests {
    @Test func electronOrUnreadableFieldsAreNeverWatched() async {
        let reader = FakeFieldReader()
        let w = CorrectionWatcher(reader: reader, clock: ManualClock())
        w.watch(InsertedDictation(pid: 1, bundleID: "com.tinyspeck.slackmacgap", elementID: nil, text: "hi there", axReadable: false)) { _ in }
        #expect(!w.isWatching)
        #expect(reader.reads == 0)
    }

    @Test func pollsAndReportsTheCorrection() async {
        let reader = FakeFieldReader()
        reader.script = [FieldSnapshot(elementID: 3, text: "ship kuber netties"),
                         FieldSnapshot(elementID: 3, text: "ship Kubernetes")]
        let clock = ManualClock()
        let w = CorrectionWatcher(reader: reader, clock: clock)
        var found: [Correction] = []
        w.watch(InsertedDictation(pid: 1, bundleID: "com.apple.TextEdit", elementID: 3, text: "ship kuber netties", axReadable: true)) {
            found.append($0)
        }
        for _ in 0..<4 {                                     // baseline + 3 stable polls
            await clock.waitForSleepers(count: 1)            // the watcher is asleep before time moves
            await clock.advance(by: CorrectionWatchSession.pollInterval)
        }
        await w.waitUntilFinished()
        #expect(found == [Correction(misheard: "kuber netties", correct: "Kubernetes")])
        #expect(!w.isWatching)
        #expect(reader.reads == 4)   // baseline + 3 stable polls, then stop
    }

    @Test func stopsAfterFifteenSeconds() async {
        let reader = FakeFieldReader()
        reader.script = [FieldSnapshot(elementID: 3, text: "ship kuber netties")]
        let clock = ManualClock()
        let w = CorrectionWatcher(reader: reader, clock: clock)
        w.watch(InsertedDictation(pid: 1, bundleID: nil, elementID: 3, text: "ship kuber netties", axReadable: true)) { _ in }
        #expect(CorrectionWatchSession.pollInterval == .seconds(1))
        for _ in 0..<16 {                                    // polls at 1 … 16 s
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: CorrectionWatchSession.pollInterval)
        }
        await w.waitUntilFinished()
        #expect(!w.isWatching)
        #expect(reader.reads == 16)  // the 16 s read is past maxDuration and ends the watch
        #expect(clock.sleeperCount == 0)
    }
}

@MainActor @Suite struct DictionaryLearnerTests {
    final class Box { var mode: LearnMode; init(_ m: LearnMode) { mode = m } }

    func make(_ mode: LearnMode) -> (DictionaryLearner, DictionaryStore, LearningStore, Box) {
        let store = tempDictionary()
        let learning = LearningStore(besideDictionary: store.url)
        let box = Box(mode)
        return (DictionaryLearner(dictionary: store, store: learning, mode: { box.mode }), store, learning, box)
    }

    static let k8s = Correction(misheard: "kuber netties", correct: "Kubernetes")

    @Test func suggestModeAsksAndAddsOnlyOnAccept() throws {
        let (l, store, _, _) = make(.suggest)
        #expect(l.consider(Self.k8s) == .suggest(Self.k8s))
        #expect(!store.dictionary.vocabulary.contains("Kubernetes"))
        try l.accept(Self.k8s)
        #expect(store.dictionary.vocabulary.contains("Kubernetes"))
        #expect(store.dictionary.replacements.contains { $0.from == "kuber netties" && $0.to == "Kubernetes" })
        #expect(store.apply(to: "we use kuber netties") == "we use Kubernetes")
        #expect(l.learnedCount == 1)
        #expect(l.consider(Self.k8s) == .ignored(.alreadyKnown))
    }

    @Test func automaticModeAddsStraightAway() {
        let (l, store, _, _) = make(.automatic)
        #expect(l.consider(Self.k8s) == .added(Self.k8s))
        #expect(store.dictionary.vocabulary.contains("Kubernetes"))
        #expect(l.learnedCount == 1)
    }

    @Test func offModeIgnores() {
        let (l, store, _, _) = make(.off)
        #expect(l.consider(Self.k8s) == .ignored(.off))
        #expect(!store.dictionary.vocabulary.contains("Kubernetes"))
    }

    @Test func modeIsReadLive() {
        let (l, _, _, box) = make(.off)
        #expect(l.consider(Self.k8s) == .ignored(.off))
        box.mode = .suggest
        #expect(l.consider(Self.k8s) == .suggest(Self.k8s))
    }

    @Test func deletedWordsAreTombstonedAndNeverSuggestedAgain() throws {
        let (l, store, learning, _) = make(.automatic)
        _ = l.consider(Self.k8s)
        var d = store.dictionary
        d.vocabulary.removeAll { $0 == "Kubernetes" }
        d.replacements.removeAll { $0.to == "Kubernetes" }
        try store.update(d)                                       // the user deletes it in Dictionary
        #expect(learning.isTombstoned("kubernetes"))
        #expect(learning.isTombstoned("Kuber Netties"))
        #expect(l.consider(Self.k8s) == .ignored(.tombstoned))
        #expect(l.consider(Correction(misheard: "cooper netties", correct: "Kubernetes")) == .ignored(.tombstoned))
        #expect(!store.dictionary.vocabulary.contains("Kubernetes"))
        // Survives a relaunch (learning.json beside the dictionary, owner-only).
        let reloaded = LearningStore(besideDictionary: store.url)
        #expect(reloaded.isTombstoned("Kubernetes"))
        let mode = try FileManager.default.attributesOfItem(atPath: reloaded.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func seedWordsDeletedByTheUserAreTombstonedToo() throws {
        let (l, store, learning, _) = make(.suggest)
        var d = store.dictionary
        d.vocabulary.removeAll { $0 == "Tailscale" }
        try store.update(d)
        #expect(learning.isTombstoned("Tailscale"))
        #expect(l.consider(Correction(misheard: "tale scale", correct: "Tailscale")) == .ignored(.tombstoned))
    }

    @Test func editingARowIsNotADeletion() throws {
        let (_, store, learning, _) = make(.suggest)
        var d = store.dictionary
        let id = d.replacements[0].id
        let oldFrom = d.replacements[0].from
        // The Dictionary page drops a row whose "heard" field is momentarily empty, then re-adds it.
        let row = d.replacements[0]
        d.replacements.removeAll { $0.id == id }
        try store.update(d)
        #expect(learning.isTombstoned(oldFrom))
        var r = row; r.from = oldFrom + "x"
        d.replacements.append(r)
        try store.update(d)
        #expect(!learning.isTombstoned(row.to))
    }

    @Test func fixAWordIsTheElectronFallback() throws {
        let (l, store, learning, _) = make(.off)                  // works even with learning off: explicit
        let entryText = "Ship it to kuber netties tonight."
        let words = FixAWord.words(in: entryText)
        #expect(words == ["Ship", "it", "to", "kuber", "netties", "tonight"])
        let phrase = try #require(FixAWord.phrase(words, selection: 3...4))
        #expect(phrase == "kuber netties")
        learning.tombstone(["Kubernetes"])                        // deleted before; an explicit fix wins
        try l.fixWord(misheard: phrase, correct: "Kubernetes")
        #expect(store.apply(to: "kuber netties") == "Kubernetes")
        #expect(store.dictionary.vocabulary.contains("Kubernetes"))
        #expect(!learning.isTombstoned("Kubernetes"))
        #expect(l.learnedCount == 1)
    }

    @Test func fixAWordRefusesCommonWordsAndBadPicks() {
        let (l, _, _, _) = make(.suggest)
        #expect(throws: LearnError.commonWord("their")) { try l.fixWord(misheard: "their", correct: "there") }
        #expect(throws: LearnError.empty) { try l.fixWord(misheard: "kuber", correct: " ") }
        #expect(throws: LearnError.same) { try l.fixWord(misheard: "Kubernetes", correct: "Kubernetes") }
        #expect(throws: LearnError.tooManyWords) { try l.fixWord(misheard: "a b c d", correct: "x") }
        #expect(FixAWord.phrase(["a", "b", "c", "d"], selection: 0...3) == nil)
        #expect(FixAWord.phrase(["a"], selection: 0...1) == nil)
    }
}

extension DictionaryLearnerTests {
    @Test func learningEditorAndHistoryFixInterleavedKeepAllChanges() async throws {
        let (learner, dictionary, _, _) = make(.suggest)
        let old = dictionary.dictionary
        var edited = old
        edited.addTerm("EditorWord")
        var fixed = old
        fixed.addTerm("HistoryWord")
        fixed.addReplacement(from: "history werd", to: "HistoryWord")
        let editorSave = dictionary.enqueueEditorChanges(from: old, to: edited)
        try learner.accept(Correction(misheard: "kuber netties", correct: "Kubernetes"))
        // Fix a Word was opened on the same old revision as the editor.
        let fixSave = dictionary.enqueueEditorChanges(from: old, to: fixed)
        try await editorSave.value
        try await fixSave.value
        let reloaded = DictionaryStore(url: dictionary.url).dictionary
        #expect(reloaded.vocabulary.contains("EditorWord"))
        #expect(reloaded.vocabulary.contains("HistoryWord"))
        #expect(reloaded.vocabulary.contains("Kubernetes"))
        #expect(reloaded.replacements.contains { $0.from == "kuber netties" && $0.to == "Kubernetes" })
        #expect(reloaded.replacements.contains { $0.from == "history werd" && $0.to == "HistoryWord" })
    }
}
