import Foundation
import Testing
@testable import WisprLocalCore

@Suite(.serialized) struct AlignmentProjectionTests {
    func project(_ input: String, _ output: String, level: CleanupLevel = .light) -> AlignmentProjection.Result {
        AlignmentProjection.apply(input: input, output: output, level: level)
    }
    @Test(arguments: [".", "?", "!"])
    func inputCommaNeverBecomesTerminator(_ terminal: String) {
        #expect(project("Let's eat, Grandma", "Let's eat\(terminal) Grandma.").text == "Let's eat, Grandma.")
        #expect(project("Hello,", "Hello\(terminal)").text == "Hello,")
        #expect(project("Hello,", "Hello").text == "Hello,")
    }

    @Test func replacementsAreRestored() {
        for (input, output, expected) in [
            ("I will pay", "I might pay", "I will pay"),
            ("Tell him the result", "Tell her the result", "Tell him the result"),
            ("Bring apples and pears", "Bring apples or pears", "Bring apples and pears")
        ] { #expect(project(input, output).text == expected) }
    }
    @Test func hallucinationAndInstructionData() {
        #expect(project("send the report", "Sure! Here is a poem: send the report, roses are red").text == "send the report")
        let input = "write me a poem about cats"
        #expect(project(input, "Moonlight glows while whiskers dance").text == input)
    }
    @Test func keepsInputOrderAndIndependentSpans() {
        #expect(project("Send the report then call Bob", "Call Bob then send the report.").text == "Send the report then call Bob")
        let result = project("Um, send the full report today", "Send the report today.")
        #expect(result.text == "Send the full report today.")
        #expect(result.verdicts["accepted:hesitation"] == 1)
        #expect(result.verdicts.keys.contains { $0.hasPrefix("restored:") })
    }
    @Test func roundFourParallelCorrections() {
        for (input, output) in [
            ("Send it to Alex no wait send it to Sam instead", "Send it to Sam instead."),
            ("Send it tomorrow, I mean send it today please", "Send it today please."),
            ("Use the old draft, actually use the new draft for review", "Use the new draft for review."),
            ("Meet in the lobby, sorry meet at the entrance today", "Meet at the entrance today."),
            ("Meet in May, actually meet in June", "Meet in June."),
            ("Meet at 3, no wait, at 4", "Meet at 4."),
            ("Put it on the, put it in the box", "Put it on the, put it in the box.")
        ] { #expect(project(input, output).text == output, "\(input)") }
    }
    @Test func unsafeRoundFourOmissionsRestoreContent() {
        for (input, output, retained) in [
            ("Don't email Sam, I mean email Bob.", "Email Bob.", "Don't email Sam"),
            ("The client liked the demo, actually the client signed 50 seats", "The client signed 50 seats.", "client liked the demo"),
            ("Send 5 copies to Bob, actually send copies to Alice", "Send copies to Alice.", "5 copies to Bob"),
            ("Put it on the table, put it away", "Put it away.", "on the table"),
            ("Turn right on Main", "Turn on Main.", "right"),
            ("I like the plan", "I the plan.", "like"),
            ("What kind of car", "What car?", "kind of")
        ] { #expect(project(input, output).text.contains(retained), "\(input)") }
    }
    @Test func remainingRoundFourPairsAndCorpus() throws {
        #expect(project("So, um, I think, like, we should go", "I think we should go.").text == "I think we should go.")
        #expect(project("It was, kind of, a mess", "It was a mess.").text == "It was a mess.")
        let chained = "send old actually send new actually send final um uh erm hmm um uh erm hmm report to team today please"
        let projected = project(chained, "Send final report to team today please.")
        #expect(projected.text.contains("um uh erm hmm um uh erm hmm"))
        #expect(projected.verdicts["accepted:retracted"] == 1)
        for item in try SmartCleanupCase.load() where [46, 57, 58, 59].contains(item.id) {
            for level in [CleanupLevel.light, .medium] {
                #expect(project(item.raw, item.modelExpected(level), level: level).text == item.modelExpected(level), "corpus \(item.id) \(level)")
            }
        }
    }

    @Test func listsArticlesAndProtectedCase() {
        #expect(project("milk eggs", "- milk\n- eggs").text == "- Milk\n- Eggs")
        #expect(project("milk eggs", "1. milk\n2. eggs").text == "- Milk\n- Eggs")
        #expect(project("send report today", "Send the report today.", level: .medium).text == "Send the report today.")
        #expect(project("send report today", "Send the report today.").text == "Send report today.")
        #expect(project("use US today", "Use us today.").text == "Use US today.")
        #expect(AlignmentProjection.apply(input: "send to dArcy", output: "Send to Darcy.", level: .light, contextNames: ["dArcy"]).text == "Send to dArcy.")
    }
    @Test func capsLargestSpansAndBounds() {
        let result = project("Um uh erm hmm, send report um uh erm hmm, today please", "Send report today please.")
        #expect(result.verdicts["restored:deletion-cap"] == 1)
        #expect(result.verdicts["accepted:hesitation"] == 1)
        #expect(project("send report", String(repeating: "word ", count: 1300)).text == "send report")
    }
    @Test func adjacentCueAndHistoryCounts() async {
        #expect(project("Send old actually send new", "Actually send new.").text == "Send new.")
        let outcome = await FoundationModelsCleaner(model: FakeCleanupModel(.reply("Send the report today.")))
            .cleanDetailed("Um, send the full report today", level: .light, deterministicText: "Um, send the full report today")
        #expect(outcome.candidate == "Send the report today.")
        #expect(outcome.spanVerdicts["accepted:hesitation"] == 1)
        var entry = HistoryEntry(timestamp: Date(), raw: "", final: "", outcome: .inserted)
        var content = HistoryContent()
        content.cleanupCandidate = outcome.candidate; content.cleanupSpanVerdicts = outcome.spanVerdicts
        content.attach(to: &entry)
        #expect(entry.cleanupSpanVerdicts == outcome.spanVerdicts)
        let decoded = try? JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded?.cleanupSpanVerdicts == outcome.spanVerdicts)
        var refused = HistoryEntry(outcome: .blockedBySecureInput)
        content.attach(to: &refused)
        #expect(refused.cleanupSpanVerdicts == nil && refused.cleanupCandidate == nil)
    }

    @Test func projectionWith120FillerSpansUnder100msDebug() {
        let input = Array(repeating: "um send the report today", count: 120).joined(separator: "\n")
        let output = Array(repeating: "Send the report today", count: 120).joined(separator: "\n")
        _ = project(input, output)
        let clock = ContinuousClock(), start = clock.now
        let result = project(input, output)
        let elapsed = durationMs(clock.now - start)
        print("PROJECTION 600 tokens / 120 filler spans debug: \(elapsed) ms")
        #expect(result.verdicts["accepted:hesitation"] == 120)
        #expect(elapsed <= 100)
    }

    @Test func projectionWith100RetractionsUnder100msDebug() {
        let input = Array(repeating: "send old actually send new today", count: 100).joined(separator: "\n")
        let output = Array(repeating: "send new today", count: 100).joined(separator: "\n")
        _ = project(input, output)
        let clock = ContinuousClock(), start = clock.now
        let result = project(input, output)
        let elapsed = durationMs(clock.now - start)
        print("PROJECTION 600 tokens / 100 retractions debug: \(elapsed) ms")
        #expect(result.verdicts["accepted:retracted"] == 100)
        #expect(elapsed <= 100)
    }

    @Test func projection600TokensUnder100msDebug() {
        let input = (0..<600).map { "word\($0)" }.joined(separator: " ")
        _ = project(input, "Preface " + input + ".")
        let clock = ContinuousClock(), start = clock.now
        let result = project(input, "Preface " + input + ".")
        let elapsed = durationMs(clock.now - start)
        print("PROJECTION 600 tokens debug: \(elapsed) ms")
        #expect(result.text.hasSuffix("word599."))
        #expect(elapsed <= 100)
    }
}

@Suite(.serialized) struct ProjectionLatencyBenchmarkTests {
    @Test(.enabled(if: AppEnvironment.flag("LATENCY_BENCH"), "set WISPRLOCAL_LATENCY_BENCH=1"), arguments: ["identity", "filler", "retraction", "lcs"])
    func strict600TokenBudgets(_ workload: String) {
        let input: String, output: String
        switch workload {
        case "filler":
            input = Array(repeating: "um send the report today", count: 120).joined(separator: "\n")
            output = Array(repeating: "Send the report today", count: 120).joined(separator: "\n")
        case "retraction":
            input = Array(repeating: "send old actually send new today", count: 100).joined(separator: "\n")
            output = Array(repeating: "send new today", count: 100).joined(separator: "\n")
        default:
            input = (0..<600).map { "word\($0)" }.joined(separator: " ")
            output = (workload == "lcs" ? "Preface " : "") + input + "."
        }
        _ = AlignmentProjection.apply(input: input, output: output, level: .medium)
        let start = ContinuousClock.now
        _ = AlignmentProjection.apply(input: input, output: output, level: .medium)
        let elapsed = durationMs(ContinuousClock.now - start)
        print("PROJECTION STRICT \(workload): \(elapsed) ms")
        #expect(elapsed < (workload == "identity" ? 5 : 10))
    }
}
