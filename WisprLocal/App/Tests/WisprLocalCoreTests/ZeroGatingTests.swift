import Foundation
import Testing
@testable import WisprLocalCore

/// The zero-gating detector: metric definition, thresholds and the diagnostics line.
@Suite struct ZeroGateDetectorTests {
    static func tone(_ n: Int) -> [Float] { var s = TestSignal(); return (0..<n).map { _ in s.next(rate: 16_000) } }

    @Test func continuousAudioMeasuresZero() {
        #expect(AudioGatingMetrics.measure(Self.tone(16_000)) == .none)
        #expect(AudioGatingMetrics.measure([Float]()) == .none)
    }

    @Test func measuresFractionAndLongestRun() {
        var s = Self.tone(16_000)
        for i in 2_000..<6_800 { s[i] = 0 }        // 300 ms hole
        for i in 10_000..<10_800 { s[i] = 0 }      // 50 ms hole
        let m = AudioGatingMetrics.measure(s)
        #expect(abs(m.zeroFraction - 5_600.0 / 16_000) < 1e-9)
        #expect(abs(m.maxZeroRunMs - 300) < 1e-9)
    }

    @Test func belowHalfAnLSBIsSilentButOneLSBIsNot() {
        var s = Self.tone(16_000)
        for i in 4_000..<5_600 { s[i] = 1e-6 }                // rounds to int16 0
        #expect(AudioGatingMetrics.measure(s).maxZeroRunMs == 100)
        for i in 4_000..<5_600 { s[i] = 1.0 / 32_767 }        // 1 LSB: real (if faint) signal
        #expect(AudioGatingMetrics.measure(s) == .none)
    }

    @Test func zeroCrossingsAreNotGating() {
        var s = Self.tone(16_000)
        for i in stride(from: 0, to: 16_000, by: 50) { for k in 0..<7 where i + k < s.count { s[i + k] = 0 } }
        #expect(AudioGatingMetrics.measure(s) == .none, "runs shorter than \(AudioGatingMetrics.minRunSamples) samples are ignored")
    }

    @Test func thresholds() {
        #expect(!ZeroGatingPolicy.isCuttingOut(.init(zeroFraction: 0.05, maxZeroRunMs: 250)))
        #expect(ZeroGatingPolicy.isCuttingOut(.init(zeroFraction: 0.0501, maxZeroRunMs: 0)))
        #expect(ZeroGatingPolicy.isCuttingOut(.init(zeroFraction: 0, maxZeroRunMs: 250.1)))
        #expect(ZeroGatingPolicy.maxZeroFraction == 0.05 && ZeroGatingPolicy.maxZeroRunMs == 250)
    }

    /// The plane clips' signature (10–15 % silenced, runs up to ~0.5 s) trips the detector; a
    /// cold start's leading engine-start mute is not counted (trimmed by the detector itself).
    @Test func planeLikeClipTripsAndStartupMuteIsStripped() {
        var s = Self.tone(48_000)
        for start in stride(from: 4_000, to: 44_000, by: 8_000) { for i in start..<(start + 1_000) { s[i] = 0 } }
        #expect(AudioGatingMetrics.measure(s).isCuttingOut)
        let cold = [Float](repeating: 0, count: 3_200) + Self.tone(16_000)   // 200 ms start-up mute
        #expect(AudioGatingMetrics.measureAllRuns(cold).isCuttingOut, "the raw metric sees it")
        #expect(AudioGatingMetrics.measure(cold) == .none)
    }

    // MARK: cold start (the false "mic is cutting out" on the first dictation after launch)

    /// dB → linear amplitude.
    static func amp(_ db: Double) -> Float { Float(pow(10, db / 20)) }

    /// The real cold-start shape (debug clips 2026-10-03): `leadMs` of exact zeros with a stray
    /// ±1 LSB blip inside, then a fade-in rising ~1 dB/ms from the noise, then clean speech.
    static func coldStartClip(leadMs: Int = 450, speech: Int = 24_000) -> [Float] {
        var s = [Float](repeating: 0, count: leadMs * 16)
        if !s.isEmpty { s[s.count / 3] = 1.0 / 32_767 }                     // the blip that fooled droppingStartupMute
        var fade = Self.tone(1_600)                                          // 100 ms fade, −110 → −10 dB
        for i in fade.indices { fade[i] *= amp(-100 + Double(i) / 16) }
        for i in fade.indices where abs(fade[i]) < AudioGatingMetrics.silenceThreshold { fade[i] = 0 }
        return s + fade + Self.tone(speech)
    }

