import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

/// Health of the two TCC grants the Globe-key event tap needs (Accessibility + Input Monitoring).
///
/// Why this exists: TCC keys a grant to the app's code signature (its designated requirement).
/// With ad-hoc signing that requirement is the binary's hash, so every rebuild leaves System
/// Settings showing WisprLocal as ON while the grant actually belongs to a stale binary. Even with
/// a stable signature, a grant made while the app is running is not always picked up by the
/// already-running process. Both cases are invisible unless we say so.
public enum PermissionHealth: Equatable, Sendable {
    /// One or both grants read as missing (listed in `Permission.tapPermissions` order).
    case missing([Permission])
    /// Granted at launch and the event tap is running.
    case ready
    /// A grant appeared while this process was running: relaunch so it takes effect cleanly.
    case needsRelaunch
    /// Both grants read as granted since launch, yet the event tap cannot be created: the
    /// System Settings entry belongs to a different (older) signature of WisprLocal.
    case stalePermission

    public var isReady: Bool { self == .ready }
    public var offersRelaunch: Bool { self == .needsRelaunch || self == .stalePermission }

    /// Content-free alert when an established session loses its event-tap permissions.
    public func lossNotice(previous: PermissionHealth) -> String? {
        guard previous.isReady else { return nil }
        switch self {
        case .missing(let permissions):
            return permissions.map(\.title).joined(separator: " and ") + (permissions.count == 1 ? " was" : " were") + " turned off — open Settings"
        case .ready, .stalePermission, .needsRelaunch: return nil
        }
    }

    public var headline: String {
        switch self {
        case .missing(let ps): return "Grant " + ps.map(\.title).joined(separator: " and ") + " to use the Globe key"
        case .ready: return "Permissions OK"
        case .needsRelaunch: return "Permissions updated — Relaunch WisprLocal"
        case .stalePermission: return "Stale permission — re-add WisprLocal in System Settings"
        }
    }

    /// Exactly what to do, step by step.
    public var instructions: [String] {
        switch self {
        case .missing(let ps): return ps.map(\.toggleInstruction)
        case .ready: return []
        case .needsRelaunch:
            return ["Click Relaunch so the new permission takes effect.",
                    "If the Globe key still does nothing after relaunching, remove WisprLocal from the list with − and add it again."]
        case .stalePermission:
            return Permission.tapPermissions.map {
                "System Settings › Privacy & Security › \($0.title): select WisprLocal, click − to remove it, then click + and add WisprLocal again (from ~/Applications) and turn it on."
            } + ["Then click Relaunch."]
        }
    }
}

extension Permission {
    /// The grants the event tap depends on (microphone is checked separately and never needs a relaunch).
    public static let tapPermissions: [Permission] = [.accessibility, .inputMonitoring]

    public var toggleInstruction: String {
        "System Settings › Privacy & Security › \(title): turn on WisprLocal (click + to add it if it isn't listed)."
    }
}

/// Pure state machine (unit-tested): missing → granted → needs relaunch; granted-at-launch but
/// tap failing → stale permission.
public struct PermissionStateMachine: Equatable, Sendable {
    public private(set) var health: PermissionHealth?
    /// Sticky: once a grant has read as missing in this process, a later grant needs a relaunch.
    public private(set) var sawMissing = false

    public init() {}

    @discardableResult
    public mutating func update(accessibility: Bool, inputMonitoring: Bool, tapRunning: Bool) -> PermissionHealth {
        var missing: [Permission] = []
        if !accessibility { missing.append(.accessibility) }
        if !inputMonitoring { missing.append(.inputMonitoring) }
        let next: PermissionHealth
        if !missing.isEmpty {
            sawMissing = true
            next = .missing(missing)
        } else if sawMissing {
            next = .needsRelaunch
        } else if !tapRunning {
            next = .stalePermission
        } else {
            next = .ready
        }
        health = next
        return next
    }
}

/// A transient negative preflight read must not revoke an established session.
/// Confirmation needs a second consecutive negative at least nine seconds (10 s with the 0.9 tolerance) later.
struct PermissionRevocationDebouncer {
    private var firstNegative: TimeInterval?
    mutating func confirmed(granted: Bool, at now: TimeInterval) -> Bool {
        if granted { firstNegative = nil; return false }
        guard let firstNegative else { self.firstNegative = now; return false }
        return now - firstNegative >= PermissionMonitor.healthyPollInterval * 0.9
    }
}

