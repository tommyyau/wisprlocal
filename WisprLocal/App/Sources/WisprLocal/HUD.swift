import AppKit
import SwiftUI
import WisprLocalCore

// MARK: - State

/// What the HUD shows. `nil` (in HUDModel) = hidden (the exit choreography plays first).
enum HUDState: Equatable {
    case recording(handsFree: Bool)
    /// Recording from a COLD mic: a dim pulsing dot until the first non-zero audio arrives
    /// (`RecordingCue.starting`), so users learn to wait ~0.2 s before speaking.
    case starting(handsFree: Bool)
    case processing
    case notice(HUDNotice)

    var showsBars: Bool { if case .notice = self { return false } else { return true } }
    var isHandsFree: Bool {
        switch self {
        case .recording(let hf), .starting(let hf): hf
        case .processing, .notice: false
        }
    }
    var hasButtons: Bool { if case .notice(let n) = self { return !n.buttons.isEmpty } else { return isHandsFree } }
}

struct HUDNotice: Equatable {
    enum Tint: Equatable { case info, warning, error }
    var symbol: String
    var tint: Tint
    var text: String
    var buttons: [HUDButton] = []
    /// Non-nil: append live elapsed seconds (model preparing).
    var elapsedSince: Date? = nil
}

enum HUDButton: Equatable {
    case quitWisprFlow, useWisprLocalAnyway, wisprFlowDifferentShortcut, retryModel, relaunch, permissionHelp, positioningDone, recordingDone
    /// A transient chip's button (`HUDChipPolicy.actions`): See why, Settings, Undo, Add, Not now.
    case chip(HUDChipAction)
    var title: String {
        switch self {
        case .positioningDone, .recordingDone: "Done"
        case .quitWisprFlow: "Quit Wispr Flow"
        case .useWisprLocalAnyway: WisprFlowCopy.useAnyway
        case .wisprFlowDifferentShortcut: WisprFlowCopy.differentShortcutButton
        case .retryModel: "Retry"
        case .relaunch: "Relaunch"
        case .permissionHelp: "Fix…"
        case .chip(let a): a.title
        }
    }
    var isPrimary: Bool {
        if case .chip(let a) = self { return a.isPrimary }
        return ![.useWisprLocalAnyway, .wisprFlowDifferentShortcut, .permissionHelp].contains(self)
    }
}

/// Non-activating floating panel: never becomes key, never steals focus.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Right-click on the pill (`HUDContextMenu`).
    var onRightMouseDown: ((NSEvent) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let onRightMouseDown { onRightMouseDown(event); return }
        super.sendEvent(event)
    }
}

@MainActor
@Observable
final class HUDModel {
    /// Persistent problems with their own timing; they outrank every chip.
    enum Banner: Equatable { case none, conflict, modelError(String), permission(PermissionHealth) }
    var banner: Banner = .none
    /// The transient chip showing now (`HUDChipQueue.current`), below any banner.
    var chip: HUDChip?
    /// Target state; the animator plays enter/exit/morphs towards it.
    var state: HUDState?
    /// True while the panel is on screen (drives the display-rate timeline).
    var ticking = false
    /// Which pill edge stays fixed as the pill changes width (from the placement).
    var alignment: HUDAlignment = .center
    /// Settings › General › "Adjust position…": the pill is shown and draggable, with Done.
    var positioning = false
    /// Positioning controls go below the pill when it sits in the top half of the screen.
    var controlsBelow = false
    /// ⌥ held while the pill is visible: the pill accepts a drag (otherwise click-through).
    var optionDrag = false
    /// The pointer is over the pill: it accepts clicks (right-click menu).
    var pointerOverPill = false
    var dragEnabled: Bool { positioning || optionDrag }
}

enum HUDDragPhase { case changed, ended }

// MARK: - Controller

@MainActor
final class HUDController {
    /// Window is larger than the pill so the shadow and spring overshoot never clip.
    /// Tall enough for the positioning-mode caption + Done above or below the pill.
    static let windowSize = CGSize(width: 640, height: 200)
    /// Distance from the window's bottom edge to the pill's vertical centre.
    static let pillCentreFromBottom: CGFloat = 100
    /// Leading/trailing-aligned pills keep this much room for the shadow and spring overshoot.
    static let sideInset: CGFloat = 20

    /// Preset / per-display custom position (Settings › General).
    var placement: HUDPlacementStore { controller.hudPlacement }
    private var currentScreen: NSScreen?
    private var currentCentre: CGPoint = .zero
    private var dragStart: (mouse: CGPoint, centre: CGPoint)?
    private var lastSnapped = false
    private var flagMonitors: [Any] = []

    private let panel: HUDPanel
    private let model = HUDModel()
    private unowned let controller: AppController
    private var bannerTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    init(controller: AppController) {
        self.controller = controller
        panel = HUDPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let recorder = controller.recorder
        let model = self.model
        let pipeline = controller.pipeline
        let host = NSHostingView(rootView: HUDView(
            model: model,
            bands: { model.positioning && !pipeline.status.isRecording ? HUDController.idleBands(CACurrentMediaTime()) : recorder.spectrum.read() },
            onButton: { [weak self] b in self?.handle(b) },
            onDrag: { [weak self] phase in self?.drag(phase) },
            recordingSeconds: { pipeline.activeDictationSeconds }))
        host.sizingOptions = []
        panel.contentView = host
        observe()
        watchOptionKey()
        watchPointer()
        panel.onRightMouseDown = { [weak self] e in
            guard let self, let view = self.panel.contentView, self.model.state != nil else { return }
            HUDContextMenu.show(with: e, in: view) { [weak self] in self?.controller.conveniences.hideIndicator() }
        }
    }

