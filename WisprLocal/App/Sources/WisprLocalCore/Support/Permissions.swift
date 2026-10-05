import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case microphone, accessibility, inputMonitoring
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    public var why: String {
        switch self {
        case .microphone: return "WisprLocal needs the microphone to hear you while you hold 🌐, during hands-free dictation and, if you keep the mic ready, for a short while afterwards. Everything is transcribed on this Mac and audio never leaves it."
        case .accessibility: return "Watch the Globe key and paste text at your cursor."
        case .inputMonitoring: return "Detect the Globe key system-wide."
        }
    }

    @MainActor public var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        }
    }

    /// Triggers the system prompt where one exists, otherwise opens the settings pane.
    @MainActor public func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else { openSettings() }
        case .accessibility:
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) { openSettings() }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings() }
        }
    }

    public var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    @MainActor public func openSettings() { NSWorkspace.shared.open(settingsURL) }
}
