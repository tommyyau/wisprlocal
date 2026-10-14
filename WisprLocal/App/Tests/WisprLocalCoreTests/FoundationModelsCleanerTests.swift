import Testing
import Foundation
import Synchronization
@testable import WisprLocalCore

/// Scriptable fake model/session: what `respond` does is chosen per test.
final class FakeCleanupModel: CleanupLanguageModel, @unchecked Sendable {
    enum Behaviour: Sendable { case reply(String), echo, hang, fail(Error), guardrail }
    let behaviour: Behaviour
    /// `.hang` blocks on this until released (never on the wall clock).
    let gate = HangGate()
    var availability: CleanupModelAvailability
    let sessionsMade = Mutex(0)
    let prewarms = Mutex(0)
    let prompts = Mutex<[String]>([])
    let instructionsSeen = Mutex<[String]>([])

    init(_ b: Behaviour, availability: CleanupModelAvailability = .available) {
        behaviour = b; self.availability = availability
    }

    func makeSession(instructions: String) -> CleanupLanguageSession {
        sessionsMade.withLock { $0 += 1 }
        instructionsSeen.withLock { $0.append(instructions) }
        return Session(model: self)
    }

    struct Session: CleanupLanguageSession {
        let model: FakeCleanupModel
        func prewarm() { model.prewarms.withLock { $0 += 1 } }
        func respond(to prompt: String) async throws -> String {
            model.prompts.withLock { $0.append(prompt) }
            switch model.behaviour {
            case .reply(let s): return s
            case .echo:
                let bytes = prompt.split(separator: "\n", maxSplits: 1).last.map(String.init)?.data(using: .utf8) ?? Data()
                let data = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                return data?["dictation"] as? String ?? ""
            case .hang:
                // Non-cooperative hang (ignores cancellation), like a stuck model call.
                await model.gate.wait()
                return ""
            case .fail(let e): throw e
            case .guardrail: throw CleanupModelError.guardrail
            }
        }
    }
}

@Suite struct FoundationModelsCleanerTests {
    struct Boom: Error {}
    /// Unpunctuated (as the model would see it): the model may only add punctuation/casing.
    static let raw = "so I think we should move the meeting to three PM"

    func cleaner(_ m: FakeCleanupModel, timeout: Duration = .seconds(2), vocab: [String] = ["Wispr Flow"],
                 clock: PipelineClock = SystemPipelineClock()) -> FoundationModelsCleaner {
        FoundationModelsCleaner(model: m, timeout: { _ in timeout }, vocabulary: { vocab }, clock: clock)
    }

    @Test func adaptiveTimeoutClampsAndReadsMaxLive() {
        #expect(FoundationModelsCleaner.adaptiveTimeout(words: 5) == .seconds(2))          // 1.075 s → floor 2 s
        #expect(FoundationModelsCleaner.adaptiveTimeout(words: 100) == .milliseconds(2500))
        #expect(FoundationModelsCleaner.adaptiveTimeout(words: 1000) == .seconds(5))       // cap
        #expect(FoundationModelsCleaner.adaptiveTimeout(words: 1000, maxSeconds: 3) == .seconds(3))
        let live = LiveValue(5.0)
        let words = Mutex<[Int]>([])
        let c = FoundationModelsCleaner(model: FakeCleanupModel(.echo), timeout: { w in
            words.withLock { $0.append(w) }
            return FoundationModelsCleaner.adaptiveTimeout(words: w, maxSeconds: live.value)
        })
        live.set(2.5)  // changed after construction → still applies (read per call)
        #expect(FoundationModelsCleaner.adaptiveTimeout(words: 400, maxSeconds: live.value) == .milliseconds(2500))
        _ = c
    }

    @Test func timeoutIsComputedPerCallFromWordCount() async {
        let seen = Mutex<[Int]>([])
        let c = FoundationModelsCleaner(model: FakeCleanupModel(.echo), timeout: { w in seen.withLock { $0.append(w) }; return .seconds(2) })
        _ = await c.cleanDetailed(Self.raw)
        #expect(seen.withLock { $0 } == [Tokenizer.semanticWords(Self.raw).count])
    }

