import Testing
import Foundation
@testable import WisprLocalCore

/// Audio fake for the warm-mic controller: records enter/leave calls and the stop intent.
@MainActor final class WarmAudioSpy: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    var onMaxDurationReached: (() -> Void)?
    var warm = false, enters = 0, leaves = 0, failEnter = false
    var vpEnabled = false
    var keepWarmAfterStop = false
    func start() throws {}
    func stop(tail: Duration) async -> [Float] { if !keepWarmAfterStop { warm = false }; return [] }
    func cancel() {}
    func enterWarm() throws {
        if vpEnabled { throw AudioError.startFailed("warm mode is off while Noise reduction is on") }
        if failEnter { throw AudioError.startFailed("test") }
        enters += 1; warm = true
    }
    func leaveWarm() { leaves += 1; warm = false }
    var isWarm: Bool { warm }
}

@Suite struct PreRollTests {
    static func ramp(_ n: Int, from: Int = 0) -> [Float] { (from..<(from + n)).map { Float($0) } }

    @Test func ringKeepsNewestInOrderAcrossWraparound() {
        var r = PreRollRing(capacity: 8000)
        r.write(Self.ramp(5000))
        r.write(Self.ramp(6000, from: 5000))       // total 11,000 → wraps
        #expect(r.count == 8000)
        #expect(r.last(4800) == Self.ramp(4800, from: 6200))
        #expect(r.last(99_999) == Self.ramp(8000, from: 3000))
        r.write(Self.ramp(20_000, from: 11_000))   // longer than capacity in one write
        #expect(r.last(3) == [30_997, 30_998, 30_999])
    }

    @Test func zeroAndFreeReleasesEverything() {
        var r = PreRollRing(capacity: 100)
        r.write(Self.ramp(100, from: 1))
        r.zeroAndFree()
        #expect(!r.isAllocated && r.count == 0 && r.last(100).isEmpty)
        r.write(Self.ramp(10))                     // a freed ring ignores writes
        #expect(r.last(10).isEmpty)
    }

    @Test func constants() {
        #expect(MicWarmPolicy.samples(MicWarmPolicy.preRoll) == 4800)       // 300 ms @ 16 kHz
        #expect(MicWarmPolicy.samples(MicWarmPolicy.ringDuration) == 8000)  // 500 ms
        #expect(MicWarmPolicy.window == 60)
    }

    /// The prepend: exactly the 300 ms before key-down, oldest first, then live audio, no gap.
    @Test func warmStartPrependsLast300msInOrder() {
        let sink = SampleSink(maxSamples: 1_000_000)
        sink.enableRing()
        let before = Self.ramp(10_000)                 // 625 ms of "room" audio while warm
        before.withUnsafeBufferPointer { _ = sink.append($0) }
        #expect(sink.begin(preRoll: 4800) == 4800)
        let live = Self.ramp(1600, from: 10_000)
        live.withUnsafeBufferPointer { _ = sink.append($0) }
        let got = sink.end()
        #expect(got.count == 4800 + 1600)
        #expect(Array(got.prefix(4800)) == Self.ramp(4800, from: 5200))
        #expect(Array(got.suffix(1600)) == live)
        #expect(zip(got, got.dropFirst()).allSatisfy { $1 == $0 + 1 }, "continuous, in sample order")
    }

    @Test func coldStartPrependsNothing() {
        let sink = SampleSink(maxSamples: 1_000_000)
        Self.ramp(8000).withUnsafeBufferPointer { _ = sink.append($0) }  // not warm: dropped
        #expect(sink.begin(preRoll: 4800) == 0)
        #expect(sink.end().isEmpty)
    }

    @Test func disableRingZeroesAndFrees() {
        let sink = SampleSink(maxSamples: 1_000_000)
        sink.enableRing()
        [Float](repeating: 0.4242, count: 8000).withUnsafeBufferPointer { _ = sink.append($0) }
        #expect(sink.ringSnapshotForTesting().count == 8000)
        sink.disableRing()
        #expect(!sink.ringEnabled && sink.ringSnapshotForTesting().isEmpty)
        #expect(sink.begin(preRoll: 4800) == 0, "nothing left to prepend")
    }
}

@MainActor @Suite struct WarmMicControllerTests {
    final class Clock { var t = Date(timeIntervalSince1970: 1_000_000) }

    func make(keep: Bool = true, always: Bool = false, vp: Bool = false) -> (WarmMicController, WarmAudioSpy, Clock, (secure: Box, conflict: Box)) {
        let a = WarmAudioSpy(), c = Clock(), s = Box(), k = Box()
        let ctl = WarmMicController(audio: a, keepReady: { keep }, alwaysReady: { always },
                                    voiceProcessingOn: { vp }, now: { c.t }, isSecureInputActive: { s.on }, isConflictActive: { k.on })
        return (ctl, a, c, (s, k))
    }
    final class Box { var on = false }

    @Test func voiceProcessingDisablesWindowAfterDictation() {
        let (w, a, _, _) = make(vp: true)
        w.start(); w.dictationFinished()
        #expect(a.enters == 0 && !a.keepWarmAfterStop)
        #expect(!w.isWarm && !a.warm)
    }

