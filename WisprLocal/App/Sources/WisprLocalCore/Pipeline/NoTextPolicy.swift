import Foundation

/// Input level of one capture (content-free numbers for history and the "Didn't catch that"
/// notice), from 20 ms frames.
public struct CaptureLevel: Equatable, Sendable {
    /// 95th-percentile frame RMS, dBFS: how loud the loud parts were (voice, or loud noise).
    public var loudDBFS: Double
    /// 10th-percentile frame RMS over frames that are not digitally silent, dBFS: the room/noise
    /// floor the mic delivered (−120 when every frame was silent).
    public var floorDBFS: Double

    public static let silent = CaptureLevel(loudDBFS: -120, floorDBFS: -120)

    public static func measure(_ s: [Float], sampleRate: Double = AudioConstants.sampleRate) -> CaptureLevel {
        let frame = max(1, Int(sampleRate * 0.02))
        guard s.count >= frame else { return .silent }
        var rms: [Double] = []; rms.reserveCapacity(s.count / frame)
        var i = 0
        while i + frame <= s.count {
            var sum: Double = 0
            for k in i..<(i + frame) { sum += Double(s[k]) * Double(s[k]) }
            rms.append((sum / Double(frame)).squareRoot())
            i += frame
        }
        func db(_ v: Double) -> Double { v > 0 ? max(-120, 20 * log10(v)) : -120 }
        let sorted = rms.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let live = sorted.filter { $0 >= Double(AudioGatingMetrics.silenceThreshold) }
        let floor = live.isEmpty ? 0 : live[Int(Double(live.count) * 0.10)]
        return CaptureLevel(loudDBFS: db(loud), floorDBFS: db(floor))
    }
}

/// "Never silent" (STRUCTURAL): when the user clearly spoke but nothing comes out, say so.
public enum NoTextPolicy {
    /// VAD speech at least this long with an empty transcript → notice.
    public static let minSpeech: TimeInterval = 0.5
    /// VAD found no speech, but the capture was longer than this…
    public static let minCaptureForLoudNoSpeech: TimeInterval = 1.0
    /// …and its loud parts were above this (talking, all of it gated or unrecognisable).
    public static let loudInputDBFS = -35.0
    /// A noise floor above this is a loud place (plane cabin with voice processing off ≈ −28).
    public static let loudRoomFloorDBFS = -45.0

    public enum Reason: String, Sendable {
        /// A deliberate hold ended before the microphone delivered any real audio.
        case micNoAudio = "The mic didn't send any audio"
        /// The speech model returned no words for ≥ `minSpeech` of VAD speech.
        case asrEmpty = "asr:empty"
        /// VAD found no speech in a long, loud capture.
        case loudNoSpeech = "vad:none-loud"
    }

    /// Why nothing came out, when the user should be told; nil = stay quiet (accidental tap,
    /// genuinely silent room, a filler-only utterance).
    public static func reason(speechDuration: TimeInterval?, transcriptEmpty: Bool,
                              captureDuration: TimeInterval, level: CaptureLevel) -> Reason? {
        if let sp = speechDuration {
            return transcriptEmpty && sp >= minSpeech ? .asrEmpty : nil
        }
        return captureDuration > minCaptureForLoudNoSpeech && level.loudDBFS > loudInputDBFS ? .loudNoSpeech : nil
    }

    /// A loud place: the built-in mic is the wrong tool there. Judged by the noise floor or by
    /// holes in speech, never by how loud the voice was: normal speech at a laptop mic peaks
    /// around −24…−15 dBFS (33 of 36 quiet-room dictations measured above −20 on 2026-10-03), so
    /// a "loud parts > −20 dBFS" clause gave quiet rooms the headset advice.
    public static func isLoudPlace(level: CaptureLevel, gating: AudioGatingMetrics) -> Bool {
        level.floorDBFS > loudRoomFloorDBFS || gating.isCuttingOut
    }

    /// The HUD line. Adds the headset suggestion when the built-in mic is in a loud place.
    public static func notice(builtInMic: Bool?, level: CaptureLevel, gating: AudioGatingMetrics) -> String {
        builtInMic == true && isLoudPlace(level: level, gating: gating) ? PipelineNotice.didntCatchThatUseHeadset
                                                                        : PipelineNotice.didntCatchThat
    }
}
