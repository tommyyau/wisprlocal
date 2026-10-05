import AppKit
import Foundation
import Synchronization

/// Snapshot of a running application, decoupled from NSRunningApplication for testability.
public struct RunningAppInfo: Sendable, Equatable {
    public var bundleID: String?
    public var bundlePath: String?
    public var pid: Int32
    public init(bundleID: String?, bundlePath: String?, pid: Int32 = 0) {
        self.bundleID = bundleID; self.bundlePath = bundlePath; self.pid = pid
    }
}

/// What the pipeline needs to know to decide whether it may insert text.
public protocol InsertionGate: Sendable {
    /// Returns nil if insertion is allowed, otherwise a human-readable reason.
    @MainActor func insertionBlockReason() -> String?
}

/// Pure detection rules (unit-tested).
public enum WisprFlowMatcher {
    public static let bundleID = "com.electron.wispr-flow"
    public static let appBundleName = "Wispr Flow.app"

    public static func isWisprFlow(_ app: RunningAppInfo) -> Bool {
        // Never ourselves (our name/path contains "Wispr" since the WisprLocal rename).
        if app.bundleID == AppPaths.bundleID { return false }
        if app.bundleID == bundleID { return true }
        // Nested helpers (e.g. its Swift helper inside Contents/) live under the .app path.
        if let p = app.bundlePath, p.contains(appBundleName) { return true }
        return false
    }

    public static func detect(in apps: [RunningAppInfo]) -> [RunningAppInfo] {
        apps.filter(isWisprFlow)
    }
}

/// Lock-free "holding off for Wispr Flow" flag. The Globe event tap reads it inside its
/// callback, which must never block or query NSWorkspace; `ConflictDetector` writes it on the
/// main actor whenever the cached state changes (launch/terminate notifications, live checks).
public final class HoldOffFlag: Sendable {
    private let storage = Atomic<Bool>(false)
    public init() {}
    public var isHoldingOff: Bool { storage.load(ordering: .relaxed) }
    func set(_ value: Bool) { storage.store(value, ordering: .relaxed) }
}

/// User-facing Wispr Flow coexistence copy (kept here so tests and the app share it).
public enum WisprFlowCopy {
    public static let holdingOff = "Wispr Flow is running — WisprLocal is holding off"
    public static let useAnyway = "Use WisprLocal anyway"
    /// Menu-bar attention row (title case per the macOS HIG).
    public static let holdingOffMenuTitle = "Wispr Flow Is Active"
    public static let useAnywayMenuTitle = "Use WisprLocal Anyway…"
    public static let useAnywayConfirmation =
        "Both apps may type the same words. Quit Wispr Flow or change its shortcut to avoid this."
    public static let differentShortcut = "Wispr Flow uses a different shortcut"
    /// Short HUD button title for `differentShortcut`.
    public static let differentShortcutButton = "Uses another shortcut"
}

/// Watches for Wispr Flow (which also listens on Globe by default) and gives it priority.
///
/// While `holdingOff` (Wispr Flow running, not overridden), WisprLocal is FULLY PASSIVE: the
/// event tap passes 🌐 through unmodified (`flag`), no recording starts, the warm mic is dropped
/// and nothing is inserted. Overrides: "Use WisprLocal anyway" (`useAnyway`, in memory only,
/// reset when Wispr Flow quits or relaunches) and the persisted "Wispr Flow uses a different
/// shortcut" setting (`differentShortcut`). When Wispr Flow quits, WisprLocal resumes on its own.
///
/// The cached state is refreshed by NSWorkspace launch/terminate notifications plus live checks
/// (`refresh()`) at key-down and before insertion, always on the main actor, never in the tap.
@MainActor
@Observable
public final class ConflictDetector: InsertionGate {
    public private(set) var wisprFlowRunning = false
    /// "Use WisprLocal anyway" (HUD/menu, after a confirmation). In memory only; resets when
    /// Wispr Flow quits or relaunches.
    public var useAnyway = false { didSet { publish() } }
    /// Persisted setting "Wispr Flow uses a different shortcut" (mirrored in by the app).
    public var differentShortcut = false { didSet { publish() } }
    public private(set) var globeConflict: GlobeKeyConflict = .unknown

    /// True while WisprLocal gives way to Wispr Flow (running and not overridden).
    public var holdingOff: Bool { wisprFlowRunning && !useAnyway && !differentShortcut }

