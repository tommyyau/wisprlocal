import CryptoKit
import Foundation

public struct StageTimings: Codable, Sendable, Equatable {
    /// Key-down → published starting HUD; nil for legacy/replayed entries.
    public var keyDownToHUDMs: Double?
    /// Key-down → first non-zero captured buffer; nil if capture never began.
    public var keyDownToCaptureMs: Double?
    public var vadMs: Double = 0
    public var asrMs: Double = 0
    public var dictionaryMs: Double = 0
    public var cleanupMs: Double = 0
    public var insertMs: Double = 0
    /// Hotkey release → pipeline end (history entry built).
    public var totalMs: Double = 0
    // Release-path breakdown (optional so older lines still decode):
    /// Key-up → capture stopped (adaptive tail, 150–400 ms).
    public var tailMs: Double?
    /// Capture stopped → pipeline job started (main-actor hops / job chain).
    public var handoffMs: Double?
    /// Conflict / secure-input / focus gates.
    public var gatesMs: Double?
    /// Waiting for the caret context (read concurrently with ASR) + JoinPolicy.
    public var joinMs: Double?
    /// KEY-UP → PASTE POSTED: the latency the user perceives (nil when nothing was inserted).
    public var perceivedMs: Double?
    public init() {}
}

public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case inserted
        case noSpeech
        case emptyAfterCleanup
        /// The mic heard the user but no words came out (`NoTextPolicy`): ≥ 0.5 s of VAD speech
        /// with an empty transcript, or > 1 s of loud input with no VAD speech at all. Never
        /// silent: the HUD says "Didn't catch that" and the clip is kept. `note` = the reason.
        case noTextRecognised
        case blockedByConflict
        case blockedBySecureInput
        case focusChanged
        case transcriptionTimedOut
        case insertFailed
        case transcriptionFailed
        /// The paired receiver refused: a password field (Secure Event Input) is focused on the
        /// remote Mac (SEC-4). Text was not inserted (the receiver refused it), and the typing fallback did NOT run.
        case blockedByRemoteSecureInput
        /// The user cancelled it (Esc, or a triple-tap of 🌐 in hands-free). Nothing was typed,
        /// no text is kept and the audio is discarded.
        case cancelled

        /// SEC-2 (STRUCTURAL): dictated text (raw, final, cleanup candidate/verdict, snippet
        /// trigger, join) is attached to the history entry ONLY when the text was delivered.
        /// Every refusal and failure path is outcome-only (timestamp, outcome, app, timings).
        /// Exhaustive switch: a new outcome must decide explicitly.
        public var retainsContent: Bool {
            switch self {
            case .inserted: return true
            case .noSpeech, .emptyAfterCleanup, .noTextRecognised, .blockedByConflict, .blockedBySecureInput,
                 .focusChanged, .transcriptionTimedOut, .insertFailed, .transcriptionFailed, .blockedByRemoteSecureInput,
                 .cancelled:
                return false
            }
        }

        /// SEC-2 safety refusals: a gate stopped the text on purpose (password field here or on
        /// the remote Mac, the user switched apps, Wispr Flow has priority). Exhaustive switch.
        public var isSafetyRefusal: Bool {
            switch self {
            case .blockedByConflict, .blockedBySecureInput, .focusChanged, .blockedByRemoteSecureInput: return true
            case .inserted, .noSpeech, .emptyAfterCleanup, .noTextRecognised, .transcriptionTimedOut, .insertFailed,
                 .transcriptionFailed, .cancelled:
                return false
            }
        }

        /// Whether the troubleshooting recording (audio) may be kept for this outcome.
        /// Retention table (2026-10-03, `RetentionTests.outcomePolicyTable`):
        ///
        /// | outcome                      | text kept | audio kept |
        /// |------------------------------|-----------|------------|
        /// | inserted                     | yes       | yes        |
        /// | noSpeech / emptyAfterCleanup | no        | yes        |
        /// | noTextRecognised             | no        | yes        |
        /// | transcriptionTimedOut/Failed | no        | yes        |
        /// | insertFailed                 | no        | yes        |
        /// | blockedBySecureInput         | no        | NO         |
        /// | blockedByRemoteSecureInput   | no        | NO         |
        /// | focusChanged                 | no        | NO         |
        /// | blockedByConflict            | no        | NO         |
        /// | cancelled                    | no        | NO         |
        ///
        /// Failed and empty dictations are exactly the ones worth replaying ("I could see the
        /// waveform but nothing came out"), so they keep audio; only the SEC-2 safety refusals
        /// stay audio-free (the user may have been speaking a password, or the text belongs to
        /// another app / Wispr Flow).
        /// A cancelled dictation is discarded entirely: the user said "not this one".
        public var mayKeepDebugAudio: Bool { !isSafetyRefusal && self != .cancelled }
    }

    /// Stable identity. Links the entry to its troubleshooting clip (`<id>.wav` + `<id>.json`,
    /// never by timestamp). Lines written before ids existed get a deterministic id derived from
    /// the line's bytes on read (`HistoryStore.readAll`), so it stays the same across reads and is
    /// persisted the next time the file is rewritten.
    public var id: UUID
    public var timestamp: Date
    public var raw: String
    public var final: String
    public var engine: String
    public var cleaner: String
    public var audioDuration: TimeInterval
    public var speechDuration: TimeInterval
    public var latencies: StageTimings
    public var frontmostApp: String?
    public var insertionStrategy: String?
    public var outcome: Outcome
    public var note: String?
    // P2 (all optional so P1 lines still decode)
    /// FM path verdict: "ok", "reject:<reason>", "timeout", "guardrail", "unavailable:<r>", …
    public var cleanupVerdict: String?
    /// FM output that was NOT used (guard rejected) — for tuning.
    public var cleanupCandidate: String?
    /// FM call latency (ms), when called.
    public var cleanupModelMs: Double?
    /// Trigger of the snippet that replaced the utterance.
    public var snippetTrigger: String?
    /// Smart join: how the text was joined to the caret context ("ax:<adjusted>" / "fallback:space"),
    /// nil when inserted verbatim.
    public var join: String?
    /// Number of words ASR recognised (a COUNT, never content), kept on every outcome so the
    /// self-test can tell "heard words but refused" from "heard nothing" without the text.
    public var rawWordCount: Int?
    /// Language code NLLanguageRecognizer gave the raw text (3+ words only); content-free.
    /// Non-English skips cleanup (`CleanupLanguagePolicy`).
    public var language: String?
    /// Apple voice processing ("Noise reduction") was active for this capture; nil =
    /// unknown (older lines, fakes). Also lands in the debug-recording sidecar (`--compare-all`).
    public var voiceProcessingActive: Bool?
    /// Zero-gating detector (`AudioGatingMetrics`): fraction of the dictation's audio that was
    /// digitally silenced, and the longest silent run (ms). Content-free numbers.
    public var zeroFraction: Double?
    public var maxZeroRunMs: Double?
    /// The recording started on a warm engine (300 ms pre-roll prepended); false = cold start.
    public var warmStart: Bool?
    /// `CaptureLevel` of the whole capture (dBFS): loud parts and noise floor.
    public var inputLevelDBFS: Double?
    public var noiseFloorDBFS: Double?
    /// macOS Mic Mode at recording start ("Standard" / "Voice Isolation" / "Wide Spectrum").
    public var micMode: String?
    /// BUG C evidence: the paste was verified to land (AX field changed) / verifiably did not /
    /// nil = could not verify (Electron). Plus whether Cmd-V was retried and the clipboard-restore
    /// delay that was used.
    public var pasteVerified: Bool?
    public var pasteRetried: Bool?
    public var pasteRestoreDelayMs: Double?
    /// Per-app style applied as the last pass ("formal", "casual", "veryCasual", "code"); nil = none.
    public var style: String?
    /// Opt-in backtrack replaced a restated value ("at 2, actually 3" → "at 3"). Heard vs
    /// Inserted shows the removed words.
    public var backtrackApplied: Bool?
    /// Smart dictionary: how many words were snapped to a context name (a COUNT, never text);
    /// nil when Settings › Writing › "Names and terms near your cursor" didn't run.
    public var contextSnaps: Int?

    /// ASR recognised at least one word (content-free check).
    public var recognisedWords: Bool {
        (rawWordCount ?? 0) > 0 || !raw.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public init(id: UUID = UUID(), timestamp: Date = Date(), raw: String = "", final: String = "", engine: String = "",
                cleaner: String = "", audioDuration: TimeInterval = 0, speechDuration: TimeInterval = 0,
                latencies: StageTimings = StageTimings(), frontmostApp: String? = nil,
                insertionStrategy: String? = nil, outcome: Outcome, note: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.raw = raw; self.final = final; self.engine = engine
        self.cleaner = cleaner; self.audioDuration = audioDuration; self.speechDuration = speechDuration
        self.latencies = latencies; self.frontmostApp = frontmostApp
        self.insertionStrategy = insertionStrategy; self.outcome = outcome; self.note = note
    }
}

