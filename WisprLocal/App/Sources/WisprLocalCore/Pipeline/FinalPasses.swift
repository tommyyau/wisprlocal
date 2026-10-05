import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The last deterministic passes on the cleaned English text, in order:
/// 1. backtrack (`Backtrack`, opt-in), 2. the per-app style (`WritingStyle`).
/// Never runs on snippets or non-English text (the pipeline skips it there). Pure.
public enum FinalPasses {
    public struct Result: Equatable, Sendable {
        /// Text to insert.
        public var text: String
        /// The same text WITHOUT the backtrack (style still applied) when a correction was made:
        /// what Undo puts back. nil when no correction was applied.
        public var uncorrected: String?
        public var style: WritingStyle?
    }

    public static func apply(_ text: String, style: WritingStyle?, backtrack: Bool, vocabulary: [String],
                             names: NameRecognizing) -> Result {
        func styled(_ s: String) -> String { style?.apply(s, vocabulary: vocabulary, names: names) ?? s }
        var uncorrected: String?
        var t = text
        if backtrack {
            let b = Backtrack.apply(text)
            if b.applied { t = b.text; uncorrected = styled(text) }
        }
        return Result(text: styled(t), uncorrected: uncorrected, style: style)
    }
}

/// A backtrack that was just inserted and can still be undone from the HUD.
public struct PendingCorrection: Sendable, Equatable {
    /// The app it went into.
    public var pid: Int32
    /// What was inserted (corrected, joined).
    public var inserted: String
    /// What Undo inserts instead (the words as spoken, same style and join).
    public var original: String
    public var at: Date
    /// The words as spoken without the join (what "Copy original" puts on the clipboard).
    public var spoken: String
    /// The focused element right after the insertion, read through AX, whose text before the
    /// caret ended with `inserted`. nil = not verifiable: no ⌘Z, only "Copy original" (R5).
    public var focus: FocusSnapshot?
    /// ⌘Z may be offered (`UndoPolicy`); false = "Copy original" only.
    public var undoable: Bool { focus != nil }

    public init(pid: Int32, inserted: String, original: String, at: Date, spoken: String? = nil,
                focus: FocusSnapshot? = nil) {
        self.pid = pid; self.inserted = inserted; self.original = original; self.at = at
        self.spoken = spoken ?? original; self.focus = focus
    }

    /// The HUD offers Undo for the standard chip time with a button (`HUDChipPolicy`, 8 s).
    public static let hudSeconds: Double = HUDChipPolicy.secondsWithButtons
    /// How long Undo still works: the chip's 8 s, plus room for it to have waited behind an
    /// alert chip with a button (8 s, `HUDChipQueue`) and a click that lands a moment late.
    public static let window: TimeInterval = 20
}

extension PipelineNotice {
    /// Backtrack applied: the HUD chip "Corrected" with an Undo button (8 s, `HUDChipPolicy`).
    public static let corrected = "Corrected"
    /// Backtrack applied where ⌘Z can't be proven safe: a "Copy original" button instead of Undo.
    public static let correctedCopyOnly = "Corrected · can't undo here"
    /// "Copy original" clicked: the words as spoken are on the clipboard.
    public static let originalCopied = "Original copied · ⌘V to paste"
    /// Undo clicked, but the field no longer ends with our text (edited, or another field): the
    /// original goes to the clipboard instead of a ⌘Z.
    public static let undoNotSafe = "Text changed · original copied"
}

/// When Undo (⌘Z + re-paste) may be offered and sent (R5, R6, R14). STRUCTURAL: the pipeline asks
/// only this.
public enum UndoPolicy {
    /// Terminals: ⌘Z is a no-op (Terminal, Ghostty) or a different command (iTerm2 "Undo Close
    /// Session", Warp). Never offered there.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
    ]

    /// - `pasteVerified` / `pasteRetried`: the paste's report (nil verified = unverifiable). An
    ///   unverified or retried paste is never undone: ⌘Z could remove the wrong thing.
    /// - `axVerified`: right after the paste, AX showed the SAME focused element with our text
    ///   ending at the caret. Required everywhere, and in particular in the Code category.
    public static func mayOfferUndo(bundleID: String?, pasteVerified: Bool?, pasteRetried: Bool,
                                    hasReport: Bool, axVerified: Bool) -> Bool {
        if let id = bundleID, terminalBundleIDs.contains(id) { return false }
        if hasReport, pasteVerified != true || pasteRetried { return false }
        return axVerified  // Code-category apps (editors) get Undo ONLY through this check
    }

    /// At click time: the same element (CFEqual, same window) and its text before the caret still
    /// ends with what we inserted. Anything else → no ⌘Z.
    public static func maySendUndo(inserted: String, atInsert: FocusSnapshot?, now: FocusSnapshot?) -> Bool {
        guard let atInsert, let now, now.isSameFocus(as: atInsert), let before = now.preceding else { return false }
        return !inserted.isEmpty && before.hasSuffix(inserted)
    }
}

/// The app's own Undo keystroke (Cmd + the key that types "z" on the current layout), posted
/// like our Cmd-V (`PasteKeystroke`: private source, exactly ⌘, marked synthetic).
public enum UndoKeystroke {
    @MainActor public static func post() throws {
        let key = KeyboardLayoutMap.layoutData().flatMap { KeyboardLayoutMap.keyCode(for: "z", layoutData: $0) }
            ?? CGKeyCode(kVK_ANSI_Z)
        try PasteKeystroke.post(key: key)
    }
}
