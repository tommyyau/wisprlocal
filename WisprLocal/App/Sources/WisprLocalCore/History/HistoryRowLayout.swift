import Foundation

/// Geometry of one History / Home dictation row, kept here so tests can prove the text column
/// never runs under the hover actions (the bug where the trailing ▷ / copy / ••• sat in an overlay
/// above selectable text, so the text's I-beam cursor and hit-testing won over the buttons).
///
/// Row, left to right: padding | time column | gap | text (flexible) | gap | actions (fixed) | padding.
public enum HistoryRowLayout {
    /// Every action button's hit target (points, square).
    public static let actionHitSize: Double = 28
    /// Space between action buttons.
    public static let actionSpacing: Double = 2
    /// Horizontal inset of the actions capsule around its buttons.
    public static let actionCapsuleInset: Double = 3

    /// ▷ play and copy only appear on rows that kept their text; ••• is always there.
    public static func actionCount(retainsContent: Bool) -> Int { retainsContent ? 3 : 1 }

    /// Fixed width reserved for the trailing action area.
    public static func actionAreaWidth(buttons: Int) -> Double {
        guard buttons > 0 else { return 0 }
        let n = Double(buttons)
        return n * actionHitSize + (n - 1) * actionSpacing + 2 * actionCapsuleInset
    }

    public struct Frames: Equatable, Sendable {
        public var time: ClosedRange<Double>
        public var text: ClosedRange<Double>
        public var actions: ClosedRange<Double>
    }

    /// Horizontal extents for a row `width` wide. The text gets whatever is left (never negative)
    /// and always ends `spacing` before the actions start.
    public static func frames(width: Double, padding: Double, timeWidth: Double, spacing: Double, buttons: Int) -> Frames {
        let timeStart = padding
        let timeEnd = timeStart + timeWidth
        let actionsEnd = max(width - padding, timeEnd + spacing)
        let actionsStart = actionsEnd - actionAreaWidth(buttons: buttons)
        let textStart = timeEnd + spacing
        let textEnd = max(textStart, actionsStart - spacing)
        return Frames(time: timeStart...timeEnd, text: textStart...textEnd, actions: max(actionsStart, textEnd)...actionsEnd)
    }
}
