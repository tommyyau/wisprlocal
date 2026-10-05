import CoreGraphics
import Foundation

/// The optional extra push-to-talk trigger: a mouse button (Settings › General). A SECOND
/// event tap, on `otherMouseDown/Up` only, that exists only while a button is selected (with
/// "None" nothing is installed). Presses of the selected button feed the 🌐 gesture machine
/// (`GlobeKeyMonitor.extraTrigger`), so hold, double-tap and triple-tap work the same, and are
/// consumed; every other button, and our own synthetic events, pass through untouched.
@MainActor
public final class MouseButtonMonitor {
    public var trigger: MouseTrigger = .none
    public private(set) var isRunning = false
    private let globe: GlobeKeyMonitor
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(globe: GlobeKeyMonitor) { self.globe = globe }

    /// Install or remove the tap for `trigger`. Returns false if a needed tap couldn't be created.
    @discardableResult
    public func apply(_ trigger: MouseTrigger) -> Bool {
        self.trigger = trigger
        if trigger == .none { stop(); return true }
        return start()
    }

    private func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<MouseButtonMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let keep = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            return keep ? Unmanaged.passUnretained(event) : nil
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: refcon)
        else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        isRunning = true
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; isRunning = false
        globe.extraTriggerLost()
    }

    /// Returns whether the event is passed on (internal for tests: synthetic, never-posted events).
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            globe.extraTriggerLost()
            return true
        case .otherMouseDown, .otherMouseUp:
            guard event.getIntegerValueField(.eventSourceUserData) != SyntheticEventMarker.value,
                  MouseTrigger.matching(buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber), selected: trigger)
            else { return true }
            return !globe.extraTrigger(down: type == .otherMouseDown, flags: event.flags)
        default:
            return true
        }
    }
}