    /// Mouse events reach the panel only while the pointer is over the pill (right-click menu).
    private func watchPointer() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateMouse()
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) { flagMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { handler($0); return $0 }) { flagMonitors.append(l) }
    }

    /// A gentle synthetic voice for positioning mode (no mic needed).
    static func idleBands(_ t: Double) -> [Float] {
        (0..<SpectrumBands.count).map { i in
            let x = Double(i) / Double(max(1, SpectrumBands.count - 1))
            return Float(0.25 + 0.35 * (0.5 + 0.5 * sin(x * 8 - t * 3)) * exp(-pow((x - 0.5) * 2.2, 2)))
        }
    }

    // MARK: placement

    /// Settings › General › Adjust position…
    func beginPositioning() {
        model.positioning = true
        position()
        update()
    }

    func endPositioning() {
        model.positioning = false
        dragStart = nil
        update()
    }

    var isPositioning: Bool { model.positioning }

    /// Re-place a visible pill after the preset changes.
    func placementChanged() { if panel.isVisible { position() } }

    private func watchOptionKey() {
        let handler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                let down = e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
                if self.model.optionDrag != down { self.model.optionDrag = down; self.updateMouse() }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { flagMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { flagMonitors.append(l) }
    }

    /// Click-through unless there are buttons to press or a drag is allowed.
    private func updateMouse() {
        // The pill can grow under a stationary cursor: recompute on state/size changes so
        // the first click on hands-free Done reaches the pill without a mouseMoved event.
        let over = panel.isVisible && model.state.map {
            HUDContextMenu.pillRect(windowFrame: panel.frame, state: $0, alignment: model.alignment)
                .contains(NSEvent.mouseLocation)
        } ?? false
        if model.pointerOverPill != over { model.pointerOverPill = over }
        // A persistent hands-free pill must leave the transparent area around it clickable.
        let noticeButtons = model.state?.isHandsFree != true && (model.state?.hasButtons ?? false)
        panel.ignoresMouseEvents = !(noticeButtons || model.dragEnabled || model.pointerOverPill)
    }

    private func drag(_ phase: HUDDragPhase) {
        guard model.dragEnabled, let screen = currentScreen else { return }
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            if dragStart == nil { dragStart = (mouse, currentCentre); lastSnapped = false }
            guard let start = dragStart else { return }
            let wanted = CGPoint(x: start.centre.x + mouse.x - start.mouse.x, y: start.centre.y + mouse.y - start.mouse.y)
            let snap = HUDPlacement.snap(wanted, visible: screen.visibleFrame)
            if snap.any && !lastSnapped {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            lastSnapped = snap.any
            place(centre: snap.point, alignment: HUDPlacement.alignment(forCentre: snap.point, visible: screen.visibleFrame), on: screen)
        case .ended:
            dragStart = nil
            if let key = Self.displayKey(screen) {
                placement.setCustom(HUDPlacement.relative(fromCentre: currentCentre, visible: screen.visibleFrame), display: key)
            }
        }
    }

    private func place(centre: CGPoint, alignment: HUDAlignment, on screen: NSScreen) {
        currentScreen = screen
        currentCentre = centre
        model.alignment = alignment
        model.controlsBelow = centre.y > screen.visibleFrame.midY
        panel.setFrameOrigin(HUDPlacement.windowOrigin(centre: centre, alignment: alignment, windowSize: Self.windowSize,
                                                       pillCentreFromBottom: Self.pillCentreFromBottom, sideInset: Self.sideInset))
        updateMouse()
    }

    /// Stable per-display key (survives reboots and rearranging displays).
    static func displayKey(_ s: NSScreen) -> String? {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The screen holding the focused window of the frontmost app (where the text goes), else
    /// the screen under the mouse.
    static func targetScreen() -> NSScreen? {
        if let r = focusedWindowFrame(),
           let best = NSScreen.screens.max(by: { $0.frame.intersection(r).area < $1.frame.intersection(r).area }),
           best.frame.intersection(r).area > 0 {
            return best
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func focusedWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication, let primary = NSScreen.screens.first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let el = w as! AXUIElement
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
        // AX is top-left origin on the primary display; AppKit is bottom-left.
        return CGRect(x: p.x, y: primary.frame.maxY - p.y - sz.height, width: sz.width, height: sz.height)
    }

    /// Re-evaluate whenever pipeline status / conflict / banner changes.
    private func observe() {
        withObservationTracking {
            _ = controller.pipeline.status
            _ = controller.pipeline.recordingCue
            _ = controller.conflicts.holdingOff
            _ = model.banner
            _ = model.chip
            _ = controller.permissions.health
        } onChange: { [weak self] in
            Task { @MainActor in self?.update(); self?.observe() }
        }
    }

    var shouldShow: Bool { currentState() != nil }

    private func currentState() -> HUDState? {
        switch model.banner {
        case .conflict where controller.conflicts.holdingOff:
            return .notice(HUDNotice(symbol: "exclamationmark.triangle.fill", tint: .warning, text: WisprFlowCopy.holdingOff,
                                     buttons: [.quitWisprFlow, .useWisprLocalAnyway, .wisprFlowDifferentShortcut]))
        case .modelError(let m) where controller.modelError != nil:
            return .notice(HUDNotice(symbol: "xmark.octagon.fill", tint: .error,
                                     text: "Speech model failed: \(m)", buttons: [.retryModel]))
        case .permission(let h) where h == controller.permissions.health:
            if h == .stalePermission {
                return .notice(HUDNotice(symbol: "exclamationmark.triangle.fill", tint: .warning,
                                         text: "Stale permission — re-add WisprLocal", buttons: [.permissionHelp, .relaunch]))
            }
            return .notice(HUDNotice(symbol: "arrow.clockwise.circle.fill", tint: .info,
                                     text: "Permissions updated — Relaunch WisprLocal", buttons: [.permissionHelp, .relaunch]))
        default: break
        }
        if let chip = model.chip { return .notice(Self.chipNotice(chip)) }
        // "Hide Indicator for 1 Hour": dictation works, only the pill is hidden (notices above still show).
        if controller.convenienceSettings.isIndicatorHidden(now: Date()) { return nil }
        switch controller.pipeline.status {
        case .recording(let hf):
            return controller.pipeline.recordingCue == .starting ? .starting(handsFree: hf) : .recording(handsFree: hf)
        case .processing: return .processing
        case .preparingModel:
            guard let start = controller.prewarmStartedAt else { return nil }
            return .notice(HUDNotice(symbol: "hourglass", tint: .info, text: "Preparing speech model…", elapsedSince: start))
        default: return nil
        }
    }

    /// The ONE way a chip's text becomes a pill notice (symbol, tint, buttons); the
    /// `--hud-preview` harness renders chips through it too.
    static func chipNotice(_ s: String) -> HUDNotice {
        chipNotice(HUDChipPolicy.chip(s))
    }

    static func chipNotice(_ chip: HUDChip) -> HUDNotice {
        HUDNotice(symbol: symbol(forNotice: chip.text), tint: chip.usesWarningTint ? .warning : .info,
                  text: chip.text, buttons: chip.actions.map(HUDButton.chip))
    }

    static func buttons(forNotice s: String) -> [HUDButton] { HUDChipPolicy.actions(for: s).map(HUDButton.chip) }

    /// Alerts are amber; everything else is the calm info tint.
    static func tint(forNotice s: String) -> HUDNotice.Tint {
        HUDChipPolicy.priority(for: s) == .alert ? .warning : .info
    }

    static func symbol(forNotice s: String) -> String {
        if s.hasPrefix(PipelineNotice.recordingLimitPrefix) { return "timer" }
        if s.hasPrefix(PipelineNotice.escapeAgainPrefix) { return "escape" }
        if s == PipelineNotice.cancelled { return "xmark.circle.fill" }
        if s.hasPrefix(PipelineNotice.didntCatchPrefix) { return "waveform.badge.exclamationmark" }
        if s == PipelineNotice.micCuttingOut { return "mic.badge.xmark" }
        if s == PipelineNotice.corrected || s == PipelineNotice.correctedCopyOnly { return "arrow.uturn.backward.circle.fill" }
        if s == PipelineNotice.originalCopied || s == PipelineNotice.undoNotSafe { return "doc.on.clipboard" }
        if SmartDictionaryCopy.isSuggestion(s) || s.hasPrefix(SmartDictionaryCopy.addedPrefix) { return "character.book.closed" }
        if s == ChipCopy.indicatorHidden { return "eye.slash" }
        return switch s {
        case PipelineNotice.focusChanged, PipelineNotice.pasteNotConfirmed: "doc.on.clipboard"
        case PipelineNotice.secureInput, PipelineNotice.remoteSecureInput: "lock.fill"
        case PipelineNotice.quickRepressDropped: "hand.raised.fill"
        case PipelineNotice.modelPreparing: "hourglass"
        default: "info.circle.fill"
        }
    }

    func update() {
        if model.banner == .conflict && !controller.conflicts.holdingOff { model.banner = .none }
        if case .modelError = model.banner, controller.modelError == nil { model.banner = .none }
        if case .permission(let h) = model.banner, h != controller.permissions.health { model.banner = .none }
        var state = currentState()
        if state == nil, model.positioning { state = .recording(handsFree: false) }
        if model.state != state { model.state = state }
        if state != nil {
            hideTask?.cancel(); hideTask = nil
            if !panel.isVisible {
                position()
                model.ticking = true
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible, hideTask == nil {
            // Let the exit choreography (≈220 ms) finish before removing the window.
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(HUDAnimator.exitDuration * 1000 + 40))
                guard let self, !Task.isCancelled else { return }
                self.hideTask = nil
                if self.model.state == nil { self.panel.orderOut(nil); self.model.ticking = false }
            }
        }
        updateMouse()
    }

    /// The saved placement on the screen where the user is working, kept inside its
    /// visibleFrame (clear of the menu bar and Dock). A display with no saved position — or a
    /// new one — uses the preset (bottom centre by default).
    private func position() {
        guard let screen = Self.targetScreen() else { return }
        let p = placement.placement(display: Self.displayKey(screen), visible: screen.visibleFrame, full: screen.frame)
        place(centre: p.centre, alignment: p.alignment, on: screen)
    }

    private func handle(_ b: HUDButton) {
        switch b {
        case .quitWisprFlow: controller.conflicts.quitWisprFlow()
        case .useWisprLocalAnyway: controller.useWisprLocalAnyway()
        case .wisprFlowDifferentShortcut: controller.setWisprFlowUsesDifferentShortcut(true); update()
        case .retryModel: controller.retryModelPreparation()
        case .relaunch: controller.relaunch()
        case .permissionHelp:
            model.banner = .none; update()
            WindowManager.shared.showOnboarding(controller: controller)
        case .positioningDone: endPositioning()
        case .recordingDone: controller.pipeline.finishHandsFree()
        case .chip(let a): chipAction(a)
        }
    }

    /// Acts first (a suggestion's word is forgotten when its chip ends), then takes the chip down.
    private func chipAction(_ a: HUDChipAction) {
        let shown = model.chip?.text
        defer { if let shown { apply(chips.dismiss(text: shown, now: Self.now())) } }
        switch a {
        case .seeWhy:
            WindowManager.shared.showMain(controller: controller, section: .history)
            if let id = controller.pipeline.lastNoTextEntryID { WindowManager.shared.model(for: controller).historyDetailRequest = id }
        case .micSettings:
            WindowManager.shared.model(for: controller).settingsRequest = .tab(.microphone)
            WindowManager.shared.showMain(controller: controller, section: .settings)
        case .undoCorrection:
            let pipeline = controller.pipeline
            Task { await pipeline.undoLastCorrection() }
        case .copyOriginal: controller.pipeline.copyOriginalOfLastCorrection()
        case .addWord: controller.smart.acceptPending()
        case .notNow: controller.smart.dismissPending()
        case .showIndicator: controller.conveniences.showIndicator()
        }
    }

    // Banners (persistent problems) keep their own timing and outrank every chip.
    func flashConflict() { showBanner(.conflict, seconds: 8) }
    /// Model preparation failed: stays up (30 s, re-shown on each dictation attempt) with Retry.
    func showModelError(_ m: String) { showBanner(.modelError(m), seconds: 30) }

    // MARK: chips (`HUDChipQueue`: one at a time, alert > undo > suggestion > info, 8 s / 3 s)

    private var chips = HUDChipQueue()
    private var chipTask: Task<Void, Never>?
    /// A chip was taken down (expired, replaced, dismissed or cleared), e.g. so a suggestion's
    /// pending word is forgotten exactly when its chip goes.
    var onChipEnded: ((String) -> Void)?
    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Every transient HUD message goes through here (`priority` overrides the classification,
    /// e.g. a dictation failure's own error text is an alert).
    func flashNotice(_ s: String, priority: HUDChipPriority? = nil) {
        apply(chips.offer(HUDChipPolicy.chip(s, priority: priority), now: Self.now()))
    }

    /// Takes `s` down early if it is showing or waiting (e.g. a suggestion when a dictation starts).
    func dismissNotice(_ s: String) { apply(chips.dismiss(text: s, now: Self.now())) }

    /// A new recording starts: every chip goes, so the pill shows the mic is on.
    func clearChips() { apply(chips.clear()) }

    private func apply(_ events: [HUDChipQueue.Event]) {
        for e in events { if case .ended(let c) = e { onChipEnded?(c.text) } }
        let chip = chips.current?.chip
        if model.chip != chip { model.chip = chip }
        update()
        chipTask?.cancel(); chipTask = nil
        guard let d = chips.nextDeadline else { return }
        chipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, d - Self.now())))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.chips.tick(now: Self.now()))
        }
    }

    /// Needs-relaunch / stale-permission prompt with buttons (cleared early if health changes).
    func showPermissionNotice(_ h: PermissionHealth) { showBanner(.permission(h), seconds: 20) }

    private func showBanner(_ b: HUDModel.Banner, seconds: Double) {
        model.banner = b
        update()
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.model.banner == b { self.model.banner = .none }
            self.update()
        }
    }
}

