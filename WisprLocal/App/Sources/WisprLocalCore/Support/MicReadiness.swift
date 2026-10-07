import Foundation

/// One decision backed by the two existing warm-microphone flags.
public enum MicReadiness: String, CaseIterable, Identifiable, Sendable {
    case off, afterDictating, always
    public var id: String { rawValue }
    public init(keep: Bool, always: Bool) {
        self = always ? .always : keep ? .afterDictating : .off
    }
    public var keep: Bool { self != .off }
    public var always: Bool { self == .always }
    public var title: String {
        switch self {
        case .off: "Off"
        case .afterDictating: "Ready for 60 s after dictating"
        case .always: "Always on"
        }
    }
    public var caption: String {
        switch self {
        case .off: "The first word can be clipped."
        case .afterDictating: "Keeps the first word of back-to-back dictations."
        case .always: "Keeps the first word of almost every dictation; ~10 % of one CPU core."
        }
    }
    @MainActor public func apply(to settings: AppSettings) {
        settings.keepMicReady = keep
        settings.alwaysMicReady = always
    }
}
