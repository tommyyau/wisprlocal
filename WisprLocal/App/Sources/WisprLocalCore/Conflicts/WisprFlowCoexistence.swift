import Foundation

/// Wires Wispr Flow priority across the hotkey, pipeline and warm mic (STRUCTURAL; unit-tested).
///
/// - Holding off starts: the warm mic is dropped at once (engine off, pre-roll zeroed), any
///   recording in flight is cancelled (discarded, never transcribed), and the notice is shown.
/// - Holding off ends (Wispr Flow quit, or an override): nothing to do here. The tap consumes 🌐
///   again on the next press, and the warm mic re-arms normally after the next dictation.
/// - A 🌐 press passed through while holding off, or a dictation refused at key-down: a live
///   re-check, then the notice, debounced (`ConflictDetector.noticeCooldown`).
@MainActor
public final class WisprFlowCoexistence {
    private let conflicts: ConflictDetector
    private let warmMic: WarmMicController
    private let pipeline: DictationPipeline
    private let resetGesture: () -> Void
    private let showNotice: () -> Void

    public init(conflicts: ConflictDetector, warmMic: WarmMicController, pipeline: DictationPipeline,
                resetGesture: @escaping () -> Void, showNotice: @escaping () -> Void) {
        self.conflicts = conflicts; self.warmMic = warmMic; self.pipeline = pipeline
        self.resetGesture = resetGesture; self.showNotice = showNotice
    }

    /// Hook up `conflicts.onChange`, `monitor.onHeldOffPress` and `pipeline.onBlockedByConflict`.
    public func install(monitor: GlobeKeyMonitor) {
        conflicts.onChange = { [weak self] in self?.holdingOffChanged() }
        monitor.onHeldOffPress = { [weak self] in self?.heldOffPress() }
        pipeline.onBlockedByConflict = { [weak self] in self?.notice() }
    }

    public func holdingOffChanged() {
        warmMic.tick()  // conflict blocker: drop now (or clear once Wispr Flow is gone)
        guard conflicts.holdingOff else { return }
        if pipeline.status.isRecording {
            pipeline.handle(.cancelRecording)
            resetGesture()
        }
        notice()
    }

    /// A press the tap passed through. Live re-check (on main, outside the tap): if Wispr Flow
    /// has actually gone, the refresh resumes WisprLocal for the next press.
    public func heldOffPress() {
        conflicts.refresh()
        if conflicts.holdingOff { notice() }
    }

    public func notice() {
        if conflicts.shouldShowHoldOffNotice() { showNotice() }
    }
}
