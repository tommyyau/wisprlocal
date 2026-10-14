import Testing
import Foundation
@testable import WisprLocalCore

/// Integration of the three feature tracks in ONE pipeline (`DictationPipeline` header comment,
/// DESIGN.md › "Dictation pipeline order"): the post-processing order, Esc reaching every new
/// stage, and backtrack Undo vs the learning watcher vs auto-send.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PipelineOrderTests {
    final class FixedProvider: ContextProviding {
        let snap: ContextSnapshot
        init(_ s: ContextSnapshot) { snap = s }
        func snapshot(for target: FrontmostApp) -> ContextSnapshot? { snap }
    }

    /// An "AI formatting" cleaner that waits until the test lets it finish.
    final class GatedModel: CleanupLanguageModel, CleanupLanguageSession, @unchecked Sendable {
        var availability: CleanupModelAvailability { .available }
        func makeSession(instructions: String) -> CleanupLanguageSession { self }
        func prewarm() {}
        @MainActor var entered = false
        @MainActor private var waiter: CheckedContinuation<Void, Never>?
        @MainActor private var released = false
        func respond(to prompt: String) async throws -> String {
            await MainActor.run { entered = true }
            await waitForRelease()
            return "Coffee at 3."
        }
        @MainActor private func waitForRelease() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }
        @MainActor func release() { released = true; waiter?.resume(); waiter = nil }
    }

    private func dictate(_ p: DictationPipeline) async {
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
    }

    /// Dictionary → hesitation → stutter → punctuation → numeric backtrack → FM →
    /// dictionary reapply → style. Uses explicit replacements so this order test does not
    /// depend on the separate system-spellchecker integration tests.
    @Test func stagesRunInTheDocumentedOrder() async throws {
        let dict = tempDictionary()
        var d = dict.dictionary
        d.addTerm("Kubernetes")
        d.addReplacement(from: "kuber netties", to: "Kubernetes")
        try dict.update(d)
        let (e, p) = await makeEnv(text: "Um I I ship kuber netties at 3, no wait, 4 period", dictionary: dict)
        let m = FakeCleanupModel(.reply("I ship Kubernetes at 4."))
        p.cleaner = FoundationModelsCleaner(model: m, vocabulary: { dict.dictionary.vocabulary })
        p.backtrackEnabled = { true }
        p.styleFor = { _ in .casual }
        await dictate(p)
        #expect(e.inserter.inserted == ["I ship Kubernetes at 4"])
        let prompt = try #require(m.prompts.withLock { $0.first })
        let json = try #require(prompt.split(separator: "\n", maxSplits: 1).last).data(using: .utf8)!
        let fields = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let dictation = try #require(fields["dictation"] as? String)
        #expect(PlanTokens(dictation).surfaces == ["I", "ship", "Kubernetes", "at", "4"])
        #expect(!prompt.contains("no wait") && !prompt.contains("kuber netties") && !prompt.contains("I I"))
        let h = try #require(e.history.entries.last)
        #expect(h.backtrackApplied == true && h.style == "casual" && h.cleanupVerdict == "llm-projected")
        #expect(p.pendingCorrection?.original == "I ship Kubernetes at 3, no wait, 4")
    }

    @Test func excludedContextNeverReachesModel() async throws {
        let (e, p) = await makeEnv(text: "Please send the report today")
        e.caret.context = CaretContext(preceding: "Private context name", elementID: 1)
        p.contextProvider = FixedProvider(ContextSnapshot(candidates: [ContextCandidate("SecretName", kind: .name)], isCodeApp: false))
        p.cleanupContextAllowed = { _ in false }
        let m = FakeCleanupModel(.reply("Please send the report today."))
        p.cleaner = FoundationModelsCleaner(model: m)
        await dictate(p)
        let prompt = try #require(m.prompts.withLock { $0.first })
        #expect(!prompt.contains("Private context") && !prompt.contains("SecretName"))
        #expect(e.history.entries.last?.final == "Please send the report today.")
    }

    @Test func caretContextAndNamesAreLocalBoundedHints() async throws {
        let (e, p) = await makeEnv(text: "Please send the report today")
        e.caret.context = CaretContext(preceding: String(repeating: "x", count: 450), elementID: 1)
        p.contextProvider = FixedProvider(ContextSnapshot(candidates: [ContextCandidate("Shaun", kind: .name)], isCodeApp: false))
        let m = FakeCleanupModel(.reply("Please send the report today."))
        p.cleaner = FoundationModelsCleaner(model: m)
        await dictate(p)
        let prompt = try #require(m.prompts.withLock { $0.first })
        #expect(prompt.contains("Shaun") && prompt.contains(String(repeating: "x", count: 300)))
        #expect(!prompt.contains(String(repeating: "x", count: 301)))
        #expect(e.history.entries.last?.cleanupVerdict == "llm-projected")
    }

    /// Esc while the (slow) AI formatter runs: nothing reaches backtrack, style, insert, auto-send
    /// or the learning watcher, and History records `cancelled` without text.
    @Test func escDuringAIFormattingStopsEveryLaterStage() async throws {
        let (e, p) = await makeEnv(text: "Coffee at 2, actually 3.")
        let fm = GatedModel()
        p.cleaner = FoundationModelsCleaner(model: fm)
        p.backtrackEnabled = { true }
        p.styleFor = { _ in .casual }
        p.autoSendRequested = { true }
        let spy = ReturnSpy(inserter: e.inserter)
        p.returnKey = spy
        p.autoSendDelay = .zero
        var watched = 0
        p.onInserted = { _ in watched += 1 }
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await waitForTest("cleaner entered") { fm.entered }
        #expect(p.cancelDictation())
        fm.release()
        await p.drain()
        #expect(e.inserter.inserted.isEmpty)
        #expect(spy.presses.isEmpty)
        #expect(watched == 0)
        #expect(p.pendingCorrection == nil)
        let h = try #require(e.history.entries.last)
        #expect(h.outcome == .cancelled)
        #expect(h.final.isEmpty && h.raw.isEmpty)
        #expect(h.backtrackApplied == nil)
        #expect(!e.notices.contains(PipelineNotice.corrected))
    }

    /// Esc while recording drops the context names read at the start (they never reach a job).
    @Test func escWhileRecordingDropsContextNames() async {
        let (e, p) = await makeEnv(text: "Thanks Sean.")
        p.contextProvider = FixedProvider(ContextSnapshot(candidates: [ContextCandidate("Shaun", kind: .name)], isCodeApp: false))
        p.handle(.startRecording)
        #expect(p.cancelDictation())
        p.contextProvider = nil
        await dictate(p)
        #expect(e.inserter.inserted == ["Thanks Sean."])
    }

    /// Backtrack Undo stops the learning watcher BEFORE ⌘Z, so our own re-paste of the words as
    /// spoken can never be read as a user correction (and learned).
    @Test func undoStopsTheLearningWatcherFirst() async throws {
        let (e, p) = await makeEnv(text: "Coffee at 2, actually 3.")
        p.backtrackEnabled = { true }
        p.undoSettle = .zero
        var events: [String] = []
        p.onInserted = { d in events.append("watch:\(d.text)") }
        p.onInsertionSuperseded = { events.append("stop watching") }
        p.postUndo = { events.append("⌘Z") }
        await dictate(p)
        #expect(events == ["watch:Coffee at 3."])
        #expect(await p.undoLastCorrection())
        #expect(events == ["watch:Coffee at 3.", "stop watching", "⌘Z"])
        #expect(e.inserter.inserted == ["Coffee at 3.", "Coffee at 2, actually 3."])
    }

    /// With the real watcher: after Undo the field holds the original words; nothing is found.
    @Test func undoneTextIsNeverLearned() async throws {
        let reader = FakeFieldReader()
        let clock = ManualClock()
        let watcher = CorrectionWatcher(reader: reader, clock: clock)
        let (e, p) = await makeEnv(text: "Ship it Friday, actually Monday.")
        p.backtrackEnabled = { true }
        p.undoSettle = .zero
        p.postUndo = {}
        var found: [Correction] = []
        p.onInserted = { d in
            var readable = d; readable.axReadable = true
            watcher.watch(readable) { found.append($0) }
        }
        p.onInsertionSuperseded = { watcher.cancel() }
        reader.script = [FieldSnapshot(elementID: 1, text: "Ship it Monday.")]
        await dictate(p)
        #expect(watcher.isWatching)
        reader.script = [FieldSnapshot(elementID: 1, text: "Ship it Friday, actually Monday.")]
        #expect(await p.undoLastCorrection())
        #expect(!watcher.isWatching)
        for _ in 0..<10 { await clock.advance(by: CorrectionWatchSession.pollInterval) }
        #expect(found.isEmpty)
        #expect(e.inserter.inserted.count == 2)
    }

    /// Auto-send after a backtrack: the message is sent, so there is no Undo offer (⌘Z would hit
    /// something else) and nothing to watch; Return comes after the paste.
    @Test func autoSendWithdrawsUndoAndWatching() async {
        let (e, p) = await makeEnv(text: "Coffee at 2, actually 3.")
        p.backtrackEnabled = { true }
        p.autoSendRequested = { true }
        let spy = ReturnSpy(inserter: e.inserter)
        p.returnKey = spy
        p.autoSendDelay = .zero
        var watched = 0
        p.onInserted = { _ in watched += 1 }
        await dictate(p)
        #expect(e.inserter.inserted == ["Coffee at 3."])
        #expect(spy.presses == [1])
        #expect(p.pendingCorrection == nil)
        #expect(!e.notices.contains(PipelineNotice.corrected))
        #expect(watched == 0)
    }

    /// Without auto-send the watcher starts only after the paste is posted.
    @Test func watcherStartsAfterThePaste() async {
        let (e, p) = await makeEnv(text: "Hello there.")
        var insertedAtWatch: Int?
        p.onInserted = { _ in insertedAtWatch = e.inserter.inserted.count }
        await dictate(p)
        #expect(insertedAtWatch == 1)
    }
}
