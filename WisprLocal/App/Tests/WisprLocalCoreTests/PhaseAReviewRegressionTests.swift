import Foundation
import Testing
@testable import WisprLocalCore

@Suite struct PhaseAReviewRegressionTests {
    @Test func M1NegationAndDirectionSafety() {
        let failures = [
            ("I do not agree with the 5 proposals", "I do agree with the 5 proposals"),
            ("I can't come", "I come"), ("I will definitely come", "I will not come"),
            ("coffee with sugar", "coffee without sugar"), ("meet before lunch", "meet after lunch"),
        ]
        for level in [CleanupLevel.light, .medium] {
            for (raw, candidate) in failures { #expect(projectionKeys(raw, candidate, level: level) == PlanTokens(raw).keys) }
            for negator in ["not", "no", "never", "nor", "none", "nothing", "nobody", "neither", "without", "cannot", "won't", "isn't", "don't"] {
                #expect(projectionKeys("We said \(negator) about the report today", "We said about the report today", level: level) == PlanTokens("We said \(negator) about the report today").keys)
            }
            for (a, b) in [("above", "below"), ("in", "out"), ("on", "off"), ("up", "down")] {
                #expect(projectionKeys("Please move \(a) today", "Please move \(b) today", level: level) == PlanTokens("Please move \(a) today").keys)
            }
        }
    }

    @Test func M2ExemptionsRequireLocalEvidence() {
        for level in [CleanupLevel.light, .medium] {
            for (raw, output) in [
                ("Hi Bob, sorry for the delay. The invoice total is 450 dollars.", "The invoice total is 450 dollars."),
                ("Thanks, no rush. Please send the 5 contracts to legal and copy Jane.", "Please send the 5 contracts."),
                ("I meant to call you and discuss all the project details today", "Discuss project details today"),
                ("let's make that happen and send the report to the team today", "Send report today"),
                ("At 3, no, 4. Please send the report to legal and copy Jane today", "At 4. Send report today"),
            ] { #expect(projectionKeys(raw, output, level: level) == PlanTokens(raw).keys) }
            #expect(projectionKeys("At 3, no, 4 please", "At 4 please", level: level) == PlanTokens("At 3, no, 4 please").keys)
        }
    }

    @Test func M4DiscardNeedsSubstantivePrefix() {
        for raw in ["Yes, cancel that.", "Okay, never mind.", "Oh, never mind, found it.", "Never mind, I'll do it myself.", "cancel that."] {
            #expect(DiscardCommand.apply(raw) == raw)
        }
        #expect(DiscardCommand.apply("Keep this. Old clause, scratch that, replacement.") == "Keep this. Old clause, scratch that, replacement.")
        #expect(DiscardCommand.apply("Send the report, cancel that.") == "")
        #expect(DiscardCommand.apply("Send the report. Cancel that.") == "")
        #expect(DiscardCommand.apply("Send the report. Cancel that. Call the team. Scratch that. Keep the invoice.") == "Keep the invoice.")
    }

    @Test func M5PunctuationNounsAndUneditedRanges() {
        for raw in ["The notice period is 30 days", "The grace period is 30 days", "The billing period is 30 days", "The time period is 30 days", "the Victorian period", "We use the Oxford comma", "use comma separated values", "use comma delimited values", "a big question mark", "make a quick dash to the store", "That's it. Period.", "5 - 3", "e.g. the"] {
            #expect(SpokenPunctuation.apply(raw) == raw, "\(raw)")
        }
        #expect(SpokenPunctuation.apply("Hello comma question mark") == "Hello,?")
        #expect(SpokenPunctuation.apply("Keep Question Mark", vocabulary: ["Question Mark"]) == "Keep Question Mark")
        #expect(SpokenPunctuation.apply("a huge question mark") == "a huge question mark")
        #expect(SpokenPunctuation.apply("Open Dash today comma Please", vocabulary: ["Dash"]) == "Open Dash today, Please")
        #expect(SpokenPunctuation.apply("Calculate 5 - 3 and read e.g. the manual is ready comma Please") == "Calculate 5 - 3 and read e.g. the manual is ready, Please")
    }

    @Test func m1GrammaticalRepeatsSurvive() {
        for raw in ["What it is is a scam", "Will will be there", "the food was so so", "check in in five minutes", "turn it on on Monday", "I think Will will be there"] { #expect(StutterRemover.apply(raw) == raw) }
    }

    @Test func m2VerbatimKeepsPreviousRules() {
        #expect(RuleCleaner().cleanSync("Send the old report. Scratch that. Send the new report.", level: .verbatim) == "Send the new report.")
        #expect(RuleCleaner().cleanSync("We should, you know, send it.", level: .verbatim) == "We should send it.")
        #expect(RuleCleaner().cleanSync("We should, like, send it.", level: .verbatim) == "We should send it.")
    }

    @Test func m3ProtectedCapitalization() {
        for word in ["US", "May", "Polish", "iOS"] {
            for level in [CleanupLevel.light, .medium] {
                #expect(projectionKeys("Please keep \(word) here today", "Please keep \(word.lowercased()) here today", level: level) == PlanTokens("Please keep \(word) here today").keys)
            }
        }
    }

    @Test func m3InflectionCannotEraseMidSentenceCapitalization() {
        #expect(projectionKeys("Please keep Polish here today", "Please keep polished here today", level: .medium) == PlanTokens("Please keep Polish here today").keys)
    }

    @Test func m4SymbolsAndNumberedMarkers() {
        for level in [CleanupLevel.light, .medium] {
            #expect(projectionKeys("meet me 5", "meet me @ 5", level: level) == PlanTokens("meet me 5").keys)
            for symbol in "&+=<>@#*/^~|" { #expect(projectionKeys("meet me at 5", "meet me \(symbol) at 5", level: level) == PlanTokens("meet me at 5").keys) }
            #expect(projectionKeys("buy milk\nbuy bread", "7. buy milk\n99. buy bread", level: level) == PlanTokens("buy milk\nbuy bread").keys)
            #expect(projectionKeys("7. buy milk\n99. buy bread", "buy milk\nbuy bread", level: level) == PlanTokens("7. buy milk\n99. buy bread").keys)
            #expect(projectionKeys("buy milk\nbuy bread", "1. Buy milk\n2. Buy bread", level: level) == ["buy", "milk", "buy", "bread"])
        }
    }

    @Test func m5ShortAndOverLimitSkipModel() async {
        let model = FakeCleanupModel(.echo)
        let cleaner = FoundationModelsCleaner(model: model)
        #expect(await cleaner.cleanDetailed("hello", level: .light).verdict == "skipped:short")
        #expect(await cleaner.cleanDetailed(String(repeating: "word ", count: 601), level: .medium).verdict == "skipped:length-limit")
        #expect(model.prompts.withLock { $0.isEmpty })
        _ = await cleaner.cleanDetailed("um hello", level: .light)
        #expect(model.prompts.withLock { $0.count } == 1)
    }
}

@MainActor @Suite(.serialized) struct PhaseAReviewPipelineTests {
    private func dictate(_ p: DictationPipeline) async {
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
    }

    @Test func M7ModelCannotDropNegation() async {
        let (e, p) = await makeEnv(text: "I do not agree with the 5 proposals")
        p.cleaner = FoundationModelsCleaner(model: FakeCleanupModel(.reply("I do agree with the 5 proposals")))
        await dictate(p)
        #expect(e.inserter.inserted == ["I do not agree with the 5 proposals"])
        #expect(e.history.entries.last?.cleanupVerdict == "llm-projected")
    }

    @Test func m2AIOptionOffKeepsLightRules() async {
        let (e, p) = await makeEnv(text: "I I need the report today")
        let model = FakeCleanupModel(.reply("Invented text"))
        p.cleaner = FoundationModelsCleaner(model: model)
        p.useOnDeviceAI = { false }
        await dictate(p)
        #expect(e.inserter.inserted == ["I need the report today"])
        #expect(model.prompts.withLock { $0.isEmpty })
        #expect(model.prewarms.withLock { $0 } == 0)
    }

    @Test func m3ContextCasingPreservedFromInput() async {
        let model = FakeCleanupModel(.reply("dArcy will send the report today."))
        let context = CleanupContext(spellings: ["dArcy"])
        let outcome = await FoundationModelsCleaner(model: model).cleanDetailed("dArcy will send the report today", level: .light, context: context)
        #expect(outcome.verdict == "llm-projected")
        #expect(outcome.text == "dArcy will send the report today.")
    }

    @Test func N1RulesOnlyNeverReapplyScreenSpellings() async {
        for raw in ["it works", "send it to us", "grace period", "this or that", "say no please"] {
            let (env, pipeline) = await makeEnv(text: raw)
            pipeline.contextProvider = PipelineOrderTests.FixedProvider(ContextSnapshot(candidates: ["IT", "US", "OR", "NO", "Grace"].map { ContextCandidate($0, kind: .name) }, isCodeApp: false))
            pipeline.useOnDeviceAI = { false }
            pipeline.styleFor = { _ in nil }
            await dictate(pipeline)
            #expect(env.inserter.inserted == [raw])
        }
    }

    @Test func m5CleanupUsesSeparateCaretReadAndVerbatimSkipsIt() async throws {
        let (e, p) = await makeEnv(text: "Please send the report today")
        let larger = FakeCaretReader()
        larger.context = CaretContext(preceding: String(repeating: "x", count: 300), elementID: 1)
        p.cleanupContextReader = larger
        let model = FakeCleanupModel(.echo)
        p.cleaner = FoundationModelsCleaner(model: model)
        await dictate(p)
        #expect(e.caret.reads.count == 1 && larger.reads.count == 1)
        let prompt = try #require(model.prompts.withLock { $0.first })
        #expect(prompt.contains(String(repeating: "x", count: 300)))
        p.cleanupLevel = { .verbatim }
        await dictate(p)
        #expect(e.caret.reads.count == 2 && larger.reads.count == 1)
    }

    @Test func m6VerbatimControlsAreScoped() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WisprLocal/Settings/WritingSettingsSection.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        let scope = try #require(source.range(of: "if store.cleanupLevel != .verbatim"))
        let end = try #require(source.range(of: "SettingRow(title: \"Per-app styles\"", range: scope.upperBound..<source.endIndex))
        let relevant = source[scope.lowerBound..<end.lowerBound]
        for title in ["Spoken punctuation", "Use on-device AI", "Fix “actually” corrections"] { #expect(relevant.contains(title)) }
    }

    @Test func m7UndoUsesContextVocabulary() async {
        let (e, p) = await makeEnv(text: "Use Sol six at 3, no wait, 4.")
        p.contextProvider = PipelineOrderTests.FixedProvider(ContextSnapshot(candidates: [ContextCandidate("Sol", kind: .name)], isCodeApp: false))
        p.backtrackEnabled = { true }
        await dictate(p)
        #expect(e.inserter.inserted == ["Use Sol 6 at 4."])
        #expect(p.pendingCorrection?.original == "Use Sol 6 at 3, no wait, 4.")
    }
}