    @Test func voiceProcessingDisablesAlwaysReadyAndPrivacyRearming() {
        let (w, a, _, _) = make(always: true, vp: true)
        w.start()
        #expect(a.enters == 0 && !a.keepWarmAfterStop)
        for reason in [WarmMicController.Reason.screenLocked, .sleep, .userSwitched, .conflict, .secureInput] {
            w.block(reason); w.clear(reason)
            #expect(a.enters == 0 && !a.keepWarmAfterStop && !w.isWarm)
        }
    }

    @Test func voiceProcessingToggleDropsWarmAndRestoresAlwaysReady() {
        let a = WarmAudioSpy(), vp = Box()
        let w = WarmMicController(audio: a, keepReady: { true }, alwaysReady: { true },
                                  voiceProcessingOn: { vp.on })
        w.start()
        #expect(w.isWarm && a.enters == 1 && a.keepWarmAfterStop)
        vp.on = true; w.settingsChanged()
        #expect(a.leaves == 1 && !w.isWarm && !a.warm && !a.keepWarmAfterStop)
        vp.on = false; w.settingsChanged()
        #expect(w.isWarm && a.enters == 2 && a.keepWarmAfterStop)
    }

    @Test func voiceProcessingToggleRestoresWindowOnlyAfterDictation() {
        let a = WarmAudioSpy(), vp = Box()
        let w = WarmMicController(audio: a, keepReady: { true }, alwaysReady: { false },
                                  voiceProcessingOn: { vp.on })
        w.dictationFinished()
        vp.on = true; w.settingsChanged()
        #expect(a.leaves == 1 && !w.isWarm && !a.keepWarmAfterStop)
        vp.on = false; w.settingsChanged()
        #expect(a.enters == 1 && !w.isWarm && a.keepWarmAfterStop)
        w.dictationFinished()
        #expect(a.enters == 2 && w.isWarm)
    }

    @Test func defaultLaunchDoesNotArmWindow() {
        let (w, a, _, _) = make()
        w.start()
        #expect(a.enters == 0 && !w.isWarm && a.keepWarmAfterStop)
    }

    @Test func windowAfterDictationThenExpiryStopsEngine() {
        let (w, a, c, _) = make()
        #expect(a.keepWarmAfterStop, "recorder stays running after a stop while allowed")
        w.dictationFinished()
        #expect(w.mode == .window(until: c.t.addingTimeInterval(60)) && a.warm && a.enters == 1)
        c.t += 18; w.tick()
        w.dictationFinished()                          // dictation inside the window resets it
        #expect(w.mode == .window(until: c.t.addingTimeInterval(60)))
        c.t += 60; w.tick()
        #expect(w.mode == .off && !a.warm && a.leaves == 1 && w.lastDrop == .expired)
    }

    @Test(arguments: [WarmMicController.Reason.screenLocked, .sleep, .userSwitched, .conflict, .secureInput, .quit])
    func everyPrivacyTriggerDropsImmediately(_ r: WarmMicController.Reason) {
        let (w, a, _, _) = make()
        w.dictationFinished()
        w.block(r)
        #expect(w.mode == .off && !a.warm && a.leaves == 1)
        #expect(!a.keepWarmAfterStop, "a blocked mic never stays on after the next stop")
        w.dictationFinished()
        #expect(w.mode == .off && a.enters == 1, "no re-arm while \(r) holds")
        w.clear(r)
        w.dictationFinished()
        #expect(w.isWarm, "re-arms after \(r) clears")
    }

    @Test func secureInputAndConflictArePolled() {
        let (w, a, _, probes) = make()
        w.dictationFinished()
        probes.secure.on = true; w.tick()
        #expect(w.mode == .off && !a.warm && w.lastDrop == .secureInput)
        probes.secure.on = false; w.tick()
        w.dictationFinished(); #expect(w.isWarm)
        probes.conflict.on = true; w.tick()
        #expect(w.mode == .off && w.lastDrop == .conflict)
    }

    @Test func alwaysReadyStaysOnAndRearmsAfterUnlock() {
        let (w, a, _, _) = make(keep: false, always: true)
        w.start()
        #expect(w.mode == .always && a.warm)
        w.block(.screenLocked)
        #expect(w.mode == .off && !a.warm)
        w.clear(.screenLocked)
        #expect(w.mode == .always && a.warm)
        w.stopNow()
        #expect(w.mode == .off && !a.warm && w.lastDrop == .userStopped)
    }

    @Test func offSettingsNeverWarm() {
        let (w, a, _, _) = make(keep: false, always: false)
        #expect(!a.keepWarmAfterStop)
        w.dictationFinished(); w.start()
        #expect(w.mode == .off && a.enters == 0)
    }

    @Test func orphanWarmEngineGetsAWindowOrStops() {
        let (w, a, c, _) = make()
        a.warm = true                                   // e.g. a cancelled tap left it running
        w.tick()
        #expect(w.mode == .window(until: c.t.addingTimeInterval(60)))
    }