    @Test func coldStartShapedClipMeasuresNothing() {
        for lead in [300, 450, 600] {
            let c = Self.coldStartClip(leadMs: lead)
            #expect(AudioGatingMetrics.measureAllRuns(c).isCuttingOut, "the old metric was fooled at \(lead) ms")
            #expect(AudioGatingMetrics.measure(c) == .none, "\(lead) ms cold start")
        }
    }

    @Test func genuineMidSpeechHoleIsCounted() {
        var s = Self.coldStartClip(speech: 32_000)
        let mid = 450 * 16 + 1_600 + 12_000
        for i in mid..<(mid + 4_800) { s[i] = 0 }                            // 300 ms inside speech
        let m = AudioGatingMetrics.measure(s)
        #expect(abs(m.maxZeroRunMs - 300) < 1e-9 && m.isCuttingOut)
    }

    /// Fade edges: zero runs inside a fade-in or fade-out (samples quantising to 0) and a pause
    /// that decays gradually into digital silence are not holes in speech.
    @Test func fadeEdgesAndGatedPausesAreNotCounted() {
        let speech = Self.tone(16_000)
        var fadeOut = Self.tone(6_400)                                       // 400 ms, −10 → −110 dB
        for i in fadeOut.indices { fadeOut[i] *= Self.amp(-Double(i) / 64) }
        for i in fadeOut.indices where abs(fadeOut[i]) < AudioGatingMetrics.silenceThreshold { fadeOut[i] = 0 }
        let pause = [Float](repeating: 0, count: 12_800)                     // 800 ms gated pause
        let fadeIn = Array(Self.coldStartClip(leadMs: 0, speech: 0))
        let clip = speech + fadeOut + pause + fadeIn + speech + [Float](repeating: 0, count: 8_000)  // + trailing zeros
        #expect(AudioGatingMetrics.measureAllRuns(clip).maxZeroRunMs >= 800)
        #expect(AudioGatingMetrics.measure(clip) == .none)
    }

    @Test func tipNeedsTwoOfThreeOrOneSevere() {
        let ok = AudioGatingMetrics.none
        let bad = AudioGatingMetrics(zeroFraction: 0.08, maxZeroRunMs: 300)
        let severeRun = AudioGatingMetrics(zeroFraction: 0.02, maxZeroRunMs: 601)
        let severeFraction = AudioGatingMetrics(zeroFraction: 0.26, maxZeroRunMs: 100)
        #expect(!ZeroGatingPolicy.shouldWarn(recent: []))
        #expect(!ZeroGatingPolicy.shouldWarn(recent: [bad]), "one cold-start-sized artifact alone")
        #expect(!ZeroGatingPolicy.shouldWarn(recent: [ok, ok, bad]))
        #expect(ZeroGatingPolicy.shouldWarn(recent: [bad, ok, bad]))
        #expect(ZeroGatingPolicy.shouldWarn(recent: [ok, bad, bad]))
        #expect(!ZeroGatingPolicy.shouldWarn(recent: [bad, ok, ok, bad]), "only the last 3 count")
        #expect(!ZeroGatingPolicy.shouldWarn(recent: [bad, bad, ok]), "the newest must itself be cutting out")
        #expect(ZeroGatingPolicy.shouldWarn(recent: [severeRun]) && ZeroGatingPolicy.shouldWarn(recent: [severeFraction]))
        #expect(!ZeroGatingPolicy.isSevere(.init(zeroFraction: 0.25, maxZeroRunMs: 600)))
    }

    /// A loud voice in a quiet room is not a loud place (no headset advice).
    @Test func loudVoiceInAQuietRoomIsNotALoudPlace() {
        #expect(!NoTextPolicy.isLoudPlace(level: CaptureLevel(loudDBFS: -15, floorDBFS: -60), gating: .none))
        #expect(NoTextPolicy.isLoudPlace(level: CaptureLevel(loudDBFS: -15, floorDBFS: -30), gating: .none))
    }

    @Test func diagnosticsLine() {
        func e(_ z: Double?, _ run: Double?, vp: Bool? = true) -> HistoryEntry {
            var h = HistoryEntry(outcome: .inserted); h.zeroFraction = z; h.maxZeroRunMs = run; h.voiceProcessingActive = vp; return h
        }
        #expect(MicAudioDiagnostics.warning([]) == nil)
        #expect(MicAudioDiagnostics.warning([e(0, 0), e(0.01, 40), e(0, 0)]) == nil)
        #expect(MicAudioDiagnostics.warning([e(0.12, 480)]) == "Cutting out on the last dictation")
        #expect(MicAudioDiagnostics.status([]) == nil)
        #expect(MicAudioDiagnostics.status([e(nil, nil)]) == nil)
        #expect(MicAudioDiagnostics.status([e(0, 0)]) == "Last dictation: no cut-outs")
        #expect(MicAudioDiagnostics.status([e(0.01, 40), e(0, 0)]) == "Last 2 dictations: no cut-outs")
        #expect(MicAudioDiagnostics.status([e(0.12, 480), e(0.10, 300), e(0, 0)]) == "Cutting out on 2 of the last 3")
        #expect(MicAudioDiagnostics.status([e(0.12, 480)]) == "Cutting out on the last dictation")
        #expect(MicAudioDiagnostics.status((0..<30).map { _ in e(0.2, 400) }) == "Cutting out on 20 of the last 20")
    }

