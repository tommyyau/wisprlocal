import Testing
@testable import WisprLocalCore

@MainActor @Suite struct SpokenCommaPipelineTests {
    @Test func conversionLeavesUnrelatedPunctuationAndNounsAlone() {
        #expect(SpokenPunctuation.apply("Keep,, old comma next") == "Keep,, old, next")
        #expect(SpokenPunctuation.apply("Use a comma, please.") == "Use a comma, please.")
        #expect(SpokenPunctuation.apply("Hello comma,, comma world") == "Hello, world")
    }

    /// Recognition can put punctuation on both sides of a spoken command. Cover the
    /// rule floor, model projection, style pass and actual insertion destination together.
    @Test(arguments: [CleanupLevel.light, .medium], [false, true])
    func spokenCommasInsertOnce(level: CleanupLevel, useAI: Bool) async throws {
        let expected = "Review the draft, update the chart, and send the summary."
        for raw in [
            "Review the draft, comma, update the chart, comma, and send the summary.",
            "Review the draft comma, update the chart, comma and send the summary.",
            "Review the draft comma comma update the chart comma and send the summary."
        ] {
            let (environment, pipeline) = await makeEnv(text: raw)
            let model = FakeCleanupModel(.reply(expected))
            pipeline.cleaner = FoundationModelsCleaner(model: model)
            pipeline.cleanupLevel = { level }
            pipeline.useOnDeviceAI = { useAI }
            pipeline.styleFor = { _ in .casual }
            pipeline.handle(.startRecording)
            pipeline.handle(.commitRecording)
            await pipeline.drain()

            // Casual style omits the final stop, but keeps both list separators.
            #expect(environment.inserter.inserted == [String(expected.dropLast())])
            let history = try #require(environment.history.entries.last)
            #expect(history.raw == raw)
            #expect(!history.final.contains(",,"))
            if useAI {
                #expect(history.cleanupVerdict == "llm-projected")
                let prompt = try #require(model.prompts.withLock { $0.first })
                #expect(prompt.contains(expected))
                #expect(!prompt.contains(",,"))
            } else {
                #expect(model.prompts.withLock { $0.isEmpty })
            }
        }
    }
}
