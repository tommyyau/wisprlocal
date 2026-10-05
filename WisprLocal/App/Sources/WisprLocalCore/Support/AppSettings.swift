import Foundation
import Observation

/// User settings persisted in UserDefaults.
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var voiceProcessingEnabled: Bool { didSet { defaults.set(voiceProcessingEnabled, forKey: Keys.voiceProcessing) } }
    public var asrVariant: ASRModelVariant { didSet { defaults.set(asrVariant.rawValue, forKey: Keys.asrVariant) } }
    /// "Noisy room / other languages (Parakeet Ultra)". OFF (default) = "English (Parakeet v2)".
    /// Persisted; `ASRModelVariant.forMode(noisyRoom:)` maps it to the model that is loaded.
    public var noisyRoomMode: Bool { didSet { defaults.set(noisyRoomMode, forKey: Keys.noisyRoomMode) } }
    /// The model the current mode loads.
    public var activeASRVariant: ASRModelVariant { .forMode(noisyRoom: noisyRoomMode) }
    /// "Microphone readiness: Ready for 60 s after dictating" — default ON (`WarmMicController`).
    public var keepMicReady: Bool { didSet { defaults.set(keepMicReady, forKey: Keys.keepMicReady) } }
    /// "Always ready (mic stays on)" — default OFF.
    public var alwaysMicReady: Bool { didSet { defaults.set(alwaysMicReady, forKey: Keys.alwaysMicReady) } }
    public var consumeGlobeKey: Bool { didSet { defaults.set(consumeGlobeKey, forKey: Keys.consumeGlobe) } }
    /// "Wispr Flow uses a different shortcut" — default OFF. When ON, a running Wispr Flow
    /// doesn't make WisprLocal hold off (`ConflictDetector.differentShortcut`).
    public var wisprFlowUsesDifferentShortcut: Bool {
        didSet { defaults.set(wisprFlowUsesDifferentShortcut, forKey: Keys.wisprFlowDifferentShortcut) }
    }
    public var historyDirectory: URL { didSet { defaults.set(historyDirectory.path, forKey: Keys.historyDir) } }
    /// Takes effect on next launch.
    public var dictionaryURL: URL { didSet { defaults.set(dictionaryURL.path, forKey: Keys.dictionaryPath) } }
    public var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Keys.onboarding) } }
    /// "AI formatting (lists & punctuation) — adds up to ~1.5 s". OFF by
    /// default: Parakeet already punctuates and the guard only lets the model change punctuation,
    /// casing and list layout, so the 0.5–4 s FM call rarely pays. Even when OFF, the pipeline's
    /// auto mode calls FM for utterances with list cues (`CleanupPolicy`). Persisted under a NEW
    /// key (`aiFormattingEnabled`): the old `aiCleanupEnabled` key had a default-ON meaning and
    /// is deliberately ignored, so existing installs start with the fast path.
    public var aiCleanupEnabled: Bool { didSet { defaults.set(aiCleanupEnabled, forKey: Keys.aiCleanup) } }
    /// MAX timeout for the FM cleanup call, seconds (default 5.0). The per-call timeout is
    /// clamp(1.0 s + 15 ms × words, 2 s, this).
    public var aiCleanupMaxTimeout: Double { didSet { defaults.set(aiCleanupMaxTimeout, forKey: Keys.aiCleanupMaxTimeout) } }
    /// "Keep last 20 recordings (on this Mac)" — ON by default (replay and Heard vs Inserted in
    /// History need a clip). Read live by `DebugRecordingStore` through the same UserDefaults key.
    public var keepDebugRecordings: Bool { didSet { defaults.set(keepDebugRecordings, forKey: Keys.keepDebugRecordings) } }
    /// Home says "Welcome back, <first name>" (from the Mac account's full name). Default ON;
    /// OFF shows just "Welcome back", for screens other people can see.
    public var greetByName: Bool { didSet { defaults.set(greetByName, forKey: Keys.greetByName) } }

    /// Settings / onboarding label for `keepDebugRecordings`.
    public static let keepRecordingsLabel = "Keep last \(DebugRecordingStore.defaultLimit) recordings (on this Mac)"

    /// Settings label for `aiCleanupEnabled`.
    public static let aiFormattingHelp = "Off: lists are still formatted automatically when you dictate list cues (\"first… second…\", \"number one\", \"bullet point\")."

    enum Keys {
        static let voiceProcessing = "voiceProcessingEnabled"
        static let asrVariant = "asrVariant"
        static let noisyRoomMode = "noisyRoomMode"
        static let keepMicReady = "keepMicReady"
        static let alwaysMicReady = "alwaysMicReady"
        static let consumeGlobe = "consumeGlobeKey"
        static let wisprFlowDifferentShortcut = "wisprFlowUsesDifferentShortcut"
        static let historyDir = "historyDirectory"
        static let dictionaryPath = "dictionaryPath"
        static let onboarding = "onboardingCompleted"
        static let aiCleanup = "aiFormattingEnabled"
        /// Pre-latency-fix key (default ON); ignored.
        static let legacyAICleanup = "aiCleanupEnabled"
        static let aiCleanupMaxTimeout = "aiCleanupMaxTimeout"
        static let keepDebugRecordings = DebugRecordingStore.defaultsKey
        static let greetByName = "greetByName"
    }

    /// "Noise reduction" when the user never chose (`VoiceProcessingDefaultTests`).
    public static let voiceProcessingDefault = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // OFF by default since 2026-10-03: on a plane 15 of 20 real dictations had speech
        // digitally gated by voice processing (median 10 % silenced, gaps up to 481 ms) — deleted
        // speech is worse than noise. Only an explicit stored value turns it on.
        voiceProcessingEnabled = defaults.object(forKey: Keys.voiceProcessing) as? Bool ?? Self.voiceProcessingDefault
        asrVariant = defaults.string(forKey: Keys.asrVariant).flatMap(ASRModelVariant.init(rawValue:)) ?? .default
        noisyRoomMode = defaults.object(forKey: Keys.noisyRoomMode) as? Bool ?? false
        keepMicReady = defaults.object(forKey: Keys.keepMicReady) as? Bool ?? true
        alwaysMicReady = defaults.object(forKey: Keys.alwaysMicReady) as? Bool ?? false
        consumeGlobeKey = defaults.object(forKey: Keys.consumeGlobe) as? Bool ?? true
        wisprFlowUsesDifferentShortcut = defaults.bool(forKey: Keys.wisprFlowDifferentShortcut)
        historyDirectory = defaults.string(forKey: Keys.historyDir).map { URL(fileURLWithPath: $0) } ?? AppPaths.defaultHistoryDirectory
        dictionaryURL = defaults.string(forKey: Keys.dictionaryPath).map { URL(fileURLWithPath: $0) } ?? AppPaths.defaultDictionaryURL
        onboardingCompleted = defaults.bool(forKey: Keys.onboarding)
        aiCleanupEnabled = defaults.object(forKey: Keys.aiCleanup) as? Bool ?? false
        aiCleanupMaxTimeout = defaults.object(forKey: Keys.aiCleanupMaxTimeout) as? Double ?? 5.0
        // Never set → ON (also for existing installs); an explicit OFF is kept. Not written back
        // here, so "never set" stays distinguishable from "set to OFF".
        keepDebugRecordings = DebugRecordingStore.isEnabled(in: defaults)
        greetByName = defaults.object(forKey: Keys.greetByName) as? Bool ?? true
    }
}

