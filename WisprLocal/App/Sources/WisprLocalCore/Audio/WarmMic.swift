import Foundation
import Observation

/// Keeps the microphone engine running between dictations so the next one doesn't lose its
/// first word to engine start-up (~185 ms lost with voice processing off).
///
/// - "Microphone readiness: Ready for 60 s after dictating" (default ON): warm for `MicWarmPolicy.window` after
///   each dictation; a dictation inside the window gets the last 300 ms prepended and restarts
///   the window when it finishes. On expiry the engine stops and the ring is zeroed and freed.
/// - "Always ready (mic stays on)" (default OFF): warm whenever allowed.
/// Noise reduction disables both modes so voice processing cannot duck other audio while idle.
///
/// PRIVACY (STRUCTURAL): warm mode is dropped at once, and the ring zeroed, on screen lock,
/// sleep, fast user switch, the Wispr Flow conflict gate, secure input, app quit, or "Stop now".
/// While a blocker holds, nothing re-arms. All state is in memory; nothing is persisted.
@MainActor
@Observable
public final class WarmMicController {
    public enum Mode: Equatable, Sendable {
        case off
        case window(until: Date)
        case always
    }

    /// Why warm mode ended (logged by name only).
    public enum Reason: String, Sendable, CaseIterable {
        case screenLocked, sleep, userSwitched, conflict, secureInput, quit
        case expired, userStopped, settingOff, failed

        /// Conditions that block re-arming until cleared.
        public var isBlocker: Bool {
            switch self {
            case .screenLocked, .sleep, .userSwitched, .conflict, .secureInput, .quit: return true
            case .expired, .userStopped, .settingOff, .failed: return false
            }
        }
    }

    public private(set) var mode: Mode = .off
    /// Whole seconds left in the window (menu line); refreshed by `tick()`.
    public private(set) var secondsLeft = 0
    public private(set) var lastDrop: Reason?
    @ObservationIgnored public private(set) var blockers: Set<Reason> = []

    @ObservationIgnored private let audio: AudioCapturing
    @ObservationIgnored private let keepReady: () -> Bool
    @ObservationIgnored private let alwaysReady: () -> Bool
    @ObservationIgnored private let voiceProcessingOn: () -> Bool
    @ObservationIgnored public var now: () -> Date
    @ObservationIgnored public var isSecureInputActive: () -> Bool
    @ObservationIgnored public var isConflictActive: () -> Bool

    public init(audio: AudioCapturing, keepReady: @escaping () -> Bool, alwaysReady: @escaping () -> Bool,
                voiceProcessingOn: @escaping () -> Bool = { false },
                now: @escaping () -> Date = { Date() },
                isSecureInputActive: @escaping () -> Bool = { false },
                isConflictActive: @escaping () -> Bool = { false }) {
        self.audio = audio; self.keepReady = keepReady; self.alwaysReady = alwaysReady
        self.voiceProcessingOn = voiceProcessingOn
        self.now = now; self.isSecureInputActive = isSecureInputActive; self.isConflictActive = isConflictActive
        syncStopIntent()
    }

    public var isWarm: Bool { mode != .off }

    /// Launch / settings change.
    public func start() { settingsChanged() }

    /// A dictation finished (any outcome): (re)start the window, or stay always-ready.
    public func dictationFinished() { arm() }

    public func settingsChanged() {
        syncStopIntent()
        if !canArm {
            if isWarm { drop(.settingOff) }
            return
        }
        if alwaysReady() { arm(); return }
        switch mode {
        case .always: drop(.settingOff)
        case .window where !keepReady(): drop(.settingOff)
        default: break
        }
    }

    /// Once a second (twice while warm is fine): expiry, secure input, the conflict gate, and an
    /// engine left warm by `keepWarmAfterStop` without a window (e.g. a cancelled tap).
    public func tick() {
        updateBlocker(.secureInput, isSecureInputActive())
        updateBlocker(.conflict, isConflictActive())
        if isWarm && !audio.isWarm {
            drop(.failed, logMessage: "mic warm ended (engine no longer warm: input change, Bluetooth idle policy or engine stop)")
            return
        }
        if case .window(let until) = mode {
            let left = until.timeIntervalSince(now())
            if left <= 0 { drop(.expired); return }
            secondsLeft = Int(left.rounded(.up))
        }
        if mode == .off, audio.isWarm {
            // Recorder stayed warm after a stop the controller didn't see (cancelled tap): give it
            // a window if allowed, otherwise stop it now.
            if canArm { arm() } else { audio.leaveWarm() }
        }
    }

    /// Screen lock, sleep, user switch, conflict, secure input, quit: drop now and stay off
    /// until `clear(_:)`.
    public func block(_ r: Reason) {
        blockers.insert(r)
        syncStopIntent()
        drop(r)
    }

    public func clear(_ r: Reason) {
        guard blockers.remove(r) != nil else { return }
        syncStopIntent()
        if alwaysReady() { arm() }
    }

    /// Menu "Stop now".
    public func stopNow() { drop(.userStopped) }

    // MARK: -

    /// The conflict closure is read directly too (a cached flag), so a dictation finishing just
    /// as Wispr Flow appears can't re-arm before the next tick records the blocker.
    private var canArm: Bool { blockers.isEmpty && !isConflictActive() && !voiceProcessingOn() && (keepReady() || alwaysReady()) }

    private func updateBlocker(_ r: Reason, _ active: Bool) {
        if active, !blockers.contains(r) { block(r) }
        else if !active, blockers.contains(r) { clear(r) }
    }

    /// The recorder keeps the engine running after a stop only while warm mode is allowed.
    private func syncStopIntent() { audio.keepWarmAfterStop = canArm }

    private func arm() {
        guard canArm else { return }
        let next: Mode = alwaysReady() ? .always : .window(until: now().addingTimeInterval(MicWarmPolicy.window))
        do { try audio.enterWarm() } catch {
            Log.error("warm mic failed to start: \(error.localizedDescription)")
            drop(.failed); return
        }
        if case .window = next { secondsLeft = Int(MicWarmPolicy.window) }
        if mode != next { mode = next }
    }

    /// Stop warm mode: engine off (unless recording), ring zeroed + freed.
    private func drop(_ r: Reason, logMessage: String? = nil) {
        audio.leaveWarm()
        if mode != .off { Log.info(logMessage ?? "mic warm off: \(r.rawValue)") }
        mode = .off
        secondsLeft = 0
        lastDrop = r
    }
}
