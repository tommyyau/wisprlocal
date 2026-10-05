import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Marker written into `eventSourceUserData` of every CGEvent WisprLocal synthesizes, so our own
/// tap ignores them (e.g. the Cmd-V we post).
public enum SyntheticEventMarker {
    public static let value: Int64 = 0x5749_5350_524C  // "WISPRL"
}

/// CGEvent tap on flagsChanged + keyDown that feeds `HotkeyStateMachine` and (optionally)
/// swallows Globe/Fn events so macOS doesn't open the emoji picker / switch input source.
///
/// Consumption caveat: the tap sits at `.cghidEventTap` (head insert) and returns `nil` for Fn
/// flagsChanged events. Whether that suppresses the *system* Globe action depends on where
/// macOS implements it; it cannot be verified headlessly (we never post real key events in
/// tests). Onboarding therefore also recommends setting "Press 🌐 key to: Do Nothing"
/// (`AppleFnUsageType = 0`) and `GlobeKeyConflict` warns when it isn't.
///
/// CC-7 (STRUCTURAL): a lost Fn-up (Screen Sharing / a VM grabbing the keyboard, display sleep,
/// a modal blocking main) must not leave the mic on. While the monitor believes Fn is held it
/// polls the real modifier state every `pollInterval` (250 ms). Default `flagsProvider`: the
/// UNION of `.hidSystemState` (hardware) and `.combinedSessionState`, so Fn counts as held if
/// EITHER reports it.
///
/// FAIL-SAFE: release detection is ARMED only once a poll has actually seen Fn held during this
/// press. If neither source ever reports Fn while our tap consumes it ("blind"), the poll never
/// stops a recording; the pipeline's recording caps + countdown are the backstop. Once armed,
/// two consecutive "not held" polls behave exactly like a real Fn-up (a single stale read is
/// forgiven). `pollStatus` (armed / blind) is logged once per session, without content.
///
/// WISPR FLOW PRIORITY (STRUCTURAL): while `holdingOff()` is true at Fn-down (Wispr Flow running
/// and not overridden), the press is left entirely alone: the event is returned UNMODIFIED (never
/// consumed, so macOS and Wispr Flow see it), the state machine isn't fed, no polling starts,
/// and only `onHeldOffPress` is scheduled (asynchronously) once for the press. `holdingOff` is
/// a lock-free flag read (`HoldOffFlag`); the tap never queries NSWorkspace.
///
/// Must be started on the main thread; the tap's run-loop source is attached to the main run loop.
@MainActor
public final class GlobeKeyMonitor {
    public var onAction: ((HotkeyStateMachine.Action) -> Void)?
    /// Swallow Fn/Globe events while enabled.
    public var consumeGlobeEvents: Bool = true
    /// Scheduled (never run inside the tap) once per 🌐 press that was passed through because
    /// WisprLocal is holding off for Wispr Flow.
    public var onHeldOffPress: (() -> Void)?
    public private(set) var isRunning = false
    /// ⌃⌥⌘V (`PasteAgainShortcut`): scheduled (never run inside the tap); the chord is consumed.
    public var onPasteAgain: (() -> Void)?
    /// The V keycode for the current layout (injected in tests).
    public var pasteKeyCode: @MainActor () -> CGKeyCode = { KeyboardLayoutMap.shared.pasteKeyCode }
    /// 🌐 is held as far as this monitor knows (the paste waits for it to come up).
    public var isFnDown: Bool { fnDown }
    /// Esc (no ⌘/⌃/⌥) while this returns true is CONSUMED and not fed to the gesture machine.
    /// Called synchronously inside the tap, so it must only make a cheap decision and schedule
    /// any real work (`EscapeCancel`). Argument: the key-down is an auto-repeat. nil = Esc is
    /// always passed through.
    public var onEscape: (@MainActor (_ isRepeat: Bool) -> Bool)?
    /// Shift pressed or released while 🌐 is held does not cancel the recording (Shift-on-release
    /// auto-send). Other modifiers still do.
    public var shiftIsReleaseModifier = false
    /// Modifier flags of the most recent trigger event (🌐 or the extra mouse button) that fed
    /// the gesture machine: whether Shift was held when the dictation was committed.
    public private(set) var lastTriggerFlags: CGEventFlags = []
    /// The extra push-to-talk trigger (mouse button) is held.
    public var isExtraTriggerDown: Bool { extraTriggerDown }
    private var extraTriggerDown = false

