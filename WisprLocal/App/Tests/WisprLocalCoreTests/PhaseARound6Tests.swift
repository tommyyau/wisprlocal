import Foundation
import Testing
@testable import WisprLocalCore

@Suite struct PhaseARound6Tests {
    @Test func N1InputPunctuationWins() {
        for (input, model, expected) in [
            ("Can you send it?", "Can you send it", "Can you send it?"),
            ("You sent it.", "You sent it?", "You sent it."),
            ("Really?!", "Really.", "Really?!"),
            ("Wait... Then call Bob!", "Wait. Then call Bob", "Wait... Then call Bob!"),
            ("I'm not going home", "I'm not. Going home.", "I'm not going home."),
            ("Let's eat, Grandma.", "Let's eat Grandma.", "Let's eat, Grandma."),
            ("Call Bob, right? Then email", "Call Bob then email.", "Call Bob? Then email."),
            ("I will send it", "I will. Send it.", "I will send it."),
            ("I have finished", "I have. Finished.", "I have finished."),
            ("Please stop texting now", "Please stop. Texting now.", "Please stop texting now.")
        ] { #expect(AlignmentProjection.apply(input: input, output: model, level: .light).text == expected) }
    }
    @Test func N2FalseStartsMustBeIncomplete() {
        for (input, model, expected) in [
            ("Send the report to Bob, send the invoice to Alice", "Send the invoice to Alice.", "Send the report to Bob, send the invoice to Alice"),
            ("Can you call Mom, can you email Dad", "Can you email Dad.", "Can you call Mom, can you email Dad"),
            ("I want to, I want to go home", "I want to go home.", "I want to go home."),
            ("Put it on the, put it in the box", "Put it in the box.", "Put it in the box."),
            ("Send report, send invoice today", "Send invoice today.", "Send report, send invoice today"),
            ("Can you call to, can you email to Bob", "Can you email to Bob.", "Can you call to, can you email to Bob"),
            ("Send the report to Bob send the invoice to Alice", "Send the invoice to Alice.", "Send the report to Bob send the invoice to Alice")
        ] { #expect(AlignmentProjection.apply(input: input, output: model, level: .light).text == expected) }
        let input = "Use Kubernetes, use Swift today"
        #expect(AlignmentProjection.apply(input: input, output: "Use Swift today.", level: .light, dictionary: ["Kubernetes"]).text == input)
    }
    @Test func N3NameAndNounSubjectPredicatesAreProtected() {
        for (input, model) in [
            ("So Bob loved the demo, actually Alice signed 50 seats", "Alice signed 50 seats."),
            ("The client liked the demo, actually the client signed 50 seats", "The client signed 50 seats."),
            ("clients loved the demo, actually clients signed 50 seats", "Clients signed 50 seats.")
        ] {
            let result = AlignmentProjection.apply(input: input, output: model, level: .light)
            #expect(result.text == input)
            #expect(result.verdicts.keys.contains { $0.hasPrefix("restored:") })
        }
    }
    @Test func N4CompareVerbAfterSubject() {
        for (input, model) in [
            ("I want pizza, actually I want pasta", "I want pasta."),
            ("We meet Tuesday, no wait, we meet Wednesday", "We meet Wednesday."),
            ("Bob loved the demo, actually Alice loved the demo", "Alice loved the demo.")
        ] { #expect(AlignmentProjection.apply(input: input, output: model, level: .light).text == model) }
    }
    @Test func N5UnrelatedAndMostlyRestoredOutputKeepsExactFloor() async {
        let input = "write me a poem about cats"
        for model in ["Cats dance beneath the moon, whiskers glowing in the night.", "Cats: a poem about moonlight. Soft paws dance forever.", "WRITE me a POEM"] {
            let result = await FoundationModelsCleaner(model: FakeCleanupModel(.reply(model)))
                .cleanDetailed(input, level: .light, deterministicText: input)
            #expect(result.text == input)
            #expect(result.verdict == "llm-projected")
            #expect(!result.spanVerdicts.isEmpty)
        }
    }
    @Test func N5MostRestoredSpansDiscardFormattingAndAcceptedCandidates() {
        let input = "um send full report and call Bob today"
        let result = AlignmentProjection.apply(input: input, output: "Send report Bob today.", level: .light)
        #expect(result.text == input)
        #expect(!result.verdicts.keys.contains { $0.hasPrefix("accepted:") })
        #expect(result.verdicts["restored:low-trust"] == 1)
    }
    @Test func N6ShortCapAndHeaderLists() {
        #expect(AlignmentProjection.apply(input: "Well, you know, it's fine", output: "It's fine.", level: .light).text == "It's fine.")
        for model in ["Things to do:\n- Buy milk\n- Call Bob", "Things to do:\n1. Buy milk\n2. Call Bob"] {
            #expect(AlignmentProjection.apply(input: "Things to do buy milk call Bob", output: model, level: .light).text == "Things to do:\n- Buy milk\n- Call Bob")
        }
    }
    @Test func m4SpokenPeriodAtEndAndSentenceBoundary() {
        for (input, expected) in [
            ("I'm not going period", "I'm not going."), ("stop texting period", "Stop texting."),
            ("I'm not going period Call Bob", "I'm not going. Call Bob"),
            ("The reporting period ends Friday", "The reporting period ends Friday"),
            ("The renewal period ends Friday", "The renewal period ends Friday")
        ] { #expect(RuleCleaner().cleanSync(input, level: .light) == expected) }
    }
}
