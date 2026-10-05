import Foundation

/// Shared setup state for the banner, navigation and readiness text.
public enum SetupIssue: Equatable, Sendable, Identifiable {
    public enum Model: Equatable, Sendable { case ready, preparing, failed }
    case permission(Permission)
    case needsRelaunch, stalePermission, globeInactive, globeAction, wisprFlow, modelFailed, modelPreparing
    public var id: String {
        if case .permission(let p) = self { return "permission-\(p)" }
        return String(describing: self)
    }
    public var hasAction: Bool { self != .modelPreparing }
    public var text: String {
        switch self {
        case .permission(let p): "WisprLocal needs \(p == .microphone ? "the Microphone" : p.title)."
        case .needsRelaunch: "Permissions updated. Relaunch WisprLocal to finish."
        case .stalePermission: "macOS is holding an old permission. Re-add WisprLocal."
        case .globeInactive: "The 🌐 key is not active."
        case .globeAction: "macOS can also react to 🌐 while you dictate."
        case .wisprFlow: WisprFlowCopy.holdingOff
        case .modelFailed: "The speech model couldn't start."
        case .modelPreparing: "Preparing the speech model…"
        }
    }
    public static func resolve(permissions: [Permission: Bool], health: PermissionHealth,
                               globeAction: GlobeKeyConflict, consumeGlobe: Bool,
                               wisprFlow: Bool, model: Model, globeActive: Bool = true) -> [Self] {
        let missing = Permission.allCases.filter { permissions[$0] != true }
        var issues = missing.map { Self.permission($0) }
        switch health {
        case .missing(let ps):
            issues += ps.filter { !missing.contains($0) }.map { .permission($0) }
        case .needsRelaunch: issues.append(.needsRelaunch)
        case .stalePermission: issues.append(.stalePermission)
        case .ready:
            if !globeActive { issues.append(.globeInactive) }
        }
        if !consumeGlobe, globeAction != .doNothing { issues.append(.globeAction) }
        if wisprFlow { issues.append(.wisprFlow) }
        switch model {
        case .ready: break
        case .preparing: issues.append(.modelPreparing)
        case .failed: issues.append(.modelFailed)
        }
        return issues
    }
}
