import Testing
import Foundation
@testable import WisprLocalCore

/// R9: the user's own ⌘Z of a select-and-dictate is not a correction.
@Suite struct UndoneInsertionTests {
    func snap(_ t: String) -> FieldSnapshot { FieldSnapshot(elementID: 7, text: t) }

    /// "Shaun" was selected and dictated over as "Sean"; ⌘Z puts "Shaun" back.
    @Test func undoingTheInsertionStopsTheWatch() {
        var s = CorrectionWatchSession(inserted: "Sean", elementID: 7, replaced: "Shaun")
        #expect(s.observe(snap("Thanks Sean, see you"), elapsed: 1) == .keepWatching)        // baseline
        #expect(s.observe(snap("Thanks Shaun, see you"), elapsed: 2) == .stop)               // reverted
        #expect(s.observe(snap("Thanks Shaun, see you"), elapsed: 3) == .stop)
    }

    /// Without knowing what the paste replaced, the same edit reads as a correction — which is
    /// exactly what the snapshot prevents.
    @Test func withoutTheSnapshotItWouldBeLearned() {
        var s = CorrectionWatchSession(inserted: "Sean", elementID: 7, replaced: nil)
        _ = s.observe(snap("Thanks Sean, see you"), elapsed: 1)
        var step = CorrectionWatchSession.Step.keepWatching
        for t in 2...4 { step = s.observe(snap("Thanks Shaun, see you"), elapsed: Double(t)) }
        #expect(step == .found(Correction(misheard: "Sean", correct: "Shaun")))
    }

    /// Undo with nothing selected (the paste is simply removed), and a join space undone too.
    @Test func undoWithoutASelectionAndWithAJoinSpace() {
        var a = CorrectionWatchSession(inserted: " kuber netties", elementID: 7, replaced: "")
        _ = a.observe(snap("we ship kuber netties"), elapsed: 1)
        #expect(a.observe(snap("we ship"), elapsed: 2) == .stop)
        var b = CorrectionWatchSession(inserted: " Sean", elementID: 7, replaced: "Shaun")
        _ = b.observe(snap("Thanks Sean"), elapsed: 1)
        #expect(b.observe(snap("Thanks  Shaun"), elapsed: 2) == .stop)
    }

    /// A real correction over a selection is still found.
    @Test func aRealCorrectionAfterSelectAndDictateIsStillFound() {
        var s = CorrectionWatchSession(inserted: "kuber netties", elementID: 7, replaced: "Docker")
        _ = s.observe(snap("we ship kuber netties"), elapsed: 1)
        var step = CorrectionWatchSession.Step.keepWatching
        for t in 2...4 { step = s.observe(snap("we ship Kubernetes"), elapsed: Double(t)) }
        #expect(step == .found(Correction(misheard: "kuber netties", correct: "Kubernetes")))
    }

    /// The pipeline hands the watcher what the paste replaced (the caret reader's selection).
    @MainActor @Test func thePipelineReportsTheReplacedSelection() async {
        let (e, p) = await makeEnv(text: "Sean")
        e.caret.context = CaretContext(preceding: "Thanks ", elementID: 1, selectedText: "Shaun")
        var reported: [InsertedDictation] = []
        p.onInserted = { reported.append($0) }
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(reported.first?.replaced == "Shaun")
    }
}

/// S1: the watcher reads only a bounded window, off the main actor, never in excluded apps.
@MainActor @Suite struct WatcherScopeTests {
    static let ins = "ship kuber netties"

    func dictation(_ bundleID: String?, pid: Int32 = 1) -> InsertedDictation {
        InsertedDictation(pid: pid, bundleID: bundleID, elementID: 3, text: Self.ins, axReadable: true)
    }

    @Test(arguments: ["com.1password.1password", "com.apple.keychainaccess", "com.bitwarden.desktop", "COM.APPLE.PASSWORDS"])
    func passwordManagersAreNeverWatched(_ bundleID: String) {
        let reader = FakeFieldReader()
        let w = CorrectionWatcher(reader: reader, clock: ManualClock(), policy: .defaults)
        w.watch(dictation(bundleID)) { _ in }
        #expect(!w.isWatching)
        #expect(reader.reads == 0)
    }

