import Testing
import Foundation
@testable import WisprLocalCore

/// U1: the suggestion chip says what Add really does (a Word AND a rewrite rule).
@Suite struct SuggestionCopyTests {
    static let k8s = Correction(misheard: "kuber netties", correct: "Kubernetes")

    @Test func chipNamesTheRewrite() {
        let text = SmartDictionaryCopy.suggestion(Self.k8s)
        #expect(text == "Always write “kuber netties” as “Kubernetes”?")
        #expect(SmartDictionaryCopy.isSuggestion(text))
        let chip = HUDChipPolicy.chip(text)
        #expect(chip.actions == [.addWord, .notNow])
        #expect(chip.actions.map(\.title) == ["Add", "Not now"])
        #expect(!SmartDictionaryCopy.isSuggestion(SmartDictionaryCopy.added("Kubernetes")))
    }

    @Test func helpExplainsTheWordAndTheRule() {
        let info = InfoTopic.learnCorrections.sentences.joined(separator: " ")
        for needle in ["Always write", "Words", "Replacement", "15 seconds", "password managers", "banking apps", "Tuesday"] {
            #expect(info.contains(needle), "ⓘ: \(needle)")
        }
        let faq = FAQ.items.first { $0.id == "jargon" }!.answer.joined(separator: " ")
        for needle in ["Always write", "adds that Replacement", "never changed to “Claude”"] { #expect(faq.contains(needle), "FAQ: \(needle)") }
        #expect(FAQ.items.first { $0.id == "jargon" }!.question == "How do I add names or jargon?")
    }
}