    @Test(arguments: [false, true])
    func releasedWarmEngineDropsControllerAndMenu(always: Bool) {
        let (w, a, _, _) = make(always: always)
        if always { w.start() } else { w.dictationFinished() }
        #expect(w.isWarm && a.enters == 1)
        a.warm = false  // recorder releases after default input changes to Bluetooth
        w.tick()
        #expect(w.mode == .off && !w.isWarm && w.secondsLeft == 0 && w.lastDrop == .failed)
        #expect(a.leaves == 1 && a.enters == 1 && !a.warm)
        w.tick()
        #expect(a.enters == 1 && a.leaves == 1, "Later ticks must not re-arm or repeatedly drop")
        // AppController maps .off to a nil micReady menu snapshot.
        let ready: MenuSnapshot.MicReady? = switch w.mode {
        case .off: nil
        case .always: .always
        case .window: .window(secondsLeft: w.secondsLeft)
        }
        let snapshot = MenuSnapshot(micReady: ready)
        #expect(ready == nil && MenuBarIconState.resolve(snapshot) == .idle)
        #expect(MenuAttention.resolve(snapshot)?.action != .stopMic)
    }

    @Test func failedStartIsReported() {
        let (w, a, _, _) = make()
        a.failEnter = true
        w.dictationFinished()
        #expect(w.mode == .off && w.lastDrop == .failed)
    }

    @Test(arguments: [false, true]) func voiceProcessingRefusalDropsWarmAsFailed(always: Bool) {
        let (w, a, _, _) = make(always: always)
        // The recorder can observe VP before the controller's setting closure does.
        a.vpEnabled = true
        if always { w.start() } else { w.dictationFinished() }
        #expect(w.mode == .off && w.lastDrop == .failed && w.secondsLeft == 0)
        #expect(!a.warm && a.enters == 0 && a.leaves == 1)
    }
}

/// Cold vs warm HUD cue (the pill's "starting" dot).
@MainActor @Suite struct RecordingCueTests {
    @Test func coldStartShowsStartingUntilAudioFlows() async {
        let (e, p) = await makeEnv()
        e.audio.warmStart = false
        p.handle(.startRecording)
        #expect(p.recordingCue == .starting)
        e.audio.onLevel?(0)                             // muted start-up frames
        #expect(p.recordingCue == .starting)
        e.audio.onLevel?(8 * 1.0 / 32_767 / 18)         // a ±1 LSB blip in a 341-sample buffer
        #expect(p.recordingCue == .starting, "a start-up blip is not audio flowing")
        e.audio.onLevel?(0.12)                          // first real audio
        #expect(p.recordingCue == .live)
        p.handle(.cancelRecording)
    }

    @Test func warmStartIsLiveImmediately() async {
        let (e, p) = await makeEnv()
        e.audio.warmStart = true
        p.handle(.startRecording)
        #expect(p.recordingCue == .live)
        p.handle(.cancelRecording)
    }
}

/// PRIVACY (STRUCTURAL): the pre-roll ring never reaches disk, history, debug recordings or logs.
@Suite struct PreRollPrivacyTests {
    static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    /// Ring symbols appear only in the two audio files, and those files touch no persistence API.
    @Test func ringIsConfinedToAudioCode() throws {
        let allowed: Set<String> = ["PreRoll.swift", "AudioRecorder.swift"]
        let ringSymbols = ["PreRollRing", "enableRing", "disableRing", "ringSnapshotForTesting", "ring?."]
        let banned = ["FileManager", "write(to", "UserDefaults", "HistoryStore", "HistoryEntry", "DebugRecordingStore",
                      "JSONEncoder", "Codable", "NSPasteboard", "createFile", "FileHandle"]
        let e = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)!
        var checked = 0
        for case let f as URL in e where f.pathExtension == "swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            if allowed.contains(f.lastPathComponent) {
                checked += 1
                for b in banned { #expect(!text.contains(b), "\(f.lastPathComponent) uses \(b)") }
                for line in text.components(separatedBy: "\n") where line.contains("Log.") {
                    #expect(!line.lowercased().contains("ring") && !line.contains("samples"), "log line near the ring: \(line)")
                }
            } else {
                for sym in ringSymbols { #expect(!text.contains(sym), "\(f.lastPathComponent) references \(sym)") }
            }
        }
        #expect(checked == 2)
    }

    /// Runtime spy: a warm period with no dictation leaves nothing in history or debug recordings,
    /// and the marker audio is gone after the drop.
    @Test @MainActor func warmPeriodWithoutDictationPersistsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prespy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let debug = DebugRecordingStore(directory: dir, isEnabled: { true })
        let (e, p) = await makeEnv(debugRecordings: debug)
        let sink = SampleSink(maxSamples: 1_000_000)
        sink.enableRing()
        let marker = [Float](repeating: 0.31337, count: 8000)
        marker.withUnsafeBufferPointer { _ = sink.append($0) }
        // A lone tap (start + cancel) and an expiry: the ring is never read.
        p.handle(.startRecording); p.handle(.cancelRecording)
        sink.disableRing()
        await p.flushDebugRecordings()
        #expect(e.history.entries.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
        #expect(!sink.ringSnapshotForTesting().contains(0.31337))
    }
}