extension HistoryEntry {
    enum CodingKeys: String, CodingKey {
        case id, timestamp, raw, final, engine, cleaner, audioDuration, speechDuration, latencies, frontmostApp,
             insertionStrategy, outcome, note, cleanupVerdict, cleanupCandidate, cleanupModelMs, snippetTrigger, join,
             rawWordCount, language, voiceProcessingActive, zeroFraction, maxZeroRunMs, warmStart,
             inputLevelDBFS, noiseFloorDBFS, micMode, pasteVerified, pasteRetried, pasteRestoreDelayMs,
             style, backtrackApplied, contextSnaps
    }

    /// `decoder.userInfo` key: the raw bytes of the line being decoded. A line without an `id`
    /// gets `legacyID(for:)` of these bytes (stable across reads); without it, a fresh UUID.
    public static let legacyIDSeedKey = CodingUserInfoKey(rawValue: "wisprlocal.history.legacyIDSeed")!

    /// Deterministic UUID (SHA-256 of `seed`, RFC 4122 version/variant bits set).
    public static func legacyID(for seed: Data) -> UUID {
        var b = Array(SHA256.hash(data: seed).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = id
        } else if let seed = decoder.userInfo[Self.legacyIDSeedKey] as? Data {
            self.id = Self.legacyID(for: seed)
        } else {
            self.id = UUID()
        }
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        raw = try c.decode(String.self, forKey: .raw)
        final = try c.decode(String.self, forKey: .final)
        engine = try c.decode(String.self, forKey: .engine)
        cleaner = try c.decode(String.self, forKey: .cleaner)
        audioDuration = try c.decode(TimeInterval.self, forKey: .audioDuration)
        speechDuration = try c.decode(TimeInterval.self, forKey: .speechDuration)
        latencies = try c.decode(StageTimings.self, forKey: .latencies)
        frontmostApp = try c.decodeIfPresent(String.self, forKey: .frontmostApp)
        insertionStrategy = try c.decodeIfPresent(String.self, forKey: .insertionStrategy)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        cleanupVerdict = try c.decodeIfPresent(String.self, forKey: .cleanupVerdict)
        cleanupCandidate = try c.decodeIfPresent(String.self, forKey: .cleanupCandidate)
        cleanupModelMs = try c.decodeIfPresent(Double.self, forKey: .cleanupModelMs)
        snippetTrigger = try c.decodeIfPresent(String.self, forKey: .snippetTrigger)
        join = try c.decodeIfPresent(String.self, forKey: .join)
        rawWordCount = try c.decodeIfPresent(Int.self, forKey: .rawWordCount)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        voiceProcessingActive = try c.decodeIfPresent(Bool.self, forKey: .voiceProcessingActive)
        zeroFraction = try c.decodeIfPresent(Double.self, forKey: .zeroFraction)
        maxZeroRunMs = try c.decodeIfPresent(Double.self, forKey: .maxZeroRunMs)
        warmStart = try c.decodeIfPresent(Bool.self, forKey: .warmStart)
        inputLevelDBFS = try c.decodeIfPresent(Double.self, forKey: .inputLevelDBFS)
        noiseFloorDBFS = try c.decodeIfPresent(Double.self, forKey: .noiseFloorDBFS)
        micMode = try c.decodeIfPresent(String.self, forKey: .micMode)
        pasteVerified = try c.decodeIfPresent(Bool.self, forKey: .pasteVerified)
        pasteRetried = try c.decodeIfPresent(Bool.self, forKey: .pasteRetried)
        pasteRestoreDelayMs = try c.decodeIfPresent(Double.self, forKey: .pasteRestoreDelayMs)
        style = try c.decodeIfPresent(String.self, forKey: .style)
        backtrackApplied = try c.decodeIfPresent(Bool.self, forKey: .backtrackApplied)
        contextSnaps = try c.decodeIfPresent(Int.self, forKey: .contextSnaps)
    }
}

