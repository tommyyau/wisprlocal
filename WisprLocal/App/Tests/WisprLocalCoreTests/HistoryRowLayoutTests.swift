import Testing
import Foundation
@testable import WisprLocalCore

/// History / Home rows: the text column never runs under the trailing action buttons, the buttons
/// keep a 28 pt hit target, and the row source keeps the structural guarantees (no selectable row
/// text, actions as an HStack sibling not an overlay, pointing-hand cursor, tooltips).
struct HistoryRowLayoutTests {
    // Matches DictationRow: Theme.Space.m = 16, timeWidth = 64, Theme.Space.s = 12.
    let padding = 16.0, timeWidth = 64.0, spacing = 12.0

    @Test func actionAreaFitsThreeComfortableTargets() {
        #expect(HistoryRowLayout.actionHitSize >= 28)
        #expect(HistoryRowLayout.actionCount(retainsContent: true) == 3)
        #expect(HistoryRowLayout.actionCount(retainsContent: false) == 1)
        let threeButtons: Double = 3 * 28 + 2 * 2 + 2 * 3   // typed: Swift 6.3 times out on the inline literal form
        #expect(HistoryRowLayout.actionAreaWidth(buttons: 3) == threeButtons)
        #expect(HistoryRowLayout.actionAreaWidth(buttons: 0) == 0)
    }

    @Test(arguments: [120.0, 200.0, 360.0, 520.0, 760.0, 1400.0])
    func textNeverOverlapsActions(width: Double) {
        for buttons in [1, 3] {
            let f = HistoryRowLayout.frames(width: width, padding: padding, timeWidth: timeWidth, spacing: spacing, buttons: buttons)
            #expect(f.text.upperBound <= f.actions.lowerBound, "text runs under actions at width \(width)")
            #expect(f.time.upperBound <= f.text.lowerBound)
            #expect(f.actions.upperBound - f.actions.lowerBound <= HistoryRowLayout.actionAreaWidth(buttons: buttons) + 1e-9)
        }
    }

    @Test func textTakesTheRemainingWidthAtNormalSizes() {
        let f = HistoryRowLayout.frames(width: 760, padding: padding, timeWidth: timeWidth, spacing: spacing, buttons: 3)
        #expect(f.actions.upperBound == 744)
        #expect(f.actions.lowerBound == 744 - HistoryRowLayout.actionAreaWidth(buttons: 3))
        #expect(f.text.lowerBound == 92)
        #expect(f.text.upperBound == f.actions.lowerBound - spacing)
    }

    /// Structural guard on the SwiftUI row (the app target isn't importable from tests).
    @Test func rowSourceKeepsHitTestingGuarantees() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/WisprLocal/DictationRow.swift"), encoding: .utf8)
        let code = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        #expect(!code.contains(".textSelection(.enabled)"), "row text must not be selectable (I-beam steals hits)")
        #expect(!code.contains(".overlay(alignment: .topTrailing) { actions"), "actions must not float over the text")
        #expect(code.contains("HistoryRowLayout.actionAreaWidth"))
        #expect(code.contains(".layoutPriority(1)"))
        #expect(code.contains(".pointerStyle(.link)"))
        #expect(code.contains(".help(\"More\")"))
        #expect(code.contains("focused"), "actions must also show on keyboard focus")
        let detail = try String(contentsOf: root.appendingPathComponent("Sources/WisprLocal/HistoryDetailView.swift"), encoding: .utf8)
        #expect(detail.contains(".textSelection(.enabled)"), "selection stays in the details sheet")
    }
    @Test func rowIdentitySurvivesAppendAndGroupPositionChanges() {
        let old = HistoryEntry(final: "Old", outcome: .inserted)
        let new = HistoryEntry(final: "New", outcome: .inserted)
        let before = HistoryRows(groups: [(title: "Yesterday", entries: [old])])
        let sameDay = HistoryRows(groups: [(title: "Yesterday", entries: [new, old])])
        let newDay = HistoryRows(groups: [(title: "Today", entries: [new]), (title: "Yesterday", entries: [old])])
        #expect(before[1].id == old.id.uuidString)
        #expect(sameDay[2].id == before[1].id)
        #expect(newDay[3].id == before[1].id)
        #expect(before[1].first && before[1].last)
        #expect(!sameDay[2].first && sameDay[2].last)
        #expect(newDay[3].first && newDay[3].last)
    }

}