    @Test func bankingAppsAreNeverWatched() {
        let reader = FakeFieldReader()
        let policy = AppReadPolicy(denylist: { [] }, appCategory: { _ in ContextPolicy.financeCategory })
        let w = CorrectionWatcher(reader: reader, clock: ManualClock(), policy: policy)
        w.watch(dictation("com.example.bank")) { _ in }
        #expect(!w.isWatching)
        #expect(reader.reads == 0)
    }

    /// The SAME policy as context names: an app the user adds to "Never read" is not watched.
    @Test func theUsersNeverReadListAppliesToo() {
        let defaults = UserDefaults(suiteName: "watcher-scope-\(UUID().uuidString)")!
        let settings = SmartDictionarySettings(defaults: defaults)
        let provider = ContextProvider(settings: settings, appCategory: { _ in nil })
        let reader = FakeFieldReader()
        let w = CorrectionWatcher(reader: reader, clock: ManualClock(), policy: provider.readPolicy)
        w.watch(dictation("com.example.diary")) { _ in }
        #expect(w.isWatching)
        w.cancel()
        settings.deny("com.example.diary")
        w.watch(dictation("com.example.diary")) { _ in }
        #expect(!w.isWatching)
    }

    @Test func urlAndSecureFieldsStopAtOnce() {
        var a = CorrectionWatchSession(inserted: Self.ins, elementID: 3)
        #expect(a.observe(FieldSnapshot(elementID: 3, text: "", isExcluded: true), elapsed: 1) == .stop)
        var b = CorrectionWatchSession(inserted: "example.com/kuber", elementID: 3)
        #expect(b.observe(FieldSnapshot(elementID: 3, text: "https://example.com/kuber"), elapsed: 1) == .stop)
    }

    /// First read: the inserted text + 200 characters on each side of the caret; then the same
    /// span, following the field's growth. Every read happens off the main thread.
    @Test func readsABoundedWindowOffTheMainThread() async {
        let reader = FakeFieldReader()
        reader.script = [FieldSnapshot(elementID: 3, text: "we ship kuber netties", windowLocation: 500, totalLength: 900),
                         FieldSnapshot(elementID: 3, text: "we ship Kubernetes", windowLocation: 500, totalLength: 897)]
        let clock = ManualClock()
        let w = CorrectionWatcher(reader: reader, clock: clock, policy: AppReadPolicy(denylist: { [] }, appCategory: { _ in nil }))
        var found: [Correction] = []
        w.watch(dictation("com.apple.TextEdit")) { found.append($0) }
        for _ in 0..<4 {
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: CorrectionWatchSession.pollInterval)
        }
        await w.waitUntilFinished()
        #expect(found == [Correction(misheard: "kuber netties", correct: "Kubernetes")])
        let m = CorrectionWatchSession.margin
        #expect(reader.windows.first == .aroundCaret(before: Self.ins.utf16.count + m, after: m))
        #expect(reader.windows.dropFirst().allSatisfy { $0 == .tracking(location: 500, length: 21, baseTotal: 900) })
        #expect(reader.onMain.count == 4 && reader.onMain.allSatisfy { !$0 })
    }

    @Test func windowRangeMath() {
        typealias R = AXFocusedFieldReader
        // Caret at 1,000 in a 5,000-char field: 218 + 200 before, 200 after.
        #expect(R.range(.aroundCaret(before: 218, after: 200), count: 5_000, caret: 1_000) == (782, 418))
        // Clamped at both ends.
        #expect(R.range(.aroundCaret(before: 218, after: 200), count: 50, caret: 50) == (0, 50))
        // Tracking: the field grew by 7 since the baseline → read 7 more.
        #expect(R.range(.tracking(location: 782, length: 418, baseTotal: 5_000), count: 5_007, caret: 0) == (782, 425))
        // ...or shrank (the user deleted 10), and never past the end of the field.
        #expect(R.range(.tracking(location: 782, length: 418, baseTotal: 5_000), count: 4_990, caret: 0) == (782, 408))
        #expect(R.range(.tracking(location: 782, length: 418, baseTotal: 5_000), count: 800, caret: 0) == (782, 0))
    }

    @Test func pollsEverySecondForFifteenSeconds() {
        #expect(CorrectionWatchSession.pollInterval == .seconds(1))
        #expect(CorrectionWatchSession.maxDuration == 15)
        #expect(CorrectionWatchSession.margin == 200)
    }
}
