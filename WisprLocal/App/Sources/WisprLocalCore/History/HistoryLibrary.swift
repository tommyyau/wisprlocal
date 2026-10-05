import Foundation

/// History plus its troubleshooting clips, kept consistent in both directions:
/// deleting an entry (or Clear All) deletes its `<id>.wav` + `<id>.json`; deleting clips
/// (Settings › Privacy › Delete All, the rolling limit) only removes the play button, because
/// availability is always read from disk by id (`playback(for:clipIDs:)`).
public final class HistoryLibrary: @unchecked Sendable {
    public let history: HistoryStore
    public let index: HistoryIndex
    public let recordings: DebugRecordingStore

    public init(history: HistoryStore, recordings: DebugRecordingStore) {
        self.history = history; self.recordings = recordings
        index = HistoryIndex(store: history, recordings: recordings)
    }

    /// The playable clip for `entry`, nil when there is none. Outcome-only entries never have one.
    public func clipURL(for entry: HistoryEntry) -> URL? {
        guard entry.outcome.mayKeepDebugAudio else { return nil }
        return recordings.clipURL(for: entry.id)
    }
}

/// What a History row shows in its play-button slot.
public enum HistoryPlayback: Equatable, Sendable {
    /// A clip exists for this id: show the play button.
    case playable
    /// Delivered dictation without a clip: a subtle, disabled waveform with a tooltip.
    case noClip
    /// Refused / failed entry (SEC-2) without a clip: no text; only the outcome is shown.
    case outcomeOnly

    public static func of(_ entry: HistoryEntry, clipIDs: Set<UUID>) -> HistoryPlayback {
        // Outcome-only entries that may keep audio (failed / empty dictations) are playable when
        // their clip exists; safety refusals never are.
        guard entry.outcome.retainsContent else {
            return entry.outcome.mayKeepDebugAudio && clipIDs.contains(entry.id) ? .playable : .outcomeOnly
        }
        return clipIDs.contains(entry.id) ? .playable : .noClip
    }

    public var showsPlayButton: Bool { self == .playable }

    /// Tooltip for the disabled waveform.
    public static func noClipHelp(recordingOn: Bool) -> String {
        recordingOn
            ? "Only the last \(DebugRecordingStore.defaultLimit) dictations keep a recording"
            : "Turn on ‘Keep last 20 recordings’ in Settings › Privacy to replay dictations"
    }

    /// History's slim "Recordings are off" banner: shown only while recordings are OFF.
    public static func showsRecordingsOffBanner(recordingOn: Bool) -> Bool { !recordingOn }
    public static let recordingsOffBannerText = "Recordings are off — turn on to replay dictations"
}

/// Plain-English metadata for History › details (content-free fields only).
extension HistoryEntry {
    /// The model that transcribed this entry, nil when the engine id is not a known model.
    public var variant: ASRModelVariant? {
        engine.split(separator: ":").last.flatMap { ASRModelVariant(rawValue: String($0)) }
    }

    public var engineLabel: String { variant?.shortName ?? (engine.isEmpty ? "Unknown" : engine) }

    /// History › details "Mic audio": the zero-gating detector's numbers (content-free).
    public var micAudioLabel: String {
        guard let z = zeroFraction else { return "Not measured" }
        let m = AudioGatingMetrics(zeroFraction: z, maxZeroRunMs: maxZeroRunMs ?? 0)
        let base = "\(MicAudioDiagnostics.percent(z)) silenced, longest gap \(Int(m.maxZeroRunMs.rounded())) ms"
        return m.isCuttingOut ? base + " (cutting out)" : base
    }

    /// The "why" for an outcome-only entry the user may ask about (HUD "See why"). nil = the
    /// outcome label says it all.
    public var whyExplanation: String? {
        guard outcome == .noTextRecognised else { return nil }
        var parts: [String] = []
        if note == NoTextPolicy.Reason.loudNoSpeech.rawValue {
            parts.append(String(format: "The mic picked up %.1f s of loud sound, but no speech was detected in it.", audioDuration))
        } else {
            parts.append(String(format: "WisprLocal heard %.1f s of speech, but the speech model returned no words.", speechDuration))
        }
        let gating = AudioGatingMetrics(zeroFraction: zeroFraction ?? 0, maxZeroRunMs: maxZeroRunMs ?? 0)
        if gating.isCuttingOut {
            parts.append("Your mic audio was cutting out (\(MicAudioDiagnostics.percent(gating.zeroFraction)) went digitally silent, longest gap \(Int(gating.maxZeroRunMs.rounded())) ms). Noise reduction can do this in very loud places; try turning it off in Settings › Microphone, or set Mic Mode to Standard.")
        }
        let level = CaptureLevel(loudDBFS: inputLevelDBFS ?? -120, floorDBFS: noiseFloorDBFS ?? -120)
        if NoTextPolicy.isLoudPlace(level: level, gating: gating) {
            parts.append("In very loud places (planes, trains), a headset mic close to your mouth works far better than the built-in mic.")
        }
        parts.append("Play the recording to hear what the mic captured.")
        return parts.joined(separator: " ")
    }

    public var voiceProcessingLabel: String {
        switch voiceProcessingActive {
        case true?: return "On"
        case false?: return "Off"
        case nil: return "Not recorded"
        }
    }

    public var cleanupLabel: String {
        if cleaner == "fm" { return "AI (Apple Intelligence)" }
        if cleaner == "snippet" { return "Snippet" }
        if cleaner.hasPrefix("none:") { return "None (not English)" }
        if cleaner == "rules" {
            if let v = cleanupVerdict, v != "ok", !v.hasPrefix("skipped") { return "Rules (AI result not used)" }
            return "Rules"
        }
        return cleaner.isEmpty ? "—" : cleaner
    }

    /// How the text was joined to what was already in the field.
    public var joinLabel: String {
        guard let j = join else { return "Typed as dictated" }
        if j.hasPrefix("ax:") { return "Joined to the text before the cursor" }
        if j.hasPrefix("fallback:") { return "Joined to the previous dictation" }
        return "Adjusted"
    }

    public static let microphoneInterruptedNote = "Microphone interrupted"

    public var outcomeLabel: String {
        switch outcome {
        case .inserted: return "Typed"
        case .noSpeech: return "No speech heard"
        case .emptyAfterCleanup: return "Nothing left after cleanup"
        case .noTextRecognised: return "Didn't catch that: no words recognised"
        case .blockedByConflict: return "Not typed: Wispr Flow was running"
        case .blockedBySecureInput: return "Not typed: a password field was active"
        case .focusChanged: return "Not typed: you switched apps"
        case .transcriptionTimedOut: return "Speech model timed out"
        case .insertFailed: return "Couldn't type the text"
        case .transcriptionFailed: return "Speech model failed"
        case .blockedByRemoteSecureInput: return "Not typed: a password field was active on the remote Mac"
        case .cancelled: return note == Self.microphoneInterruptedNote ? Self.microphoneInterruptedNote : "Cancelled: nothing was typed"
        }
    }
}

extension ASRModelVariant {
    /// "Parakeet v2" / "Parakeet Ultra" (History details, re-transcribe button).
    public var shortName: String {
        switch self {
        case .parakeetV2: return "Parakeet v2"
        case .parakeetUltra: return "Parakeet Ultra"
        }
    }
}
