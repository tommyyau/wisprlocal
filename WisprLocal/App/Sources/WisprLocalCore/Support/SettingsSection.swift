import Foundation

/// The five Settings tabs, in display order.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, microphone, writing, privacy, remote
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: "General"
        case .microphone: "Microphone"
        case .writing: "Writing"
        case .privacy: "Privacy"
        case .remote: "Remote Macs"
        }
    }
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .microphone: "mic"
        case .writing: "text.alignleft"
        case .privacy: "lock.shield"
        case .remote: "display.2"
        }
    }
    public var path: String { "Settings \u{203A} " + title }
}

public enum SettingsRequest: Equatable, Sendable {
    case tab(SettingsSection)
    case setup
}