    @Test func historyRoundTripsTheNewFields() throws {
        var h = HistoryEntry(outcome: .noTextRecognised)
        h.zeroFraction = 0.12; h.maxZeroRunMs = 480; h.warmStart = true; h.micMode = "Voice Isolation"
        h.inputLevelDBFS = -22; h.noiseFloorDBFS = -40
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(HistoryEntry.self, from: enc.encode(h))
        #expect(back.zeroFraction == 0.12 && back.maxZeroRunMs == 480 && back.warmStart == true)
        #expect(back.micMode == "Voice Isolation" && back.inputLevelDBFS == -22 && back.noiseFloorDBFS == -40)
        #expect(back.outcome == .noTextRecognised)
    }
}

@Suite struct NoTextPolicyTests {
    static let loud = CaptureLevel(loudDBFS: -20, floorDBFS: -28)
    static let quiet = CaptureLevel(loudDBFS: -60, floorDBFS: -80)

    @Test func reasons() {
        #expect(NoTextPolicy.reason(speechDuration: 0.5, transcriptEmpty: true, captureDuration: 1, level: Self.quiet) == .asrEmpty)
        #expect(NoTextPolicy.reason(speechDuration: 0.49, transcriptEmpty: true, captureDuration: 1, level: Self.loud) == nil)
        #expect(NoTextPolicy.reason(speechDuration: 2, transcriptEmpty: false, captureDuration: 2, level: Self.loud) == nil)
        #expect(NoTextPolicy.reason(speechDuration: nil, transcriptEmpty: true, captureDuration: 1.5, level: Self.loud) == .loudNoSpeech)
        #expect(NoTextPolicy.reason(speechDuration: nil, transcriptEmpty: true, captureDuration: 1.0, level: Self.loud) == nil)
        #expect(NoTextPolicy.reason(speechDuration: nil, transcriptEmpty: true, captureDuration: 3, level: Self.quiet) == nil)
    }

    @Test func headsetAdviceOnlyForBuiltInMicInLoudPlaces() {
        #expect(NoTextPolicy.notice(builtInMic: true, level: Self.loud, gating: .none) == PipelineNotice.didntCatchThatUseHeadset)
        #expect(NoTextPolicy.notice(builtInMic: false, level: Self.loud, gating: .none) == PipelineNotice.didntCatchThat)
        #expect(NoTextPolicy.notice(builtInMic: nil, level: Self.loud, gating: .none) == PipelineNotice.didntCatchThat)
        #expect(NoTextPolicy.notice(builtInMic: true, level: Self.quiet, gating: .none) == PipelineNotice.didntCatchThat)
        #expect(NoTextPolicy.notice(builtInMic: true, level: Self.quiet, gating: .init(zeroFraction: 0.2, maxZeroRunMs: 400))
                == PipelineNotice.didntCatchThatUseHeadset, "gating itself means a loud place")
        for n in [PipelineNotice.didntCatchThat, PipelineNotice.didntCatchThatUseHeadset] {
            // The chip's See why button says it; the text never repeats it ("tap to see why").
            #expect(n.hasPrefix(PipelineNotice.didntCatchPrefix) && !n.contains("see why") && HUDChipPolicy.actions(for: n) == [.seeWhy])
        }
        #expect(PipelineNotice.didntCatchThatUseHeadset.contains("headset mic"))
    }

    @Test func captureLevel() {
        #expect(CaptureLevel.measure([Float](repeating: 0, count: 16_000)) == .silent)
        let l = CaptureLevel.measure([Float](repeating: 0.1, count: 16_000))
        #expect(abs(l.loudDBFS - -20) < 0.01 && abs(l.floorDBFS - -20) < 0.01)
    }

    @Test func whyExplanation() {
        var e = HistoryEntry(outcome: .noTextRecognised, note: NoTextPolicy.Reason.asrEmpty.rawValue)
        e.speechDuration = 2.1; e.zeroFraction = 0.14; e.maxZeroRunMs = 480; e.inputLevelDBFS = -25; e.noiseFloorDBFS = -96
        let why = e.whyExplanation ?? ""
        #expect(why.contains("2.1 s of speech") && why.contains("cutting out") && why.contains("headset mic"))
        #expect(HistoryEntry(outcome: .inserted).whyExplanation == nil)
        #expect(e.micAudioLabel.contains("cutting out"))
        #expect(HistoryEntry(outcome: .inserted).micAudioLabel == "Not measured")
    }
}