/// Recovery order shared with the real CGEvent tap and exercised without TCC.
enum EventTapRecovery {
    static func ensure(isEnabled: () -> Bool, enable: () -> Void, recreate: () -> Bool) -> Bool {
        if isEnabled() { return true }
        enable()
        if isEnabled() { return true }
        return recreate()
    }
}

/// Reads the system state. Injected so the monitor is testable without TCC.
@MainActor
public protocol PermissionProbe: AnyObject {
    var accessibilityGranted: Bool { get }
    var inputMonitoringGranted: Bool { get }
    /// Re-enable a disabled tap, then recreate it if needed. Returns whether it is running.
    func ensureEventTap() -> Bool
}

@MainActor
public final class SystemPermissionProbe: PermissionProbe {
    private let startTap: @MainActor () -> Bool
    public init(startTap: @escaping @MainActor () -> Bool) { self.startTap = startTap }
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }
    public var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    public func ensureEventTap() -> Bool { startTap() }
}

/// Polls unhealthy grants every two seconds and healthy grants every ten seconds, (re)trying the
/// event tap on each tick, and publishes `health` / `tapRunning` for the UI.
@MainActor
@Observable
public final class PermissionMonitor {
    public static let pollInterval: TimeInterval = 2
    nonisolated public static let healthyPollInterval: TimeInterval = 10

    public private(set) var health: PermissionHealth = .missing(Permission.tapPermissions)
    public private(set) var tapRunning = false
    /// Called on the main actor whenever `health` changes.
    @ObservationIgnored public var onChange: ((PermissionHealth) -> Void)?

    @ObservationIgnored private var machine = PermissionStateMachine()
    @ObservationIgnored private let probe: PermissionProbe
    @ObservationIgnored private var timer: Timer?

    @ObservationIgnored private let clock: @MainActor () -> TimeInterval
    @ObservationIgnored private var lastRefresh: TimeInterval = -.infinity
    @ObservationIgnored private var tapObserver: NSObjectProtocol?
    @ObservationIgnored private var revocation = PermissionRevocationDebouncer()

    public init(probe: PermissionProbe,
                clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.probe = probe; self.clock = clock
    }

    public var isPolling: Bool { timer != nil }
    var scheduledPollInterval: TimeInterval? { timer?.timeInterval }

    /// One poll: try the tap, read both grants, advance the state machine.
    @discardableResult
    public func refresh() -> PermissionHealth {
        lastRefresh = clock()
        let running = probe.ensureEventTap()
        let accessibility = probe.accessibilityGranted, inputMonitoring = probe.inputMonitoringGranted
        let granted = accessibility && inputMonitoring
        let revoked = revocation.confirmed(granted: granted, at: lastRefresh)
        if machine.health == .ready, !granted, !revoked {
            scheduleNextPoll()
            return health
        }
        tapRunning = running && granted
        let next = machine.update(accessibility: accessibility,
                                  inputMonitoring: inputMonitoring,
                                  tapRunning: tapRunning)
        if next != health {
            health = next
            onChange?(next)
        }
        scheduleNextPoll()
        return next
    }

    /// Timer tick, exposed internally for deterministic fake-clock tests.
    func pollIfDue() {
        let interval = health.isReady ? Self.healthyPollInterval : Self.pollInterval
        if clock() - lastRefresh >= interval * 0.9 { refresh() }
    }

    /// Refresh now and continue checking for mid-session revocation.
    public func start() {
        refresh()
        guard timer == nil else { return }
        tapObserver = NotificationCenter.default.addObserver(forName: GlobeKeyMonitor.permissionHealthChanged,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
        scheduleNextPoll(force: true)
    }

    private func scheduleNextPoll(force: Bool = false) {
        guard force || timer != nil else { return }
        let interval = health.isReady ? Self.healthyPollInterval : Self.pollInterval
        if timer?.timeInterval == interval { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollIfDue() }
        }
        timer?.tolerance = interval * 0.1
    }

    public func stopPolling() {
        timer?.invalidate(); timer = nil
        if let tapObserver { NotificationCenter.default.removeObserver(tapObserver) }
        tapObserver = nil
    }
}

/// Relaunch this app bundle as a new instance, then quit the current one.
@MainActor
public enum AppRelauncher {
    public static func relaunch(bundleURL: URL = Bundle.main.bundleURL,
                                onError: @escaping @MainActor (String) -> Void = { Log.info("relaunch failed: \($0)") }) {
        guard bundleURL.pathExtension == "app" else {
            onError("not running from an .app bundle (\(bundleURL.path)); quit and reopen WisprLocal manually")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let message { onError(message) } else { NSApp.terminate(nil) }
                }
            }
        }
    }
}
