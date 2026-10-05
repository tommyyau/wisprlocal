import CoreGraphics
import Foundation
import Observation

/// Where the recording pill sits on screen. Pure geometry (unit-tested) + persistence.
///
/// Coordinates are AppKit screen points (origin bottom-left). Positions are stored as the
/// pill centre *relative to the display's visibleFrame* (0…1 on each axis), per display, so a
/// resolution change or Dock move keeps the pill in the same place visually.
public enum HUDPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case bottomCenter, topCenter, topRight, bottomRight, topLeft, bottomLeft
    public var id: String { rawValue }
    public static let `default`: HUDPreset = .bottomCenter

    public var title: String {
        switch self {
        case .bottomCenter: "Bottom centre"
        case .topCenter: "Top centre"
        case .topRight: "Top right"
        case .bottomRight: "Bottom right"
        case .topLeft: "Top left"
        case .bottomLeft: "Bottom left"
        }
    }
    var isTop: Bool { self == .topCenter || self == .topLeft || self == .topRight }
    var column: HUDAlignment {
        switch self {
        case .topLeft, .bottomLeft: .leading
        case .topCenter, .bottomCenter: .center
        case .topRight, .bottomRight: .trailing
        }
    }
}

/// Which pill edge stays put while the pill changes width (notices are wider than the
/// recording pill): left-hand positions grow rightwards, right-hand ones leftwards.
public enum HUDAlignment: String, Codable, Sendable { case leading, center, trailing }

public struct HUDRelativePosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum HUDPlacement {
    /// The resting (recording) pill the position refers to.
    public static let pillSize = CGSize(width: 132, height: 40)
    /// Gap between the pill and the visibleFrame edge.
    public static let margin: CGFloat = 24
    /// Bottom positions stay at least this far above the physical screen bottom, so an
    /// auto-hidden Dock popping up never lands on the pill (matches the original HUD).
    public static let dockClearance: CGFloat = 110
    /// Snap distance (points) to edges and centre lines while dragging.
    public static let snapDistance: CGFloat = 10

    /// Allowed pill-centre rectangle inside `visible`.
    public static func bounds(visible: CGRect, pill: CGSize = pillSize) -> CGRect {
        let insetX = min(visible.width / 2, margin + pill.width / 2)
        let insetY = min(visible.height / 2, margin + pill.height / 2)
        return visible.insetBy(dx: insetX, dy: insetY)
    }