// MARK: - Animator (physics + choreography, integrated per display frame)

/// Damped spring, unit mass. Semi-implicit Euler with ≤ 1/240 s substeps (stable at 60–120 Hz).
struct Spring {
    var x: Double
    var v: Double = 0
    init(_ x: Double) { self.x = x }
    mutating func step(to target: Double, stiffness k: Double, damping c: Double, dt: Double) {
        let a = -k * (x - target) - c * v
        v += a * dt; x += v * dt
    }
}

/// One rendered frame of the HUD.
struct HUDFrame {
    var state: HUDState?
    var size = CGSize(width: 8, height: 8)
    var opacity: Double = 0
    /// Bar heights in 0...~1.15 (overshoot allowed) and per-bar alpha (stagger).
    var bars = [Double](repeating: 0, count: SpectrumBands.count)
    var barAlpha = [Double](repeating: 0, count: SpectrumBands.count)
    var barsVisibility: Double = 0
    var noticeVisibility: Double = 0
    var handsFreeDot: Double = 0
    /// Dim centre dot while the mic is starting (0 = hidden).
    var startingDot: Double = 0
    var time: Double = 0
}

@MainActor
final class HUDAnimator {
    static let barCount = SpectrumBands.count
    static let exitDuration = 0.22
    static let dot: Double = 8

