import Foundation
import Testing
@testable import WisprLocalCore

/// "Never silent" (BUG A, 2026-10-03): speech was heard but nothing came out → a HUD notice,
/// outcome `.noTextRecognised` with a content-free reason, the clip KEPT; plus the zero-gating
/// tip (once per session) and the capture metadata in history.
@MainActor @Suite(.serialized) struct EmptyTranscriptTests {
    static func store() -> (DebugRecordingStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        return (DebugRecordingStore(directory: dir, isEnabled: { true }), dir)
    }

    static func gated(_ n: Int = 32_000) -> [Float] {
        var s = ZeroGateDetectorTests.tone(n)
        for start in stride(from: 1_000, to: n - 2_000, by: 8_000) { for i in start..<(start + 1_600) { s[i] = 0 } }
        return s
    }

    @Test func emptyTranscriptForRealSpeechShowsNoticeAndKeepsClip() async {
        let (store, dir) = Self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let (e, p) = await makeEnv(text: "", debugRecordings: store)
        p.inputIsBuiltInMic = { false }
        let h = await p.process(samples: e.audio.samples, target: e.front)   // 1 s of speech
        #expect(h.outcome == .noTextRecognised)
        #expect(h.note == NoTextPolicy.Reason.asrEmpty.rawValue)
        #expect(e.notices == [PipelineNotice.didntCatchThat])
        #expect(p.lastNoTextEntryID == h.id)
        #expect(e.inserter.inserted.isEmpty)
        await p.flushDebugRecordings()
        #expect(store.clipIDs() == [h.id], "the failed dictation keeps its recording")
        #expect(HistoryPlayback.of(h, clipIDs: store.clipIDs()) == .playable)
    }

    @Test func builtInMicInALoudPlaceGetsTheHeadsetAdvice() async {
        let (e, p) = await makeEnv(text: "")
        p.inputIsBuiltInMic = { true }
        _ = await p.process(samples: e.audio.samples, target: e.front)      // constant −20 dBFS: loud floor
        #expect(e.notices == [PipelineNotice.didntCatchThatUseHeadset])
    }

    @Test func shortEmptyUtteranceStaysQuiet() async {
        let (e, p) = await makeEnv(text: "")
        e.audio.samples = [Float](repeating: 0.1, count: 6_400)                // 0.4 s
        let h = await p.process(samples: e.audio.samples, target: e.front)
        #expect(h.outcome == .emptyAfterCleanup && e.notices.isEmpty)
    }

    @Test func loudCaptureWithNoSpeechIsNotSilent() async {
        let (store, dir) = Self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let (e, p) = await makeEnv(speech: false, debugRecordings: store)
        let loud = [Float](repeating: 0.1, count: 24_000)                     // 1.5 s at −20 dBFS
        let h = await p.process(samples: loud, target: e.front)
        #expect(h.outcome == .noTextRecognised && h.note == NoTextPolicy.Reason.loudNoSpeech.rawValue)
        #expect(e.notices.first?.hasPrefix(PipelineNotice.didntCatchPrefix) == true)
        await p.flushDebugRecordings()
        #expect(store.clipIDs() == [h.id], "the whole capture is kept to hear what was gated")
    }

    @Test func quietCaptureWithNoSpeechStaysQuietButKeepsAudio() async {
        let (store, dir) = Self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let (e, p) = await makeEnv(speech: false, debugRecordings: store)
        let h = await p.process(samples: [Float](repeating: 0.001, count: 32_000), target: e.front)
        #expect(h.outcome == .noSpeech && e.notices.isEmpty)
        await p.flushDebugRecordings()
        #expect(store.clipIDs() == [h.id])
    }