    public static func clamp(_ p: CGPoint, visible: CGRect, pill: CGSize = pillSize) -> CGPoint {
        let b = bounds(visible: visible, pill: pill)
        return CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    /// Pill centre for a preset. `full` (the display's whole frame) adds Dock clearance.
    public static func centre(for preset: HUDPreset, visible: CGRect, full: CGRect? = nil, pill: CGSize = pillSize) -> CGPoint {
        let b = bounds(visible: visible, pill: pill)
        let x: CGFloat = switch preset.column { case .leading: b.minX; case .center: b.midX; case .trailing: b.maxX }
        var y = preset.isTop ? b.maxY : b.minY
        if !preset.isTop, let full { y = min(b.maxY, max(y, full.minY + dockClearance)) }
        return CGPoint(x: x, y: y).rounded
    }

    public static func relative(fromCentre p: CGPoint, visible: CGRect) -> HUDRelativePosition {
        guard visible.width > 0, visible.height > 0 else { return HUDRelativePosition(x: 0.5, y: 0.5) }
        return HUDRelativePosition(x: Double((p.x - visible.minX) / visible.width), y: Double((p.y - visible.minY) / visible.height))
    }

    /// Relative → absolute, clamped (a stored position always lands fully on screen).
    public static func centre(for r: HUDRelativePosition, visible: CGRect, pill: CGSize = pillSize) -> CGPoint {
        let p = CGPoint(x: visible.minX + CGFloat(r.x) * visible.width, y: visible.minY + CGFloat(r.y) * visible.height)
        return clamp(p, visible: visible, pill: pill).rounded
    }

    public static func alignment(forCentre p: CGPoint, visible: CGRect) -> HUDAlignment {
        guard visible.width > 0 else { return .center }
        let f = (p.x - visible.minX) / visible.width
        return f < 1.0 / 3 ? .leading : (f > 2.0 / 3 ? .trailing : .center)
    }

    public struct Snap: Equatable, Sendable {
        public var point: CGPoint
        public var snappedX: Bool
        public var snappedY: Bool
        public var any: Bool { snappedX || snappedY }
    }

    /// Clamp, then snap to the left/centre/right and bottom/middle/top lines within `distance`.
    public static func snap(_ p: CGPoint, visible: CGRect, pill: CGSize = pillSize, distance: CGFloat = snapDistance) -> Snap {
        let c = clamp(p, visible: visible, pill: pill)
        let b = bounds(visible: visible, pill: pill)
        func nearest(_ v: CGFloat, _ lines: [CGFloat]) -> CGFloat? {
            lines.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) <= distance ? $0 : nil }
        }
        let sx = nearest(c.x, [b.minX, b.midX, b.maxX])
        let sy = nearest(c.y, [b.minY, b.midY, b.maxY])
        return Snap(point: CGPoint(x: sx ?? c.x, y: sy ?? c.y).rounded, snappedX: sx != nil, snappedY: sy != nil)
    }

    /// Window origin for a pill centred at `centre`, given the HUD window size, where the pill
    /// sits inside it (`pillCentreFromBottom`), the side inset for leading/trailing growth, and
    /// the alignment.
    public static func windowOrigin(centre: CGPoint, alignment: HUDAlignment, windowSize: CGSize,
                                    pillCentreFromBottom: CGFloat, sideInset: CGFloat, pill: CGSize = pillSize) -> CGPoint {
        let x: CGFloat = switch alignment {
        case .center: centre.x - windowSize.width / 2
        case .leading: centre.x - pill.width / 2 - sideInset
        case .trailing: centre.x + pill.width / 2 + sideInset - windowSize.width
        }
        return CGPoint(x: x, y: centre.y - pillCentreFromBottom).rounded
    }
}

extension CGPoint {
    var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}

/// Persisted placement: a global preset plus optional per-display custom positions
/// (keyed by display UUID). A display with no custom position — including one that has been
/// unplugged and replaced — uses the preset.
@MainActor
@Observable
public final class HUDPlacementStore {
    @ObservationIgnored private let defaults: UserDefaults
    static let presetKey = "hudPreset"
    static let customKey = "hudCustomPositions"

    public private(set) var preset: HUDPreset
    public private(set) var custom: [String: HUDRelativePosition]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preset = defaults.string(forKey: Self.presetKey).flatMap(HUDPreset.init(rawValue:)) ?? .default
        custom = defaults.data(forKey: Self.customKey).flatMap { try? JSONDecoder().decode([String: HUDRelativePosition].self, from: $0) } ?? [:]
    }

    /// Choosing a preset applies it on every display (clears custom positions).
    public func setPreset(_ p: HUDPreset) {
        preset = p
        custom = [:]
        save()
    }

    public func setCustom(_ r: HUDRelativePosition, display: String) {
        custom[display] = HUDRelativePosition(x: min(1, max(0, r.x)), y: min(1, max(0, r.y)))
        save()
    }

    public var hasCustom: Bool { !custom.isEmpty }

    /// Pill centre + growth alignment on a display.
    public func placement(display: String?, visible: CGRect, full: CGRect?) -> (centre: CGPoint, alignment: HUDAlignment) {
        if let d = display, let r = custom[d] {
            let c = HUDPlacement.centre(for: r, visible: visible)
            return (c, HUDPlacement.alignment(forCentre: c, visible: visible))
        }
        return (HUDPlacement.centre(for: preset, visible: visible, full: full), preset.column)
    }

    private func save() {
        defaults.set(preset.rawValue, forKey: Self.presetKey)
        defaults.set(try? JSONEncoder().encode(custom), forKey: Self.customKey)
    }
}