    // Pill: response ≈ 0.38 s, damping fraction ≈ 0.72 → small visible overshoot.
    static let pillK = pow(2 * Double.pi / 0.38, 2)
    static let pillC = 2 * 0.72 * (2 * Double.pi / 0.38)
    // Bars: stiffness 300, damping 18 → fast attack, ~15 % overshoot, slower settle.
    static let barK = 300.0, barC = 18.0

    /// Gentle centre weighting (centre bars a little taller, like a voice envelope).
    static let weights: [Double] = (0..<barCount).map { i in
        let d = abs(Double(i) - Double(barCount - 1) / 2) / (Double(barCount - 1) / 2)
        return 0.62 + 0.38 * (1 - d * d)
    }

    private(set) var frame = HUDFrame()
    private var width = Spring(dot), height = Spring(dot)
    private var bars = [Spring](repeating: Spring(0), count: barCount)
    private var lastT: Double?
    private var enterT: Double = 0
    private var barsSinceT: Double = 0
    private var exitT: Double?
    private var exitFrom = CGSize(width: dot, height: dot)
    private var exitBars = [Double](repeating: 0, count: barCount)

    static func targetSize(for s: HUDState) -> CGSize {
        switch s {
        case .recording(let hf), .starting(let hf): CGSize(width: hf ? 300 : 132, height: hf ? 48 : 40)
        case .processing: CGSize(width: 132, height: 40)
        case .notice(let n): CGSize(width: HUDNoticeMetrics.width(for: n), height: HUDNoticeMetrics.height(for: n))
        }
    }