    @Test func gatingTipShowsOncePerSessionAndMetricsAreStored() async {
        let (e, p) = await makeEnv(text: "Hello there.")
        let first = await p.process(samples: Self.gated(), target: e.front, warmStart: true)
        #expect(first.outcome == .inserted)
        #expect((first.zeroFraction ?? 0) > 0.05 && (first.maxZeroRunMs ?? 0) == 100)
        #expect(e.notices.isEmpty, "one non-severe gated dictation is not enough (2 of the last 3)")
        _ = await p.process(samples: Self.gated(), target: e.front, warmStart: true)
        #expect(e.notices == [PipelineNotice.micCuttingOut], "the second of three warns")
        _ = await p.process(samples: Self.gated(), target: e.front, warmStart: true)
        #expect(e.notices == [PipelineNotice.micCuttingOut], "once per session")
        let clean = await p.process(samples: ZeroGateDetectorTests.tone(32_000), target: e.front, warmStart: true)
        #expect(clean.zeroFraction == 0 && clean.maxZeroRunMs == 0)
    }

    @Test func tipNeverHidesAnotherNoticeOrARefusal() async {
        let (e, p) = await makeEnv(text: "")
        p.inputIsBuiltInMic = { false }
        _ = await p.process(samples: Self.severe(), target: e.front, warmStart: true)
        #expect(e.notices == [PipelineNotice.didntCatchThat], "the dictation's own notice wins")
        #expect(!p.gatingTipShown, "the tip waits for the next gated dictation")
        let (e2, p2) = await makeEnv(text: "Hello.")
        e2.secure.active = true
        _ = await p2.process(samples: Self.gated(), target: e2.front, warmStart: true)
        #expect(e2.notices == [PipelineNotice.secureInput])
    }

    /// One hole > 600 ms inside speech: severe, warns on its own.
    static func severe() -> [Float] {
        var s = ZeroGateDetectorTests.tone(32_000)
        for i in 8_000..<19_200 { s[i] = 0 }                                   // 700 ms
        return s
    }

    @Test func severeSingleDictationWarnsAtOnce() async {
        let (e, p) = await makeEnv(text: "Hello there.")
        let h = await p.process(samples: Self.severe(), target: e.front, warmStart: false)
        #expect((h.maxZeroRunMs ?? 0) == 700)
        #expect(e.notices == [PipelineNotice.micCuttingOut])
    }

    /// The reported bug: first dictation after launch, quiet room, the tip fired on cold-start
    /// engine mute. A cold-start-shaped clip (zeros with a ±1 LSB blip, fade-in, clean speech)
    /// measures nothing and never warns, warm or cold, however often it repeats.
    @Test func coldStartShapedClipNeverWarns() async {
        let (e, p) = await makeEnv(text: "Hello.")
        for warm in [false, true, false] {
            let h = await p.process(samples: ZeroGateDetectorTests.coldStartClip(), target: e.front, warmStart: warm)
            #expect(h.zeroFraction == 0 && h.maxZeroRunMs == 0)
        }
        #expect(e.notices.isEmpty && !p.gatingTipShown)
    }

    @Test func coldStartMuteIsNotCountedAsGating() async {
        let (e, p) = await makeEnv(text: "Hello.")
        let cold = [Float](repeating: 0, count: 3_200) + ZeroGateDetectorTests.tone(16_000)
        let h = await p.process(samples: cold, target: e.front, warmStart: false)
        #expect(h.zeroFraction == 0 && e.notices.isEmpty)
    }

    @Test func micModeAndWarmStartRecordedFromRecordingStart() async {
        let (e, p) = await makeEnv()
        p.micModeProvider = { "Voice Isolation" }
        e.audio.warmStart = true
        p.handle(.startRecording)
        p.micModeProvider = { "Standard" }                                    // changed after start: ignored
        p.handle(.commitRecording)
        await p.drain()
        let h = e.history.entries.last!
        #expect(h.micMode == "Voice Isolation" && h.warmStart == true)
        #expect(h.inputLevelDBFS != nil && h.noiseFloorDBFS != nil && h.zeroFraction != nil)
    }
}
