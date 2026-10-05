import Testing
import Foundation
@testable import WisprLocalCore

/// R13: tombstones block the term the user actually deleted, and the snapper honours them.
@MainActor @Suite struct TombstoneTests {
    func make() -> (DictionaryLearner, DictionaryStore, LearningStore) {
        let store = tempDictionary()
        let learning = LearningStore(besideDictionary: store.url)
        return (DictionaryLearner(dictionary: store, store: learning, mode: { .suggest }), store, learning)
    }

    /// Deleting the seed rule "whisperflow → Wispr Flow" while the Word "Wispr Flow" stays
    /// tombstones only the heard form: "Wispr Flow" can still be learned and snapped.
    @Test func deletingARuleTombstonesItsHeardFormNotAWordThatStays() throws {
        let (l, store, learning) = make()
        #expect(store.dictionary.vocabulary.contains("Wispr Flow"))
        var d = store.dictionary
        d.replacements.removeAll { $0.from == "whisperflow" }
        try store.update(d)
        #expect(learning.isTombstoned("whisperflow"))
        #expect(!learning.isTombstoned("Wispr Flow"))
        #expect(l.consider(Correction(misheard: "whisper flo", correct: "Wispr Flow")) != .ignored(.tombstoned))
    }

    /// Deleting a rule whose replacement is no longer a Word tombstones both sides.
    @Test func deletingARuleAndItsWordTombstonesBoth() throws {
        let (_, store, learning) = make()
        var d = store.dictionary
        d.addTerm("Kubernetes")
        d.addReplacement(from: "kuber netties", to: "Kubernetes")
        try store.update(d)
        d.vocabulary.removeAll { $0 == "Kubernetes" }
        d.replacements.removeAll { $0.to == "Kubernetes" }
        try store.update(d)
        #expect(learning.isTombstoned("kuber netties"))
        #expect(learning.isTombstoned("Kubernetes"))
    }

    @Test func theSnapperNeverOffersATombstonedTerm() {
        let none = FixedLexicon([])
        #expect(SpellingSnapper(vocabulary: ["Kubernetes"], lexicon: none).apply("ship kubernetties").text == "ship Kubernetes")
        #expect(SpellingSnapper(vocabulary: ["Kubernetes"], tombstones: ["kubernetes"], lexicon: none)
            .apply("ship kubernetties").text == "ship kubernetties")
    }

    /// Deleted rule "claud → Claude" but kept the Word "Claude": "claud" is never snapped again.
    @Test func theSnapperNeverRewritesATombstonedHeardForm() {
        let none = FixedLexicon([])
        #expect(SpellingSnapper(vocabulary: ["Claude"], tombstones: ["claud"], lexicon: none).apply("ask claud").text == "ask claud")
        #expect(SpellingSnapper(vocabulary: ["Kubernetes"], tombstones: ["kuber netties"], lexicon: none)
            .apply("ship kuber netties").text == "ship kuber netties")
    }

    /// The pipeline passes the learning tombstones to the snapper.
    @Test func thePipelineHonoursTombstones() async throws {
        let dict = tempDictionary()
        var d = dict.dictionary
        d.addTerm("Kubernetes")
        try dict.update(d)
        let (e, p) = await makeEnv(text: "we ship kubernetties", dictionary: dict)
        p.snapperTombstones = { ["kubernetties"] }
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.last?.contains("kubernetties") == true)
    }

    /// The privacy FAQ says what learning.json holds.
    @Test func privacyFAQDescribesLearningJSON() {
        let data = FAQ.items.first { $0.id == "data" }!.answer.joined(separator: " ")
        for needle in ["learning.json", "only by your user account", "never dictated text"] { #expect(data.contains(needle), "\(needle)") }
    }
}