    func step(t: Double, target: HUDState?, bands: [Float], reduceMotion: Bool) -> HUDFrame {
        let dt = min(1.0 / 20, max(0, t - (lastT ?? t)))
        lastT = t
        var f = frame
        f.time = t

        // --- transitions ---
        if let target {
            if exitT != nil {  // re-enter mid-exit: spring back out from where the pill is now
                width = Spring(f.size.width); height = Spring(f.size.height)
                exitT = nil; enterT = t; barsSinceT = t
                f.state = target
            } else if f.state == nil {  // enter: an 8 pt dot springs out, bars stagger in
                let full = Self.targetSize(for: target)
                width = Spring(reduceMotion ? full.width : Self.dot)
                height = Spring(reduceMotion ? full.height : Self.dot)
                bars = .init(repeating: Spring(0), count: Self.barCount)
                f.opacity = 0; f.barsVisibility = 0; f.noticeVisibility = 0
                enterT = t; barsSinceT = t + 0.06
                f.state = target
            } else if f.state != target {
                if f.state?.showsBars != target.showsBars, target.showsBars { barsSinceT = t }
                f.state = target
            }
        } else if f.state != nil, exitT == nil {
            exitT = t
            exitFrom = CGSize(width: width.x, height: height.x)
            exitBars = bars.map(\.x)
        }

        guard let state = f.state else { frame = f; return f }

        if let exitT {
            // Exit: bars collapse to nubs while the pill contracts (0–160 ms), then fade (110–220 ms).
            let e = t - exitT
            let flat = Self.ease(e / 0.10)
            for i in bars.indices { f.bars[i] = exitBars[i] * (1 - flat) }
            if reduceMotion {
                f.opacity = 1 - min(1, e / Self.exitDuration)
            } else {
                let k = Self.easeInOut((e - 0.02) / 0.17)
                f.size = CGSize(width: exitFrom.width + (Self.dot - exitFrom.width) * k,
                                height: exitFrom.height + (Self.dot - exitFrom.height) * k)
                f.opacity = 1 - Self.ease((e - 0.11) / 0.11)
            }
            f.noticeVisibility = max(0, f.noticeVisibility - dt / 0.08)
            if e >= Self.exitDuration {
                f = HUDFrame(); f.time = t
                self.exitT = nil
                width = Spring(Self.dot); height = Spring(Self.dot)
                bars = .init(repeating: Spring(0), count: Self.barCount)
            }
            frame = f
            return f
        }

        // --- pill size ---
        let size = Self.targetSize(for: state)
        if reduceMotion {
            width = Spring(size.width); height = Spring(size.height)
        } else {
            Self.integrate(&width, to: size.width, k: Self.pillK, c: Self.pillC, dt: dt)
            Self.integrate(&height, to: size.height, k: Self.pillK, c: Self.pillC, dt: dt)
        }
        f.size = CGSize(width: max(Self.dot, width.x), height: max(Self.dot, height.x))
        f.opacity = min(1, f.opacity + dt / (reduceMotion ? 0.15 : 0.06))

        // --- content visibility ---
        let barsTarget: Double = state.showsBars ? 1 : 0
        f.barsVisibility = Self.approach(f.barsVisibility, barsTarget, rate: dt / 0.10)
        let noticeTarget: Double = (!state.showsBars && t - enterT > (reduceMotion ? 0 : 0.10)) ? 1 : 0
        f.noticeVisibility = Self.approach(f.noticeVisibility, noticeTarget, rate: dt / 0.14)

        // --- bars ---
        let damping = reduceMotion ? 2 * Self.barK.squareRoot() : Self.barC  // critical = no overshoot
        for i in bars.indices {
            let since = t - (barsSinceT + 0.015 * Double(i))
            f.barAlpha[i] = reduceMotion ? 1 : min(1, max(0, since / 0.07))
            var target = 0.0
            if since > 0 {
                switch state {
                case .recording:
                    let b = i < bands.count ? Double(bands[i]) : 0
                    // Noise floor, then a perceptual curve so ordinary speech fills the pill.
                    let gated = max(0, (b - 0.04) / 0.96)
                    target = min(1, Self.weights[i] * pow(gated, 0.6) * 1.15)
                case .processing:
                    // Travelling ripple at reduced height (static low bars under Reduce Motion).
                    target = reduceMotion ? 0.3
                        : 0.10 + 0.62 * (0.5 + 0.5 * sin(2 * .pi * 1.3 * t - Double(i) * 0.85))
                case .notice, .starting: target = 0
                }
            }
            Self.integrate(&bars[i], to: target, k: Self.barK, c: damping, dt: dt)
            f.bars[i] = bars[i].x
        }

        if case .starting = state {
            f.startingDot = reduceMotion ? 0.45 : 0.25 + 0.30 * (0.5 + 0.5 * sin(2 * .pi * t / 0.9))
            for i in f.barAlpha.indices { f.barAlpha[i] *= 0.25 }  // bars dimmed to nubs
        } else {
            f.startingDot = Self.approach(f.startingDot, 0, rate: dt / 0.08)
        }
        if case .recording(true) = state {
            f.handsFreeDot = reduceMotion ? 0.9 : 0.55 + 0.45 * (0.5 + 0.5 * sin(2 * .pi * t / 1.6))
        } else {
            f.handsFreeDot = Self.approach(f.handsFreeDot, 0, rate: dt / 0.1)
        }
        frame = f
        return f
    }