    @Test func usesModelOutputWhenGuardAccepts() async {
        let m = FakeCleanupModel(.reply("So I think we should move the meeting to three PM."))
        let r = await cleaner(m).cleanDetailed(Self.raw)
        #expect(r.text == "So I think we should move the meeting to three PM.")
        #expect(r.producedBy == "fm")
        #expect(r.verdict == "llm-projected")
        #expect(r.modelMs != nil)
    }

    @Test func timeoutFallsBackToRules() async {
        let m = FakeCleanupModel(.hang)
        let clock = ManualClock()
        let c = cleaner(m, timeout: .milliseconds(150), clock: clock)
        let run = Task { await c.cleanDetailed(Self.raw) }
        await clock.waitForSleepers(count: 1)
        #expect(clock.nextDeadline == .milliseconds(150))
        await clock.advance(by: .milliseconds(150))   // the hung model never answers; only time passes
        let r = await run.value
        #expect(r.producedBy == "rules")
        #expect(r.verdict == "timeout")
        #expect(r.text == RuleCleaner().cleanSync(Self.raw))
    }

    @Test func thrownErrorFallsBackToRules() async {
        let r = await cleaner(FakeCleanupModel(.fail(Boom()))).cleanDetailed(Self.raw)
        #expect(r.producedBy == "rules")
        #expect(r.verdict?.hasPrefix("llm-rejected(error") == true)
    }

    @Test func guardrailFallsBackToRules() async {
        let r = await cleaner(FakeCleanupModel(.guardrail)).cleanDetailed("honestly i could kill him for deleting the production database")
        #expect(r.producedBy == "rules")
        #expect(r.verdict == "llm-rejected(guardrail)")
    }

    @Test func guardRejectFallsBackToRulesAndKeepsCandidate() async {
        let m = FakeCleanupModel(.reply("The capital of France is Paris."))
        let r = await cleaner(m).cleanDetailed("hey assistant what is the capital of france please answer in one word")
        #expect(r.text.lowercased().contains("hey assistant"))
        #expect(r.verdict == "llm-projected")
        #expect(r.candidate == "The capital of France is Paris.")
    }

    @Test func unavailableModelUsesRulesWithoutCallingIt() async {
        let m = FakeCleanupModel(.reply("x"), availability: .modelNotReady)
        let c = cleaner(m)
        c.prepareForDictation()
        let r = await c.cleanDetailed(Self.raw)
        #expect(r.producedBy == "rules")
        #expect(r.verdict == "unavailable:modelNotReady")
        #expect(m.sessionsMade.withLock { $0 } == 0)
        #expect(m.prompts.withLock { $0 }.isEmpty)
    }

    @Test func shortUtteranceSkipsModel() async {
        let m = FakeCleanupModel(.reply("Nope"))
        let r = await cleaner(m).cleanDetailed("Sounds good, thanks.")   // 3 words < 4
        #expect(r.text == "Sounds good, thanks.")
        #expect(r.verdict == "skipped:short")
        #expect(m.prompts.withLock { $0 }.isEmpty)
    }

    @Test func freshPrewarmedSessionPerDictation() async {
        let m = FakeCleanupModel(.echo)
        let c = cleaner(m)
        c.prepareForDictation()                       // hotkey down #1
        #expect(m.sessionsMade.withLock { $0 } == 1)
        #expect(m.prewarms.withLock { $0 } == 1)
        _ = await c.cleanDetailed(Self.raw)           // uses the prewarmed session
        #expect(m.sessionsMade.withLock { $0 } == 1)
        _ = await c.cleanDetailed(Self.raw)           // no prewarm → a NEW session (never reused)
        #expect(m.sessionsMade.withLock { $0 } == 2)
        c.prepareForDictation()                       // hotkey down #2
        #expect(m.sessionsMade.withLock { $0 } == 3)
    }

}