/// On-device self-test logic with a fake recorder (the real one needs hardware: Settings ›
/// Microphone & models › Check your microphone, or `WisprLocalReplay --mic-check`).
@MainActor @Suite struct MicSelfTestTests {
    final class Rec: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var onMaxDurationReached: (() -> Void)?
        let samples: [Float]; let vp: Bool
        var started = false, cancelled = false
        init(_ s: [Float], vp: Bool) { samples = s; self.vp = vp }
        func start() throws { started = true }
        func stop(tail: Duration) async -> [Float] { samples }
        func cancel() { cancelled = true }
        var captureVoiceProcessingActive: Bool? { vp }
    }

    static let clean: [Float] = ZeroGateDetectorTests.tone(48_000)
    static var gated: [Float] {
        var s = clean
        for start in stride(from: 4_000, to: 44_000, by: 8_000) { for i in start..<(start + 1_600) { s[i] = 0 } }
        return s
    }

    @Test func vpOnRunsTwiceSideBySide() async throws {
        var made: [Bool] = []
        let t = MicSelfTest(makeRecorder: { vp in made.append(vp); return Rec(vp ? Self.gated : Self.clean, vp: vp) },
                            sleep: { _ in }, micMode: { "Voice Isolation" })
        var phases: [MicSelfTest.Phase] = []
        let r = try await t.run(currentVoiceProcessing: true) { phases.append($0) }
        #expect(made == [true, false])
        #expect(phases == [.recording(voiceProcessing: true), .recording(voiceProcessing: false), .done])
        #expect(r.count == 2 && !r[0].passed && r[1].passed)
        #expect(r[0].verdict.hasPrefix("Fail — audio cut out") && r[1].verdict.hasPrefix("Pass"))
        #expect(r[0].details.contains("Mic Mode: Voice Isolation"))
        #expect(MicSelfTest.comparison(r)?.contains("Noise reduction is what's cutting") == true)
    }

    @Test func vpOffRunsOnce() async throws {
        let t = MicSelfTest(makeRecorder: { vp in Rec(Self.clean, vp: vp) }, sleep: { _ in }, micMode: { nil })
        let r = try await t.run(currentVoiceProcessing: false)
        #expect(r.count == 1 && r[0].passed && !r[0].voiceProcessing)
        #expect(MicSelfTest.comparison(r) == nil)
    }

    @Test func quietAndEmptyFail() {
        let quiet = MicCheckResult.measure([Float](repeating: 0.001, count: 48_000), voiceProcessing: false,
                                           voiceProcessingActive: false, micMode: nil)
        #expect(!quiet.passed && quiet.verdict.contains("very quiet"))
        let empty = MicCheckResult.measure([], voiceProcessing: false, voiceProcessingActive: false, micMode: nil)
        #expect(!empty.passed && empty.verdict.contains("almost no audio"))
    }

    @Test func cancellationStopsTheRecorder() async {
        var rec: Rec?
        let t = MicSelfTest(makeRecorder: { vp in let r = Rec(Self.clean, vp: vp); rec = r; return r },
                            sleep: { _ in throw CancellationError() }, micMode: { nil })
        await #expect(throws: CancellationError.self) { _ = try await t.run(currentVoiceProcessing: false) }
        #expect(rec?.cancelled == true)
    }

    @Test func comparisonCopy() {
        func r(_ vp: Bool, _ bad: Bool) -> MicCheckResult {
            MicCheckResult.measure(bad ? Self.gated : Self.clean, voiceProcessing: vp, voiceProcessingActive: vp, micMode: nil)
        }
        #expect(MicSelfTest.comparison([r(true, true), r(false, true)])?.contains("either way") == true)
        #expect(MicSelfTest.comparison([r(true, false), r(false, true)])?.contains("keep it on") == true)
        #expect(MicSelfTest.comparison([r(true, false), r(false, false)])?.contains("No cut-outs") == true)
    }
}

@Suite struct LostKeyCopyTests {
    @Test func everyStatusHasPlainCopy() {
        #expect(LostKeyCopy.line(.armed).hasPrefix("Armed"))
        #expect(LostKeyCopy.line(.blind).contains("time limit"))
        #expect(LostKeyCopy.line(.unknown).hasPrefix("Not checked"))
    }
}