    private static func integrate(_ s: inout Spring, to target: Double, k: Double, c: Double, dt: Double) {
        var remaining = dt
        while remaining > 1e-6 {
            let h = min(remaining, 1.0 / 240)
            s.step(to: target, stiffness: k, damping: c, dt: h)
            remaining -= h
        }
    }

    private static func approach(_ x: Double, _ target: Double, rate: Double) -> Double {
        x < target ? min(target, x + rate) : max(target, x - rate)
    }
    static func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
    static func easeInOut(_ x: Double) -> Double {
        let c = min(1, max(0, x)); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }
}

// MARK: - Views

@MainActor
enum HUDNoticeMetrics {
    /// Monospaced digits, like the notice `Text` (`.monospacedDigit()`): measuring with
    /// proportional digits under-sized "1 hour" and wrapped it.
    static let textFont = NSFont.monospacedDigitSystemFont(ofSize: Theme.Typo.hudTextSize, weight: .medium)  // = Theme.Typo.hudText
    static let buttonFont = NSFont.systemFont(ofSize: Theme.Typo.hudButtonSize, weight: .semibold)  // = Theme.Typo.hudButton
    static let maxText: CGFloat = 360

    static func textWidth(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    static func displayText(_ n: HUDNotice, at date: Date) -> String {
        guard let since = n.elapsedSince else { return n.text }
        return "\(n.text) \(max(0, Int(date.timeIntervalSince(since)))) s"
    }

    static func textColumnWidth(_ n: HUDNotice) -> CGFloat {
        let sample = n.elapsedSince == nil ? n.text : n.text + " 99 s"
        return min(maxText, textWidth(sample, font: textFont) + 1)
    }

    static let maxLines = 3
    /// Every built-in chip fits one line (`HUDChipOneLineTests`); a longer notice (an error
    /// message) wraps to up to three lines and the pill grows 17 pt per extra line.
    static func lines(for n: HUDNotice) -> Int {
        let w = textWidth(displayText(n, at: Date()), font: textFont)
        return min(maxLines, max(1, Int(ceil(w / (maxText - 24)))))
    }

    static func height(for n: HUDNotice) -> CGFloat { 40 + CGFloat(lines(for: n) - 1) * 17 }

    /// Deterministic width (no layout pass), so the pill can spring to it from the first frame.
    static func width(for n: HUDNotice) -> CGFloat {
        var w: CGFloat = 14 + 18 + 8 + textColumnWidth(n) + (n.buttons.isEmpty ? 14 : 8)
        for b in n.buttons { w += 6 + textWidth(b.title, font: buttonFont) + 20 }
        if !n.buttons.isEmpty { w += 4 }
        return min(600, w)
    }
}

/// Live HUD: steps the animator once per display frame (60/120 Hz).
struct HUDView: View {
    let model: HUDModel
    let bands: () -> [Float]
    let onButton: (HUDButton) -> Void
    var onDrag: (HUDDragPhase) -> Void = { _ in }
    var recordingSeconds: () -> TimeInterval? = { nil }
    @State private var animator = HUDAnimator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !model.ticking)) { ctx in
            let f = animator.step(t: ctx.date.timeIntervalSinceReferenceDate, target: model.state,
                                  bands: bands(), reduceMotion: reduceMotion)
            HUDFrameView(frame: f, date: ctx.date, alignment: model.alignment,
                         positioning: model.positioning ? (model.controlsBelow ? .below : .above) : nil,
                         dragEnabled: model.dragEnabled, onButton: onButton, onDrag: onDrag,
                         elapsedSeconds: recordingSeconds() ?? 0, captionBelow: model.controlsBelow)
        }
        .frame(width: HUDController.windowSize.width, height: HUDController.windowSize.height)
    }
}

/// Simulated material for offscreen rendering (ImageRenderer cannot sample what's behind a window).
private struct HUDSimulatedMaterialKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var hudSimulatedMaterial: Bool {
        get { self[HUDSimulatedMaterialKey.self] }
        set { self[HUDSimulatedMaterialKey.self] = newValue }
    }
}