/// The dictated content of one utterance, held apart from the `HistoryEntry` until the pipeline
/// knows the outcome (SEC-2). `attach(to:)` is the ONLY way content reaches an entry.
public struct HistoryContent: Sendable, Equatable {
    public var raw = ""
    public var final = ""
    public var cleanupVerdict: String?
    public var cleanupCandidate: String?
    public var snippetTrigger: String?
    public var join: String?
    public init() {}

    /// Copies the content into `entry` iff its outcome retains content; otherwise leaves the
    /// entry outcome-only.
    public func attach(to entry: inout HistoryEntry) {
        guard entry.outcome.retainsContent else { return }
        entry.raw = raw; entry.final = final
        entry.cleanupVerdict = cleanupVerdict; entry.cleanupCandidate = cleanupCandidate
        entry.snippetTrigger = snippetTrigger; entry.join = join
    }
}

public protocol HistoryWriting: Sendable {
    func append(_ entry: HistoryEntry)
}

/// Append-only JSON Lines file: `<directory>/history.jsonl`.
public final class HistoryStore: HistoryWriting, @unchecked Sendable {
    public let fileURL: URL
    let queue = DispatchQueue(label: "wisprlocal.history")

    let beforeRewrite: @Sendable () throws -> Void

    public init(directory: URL = AppPaths.defaultHistoryDirectory,
                beforeRewrite: @escaping @Sendable () throws -> Void = {}) {
        self.beforeRewrite = beforeRewrite
        fileURL = directory.appendingPathComponent("history.jsonl")
    }

    public func append(_ entry: HistoryEntry) {
        let url = fileURL
        queue.async {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var line = try? enc.encode(entry) else { return }
            line.append(0x0A)
            try? AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
            if let h = try? FileHandle(forUpdating: url) {
                defer { try? h.close() }
                if let end = try? h.seekToEnd(), end > 0 {
                    try? h.seek(toOffset: end - 1)
                    if let last = try? h.read(upToCount: 1), last.last != 10 {
                        _ = try? h.seekToEnd()
                        try? h.write(contentsOf: Data([10]))
                    }
                }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
                AppPaths.restrictToOwner(url)  // tightens files written by older builds
            } else {
                try? AppPaths.writePrivate(line, to: url)
            }
        }
    }

    /// Block until queued writes finish (tests).
    public func flush() { queue.sync {} }


}