    /// What the event tap reads (lock-free, no NSWorkspace).
    @ObservationIgnored public let flag = HoldOffFlag()
    /// "Wispr Flow is running" notice cooldown (at most one per press, and one per 8 s).
    public static let noticeCooldown: TimeInterval = 8

    @ObservationIgnored private let runningApps: @MainActor () -> [RunningAppInfo]
    @ObservationIgnored private let fnUsageReader: () -> Int?
    @ObservationIgnored private let clock: @MainActor () -> TimeInterval
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastHoldingOff = false
    @ObservationIgnored private var wisprPIDs: Set<Int32> = []
    @ObservationIgnored private var lastNoticeAt: TimeInterval?
    @ObservationIgnored private var batching = false
    /// Fired when `holdingOff` changes (main actor).
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(runningApps: @escaping @MainActor () -> [RunningAppInfo] = ConflictDetector.systemRunningApps,
                fnUsageReader: @escaping () -> Int? = GlobeKeyConflict.readSystemValue,
                clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.runningApps = runningApps
        self.fnUsageReader = fnUsageReader
        self.clock = clock
    }

    public static func systemRunningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(bundleID: $0.bundleIdentifier, bundlePath: $0.bundleURL?.path, pid: $0.processIdentifier)
        }
    }

    /// Check now and subscribe to launch/terminate notifications.
    public func start() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    public func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    /// Live check of the running-app list (main actor only; never from the event tap).
    public func refresh() {
        let found = WisprFlowMatcher.detect(in: runningApps())
        let running = !found.isEmpty
        let pids = Set(found.map(\.pid))
        batching = true
        // "Use anyway" lasts only while the same Wispr Flow runs: reset on quit or relaunch
        // (a relaunch seen without its terminate notification shows up as all-new PIDs).
        if !running || (!wisprPIDs.isEmpty && wisprPIDs.isDisjoint(with: pids)) { useAnyway = false }
        wisprPIDs = pids
        wisprFlowRunning = running
        globeConflict = GlobeKeyConflict(fnUsageType: fnUsageReader())
        batching = false
        publish()
    }

    /// Mirror `holdingOff` into the tap flag; notify on change.
    private func publish() {
        guard !batching else { return }
        let now = holdingOff
        flag.set(now)
        guard now != lastHoldingOff else { return }
        lastHoldingOff = now
        onChange?()
    }

    /// Debounce for the holding-off notice: true at most once per `noticeCooldown`.
    public func shouldShowHoldOffNotice() -> Bool {
        let t = clock()
        if let last = lastNoticeAt, t - last < Self.noticeCooldown { return false }
        lastNoticeAt = t
        return true
    }

    /// Live check: re-queries the running-app list right now (doesn't trust the cached flag,
    /// which depends on launch/terminate notifications having been delivered).
    public func insertionBlockReason() -> String? {
        refresh()
        return holdingOff ? "Wispr Flow is running (WisprLocal is holding off to avoid double text)" : nil
    }

    /// Politely ask Wispr Flow to quit. Only call from an explicit UI button.
    public func quitWisprFlow() {
        for app in NSWorkspace.shared.runningApplications {
            let info = RunningAppInfo(bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path)
            if WisprFlowMatcher.isWisprFlow(info) { app.terminate() }
        }
    }
}

/// macOS "Press 🌐 key to" setting (`com.apple.HIToolbox` `AppleFnUsageType`).
public enum GlobeKeyConflict: Sendable, Equatable {
    case doNothing
    case changeInputSource
    case emojiAndSymbols
    case startDictation
    /// Key absent (macOS default for the hardware applies, usually emoji or input source).
    case unknown

    public init(fnUsageType: Int?) {
        switch fnUsageType {
        case 0: self = .doNothing
        case 1: self = .changeInputSource
        case 2: self = .emojiAndSymbols
        case 3: self = .startDictation
        default: self = .unknown
        }
    }

    /// True when Globe is (or may be) bound to a system action that will fight our hotkey.
    public var isConflict: Bool { self != .doNothing }

    public var label: String {
        switch self {
        case .doNothing: return "Do Nothing"
        case .changeInputSource: return "Change Input Source"
        case .emojiAndSymbols: return "Show Emoji & Symbols"
        case .startDictation: return "Start Dictation"
        case .unknown: return "system default (not set)"
        }
    }

    public static func readSystemValue() -> Int? {
        let v = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (v as? NSNumber)?.intValue
    }

    /// Deep link to System Settings > Keyboard.
    public static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}
