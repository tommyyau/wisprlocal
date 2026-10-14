import Foundation
import Testing
@testable import WisprLocalCore

@Suite struct PlanHardeningTests {
    @Test func unsafeRetractionsAndFalseStartsRestoreContent() {
        for (input, model) in [
            ("Pay Bob 500 dollars on Friday. Email the team, actually email the board.", "Email the board."),
            ("Send the 5 files to Bob, I mean the files are ready", "The files are ready."),
            ("The client liked the demo, actually the client signed 50 seats", "The client signed 50 seats."),
            ("Send 5 copies to Bob, actually send copies to Alice", "Send copies to Alice."),
            ("Fly to Paris. Book 3 hotels in Rome, sorry in Milan", "Fly in Milan."),
            ("Send it today, to Bob, actually send it tomorrow to Alice", "Send it tomorrow to Alice."),
            ("Don't email Sam, I mean email Bob.", "Email Bob."),
            ("The invoice is due Friday. The team meets Monday to review the budget and plan hiring", "The team meets Monday to review the budget and plan hiring."),
            ("Put it on the table, put it away", "Put it away."),
            ("I saw the team, I signed today", "I signed today."),
            ("the team, the board arrived today", "The board arrived today."),
            ("I want to send all the files, I want to send them", "I want to send them.")
        ] {
            #expect(projectionKeys(input, model) == PlanTokens(input).keys, "\(input)")
        }
    }
    @Test func protectedSlotsRequireRestatementAndMultiplicity() {
        for word in ["Friday", "January", "today", "tomorrow", "tonight", "yesterday", "morning", "afternoon", "evening", "noon", "midnight", "am", "pm", "o'clock"] {
            let input = "Send it \(word), actually send it please"
            #expect(projectionKeys(input, "Send it please.") == PlanTokens(input).keys)
        }
        let input = "Send 5 and 6 copies, actually send 7 copies"
        #expect(projectionKeys(input, "Send 7 copies.") == PlanTokens(input).keys)
    }
    @Test func lexicalFillersSurvive() {
        for (input, model) in [
            ("Do you know where it is", "Do where it is."), ("I'll let you know tomorrow", "I'll let tomorrow."),
            ("I mean it", "It."), ("I like the plan", "I the plan."), ("Looks like rain", "Looks rain."),
            ("Turn right on Main", "Turn on Main."), ("The well is dry", "The is dry."),
            ("I'm not feeling well", "I'm not feeling."), ("Is that okay with you", "Is that with you?"),
            ("It was, so, good", "It was good."), ("It was, like, the plan", "It was the plan."),
            ("What kind of car", "What car?"), ("do it so that it works", "Do it that it works.")
        ] { #expect(projectionKeys(input, model) == PlanTokens(input).keys) }
    }
    @Test func removedTerminalsAndPairedBrackets() {
        for (input, model, expected) in [
            ("Call Bob, right. Then email", "Call Bob. Then email", "Call Bob. Then email."),
            ("He said (um) hi", "He said hi.", "He said hi."),
            ("He said (hi um) then left", "He said (hi) then left.", "He said (hi) then left.")
        ] { #expect(AlignmentProjection.apply(input: input, output: model, level: .light).text == expected) }
    }
    @Test func freeTextPromptAndBudget() throws {
        let raw = "well-known 3:30 $5 e.g."
        let prompt = FoundationModelsCleaner.semanticPrompt(for: raw, context: CleanupContext())
        let data = try #require(prompt.split(separator: "\n", maxSplits: 1).last).data(using: .utf8)!
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["dictation"] as? String == raw)
        #expect(fields["tokens"] == nil)
        #expect(FoundationModelsCleaner.responseTokenLimit(prompt) == PlanTokens(raw).surfaces.count * 2 + 64)
        #expect(!FoundationModelsCleaner.semanticInstructions(level: .light).contains("span"))
    }

    @Test func m4PreservesGeneralizedSpokenCompounds() {
        for raw in ["reporting period", "serial comma", "same period", "rest period", "short dash", "renewal period", "processing period"] {
            #expect(SpokenPunctuation.apply(raw) == raw)
        }
        #expect(SpokenPunctuation.apply("Please review the document period") == "Please review the document.")
        #expect(StutterRemover.apply("Place them at the, place them on the shelf") == "Place them on the shelf")
    }

    @Test func sevenRejectedPlanRetainsLocalHistoryCandidate() async {
        let raw = "Send 5 copies to Bob, actually send copies to Alice"
        let result = await FoundationModelsCleaner(model: FakeCleanupModel(.reply("Send copies to Alice."))).cleanDetailed(raw, level: .light, deterministicText: raw)
        #expect(result.text.contains("5 copies to Bob"))
        #expect(result.candidate == "Send copies to Alice.")
        #expect(result.spanVerdicts.keys.contains(where: { $0.hasPrefix("restored:") }))
    }
}
