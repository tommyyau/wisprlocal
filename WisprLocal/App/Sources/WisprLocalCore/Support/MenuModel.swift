import Foundation

/// The menu-bar menu as data: the app renders it as an NSMenu (`MenuContent`) and the DEBUG
/// preview renders a mock from the SAME entries, so they cannot drift. Everything the menu
/// shows is derived here from a `MenuSnapshot` of live state; nothing is a sticky flag.
///
/// Copy follows the macOS HIG: title case, an ellipsis when more input is needed or by convention.

/// Live state the menu and the menu-bar icon are derived from.
public struct MenuSnapshot: Equatable, Sendable {
    public enum MicReady: Equatable, Sendable {
        /// Settings › Microphone › "Ready for 60 s after dictating" window, whole seconds left;
        /// the menu shows "Mic Ready · 0:42 — Stop".
        case window(secondsLeft: Int)
        /// Settings › Microphone › Microphone readiness: "Always on".
        case always
    }

    /// A permission is missing, stale, or waiting for a relaunch.
    public var permissionNeeded = false
    /// Wispr Flow is running and WisprLocal is holding off (not overridden).
    public var holdingOffForWisprFlow = false
    /// The speech model failed to prepare (persistent until retried).
    public var modelFailed = false
    /// The speech model is being loaded right now (start-up, mode switch or retry).
    public var modelLoading = false
    public var recording = false
    public var micReady: MicReady?
    /// The recording pill is hidden for an hour (dictation still works).
    public var indicatorHidden = false

    public init(permissionNeeded: Bool = false, holdingOffForWisprFlow: Bool = false, modelFailed: Bool = false,
                modelLoading: Bool = false, recording: Bool = false, micReady: MicReady? = nil,
                indicatorHidden: Bool = false) {
        self.permissionNeeded = permissionNeeded; self.holdingOffForWisprFlow = holdingOffForWisprFlow
        self.modelFailed = modelFailed; self.modelLoading = modelLoading
        self.recording = recording; self.micReady = micReady
        self.indicatorHidden = indicatorHidden
    }
}

/// The single attention row at the top of the menu, shown ONLY outside the normal ready state.
public enum MenuAttention: Equatable, Sendable {
    case permissionNeeded
    case holdingOffForWisprFlow
    case modelFailed
    case loadingModel
    case recording
    case indicatorHidden
    case micReady(MenuSnapshot.MicReady)

    /// What the row does when clicked (nil = an informational, disabled row).
    public enum Action: Equatable, Sendable { case openSetup, useAnyway, retryModel, stopMic, showIndicator }

    /// Most important first: permission > Wispr Flow > model failed > loading > recording >
    /// indicator hidden > mic ready. nil in the normal ready state (never a "Ready…" row).
    public static func resolve(_ s: MenuSnapshot) -> MenuAttention? {
        if s.permissionNeeded { return .permissionNeeded }
        if s.holdingOffForWisprFlow { return .holdingOffForWisprFlow }
        if s.modelFailed { return .modelFailed }
        if s.modelLoading { return .loadingModel }
        if s.recording { return .recording }
        if s.indicatorHidden { return .indicatorHidden }
        if let m = s.micReady { return .micReady(m) }
        return nil
    }

    public var title: String {
        switch self {
        case .permissionNeeded: return "Permission Needed"
        case .holdingOffForWisprFlow: return WisprFlowCopy.holdingOffMenuTitle
        case .modelFailed: return "Speech Model Unavailable"
        case .loadingModel: return "Loading Speech Model…"
        case .recording: return "Recording…"
        case .indicatorHidden: return "Indicator Hidden"
        case .micReady(.always): return "Mic Ready"
        case .micReady(.window(let s)): return "Mic Ready · \(Self.clock(s))"
        }
    }