/// Pure rendering of one frame; positioned inside the fixed-size HUD window.
struct HUDFrameView: View {
    let frame: HUDFrame
    var date: Date = .now
    var alignment: HUDAlignment = .center
    enum Controls { case above, below }
    /// Non-nil in positioning mode: where the caption + Done go.
    var positioning: Controls?
    var dragEnabled = false
    var onButton: (HUDButton) -> Void = { _ in }
    var onDrag: (HUDDragPhase) -> Void = { _ in }
    var elapsedSeconds: TimeInterval = 0
    var captionBelow = false
    @Environment(\.hudSimulatedMaterial) private var simulated

    /// Pill centre x inside the window: centred, or anchored by its resting edge.
    private var pillX: CGFloat {
        let W = HUDController.windowSize.width, inset = HUDController.sideInset
        switch alignment {
        case .center: return W / 2
        case .leading: return inset + frame.size.width / 2  // left edge fixed
        case .trailing: return W - inset - frame.size.width / 2
        }
    }

    var body: some View {
        let pillY = HUDController.windowSize.height - HUDController.pillCentreFromBottom
        ZStack {
            pillStack
                .contentShape(Capsule(style: .continuous))
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in onDrag(.changed) }
                    .onEnded { _ in onDrag(.ended) }, isEnabled: dragEnabled)
                .position(x: pillX, y: pillY)
            if let positioning {
                PositioningControls { onButton(.positioningDone) }
                    .position(x: pillX, y: pillY + (positioning == .above ? -54 : 54))
            } else if frame.state?.isHandsFree == true {
                Text("HANDS-FREE").font(Theme.Typo.eyebrow).kerning(1.2)
                    .foregroundStyle(.white.opacity(0.65))
                    .opacity(frame.opacity)
                    .position(x: pillX, y: pillY + (captionBelow ? 1 : -1) * (frame.size.height / 2 + 18))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: HUDController.windowSize.width, height: HUDController.windowSize.height)
        .environment(\.colorScheme, .dark)
    }

    private var pillStack: some View {
        let w = frame.size.width, h = frame.size.height
        return ZStack {
            pill(w: w, h: h)
            if frame.barsVisibility > 0.001 {
                Group {
                    if frame.state?.isHandsFree == true {
                        HUDHandsFreeContent(frame: frame, elapsedSeconds: elapsedSeconds) { onButton(.recordingDone) }
                    } else {
                        HUDBars(frame: frame)
                    }
                }
                    .frame(width: w, height: h)
                    .clipShape(Capsule(style: .continuous))
                    .opacity(frame.barsVisibility)
            }
            if case .notice(let n) = frame.state, frame.noticeVisibility > 0.001 {
                HUDNoticeContent(notice: n, date: date, onButton: onButton)
                    .frame(width: w, height: h)
                    .clipShape(Capsule(style: .continuous))
                    .opacity(frame.noticeVisibility)
            }
        }
        .frame(width: w, height: h)
        .opacity(frame.opacity)
    }

    @ViewBuilder private func pill(w: CGFloat, h: CGFloat) -> some View {
        let shape = Capsule(style: .continuous)
        ZStack {
            if simulated {
                shape.fill(Color(white: 0.09).opacity(0.86))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.38))
            }
            // Indigo glass tint (brand: violet/indigo orb), #1B1440 @ 35 %.
            shape.fill(HUDPalette.indigo.opacity(0.35))
            // Faint top sheen + hairline top highlight, so it reads as glass.
            shape.fill(LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            shape.inset(by: 0.5).stroke(
                LinearGradient(stops: [.init(color: .white.opacity(0.32), location: 0),
                                       .init(color: .white.opacity(0.0), location: 0.35)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
        }
        .frame(width: w, height: h)
        .compositingGroup()
        .shadow(color: .black.opacity(0.30), radius: 12, y: 5)
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

/// Hands-free has an explicit finish target in the same non-activating panel as the waveform.
struct HUDHandsFreeContent: View {
    let frame: HUDFrame
    let elapsedSeconds: TimeInterval
    let done: () -> Void

    private var waveFrame: HUDFrame {
        var wave = frame
        wave.handsFreeDot = 0
        wave.startingDot = 0
        return wave
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(Theme.onDarkDanger)
                .frame(width: 10, height: 10)
                .opacity(frame.startingDot > 0 ? 0.4 : max(0.65, frame.handsFreeDot))
                .shadow(color: Theme.onDarkDanger.opacity(0.65), radius: 5)
                .accessibilityLabel(frame.startingDot > 0 ? "Microphone starting" : "Recording hands-free")
            HUDBars(frame: waveFrame).frame(width: 104, height: 40).accessibilityHidden(true)
            Text(Format.clip(floor(max(0, elapsedSeconds))))
                .font(Theme.Typo.hudText).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                .frame(width: 42, alignment: .leading)
                .accessibilityLabel("Recording time \(Int(max(0, elapsedSeconds))) seconds")
            Button(action: done) {
                Text("Done").font(Theme.Typo.hudButton).foregroundStyle(.white)
                    .padding(.horizontal, Theme.Space.m).frame(height: 30)
                    .background(Capsule(style: .continuous).fill(Theme.inset))
            }
            .buttonStyle(.plain).pointerStyle(.link)
            .help("Finish hands-free recording and insert your dictation")
            .accessibilityLabel("Finish hands-free dictation")
        }
        .padding(.horizontal, Theme.Space.m)
        .fixedSize()
    }
}

enum HUDPalette {
    static let indigo = Theme.indigo
    static let mintTop = Theme.mint
    static let mintBottom = Theme.mintDeep
}

/// Bars drawn in a Canvas: rounded capsules, mint gradient, soft mint glow on louder bars.
/// When the pill is narrower than the bar group (enter/exit), the group squeezes to fit.
struct HUDBars: View {
    let frame: HUDFrame
    static let barWidth: CGFloat = 4.5
    static let gap: CGFloat = 5
    static let minHeight: CGFloat = 6
    static let maxHeight: CGFloat = 30   // 75 % of the 40 pt pill
    static let sidePadding: CGFloat = 14

    var body: some View {
        Canvas { ctx, size in
            let n = frame.bars.count
            let handsFreeShift: CGFloat = frame.handsFreeDot > 0.01 ? 7 : 0
            let full = CGFloat(n) * Self.barWidth + CGFloat(n - 1) * Self.gap
            let room = max(0, size.width - 2 * Self.sidePadding - 2 * handsFreeShift)
            let squeeze = min(1, room / full)
            let bw = Self.barWidth * max(0.6, squeeze)
            let pitch = n > 1 ? (full * squeeze - bw) / CGFloat(n - 1) : 0
            let total = bw + pitch * CGFloat(n - 1)
            let x0 = (((size.width - total) / 2 + handsFreeShift) * 2).rounded() / 2
            let midY = size.height / 2
            let limit = min(Self.maxHeight * 1.12, size.height - 6)
            let shading = { (r: CGRect) in
                GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [HUDPalette.mintTop, HUDPalette.mintBottom]),
                    startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY))
            }
            for i in 0..<n {
                let v = max(0, frame.bars[i])
                let h = min(limit, Self.minHeight + CGFloat(v) * (Self.maxHeight - Self.minHeight))
                // Snap to the 0.5 pt (Retina pixel) grid for crisp edges.
                let x = ((x0 + CGFloat(i) * pitch) * 2).rounded() / 2
                let hh = (h * 2).rounded() / 2
                let rect = CGRect(x: x, y: ((midY - hh / 2) * 2).rounded() / 2, width: bw, height: hh)
                let path = Path(roundedRect: rect, cornerRadius: bw / 2, style: .continuous)
                ctx.opacity = frame.barAlpha[i] * Double(min(1, squeeze * 1.4))
                if v > 0.35 {
                    ctx.drawLayer { l in
                        l.addFilter(.shadow(color: HUDPalette.mintTop.opacity(min(0.6, (v - 0.35) * 1.0)), radius: 4))
                        l.fill(path, with: shading(rect))
                    }
                } else {
                    ctx.fill(path, with: shading(rect))
                }
            }
            if frame.startingDot > 0.01 {
                ctx.opacity = frame.startingDot
                let c = CGPoint(x: size.width / 2, y: midY)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.white))
            }
            if frame.handsFreeDot > 0.01 {
                ctx.opacity = frame.handsFreeDot
                let c = CGPoint(x: 16, y: midY)
                let red = Theme.onDarkDanger
                ctx.drawLayer { l in
                    l.addFilter(.shadow(color: red.opacity(0.8), radius: 3))
                    l.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(red))
                }
            }
        }
    }
}

