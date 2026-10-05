import AppKit
import WisprLocalCore

/// Wires the small conveniences (Settings › General) into the hotkey, pipeline and HUD:
/// Esc to cancel, the extra mouse-button trigger, start/stop sounds, Shift-on-release auto-send,
/// history retention and "hide the indicator for 1 hour". Owned by `AppController`, installed
/// once from `start()`; every setting applies at once.
@MainActor
final class Conveniences {
    let settings: ConvenienceSettings
    private unowned let app: AppController
    private var escape = EscapeCancel()
    private let mouse: MouseButtonMonitor
    private let sounds = ToneFeedbackSounds()
    private var retentionTimer: Timer?

    init(app: AppController, settings: ConvenienceSettings) {
        self.app = app
        self.settings = settings
        mouse = MouseButtonMonitor(globe: app.hotkey)
    }

    func install() {
        let hotkey = app.hotkey, settings = self.settings
        hotkey.onEscape = { [weak self] isRepeat in self?.escapePressed(isRepeat: isRepeat) ?? false }
        hotkey.shiftIsReleaseModifier = settings.shiftReturnAutoSend
        app.pipeline.autoSendRequested = {
            settings.shiftReturnAutoSend && hotkey.lastTriggerFlags.contains(.maskShift)
        }
        applySounds()
        applyMouseTrigger()
        pruneHistory()
        let timer = Timer(timeInterval: HistoryRetention.pruneInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneHistory() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    func stop() {
        retentionTimer?.invalidate(); retentionTimer = nil
        mouse.stop()
    }

    // MARK: Esc

    /// Runs INSIDE the event tap: decide (pure), schedule the work, return whether to consume.
    private func escapePressed(isRepeat: Bool) -> Bool {
        let decision = escape.escape(at: ProcessInfo.processInfo.systemUptime,
                                     dictationSeconds: app.pipeline.activeDictationSeconds, isRepeat: isRepeat)
        switch decision {
        case .passThrough, .consume: break
        case .cancel:
            GlobeKeyMonitor.mainAsync { [weak self] in
                guard let self else { return }
                self.app.pipeline.cancelDictation()
                self.app.hotkey.resetGesture()
            }
        case .confirm(let seconds):
            GlobeKeyMonitor.mainAsync { [weak self] in self?.app.flash(PipelineNotice.escapeAgain(seconds: seconds)) }
        }
        return decision.consumesKey
    }

    // MARK: settings actions

    func setMouseTrigger(_ t: MouseTrigger) {
        settings.mouseTrigger = t
        applyMouseTrigger()
    }

    func setFeedbackSounds(_ on: Bool) {
        settings.feedbackSounds = on
        applySounds()
    }

    func setShiftReturn(_ on: Bool) {
        settings.shiftReturnAutoSend = on
        app.hotkey.shiftIsReleaseModifier = on
    }

    /// Asked before `setHistoryRetention` (U3): "Delete 123 dictations older than 7 days?", or
    /// nil when nothing would be deleted.
    func retentionConfirmation(for r: HistoryRetention) async -> String? {
        let index = app.library.index
        await index.load()
        return r.deleteConfirmation(count: await index.prunableCount(retention: r))
    }

    func setHistoryRetention(_ r: HistoryRetention) {
        settings.historyRetention = r
        pruneHistory()
    }

    /// Hides the pill for an hour and says so in a chip with Undo (chips still show while hidden).
    func hideIndicator() {
        settings.hideIndicator(now: Date())
        app.hud.update()
        app.flash(ChipCopy.indicatorHidden)
    }

    func showIndicator() {
        settings.showIndicator()
        app.hud.dismissNotice(ChipCopy.indicatorHidden)
        app.hud.update()
    }

    private func applySounds() { app.pipeline.feedbackSounds = settings.feedbackSounds ? sounds : nil }

    private func applyMouseTrigger() {
        if !mouse.apply(settings.mouseTrigger) { Log.error("mouse trigger: event tap unavailable") }
    }

    /// Launch, hourly and on change: entries past the retention period go, with their clips.
    private func pruneHistory() {
        let retention = settings.historyRetention, library = app.library
        guard retention != .forever else { return }
        // Keep disk I/O off the main actor; prune performs its read/filter/rewrite atomically
        // on the history append queue.
        Task.detached(priority: .utility) {
            let n = await library.index.prune(retention: retention)
            guard n > 0 else { return }
            Log.info("history retention (\(retention.rawValue)): removed \(n) entr\(n == 1 ? "y" : "ies")")
            await MainActor.run { [weak self] in self?.app.historyDidChange() }
        }
    }
}
