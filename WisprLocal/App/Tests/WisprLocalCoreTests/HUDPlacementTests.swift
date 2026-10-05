import Testing
import Foundation
import CoreGraphics
@testable import WisprLocalCore

@Suite struct HUDPlacementTests {
    // 1440×900 display, 25 pt menu bar on top, 70 pt Dock at the bottom.
    static let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)

    @Test func presetsSitInsideVisibleFrameWithMargin() {
        let pill = HUDPlacement.pillSize, m = HUDPlacement.margin
        for p in HUDPreset.allCases {
            let c = HUDPlacement.centre(for: p, visible: Self.visible, full: Self.full)
            #expect(c.x - pill.width / 2 >= Self.visible.minX + m - 0.5, "\(p)")
            #expect(c.x + pill.width / 2 <= Self.visible.maxX - m + 0.5, "\(p)")
            #expect(c.y - pill.height / 2 >= Self.visible.minY + m - 0.5, "\(p)")
            #expect(c.y + pill.height / 2 <= Self.visible.maxY - m + 0.5, "\(p)")
        }
        #expect(HUDPlacement.centre(for: .bottomCenter, visible: Self.visible, full: Self.full).x == 720)
        #expect(HUDPlacement.centre(for: .topRight, visible: Self.visible).x == 1350)
        #expect(HUDPlacement.centre(for: .topLeft, visible: Self.visible).y == 831)
    }

    @Test func bottomKeepsDockClearanceWhenDockIsHidden() {
        let visibleNoDock = CGRect(x: 0, y: 4, width: 1440, height: 871)
        let c = HUDPlacement.centre(for: .bottomCenter, visible: visibleNoDock, full: Self.full)
        #expect(c.y == HUDPlacement.dockClearance)
        // With a visible Dock, the margin above it already wins.
        #expect(HUDPlacement.centre(for: .bottomLeft, visible: Self.visible, full: Self.full).y == 114)
        #expect(HUDPlacement.centre(for: .bottomLeft, visible: CGRect(x: 0, y: 120, width: 1440, height: 755), full: Self.full).y == 164)
    }

    @Test func clampKeepsPillOnScreen() {
        let c = HUDPlacement.clamp(CGPoint(x: -500, y: 5000), visible: Self.visible)
        #expect(c == CGPoint(x: 24 + 66, y: 875 - 24 - 20))
        // Tiny screen: never inverts.
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 30)
        let t = HUDPlacement.clamp(CGPoint(x: 999, y: -999), visible: tiny)
        #expect(t == CGPoint(x: 50, y: 15))
    }

    @Test func relativeRoundTripSurvivesResolutionChange() {
        let p = CGPoint(x: 1100, y: 300)
        let r = HUDPlacement.relative(fromCentre: p, visible: Self.visible)
        #expect(HUDPlacement.centre(for: r, visible: Self.visible) == p)
        // Same display at a scaled resolution: same visual spot.
        let scaled = CGRect(x: 0, y: 105, width: 2160, height: 1207.5)
        let q = HUDPlacement.centre(for: r, visible: scaled)
        #expect(abs(q.x - 1650) <= 1)
        // A display arranged to the left (negative origin).
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let l = HUDPlacement.centre(for: HUDRelativePosition(x: 0.5, y: 0.5), visible: left)
        #expect(l == CGPoint(x: -960, y: 528))
    }

    @Test func snapsToEdgesAndCentreLines() {
        let b = HUDPlacement.bounds(visible: Self.visible)
        let near = HUDPlacement.snap(CGPoint(x: b.midX + 7, y: b.maxY - 9), visible: Self.visible)
        #expect(near.point == CGPoint(x: b.midX, y: b.maxY))
        #expect(near.snappedX && near.snappedY)
        let far = HUDPlacement.snap(CGPoint(x: b.midX + 40, y: 400), visible: Self.visible)
        #expect(!far.any)
        #expect(far.point == CGPoint(x: b.midX + 40, y: 400))
        // Dragged past the edge: clamped onto the edge line, which counts as snapped.
        let past = HUDPlacement.snap(CGPoint(x: 5000, y: 400), visible: Self.visible)
        #expect(past.point.x == b.maxX && past.snappedX)
    }

    @Test func alignmentAndWindowOrigin() {
        #expect(HUDPlacement.alignment(forCentre: CGPoint(x: 100, y: 0), visible: Self.visible) == .leading)
        #expect(HUDPlacement.alignment(forCentre: CGPoint(x: 720, y: 0), visible: Self.visible) == .center)
        #expect(HUDPlacement.alignment(forCentre: CGPoint(x: 1300, y: 0), visible: Self.visible) == .trailing)
        let w = CGSize(width: 640, height: 200)
        let c = CGPoint(x: 720, y: 110)
        #expect(HUDPlacement.windowOrigin(centre: c, alignment: .center, windowSize: w, pillCentreFromBottom: 100, sideInset: 20) == CGPoint(x: 400, y: 10))
        // Leading: the pill's left edge (centre − 66) sits 20 pt inside the window's left edge.
        #expect(HUDPlacement.windowOrigin(centre: c, alignment: .leading, windowSize: w, pillCentreFromBottom: 100, sideInset: 20).x == 634)
        #expect(HUDPlacement.windowOrigin(centre: c, alignment: .trailing, windowSize: w, pillCentreFromBottom: 100, sideInset: 20).x == 166)
    }

    @MainActor @Test func storePersistsPerDisplayAndFallsBackToPreset() {
        let suite = "hudplacement-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = HUDPlacementStore(defaults: d)
        #expect(s.preset == .bottomCenter)
        s.setCustom(HUDRelativePosition(x: 0.9, y: 1.4), display: "A")
        let reloaded = HUDPlacementStore(defaults: d)
        #expect(reloaded.custom["A"] == HUDRelativePosition(x: 0.9, y: 1.0))  // clamped to 0…1
        let onA = reloaded.placement(display: "A", visible: Self.visible, full: Self.full)
        #expect(onA.alignment == .trailing)
        #expect(onA.centre.y == 831)
        // Unknown / replaced display → the preset.
        let onB = reloaded.placement(display: "B", visible: Self.visible, full: Self.full)
        #expect(onB.centre == HUDPlacement.centre(for: .bottomCenter, visible: Self.visible, full: Self.full))
        #expect(reloaded.placement(display: nil, visible: Self.visible, full: Self.full).alignment == .center)
        // Picking a preset applies everywhere.
        reloaded.setPreset(.topLeft)
        #expect(!HUDPlacementStore(defaults: d).hasCustom)
        #expect(HUDPlacementStore(defaults: d).preset == .topLeft)
    }
}
