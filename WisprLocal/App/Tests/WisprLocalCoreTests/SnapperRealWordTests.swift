import Testing
import Foundation
@testable import WisprLocalCore

/// R2 (FABLE_REVIEW_2): the spelling snapper must never rewrite a correct English word into a
/// dictionary term or context name. These rows run the REAL snapper with the REAL offline system
/// spell checker (`SystemEnglishLexicon`), so the guard is tested as it ships.
@Suite struct SnapperRealWordTests {
    struct Row: CustomTestStringConvertible, Sendable {
        var heard: String
        var vocabulary: [String] = []
        var names: [String] = []
        var testDescription: String { "\"\(heard)\" stays (\((vocabulary + names).joined(separator: ", ")))" }
    }

    static func run(_ r: Row) -> String {
        let ctx = r.names.isEmpty ? nil : ContextSnapshot(candidates: r.names.map { ContextCandidate($0, kind: .name) }, isCodeApp: false)
        return SpellingSnapper(vocabulary: r.vocabulary, context: ctx).apply(r.heard).text
    }

    /// The measured false positives from the review, then 30+ more real-word cases.
    static let realWords: [Row] = [
        Row(heard: "upload it to the cloud", vocabulary: ["Claude"]),
        Row(heard: "upload it to the cloud", names: ["Claude"]),
        Row(heard: "scale the cluster", vocabulary: ["Kluster"]),
        Row(heard: "cut me some slack", vocabulary: ["Slack"]),
        Row(heard: "do a linear scan", vocabulary: ["Linear"]),
        Row(heard: "put it over their", vocabulary: ["There"]),
        Row(heard: "over there now", vocabulary: ["Their"]),
        Row(heard: "act with swift resolve", vocabulary: ["Swift"]),
        Row(heard: "the notion of it", vocabulary: ["Notion"]),
        Row(heard: "go faster", names: ["Foster"]),
        Row(heard: "the gross margin", names: ["Gross"]),
        // 30+ more: real English words next to a sound-alike (or same-spelled) product or name.
        Row(heard: "use your brain", vocabulary: ["Brian"]),
        Row(heard: "a bowl of rice", vocabulary: ["Rhys"]),
        Row(heard: "count down to zero", vocabulary: ["Xero"]),
        Row(heard: "the lights flicker", vocabulary: ["Flickr"]),
        Row(heard: "a glass tumbler", vocabulary: ["Tumblr"]),
        Row(heard: "look in the mirror", vocabulary: ["Miro"]),
        Row(heard: "we played well", vocabulary: ["Plaid"]),
        Row(heard: "hit your stride", vocabulary: ["Stryd"]),
        Row(heard: "the fire alarm", vocabulary: ["Fyre"]),
        Row(heard: "give me a lift", vocabulary: ["Lyft"]),
        Row(heard: "trim the wicks", vocabulary: ["Wix"]),
        Row(heard: "a hula hoop", vocabulary: ["Hulu"]),
        Row(heard: "lend me a fiver", vocabulary: ["Fiverr"]),
        Row(heard: "the stock market", vocabulary: ["Markit"]),
        Row(heard: "a yoga asana", vocabulary: ["Asana"]),
        Row(heard: "said in jest", vocabulary: ["Jest"]),
        Row(heard: "a ruby ring", vocabulary: ["Ruby"]),
        Row(heard: "the tiger stripe", vocabulary: ["Stripe"]),
        Row(heard: "weave on a loom", vocabulary: ["Loom"]),
        Row(heard: "ask the oracle", vocabulary: ["Oracle"]),
        Row(heard: "fresh mint tea", vocabulary: ["Mint"]),
        Row(heard: "arts and craft", vocabulary: ["Craft"]),
        Row(heard: "they react quickly", vocabulary: ["React"]),
        Row(heard: "rust on the car", vocabulary: ["Rust"]),
        Row(heard: "the arc of it", vocabulary: ["Arc"]),
        Row(heard: "a wall mural", vocabulary: ["Mural"]),
        Row(heard: "a bird nest", vocabulary: ["Nest"]),
        Row(heard: "home brew", vocabulary: ["Brew"]),
        Row(heard: "the final coda", vocabulary: ["Coda"]),
        Row(heard: "a sentry post", vocabulary: ["Sentry"]),
        Row(heard: "the clever fox", vocabulary: ["Clevr"]),
        Row(heard: "a quiet notion", names: ["Noshun"]),
        Row(heard: "meet on tuesday", vocabulary: ["Tuesdei"]),
    ]

    @Test(arguments: realWords) func realEnglishWordsAreNeverRewritten(_ r: Row) {
        #expect(Self.run(r) == r.heard)
    }

    @Test func tableHasTheMeasuredCasesAndThirtyMore() {
        #expect(Self.realWords.count >= 11 + 30)
    }
}
