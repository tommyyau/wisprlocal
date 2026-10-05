import Foundation
import Observation

/// How text is typed into a remote viewer when no receiver is paired/reachable.
public enum RemoteTypingFallback: String, Codable, Sendable, CaseIterable, Identifiable {
    /// CGEvent `keyboardSetUnicodeString`, one character per event.
    case unicode
    /// Real virtual keycodes + modifiers from the current layout (`KeyStrokeMap`); characters the
    /// layout cannot produce fall back to Unicode per character.
    case keycode
    /// Local pasteboard, wait for Screen Sharing to sync it, then Cmd-V.
    case clipboardDelay

    public var id: String { rawValue }
}

/// Remote-dictation settings (persisted as one JSON blob in UserDefaults).
public struct RemoteConfig: Codable, Sendable, Equatable {
    /// THE default typing fallback. Unicode until the S2 two-Mac comparison is run (Remote Macs
    /// is Beta, see docs/ROADMAP.md); change this one line if keycode typing wins.
    public static let defaultTypingFallback: RemoteTypingFallback = .unicode

    /// Bundle IDs treated as remote viewers (editable in Settings).
    public static let defaultViewerBundleIDs: [String] = [
        "com.apple.ScreenSharing",
        "com.p5sys.jump.mac.viewer",        // Jump Desktop
        "com.p5sys.jump.mac.viewer.web",    // Jump Desktop (Setapp / web build)
        "com.realvnc.vncviewer",            // RealVNC Viewer
        "com.microsoft.rdc.macos",          // Microsoft Windows App (ex Remote Desktop)
        "com.carriez.rustdesk",             // RustDesk
        "tv.parsec.www",                    // Parsec
    ]
    public static let defaultClipboardDelayMs = 1500

    public var viewerBundleIDs: [String]
    public var typingFallback: RemoteTypingFallback
    public var clipboardDelayMs: Int
    /// Receiver used when no paired receiver matches the viewer's window title.
    public var defaultReceiverID: UUID?

    public init(viewerBundleIDs: [String] = RemoteConfig.defaultViewerBundleIDs,
                typingFallback: RemoteTypingFallback = RemoteConfig.defaultTypingFallback,
                clipboardDelayMs: Int = RemoteConfig.defaultClipboardDelayMs,
                defaultReceiverID: UUID? = nil) {
        self.viewerBundleIDs = viewerBundleIDs
        self.typingFallback = typingFallback
        self.clipboardDelayMs = clipboardDelayMs
        self.defaultReceiverID = defaultReceiverID
    }

    public var viewerSet: Set<String> { Set(viewerBundleIDs) }
}

/// Observable, persisted `RemoteConfig`. `shared` is what the app and RemoteSettingsView use.
@MainActor
@Observable
public final class RemoteConfigStore {
    public static let defaultsKey = "remoteConfig.v1"
    public static let shared = RemoteConfigStore()

    @ObservationIgnored private let defaults: UserDefaults
    public var config: RemoteConfig { didSet { save() } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let c = try? JSONDecoder().decode(RemoteConfig.self, from: data) {
            config = c
        } else {
            config = RemoteConfig()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
