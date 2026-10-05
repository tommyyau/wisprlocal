import AppKit
import Observation
import WisprLocalCore

/// Owns the smart dictionary at runtime: settings, the opt-in context reader, the correction
/// watcher and the learner. Nothing it handles is logged; dictated text lives in memory only
/// (the watcher's ≤ 15 s session, the pending suggestion until the chip goes).
@MainActor
@Observable
final class SmartDictionaryController {
    let settings: SmartDictionarySettings
    @ObservationIgnored let learner: DictionaryLearner
    @ObservationIgnored let watcher: CorrectionWatcher
    @ObservationIgnored let contextProvider: ContextProvider
    /// The suggestion on the HUD right now (cleared when the chip goes).
    @ObservationIgnored private(set) var pending: Correction?
    /// Bumped whenever learning adds words (Dictionary's "Words learned" stat).
    private(set) var revision = 0
    /// Shows a HUD notice WITHOUT logging it (it can contain a dictionary word).
    @ObservationIgnored var showNotice: (String) -> Void = { _ in }
    @ObservationIgnored var dismissNotice: (String) -> Void = { _ in }

    init(dictionary: DictionaryStore, settings: SmartDictionarySettings = SmartDictionarySettings()) {
        self.settings = settings
        let learning = LearningStore(besideDictionary: dictionary.url)
        learner = DictionaryLearner(dictionary: dictionary, store: learning, mode: { settings.learnMode })
        contextProvider = ContextProvider(settings: settings)
        // One exclusion list for both readers (S1): what context names never read, the watcher never watches.
        watcher = CorrectionWatcher(policy: contextProvider.readPolicy)
    }

    var learnedCount: Int { _ = revision; return learner.learnedCount }
    /// Learned words still in `d` (the Dictionary page passes its live, unsaved state).
    func learnedCount(in d: UserDictionary) -> Int { _ = revision; return learner.store.learnedCount(in: d) }

    /// Hooks the pipeline: context names at recording start, watching after each paste.
    func install(on pipeline: DictationPipeline) {
        pipeline.contextProvider = contextProvider
        let learning = learner.store
        pipeline.snapperTombstones = { Set(learning.snapshot.tombstones) }
        pipeline.onInserted = { [weak self] d in self?.inserted(d) }
        pipeline.onInsertionSuperseded = { [weak self] in self?.watcher.cancel() }  // backtrack Undo
    }

    /// A new dictation is starting: stop watching and take any open suggestion down.
    func dictationStarting() {
        watcher.cancel()
        clearPending()
    }

    private func inserted(_ d: InsertedDictation) {
        guard settings.learnMode != .off else { watcher.cancel(); return }   // Off: never read the field
        watcher.watch(d) { [weak self] c in self?.found(c) }
    }

    private func found(_ c: Correction) {
        if settings.learnMode == .automatic {
            Task { handle(await learner.considerAsync(c)) }
        } else { handle(learner.consider(c)) }
    }

    private func handle(_ decision: LearnDecision) {
        switch decision {
        case .ignored: break
        case .suggest(let c):
            clearPending()
            pending = c
            // Standard chip timing (`HUDChipPolicy`); the word is forgotten when the chip ends
            // (`chipEnded`), even if it first waited behind an alert or Undo.
            showNotice(SmartDictionaryCopy.suggestion(c))
        case .added(let c):
            revision &+= 1
            showNotice(SmartDictionaryCopy.added(c.correct))
        }
    }

    /// HUD "Add".
    func acceptPending() {
        guard let c = pending else { return }
        clearPending()
        Task {
            do { try await learner.acceptAsync(c); revision &+= 1 } catch { showNotice(error.localizedDescription) }
        }
    }

    /// HUD "Not now": nothing is stored (it may be suggested again after another correction).
    func dismissPending() { clearPending() }

    private func clearPending() {
        guard let c = pending else { return }
        pending = nil
        dismissNotice(SmartDictionaryCopy.suggestion(c))
    }

    /// The HUD took a chip down: if it was this suggestion, forget the word (nothing stored).
    func chipEnded(_ text: String) {
        guard let c = pending, text == SmartDictionaryCopy.suggestion(c) else { return }
        pending = nil
    }

    /// History "Fix a Word…".
    func fixWord(misheard: String, correct: String) async throws {
        try await learner.fixWordAsync(misheard: misheard, correct: correct)
        revision &+= 1
    }
}
