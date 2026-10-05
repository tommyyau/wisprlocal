import Testing
import Foundation
@testable import WisprLocalCore

/// R8: a change of mind is not a mishearing. A rule is proposed only when the two sound alike
/// AND the original is not a real English word (or is a phrase whose joined form is close to
/// the replacement). Runs on the real offline lexicon.
@Suite struct ChangeOfMindTests {
    func learned(_ inserted: String, _ after: String) -> Correction? {
        CorrectionDetector.detect(inserted: inserted, before: inserted, after: after)
    }

    @Test(arguments: [
        ("Meet Tuesday at 3", "Meet Thursday at 3"),
        ("about fifteen people", "about fifty people"),
        ("yes we can", "no we can"),
        ("ask Sam today", "ask Alex today"),
        ("upload it to the cloud", "upload it to the Claude"),
        ("use your brain", "use your Brian"),
        ("scale the cluster", "scale the Kluster"),
        ("cut me some slack", "cut me some Slack"),
        ("in March we ship", "in May we ship"),
        ("the gross margin", "the Gross margin"),
    ])
    func changesOfMindAreNeverLearned(_ pair: (String, String)) {
        #expect(learned(pair.0, pair.1) == nil)
    }

    @Test func mishearingsAreStillLearned() {
        #expect(learned("we ship kuber netties", "we ship Kubernetes") == Correction(misheard: "kuber netties", correct: "Kubernetes"))
        #expect(learned("we ship kubernetties", "we ship Kubernetes") == Correction(misheard: "kubernetties", correct: "Kubernetes"))
        #expect(learned("Thanks Sean.", "Thanks Shaun.") == Correction(misheard: "Sean", correct: "Shaun"))
        #expect(learned("ping whisker flow", "ping Wispr Flow") == Correction(misheard: "whisker flow", correct: "Wispr Flow"))
        // A phrase of real words whose joined form is close to the replacement.
        #expect(learned("train in pie torch", "train in PyTorch") == Correction(misheard: "pie torch", correct: "PyTorch"))
    }

    /// With an injected lexicon: the single-word rule is the lexicon's, not a word list.
    @Test func singleWordRuleUsesTheLexicon() {
        #expect(CorrectionDetector.judge(old: "clowd", new: "Cloud", lexicon: FixedLexicon([])) != nil)
        #expect(CorrectionDetector.judge(old: "clowd", new: "Cloud", lexicon: FixedLexicon(["clowd"])) == nil)
        // A phrase of REAL words must have a joined form close to the replacement (≤ 0.34);
        // with a non-word in it, the ordinary sound-alike check is enough.
        #expect(CorrectionDetector.judge(old: "kubo netties", new: "Kubernetes", lexicon: FixedLexicon(["kubo", "netties"])) == nil)
        #expect(CorrectionDetector.judge(old: "kubo netties", new: "Kubernetes", lexicon: FixedLexicon(["kubo"])) != nil)
    }
}
