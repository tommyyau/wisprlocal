import Testing
import Foundation
import Synchronization
@testable import WisprLocalCore

/// Engine fake with a named engine, a gated prepare and load/unload accounting.
final class ModeTranscriber: Transcriber, Sendable {
    let name: String
    let text: String
    private let state = Mutex((loaded: false, prepares: 0, unloads: 0, calls: 0))
    private let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let gated: Bool
    init(_ name: String, text: String = "Hello there friend.", gatedPrepare: Bool = false) {
        self.name = name; self.text = text; self.gated = gatedPrepare
    }
    var engineName: String { "fluidaudio:\(name)" }
    var loaded: Bool { state.withLock { $0.loaded } }
    var prepares: Int { state.withLock { $0.prepares } }
    var unloads: Int { state.withLock { $0.unloads } }
    var calls: Int { state.withLock { $0.calls } }
    func prepare() async throws {
        state.withLock { $0.prepares += 1 }
        if gated { await withCheckedContinuation { c in gate.withLock { $0 = c } } }
        state.withLock { $0.loaded = true }
    }
    /// Lets a gated prepare finish (spins until it is waiting).
    func open() async {
        while true {
            if let c = gate.withLock({ v -> CheckedContinuation<Void, Never>? in let c = v; v = nil; return c }) { c.resume(); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func unload() async { state.withLock { $0.loaded = false; $0.unloads += 1 } }
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String {
        state.withLock { $0.calls += 1 }
        return text
    }
}

struct FixedDetector: LanguageDetecting {
    var result: DetectedLanguage
    func detect(_ text: String) -> DetectedLanguage { result }
}

@MainActor func makeModeEnv(_ engine: Transcriber, detector: LanguageDetecting = NLLanguageDetector(),
                            dictionary: DictionaryStore = tempDictionary()) async -> (PipelineEnv, DictationPipeline) {
    let env = PipelineEnv(text: "", speech: true, transcriber: nil)
    let inserter = env.inserter
    let p = DictationPipeline(
        audio: env.audio, trimmer: FakeTrimmer(), transcriber: engine,
        dictionary: dictionary, cleaner: RuleCleaner(), gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
        secureInput: env.secure, clipboard: env.clipboard,
        inserterFor: { _ in (inserter, .paste) }, history: env.history,
        frontmostApp: { [unowned env] in env.front }, caretReader: env.caret, debugRecordings: nil, autoFormatter: .none,
        languageDetector: detector)
    p.onNotice = { [unowned env] in env.notices.append($0) }
    p.captureTail = .zero
    await p.prepareModels()
    env.pipeline = p
    return (env, p)
}

@Suite struct ModelModeSettingsTests {
    @Test @MainActor func noisyRoomDefaultsOffAndPersists() {
        let suite = "wl-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: d)
        #expect(s.noisyRoomMode == false)
        #expect(s.activeASRVariant == .parakeetV2)
        s.noisyRoomMode = true
        #expect(AppSettings(defaults: d).noisyRoomMode == true)
        #expect(AppSettings(defaults: d).activeASRVariant == .parakeetUltra)
    }

    @Test func modeNamesAreTheAgreedOnes() {
        #expect(ASRModelVariant.forMode(noisyRoom: false) == .parakeetV2)
        #expect(ASRModelVariant.forMode(noisyRoom: true) == .parakeetUltra)
        #expect(ASRModelVariant.parakeetV2.modeName == "English (Parakeet v2)")
        #expect(ASRModelVariant.parakeetUltra.modeName == "Noisy room / other languages (Parakeet Ultra)")
        #expect(ASRModelVariant.parakeetV2.modeLabel == "Speech: English (Parakeet v2)")
        #expect(FluidAudioTranscriber(variant: .parakeetV2, locator: ModelLocator(searchRoots: [])).engineName == "fluidaudio:v2")
        #expect(FluidAudioTranscriber(variant: .parakeetUltra, locator: ModelLocator(searchRoots: [])).engineName == "fluidaudio:ultra")
    }
}

@MainActor @Suite struct ModelSwitchTests {
    @Test func switchRefusesDictationUntilReadyThenUsesNewEngine() async {
        let v2 = ModeTranscriber("v2"), ultra = ModeTranscriber("ultra", gatedPrepare: true)
        let (e, p) = await makeModeEnv(v2)
        #expect(p.modelReady && v2.loaded)
        let task = p.switchTranscriber(to: ultra)
        #expect(!p.modelReady)
        p.handle(.startRecording)  // refused while switching
        #expect(!p.status.isRecording)
        #expect(e.notices.last == PipelineNotice.modelPreparing)
        await ultra.open()
        await task.value
        #expect(p.modelReady)
        #expect(!v2.loaded && v2.unloads == 1, "old model unloaded")
        #expect(ultra.loaded && ultra.prepares == 1)
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
        #expect(e.history.entries.last?.engine == "fluidaudio:ultra")
        #expect(v2.calls == 0 && ultra.calls == 1)
    }

    @Test func recordingStartedBeforeSwitchFinishesOnItsOwnEngine() async {
        let v2 = ModeTranscriber("v2"), ultra = ModeTranscriber("ultra")
        let (e, p) = await makeModeEnv(v2)
        p.handle(.startRecording)
        let task = p.switchTranscriber(to: ultra)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(v2.loaded, "old engine is not unloaded while its recording is running")
        #expect(ultra.prepares == 0, "new engine waits: never two models resident")
        p.handle(.commitRecording)
        await p.drain()
        await task.value
        #expect(e.history.entries.last?.engine == "fluidaudio:v2")
        #expect(v2.calls == 1 && ultra.calls == 0)
        #expect(!v2.loaded && ultra.loaded && p.modelReady)
    }

    @Test func rapidTogglesPrepareOnlyTheLastEngine() async {
        let v2 = ModeTranscriber("v2"), ultra = ModeTranscriber("ultra")
        let (_, p) = await makeModeEnv(v2)
        let prepBefore = v2.prepares
        p.switchTranscriber(to: ultra)
        let last = p.switchTranscriber(to: v2)
        await last.value
        #expect(ultra.prepares == 0, "superseded switch never loads its model")
        #expect(v2.prepares == prepBefore + 1 && v2.loaded && p.modelReady)
        #expect(!ultra.loaded)
    }

    @Test func retryActsOnTheActiveEngine() async {
        let v2 = ModeTranscriber("v2"), ultra = ModeTranscriber("ultra")
        let (_, p) = await makeModeEnv(v2)
        await p.switchTranscriber(to: ultra).value
        let before = ultra.prepares
        await p.retryModelPreparation()
        #expect(ultra.prepares == before + 1)
        #expect(!v2.loaded)
    }

    @Test func switchingNoticeNamesTheMode() {
        #expect(PipelineNotice.switchingModel(to: .parakeetUltra) == "Switching to Noisy room model…")
        #expect(PipelineNotice.switchingModel(to: .parakeetV2) == "Switching to English model…")
    }

    @Test func historyRecordsVoiceProcessingState() async {
        let (e, p) = await makeModeEnv(ModeTranscriber("v2"))
        _ = await p.process(samples: [Float](repeating: 0.1, count: 16_000), target: e.front, voiceProcessing: true)
        #expect(e.history.entries.last?.voiceProcessingActive == true)
        _ = await p.process(samples: [Float](repeating: 0.1, count: 16_000), target: e.front)
        #expect(e.history.entries.last?.voiceProcessingActive == nil)
        // An old line (no voiceProcessingActive key) still decodes.
        var withVP = HistoryEntry(engine: "x", outcome: .inserted)
        withVP.voiceProcessingActive = false
        var obj = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(withVP)) as! [String: Any]
        #expect(obj["voiceProcessingActive"] as? Bool == false)
        obj.removeValue(forKey: "voiceProcessingActive")
        let decoded = try? JSONDecoder().decode(HistoryEntry.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(decoded != nil && decoded?.voiceProcessingActive == nil, "old history lines still decode")
    }
}

/// STRUCTURAL: cleanup is English-only (`CleanupLanguagePolicy`). Real NLLanguageRecognizer.
@MainActor @Suite struct EnglishOnlyCleanupTests {
    nonisolated static let foreign: [(lang: String, text: String)] = [
        ("sv", "Jag tycker att vi borde, eh, skicka det på fredag."),
        ("de", "Ich denke, wir sollten es am Freitag ausliefern, ähm, oder nicht?"),
        ("fr", "Je pense que nous devrions l'expédier vendredi, euh, sans faute."),
    ]

    @Test(arguments: foreign)
    func nonEnglishPassesThroughUnchanged(_ c: (lang: String, text: String)) async {
        let (e, p) = await makeModeEnv(ModeTranscriber("ultra", text: c.text))
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
        #expect(e.inserter.inserted == [c.text])
        let h = e.history.entries.last!
        #expect(h.language == c.lang)
        #expect(h.cleaner == "none:\(c.lang)")
        #expect(h.outcome == .inserted)
    }

    @Test func nonEnglishStillGetsDictionaryReplacements() async throws {
        let dict = tempDictionary()
        var d = dict.dictionary
        d.replacements = [ReplacementRule(from: "fredag", to: "Fredag")]
        try dict.update(d)
        let text = "Jag tycker att vi borde skicka det på fredag."
        let (e, p) = await makeModeEnv(ModeTranscriber("ultra", text: text), dictionary: dict)
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
        #expect(e.inserter.inserted == ["Jag tycker att vi borde skicka det på Fredag."])
    }

    @Test func englishStillGetsCleaned() async {
        let (e, p) = await makeModeEnv(ModeTranscriber("ultra", text: "Um, I think we should ship it on Friday."))
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
        #expect(e.inserter.inserted == ["I think we should ship it on Friday."])
        #expect(e.history.entries.last?.cleaner == "rules")
        #expect(e.history.entries.last?.language == "en")
    }

    @Test func shortStringsAreTreatedAsEnglish() {
        let alwaysSwedish = FixedDetector(result: DetectedLanguage(code: "sv", confidence: 1))
        for s in ["Tack", "Danke schön", "Okay sure"] {
            let (v, d) = CleanupLanguagePolicy.decide(s, detector: alwaysSwedish)
            #expect(v == .tooShort && v.allowsCleanup && d == nil, "\(s)")
        }
        #expect(!CleanupLanguagePolicy.decide("tack så mycket", detector: alwaysSwedish).0.allowsCleanup)
    }

    @Test func lowConfidenceForeignGuessStillCleans() {
        let unsure = FixedDetector(result: DetectedLanguage(code: "hu", confidence: 0.4))
        #expect(CleanupLanguagePolicy.decide("Grafana dashboards Tailscale Kubernetes", detector: unsure).0 == .english)
        let enUS = FixedDetector(result: DetectedLanguage(code: "en-US", confidence: 0.99))
        #expect(CleanupLanguagePolicy.decide("one two three four", detector: enUS).0 == .english)
    }

    @Test func jargonHeavyEnglishIsNotMistakenForForeign() {
        let nl = NLLanguageDetector()
        for s in ["Grafana dashboards Tailscale Kubernetes", "Send it to Sarah Chen at Acme Robotics.",
                  "Um so the Kubernetes cluster is healthy again.", "Wispr Flow sync on Monday at ten."] {
            #expect(CleanupLanguagePolicy.decide(s, detector: nl).0.allowsCleanup, "\(s)")
        }
    }

    @Test func injectedDetectorDecides() async {
        let (e, p) = await makeModeEnv(ModeTranscriber("ultra", text: "Um, this is plainly English text."),
                                       detector: FixedDetector(result: DetectedLanguage(code: "de", confidence: 0.95)))
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
        #expect(e.inserter.inserted == ["Um, this is plainly English text."], "no cleanup when the detector says German")
    }
}

@Suite struct ModelComparisonTests {
    @Test func wordDiffMarksOnlyDifferingWords() {
        #expect(WordDiff.equivalent("Hello, world.", "hello world"))
        let (a, b) = WordDiff.highlighted("ship it on Friday", "ship it Friday now")
        #expect(a == "ship it [on] Friday")
        #expect(b == "ship it Friday [now]")
    }

    @Test func summaryCountsPerModel() {
        let en = FixedDetector(result: DetectedLanguage(code: "en", confidence: 1))
        typealias R = ModelComparison.Result
        let clips = [
            ModelComparison.Clip(name: "a", voiceProcessing: true, a: R(text: "same words here", ms: 100), b: R(text: "Same words here.", ms: 200)),
            ModelComparison.Clip(name: "b", voiceProcessing: false, a: R(text: "", ms: 50), b: R(text: "jag tycker att", ms: 100)),
        ]
        let sw = SplitDetector(en: en)
        let s = ModelComparison.summarize(clips, detector: sw)
        #expect(s.clips == 2 && s.identical == 1 && s.different == 1)
        #expect(s.emptyA == 1 && s.emptyB == 0)
        #expect(s.nonEnglishA == 0 && s.nonEnglishB == 1)
        #expect(s.avgMsA == 75 && s.avgMsB == 150)
    }

    @Test func runUsesOneModelAtATime() async {
        let a = ModeTranscriber("v2", text: "one"), b = ModeTranscriber("ultra", text: "two")
        let out = await ModelComparison.run(clips: [("x", [0.1], nil), ("y", [0.2], true)], a: a, b: b)
        #expect(out.map(\.a.text) == ["one", "one"] && out.map(\.b.text) == ["two", "two"])
        #expect(out.last?.voiceProcessing == true)
        #expect(a.unloads == 1 && b.unloads == 1 && !a.loaded && !b.loaded)
    }

    struct SplitDetector: LanguageDetecting {
        let en: FixedDetector
        func detect(_ text: String) -> DetectedLanguage {
            text.contains("jag") ? DetectedLanguage(code: "sv", confidence: 1) : en.detect(text)
        }
    }
}