    public var action: Action? {
        switch self {
        case .permissionNeeded: return .openSetup
        case .holdingOffForWisprFlow: return .useAnyway
        case .modelFailed: return .retryModel
        case .loadingModel, .recording: return nil
        case .indicatorHidden: return .showIndicator
        case .micReady: return .stopMic
        }
    }

    public var actionTitle: String? {
        switch action {
        case .openSetup: return "Fix…"
        case .useAnyway: return WisprFlowCopy.useAnywayMenuTitle
        case .retryModel: return "Retry"
        case .stopMic: return "Stop"
        case .showIndicator: return "Show"
        case nil: return nil
        }
    }

    /// The one-line menu item: "Indicator Hidden — Show", or just the title when there is no action.
    public var label: String { actionTitle.map { "\(title) — \($0)" } ?? title }

    /// "0:42" (m:ss).
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Menu-bar glyph variants (template images `<resourceName>.png` / `@2x` in Resources).
public enum MenuBarIconState: String, CaseIterable, Sendable {
    case idle, warmMic, recording, holdingOff, error

    /// error (model failed or permission needed) > holding off > recording > warm mic > idle.
    public static func resolve(_ s: MenuSnapshot) -> MenuBarIconState {
        if s.modelFailed || s.permissionNeeded { return .error }
        if s.holdingOffForWisprFlow { return .holdingOff }
        if s.recording { return .recording }
        if s.micReady != nil { return .warmMic }
        return .idle
    }

    public var resourceName: String {
        switch self {
        case .idle: return "MenuBarIcon"
        case .warmMic: return "MenuBarIconWarm"
        case .recording: return "MenuBarIconRecording"
        case .holdingOff: return "MenuBarIconHoldingOff"
        case .error: return "MenuBarIconAlert"
        }
    }

    public var accessibilityDescription: String {
        switch self {
        case .idle: return "WisprLocal"
        case .warmMic: return "WisprLocal — mic ready"
        case .recording: return "WisprLocal — recording"
        case .holdingOff: return "WisprLocal — holding off for Wispr Flow"
        case .error: return "WisprLocal — needs attention"
        }
    }
}

/// One menu entry, top to bottom.
public enum MenuEntry: Equatable, Sendable {
    case attention(MenuAttention)
    /// Checked = Noisy room / other languages (Parakeet Ultra); unchecked = Parakeet v2.
    case noisyRoom(checked: Bool)
    case openApp
    case settings
    case help([HelpItem])
    case quit
    case separator

    public enum HelpItem: String, CaseIterable, Sendable {
        case helpAndFAQ, gettingStarted, credits, about
        public var title: String {
            switch self {
            case .helpAndFAQ: return "Help & FAQ…"
            case .gettingStarted: return "Getting Started…"
            case .credits: return "Credits…"
            case .about: return "About WisprLocal…"
            }
        }
    }

    public var title: String {
        switch self {
        case .attention(let a): return a.label
        case .noisyRoom: return MenuModel.noisyRoomTitle
        case .openApp: return "Open Dashboard"
        case .settings: return "Settings…"
        case .help: return "Help"
        case .quit: return "Quit WisprLocal"
        case .separator: return ""
        }
    }

    /// ⌘-key equivalent, if any.
    public var keyEquivalent: Character? {
        switch self {
        case .settings: return ","
        case .quit: return "q"
        default: return nil
        }
    }
}

public enum MenuModel {
    public static let noisyRoomTitle = "Noisy Room Mode"
    public static let noisyRoomSubtitle = "Also understands 25 European languages"

    public static func entries(_ s: MenuSnapshot, noisyRoom: Bool) -> [MenuEntry] {
        var out: [MenuEntry] = []
        if let a = MenuAttention.resolve(s) { out += [.attention(a), .separator] }
        out += [
            .openApp,
            .settings,
            .separator,
            .noisyRoom(checked: noisyRoom),
            .separator,
            .help(MenuEntry.HelpItem.allCases),
            .separator,
            .quit,
        ]
        return out
    }
}