    private var machine = HotkeyStateMachine()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnDown = false
    private var consumedCurrentPress = false
    /// A quick release on recent Apple keyboards also emits a Globe keyDown (179).
    /// Correlate that companion with Fn-up so it cannot look like ordinary typing.
    private var lastFnRelease: (at: TimeInterval, consumed: Bool)?
    private var timer: Timer?
    private var pollTimer: Timer?
    private var missedFnPolls = 0
    /// A poll has seen Fn held during the current press (release detection armed).
    private var pollSawFnThisPress = false
    private var pollsThisPress = 0
    /// A cold mic can block the main queue while later key events wait to be delivered.
    /// Gesture durations use the events' hardware timestamps, with the same delay applied
    /// to their timeout so a queued second tap gets a chance to arrive.
    private var eventDeliveryDelay: TimeInterval = 0

    /// Whether the Fn poll can see Fn on this Mac (session-wide, for diagnostics).
    public enum PollStatus: String, Sendable { case unknown, armed, blind }
    public private(set) var pollStatus: PollStatus = .unknown
    /// Polls without ever seeing Fn after which a press marks the poll "blind".
    public static let pollsBeforeBlind = 4
    /// Real modifier state (injected in tests).
    private let flagsProvider: @MainActor () -> CGEventFlags
    /// Monotonic seconds (injected in tests).
    private let clock: @MainActor () -> TimeInterval
    private let permissionsGranted: @MainActor () -> Bool
    private var revocation = PermissionRevocationDebouncer()
    public let pollInterval: TimeInterval
    public static let defaultPollInterval: TimeInterval = 0.25
    /// Consecutive "Fn not held" polls needed to synthesize the release.
    public static let missedPollsForRelease = 2
    /// How actions leave the tap callback. MUST be asynchronous: the callback runs inside the
    /// system's event-tap deadline, so starting the mic etc. there would get the tap disabled.
    /// Injectable so tests can prove nothing runs synchronously.
    private let schedule: @MainActor (@escaping @MainActor () -> Void) -> Void
    /// Cheap, non-blocking "holding off for Wispr Flow" read (`HoldOffFlag.isHoldingOff`).
    private let holdingOff: @Sendable () -> Bool

    public init(schedule: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = GlobeKeyMonitor.mainAsync,
                holdingOff: @escaping @Sendable () -> Bool = { false },
                flagsProvider: @escaping @MainActor () -> CGEventFlags = {
                    CGEventSource.flagsState(.hidSystemState).union(CGEventSource.flagsState(.combinedSessionState))
                },
                clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                pollInterval: TimeInterval = GlobeKeyMonitor.defaultPollInterval,
                permissionsGranted: @escaping @MainActor () -> Bool = {
                    AXIsProcessTrusted() && CGPreflightListenEventAccess()
                }) {
        self.schedule = schedule
        self.holdingOff = holdingOff
        self.flagsProvider = flagsProvider
        self.clock = clock
        self.pollInterval = pollInterval
        self.permissionsGranted = permissionsGranted
    }