struct HUDNoticeContent: View {
    let notice: HUDNotice
    let date: Date
    let onButton: (HUDButton) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.symbol)
                .font(Theme.Typo.symbolLarge)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(HUDNoticeMetrics.displayText(notice, at: date))
                .font(Theme.Typo.hudText)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(HUDNoticeMetrics.maxLines).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: HUDNoticeMetrics.textColumnWidth(notice), alignment: .leading)
            if !notice.buttons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(notice.buttons, id: \.title) { b in
                        Button(b.title) { onButton(b) }.buttonStyle(HUDButtonStyle(primary: b.isPrimary))
                    }
                }
                .padding(.leading, Theme.Space.xxs)
            }
        }
        .padding(.leading, Theme.Space.ms).padding(.trailing, notice.buttons.isEmpty ? Theme.Space.ms : Theme.Space.xs)
        .fixedSize()
    }

    private var tint: Color {
        switch notice.tint {
        case .info: .white.opacity(0.75)
        case .warning: Theme.onDarkWarning
        case .error: Theme.onDarkDanger
        }
    }
}

struct HUDButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typo.hudButton)
            .foregroundStyle(primary ? Color.black.opacity(0.88) : .white.opacity(0.92))
            .padding(.horizontal, Theme.Space.snug)
            .frame(height: 24)
            .background(Capsule(style: .continuous).fill(primary ? Color.white.opacity(0.92) : Color.white.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}


/// Positioning mode: a short caption and Done, floating beside the pill.
struct PositioningControls: View {
    let done: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw").font(Theme.Typo.hudButton).foregroundStyle(HUDPalette.mintTop)
            Text("Drag the pill anywhere. It snaps to edges and centres.")
                .font(Theme.Typo.chip).foregroundStyle(.white.opacity(0.92))
            Button("Done", action: done).buttonStyle(HUDButtonStyle(primary: true))
        }
        .padding(.leading, Theme.Space.ms).padding(.trailing, Theme.Space.tight).frame(height: 36)
        .background(Capsule(style: .continuous).fill(Color(white: 0.08).opacity(0.92)))
        .background(Capsule(style: .continuous).fill(HUDPalette.indigo.opacity(0.5)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .fixedSize()
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