    public static func mainAsync(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    static let permissionHealthChanged = Notification.Name("WisprLocal.tapPermissionHealthChanged")

    public static let fnKeyCode: Int64 = 63  // kVK_Function
    static let globeTapKeyCode: Int64 = 179
    static let globeReleaseCompanionWindow: TimeInterval = 0.1
    public static let escapeKeyCode: Int64 = 53  // kVK_Escape
    static let shiftKeyCodes: Set<Int64> = [56, 60]  // kVK_Shift, kVK_RightShift
    private static let otherModifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// Returns false if the tap couldn't be created (missing Accessibility/Input Monitoring).
    @discardableResult
    public func start() -> Bool {
        let granted = permissionsGranted()
        if revocation.confirmed(granted: granted, at: clock()) {
            dispatch(machine.tapDisabled())
            stop()
            return false
        }
        if let tap {
            isRunning = EventTapRecovery.ensure(
                isEnabled: { CGEvent.tapIsEnabled(tap: tap) },
                enable: { CGEvent.tapEnable(tap: tap, enable: true) },
                recreate: {
                    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
                    self.tap = nil; self.source = nil
                    return self.createTap()
                })
            return isRunning
        }
        guard granted else { return false }
        return createTap()
    }

    private func createTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobeKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // The run-loop source lives on the main run loop, so we are on the main thread.
            let keep = MainActor.assumeIsolated { monitor.process(type: type, event: event) != nil }
            return GlobeKeyMonitor.tapResult(keep: keep, event: event)
        }
        let created =
            CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                              eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: refcon)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                 eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: refcon)
        guard let created else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        isRunning = CGEvent.tapIsEnabled(tap: created)
        return isRunning
    }

    public func stop() {
        eventDeliveryDelay = 0
        lastFnRelease = nil
        timer?.invalidate(); timer = nil
        stopPolling()
        fnDown = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; isRunning = false
        machine.reset()
    }

    /// Reset the gesture state (e.g. recorder auto-stopped at max duration).
    public func resetGesture() {
        eventDeliveryDelay = 0
        lastFnRelease = nil
        machine.reset()
        timer?.invalidate(); timer = nil
    }


    /// The tap callback's result: the SAME event, unmodified, to pass it on; nil to consume it.
    func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let time = Self.eventTime(event.timestamp, deliveredAt: clock())
        return Self.tapResult(keep: handle(type: type, event: event, at: time), event: event)
    }

    /// HID Globe events on Apple Silicon arrive in mach ticks; posted CGEvents can use
    /// nanoseconds. Select the clock domain closest to delivery time, then use seconds for
    /// every state-machine input, poll and deadline. Zero or implausible timestamps use delivery time.
    static func eventTime(_ timestamp: UInt64, deliveredAt: TimeInterval,
                          nanosecondsPerTick: Double = nanosecondsPerMachTick) -> TimeInterval? {
        guard timestamp > 0 else { return nil }
        let nanos = Double(timestamp) / 1_000_000_000
        let ticks = nanos * nanosecondsPerTick
        let chosen = abs(deliveredAt - ticks) < abs(deliveredAt - nanos) ? ticks : nanos
        guard chosen >= deliveredAt - 3, chosen <= deliveredAt + 0.05 else { return deliveredAt }
        return chosen
    }

    private static let nanosecondsPerMachTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    nonisolated static func tapResult(keep: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        keep ? Unmanaged.passUnretained(event) : nil
    }

    /// Returns whether the event should be passed on. Only updates the pure state machine and
    /// schedules actions; never does real work (internal for tests, which feed synthetic,
    /// never-posted CGEvents).
    func handle(type: CGEventType, event: CGEvent, at eventTime: TimeInterval? = nil) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lastFnRelease = nil
            if tap != nil {
                _ = start() // recover before declaring stale; negative reads are debounced
                NotificationCenter.default.post(name: Self.permissionHealthChanged, object: nil)
                return true
            }
            isRunning = false
            fnDown = false
            consumedCurrentPress = false
            stopPolling()
            dispatch(machine.tapDisabled())  // in-flight recording is DISCARDED, never inserted
            NotificationCenter.default.post(name: Self.permissionHealthChanged, object: nil)
            return true
        default: break
        }
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.value { return true }

        let deliveredAt = clock()
        let t = eventTime ?? deliveredAt
        eventDeliveryDelay = min(3, max(0, deliveredAt - t))
        if type == .flagsChanged {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if keyCode == Self.fnKeyCode {
                let isDown = flags.contains(.maskSecondaryFn)
                guard isDown != fnDown else { return true }
                if isDown, holdingOff() {
                    // Wispr Flow has priority: pass the press through untouched. `fnDown` stays
                    // false, so the matching Fn-up is passed through too.
                    schedule { [weak self] in self?.onHeldOffPress?() }
                    return true
                }
                fnDown = isDown
                lastTriggerFlags = flags
                if isDown {
                    lastFnRelease = nil
                    let mods = !flags.intersection(Self.otherModifierMask).isEmpty
                    dispatch(machine.handle(.fnDown(otherModifiers: mods), at: t))
                    consumedCurrentPress = consumeGlobeEvents && !machine.isSuppressed
                    startPolling()
                    return !consumedCurrentPress
                } else {
                    stopPolling()
                    dispatch(machine.handle(.fnUp, at: t))
                    let consumed = consumedCurrentPress
                    lastFnRelease = (t, consumed)
                    consumedCurrentPress = false
                    return !consumed
                }
            }
            // Another modifier changed.
            if fnDown {
                if shiftIsReleaseModifier, Self.shiftKeyCodes.contains(keyCode),
                   flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                    lastTriggerFlags = flags
                    return true
                }
                dispatch(machine.handle(.otherKey, at: t))
            }
            return true
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.globeTapKeyCode,
               let release = lastFnRelease, t >= release.at,
               t - release.at <= Self.globeReleaseCompanionWindow {
                return !release.consumed  // same consumption policy as the matching Fn-up
            }
            if let onEscape, event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode,
               event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
               onEscape(event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
                return false  // consumed: a WisprLocal dictation is active
            }
            if onPasteAgain != nil, !fnDown,
               PasteAgainShortcut.matches(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                                          pasteKeyCode: pasteKeyCode()) {
                schedule { [weak self] in self?.onPasteAgain?() }
                return false  // consumed: the chord does nothing else
            }
            dispatch(machine.handle(.otherKey, at: t))
        }
        return true
    }

    private func dispatch(_ actions: [HotkeyStateMachine.Action]) {
        if !actions.isEmpty {
            schedule { [weak self] in
                guard let self else { return }
                if self.isRunning { Log.info("hotkey: actions=\(String(describing: actions))") }
                for a in actions { self.onAction?(a) }
            }
        }
        scheduleDeadline()
    }

    var stateForTesting: HotkeyStateMachine.State { machine.state }

    // MARK: extra trigger (mouse button, `MouseButtonMonitor`)

    /// The extra push-to-talk button went down / up: the SAME gesture machine as 🌐 (hold,
    /// double-tap, triple-tap). Returns whether the event should be consumed. While holding off
    /// for Wispr Flow the press is passed through untouched (Wispr Flow has a mouse trigger too).
    /// Ignored while 🌐 itself is held.
    public func extraTrigger(down: Bool, flags: CGEventFlags = []) -> Bool {
        let t = clock()
        eventDeliveryDelay = 0
        if down {
            if extraTriggerDown { return true }
            if fnDown { return false }
            if holdingOff() {
                schedule { [weak self] in self?.onHeldOffPress?() }
                return false
            }
            extraTriggerDown = true
            lastTriggerFlags = flags
            dispatch(machine.handle(.fnDown(otherModifiers: false), at: t))
            return true
        }
        guard extraTriggerDown else { return false }
        extraTriggerDown = false
        lastTriggerFlags = flags
        dispatch(machine.handle(.fnUp, at: t))
        return true
    }

    /// The mouse tap was disabled by the system: the button-up may be lost, so an in-flight
    /// recording started by it is discarded, exactly like a lost 🌐 tap.
    public func extraTriggerLost() {
        guard extraTriggerDown else { return }
        extraTriggerDown = false
        dispatch(machine.tapDisabled())
    }
    var isPollingForTesting: Bool { pollTimer != nil }

    // MARK: lost Fn-up detection (CC-7)

    private func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFnState() }
        }
        RunLoop.main.add(t, forMode: .common)  // keeps polling during menu tracking / modals
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
        missedFnPolls = 0
        pollSawFnThisPress = false
        pollsThisPress = 0
    }

    private func setPollStatus(_ s: PollStatus) {
        guard s != pollStatus, pollStatus != .armed else { return }  // armed is final; log changes only
        pollStatus = s
        Log.notice("hotkey: Fn poll \(s.rawValue)")
    }

    /// One poll of the real Fn state (the timer calls this; tests call it directly).
    func pollFnState() {
        guard fnDown else { stopPolling(); return }
        pollsThisPress += 1
        if flagsProvider().contains(.maskSecondaryFn) {
            pollSawFnThisPress = true
            missedFnPolls = 0
            setPollStatus(.armed)
            return
        }
        // Never seen Fn this press: the poll may be blind; it must not stop anything.
        guard pollSawFnThisPress else {
            if pollsThisPress >= Self.pollsBeforeBlind, pollStatus == .unknown { setPollStatus(.blind) }
            return
        }
        missedFnPolls += 1
        guard missedFnPolls >= Self.missedPollsForRelease else { return }
        // The Fn-up never reached the tap: release exactly as the tap would have.
        fnDown = false
        consumedCurrentPress = false
        stopPolling()
        Log.notice("hotkey: Fn-up was lost; treating Fn as released")
        dispatch(machine.handle(.fnUp, at: clock()))
    }

    private func scheduleDeadline() {
        timer?.invalidate(); timer = nil
        guard let d = machine.deadline else { return }
        let delay = max(0, d + eventDeliveryDelay - clock())
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let timeoutAt = self.clock() - self.eventDeliveryDelay
                let actions = self.machine.timeout(at: timeoutAt)
                for a in actions { self.onAction?(a) }
                self.scheduleDeadline()  // e.g. the triple-tap window outlives a hold check
            }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}

/// Settings › Privacy troubleshooting line for CC-7 lost-release detection (content-free).
public enum LostKeyCopy {
    public static func line(_ s: GlobeKeyMonitor.PollStatus) -> String {
        switch s {
        case .armed: return "Armed: if a 🌐 release gets lost, WisprLocal notices within half a second and stops recording."
        case .blind: return "Blind on this Mac: a lost 🌐 release is caught only by the recording time limit (5 min, with a countdown)."
        case .unknown: return "Not checked yet: hold 🌐 for a second to dictate and this updates."
        }
    }
}
