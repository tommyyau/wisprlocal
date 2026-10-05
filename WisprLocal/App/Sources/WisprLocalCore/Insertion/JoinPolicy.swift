import ApplicationServices
import Foundation

/// What we could learn about the text before the caret in the focused element.
public struct CaretContext: Sendable, Equatable {
    /// Text immediately before the caret (up to a few dozen chars). `""` = caret at the start /
    /// empty field. `nil` = unreadable (common in Electron apps: Claude desktop, Slack…).
    public var preceding: String?
    /// Identity of the focused element (CFHash of the AXUIElement), nil when unknown.
    public var elementID: Int?
    /// The selected text the paste will replace ("" = no selection, nil = unknown or longer than
    /// `AXCaretContextReader.maxSelection`). In memory only: the learning watcher uses it to
    /// recognise the user's own ⌘Z of a select-and-dictate (R9).
    public var selectedText: String?
    public init(preceding: String?, elementID: Int?, selectedText: String? = nil) {
        self.preceding = preceding; self.elementID = elementID; self.selectedText = selectedText
    }
    public static let unavailable = CaretContext(preceding: nil, elementID: nil)
}

/// Reads the caret context of the focused element of `pid` (AX in the app, fakes in tests).
@MainActor public protocol CaretContextReading: AnyObject {
    func read(pid: Int32, bundleID: String?) async -> CaretContext
}

/// Our previous insertion — the fallback when AX can't read the field.
public struct LastInsertion: Sendable, Equatable {
    public var pid: Int32
    public var elementID: Int?
    public var text: String
    public var at: Date
    public init(pid: Int32, elementID: Int?, text: String, at: Date) {
        self.pid = pid; self.elementID = elementID; self.text = text; self.at = at
    }
}

/// Pure smart-join policy: adjusts a dictation so it joins the text already before the caret
/// ("the" + "That was" → " that was"; "Go." + "Is there" → " Is there").
public enum JoinPolicy {
    /// Our last insertion counts as "previous context" for this long when AX is unreadable.
    public static let fallbackWindow: TimeInterval = 120

    /// Full decision: AX context when readable, else the same-app/same-element fallback.
    public static func adjust(_ text: String, context: CaretContext, pid: Int32?, last: LastInsertion?,
                              now: Date, vocabulary: [String] = []) -> String {
        if let preceding = context.preceding {
            return adjust(text, preceding: preceding, vocabulary: vocabulary)
        }
        // AX unavailable: only when we are clearly continuing our own previous insertion (same
        // app, same element, recent, not ended by whitespace/newline), treat that text as the
        // context: space always; mid-sentence lowercasing when it ended without . ! ?.
        guard let last, let pid, last.pid == pid, last.elementID == context.elementID,
              now.timeIntervalSince(last.at) >= 0, now.timeIntervalSince(last.at) <= fallbackWindow,
              let lastChar = last.text.last, !lastChar.isWhitespace, !lastChar.isNewline,
              startsWithWordChar(text) else { return text }
        return adjust(text, preceding: last.text, vocabulary: vocabulary)
    }

    /// CC-6: opening-context characters. A dictation right after one of these is joined with NO
    /// space: "@" + "sam" → "@sam", "(" + "this" → "(this", "$" + "5" → "$5",
    /// a URL ending in "/" + "path", "state-of-the-" + "art".
    public static let noSpaceAfter: Set<Character> = ["@", "(", "[", "{", "$", "#", "/", "\\",
                                                      "-", "_", "\u{201C}", "\u{2018}"]
    /// Ambiguous quote characters: openers only after whitespace / start / another opener,
    /// otherwise closing quotes or apostrophes ("dogs'" + "bone" → "dogs' bone").
    static let ambiguousQuotes: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}"]

    static func isOpener(_ preceding: String) -> Bool {
        guard let prev = preceding.last else { return false }
        if noSpaceAfter.contains(prev) { return true }
        guard ambiguousQuotes.contains(prev) else { return false }
        let before = preceding.dropLast()
        guard let b = before.last else { return true }
        return b.isWhitespace || noSpaceAfter.contains(b)
    }

    /// Readable context: `preceding` is the text before the caret ("" = empty field / start).
    public static func adjust(_ text: String, preceding: String, vocabulary: [String] = []) -> String {
        guard let prev = preceding.last, !prev.isNewline else { return text }   // empty / new line: as is
        guard startsWithWordChar(text) else { return text }                     // "\n", ",", quotes…
        guard !isOpener(preceding) else { return text }                          // "@", "(", "$"…: verbatim
        let lastNonSpace = preceding.last(where: { $0 != " " && $0 != "\t" && $0 != "\u{00A0}" })
        var out = text
        if let c = lastNonSpace, c.isLetter || c == "," {
            out = lowercasingFirstWord(out, vocabulary: vocabulary)
        }
        // Sentence end, mid-sentence or anything else: a word char after a non-space needs a space.
        if !prev.isWhitespace { out = " " + out }
        return out
    }

    static func startsWithWordChar(_ s: String) -> Bool {
        guard let f = s.first else { return false }
        return f.isLetter || f.isNumber
    }

    /// Lowercases the first word unless it is "I"/"I'm"…, an acronym, a dictionary term, or a
    /// likely proper noun (the same word also appears Capitalised mid-sentence in this text).
    static func lowercasingFirstWord(_ text: String, vocabulary: [String]) -> String {
        let word = String(text.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" || $0 == "-" }))
        guard let first = word.first, first.isUppercase else { return text }
        let core = String(word.prefix(while: { $0.isLetter || $0.isNumber }))
        if core == "I" { return text }                                           // I, I'm, I'll
        let letters = core.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return text } // API, NASA
        if core.dropFirst().contains(where: \.isUppercase) { return text }        // iPhone-ish / McDonald
        let terms = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if terms.contains(where: { $0 == core || $0 == word || text.hasPrefix($0 + " ") || text == $0 }) { return text }
        if appearsCapitalisedMidSentence(core, in: text) { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// True when `word` occurs Capitalised elsewhere in `text`, not at a sentence start.
    static func appearsCapitalisedMidSentence(_ word: String, in text: String) -> Bool {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count > 1 else { return false }
        for i in 1..<tokens.count {
            let prevTok = tokens[i - 1]
            if let e = prevTok.last, ".!?:\n".contains(e) { continue }
            let core = tokens[i].prefix(while: { $0.isLetter || $0.isNumber })
            if core == word { return true }
        }
        return false
    }
}

/// How much of the focused field the caret reader may read, decided BEFORE any text is read.
public enum CaretReadScope: Sendable, Equatable {
    /// Text before the caret (≤ `maxChars`) and the selection (≤ `maxSelection`).
    case full
    /// Address / URL bars: the single preceding character (spacing only), never the selection.
    case spacingOnly
    /// Secure (password) fields: nothing at all.
    case nothing
}

/// The Accessibility primitives the caret reader uses: the system in the app, a spy in tests.
/// Every call happens on `AXQueue` (off the main actor).
public protocol CaretAX: Sendable {
    func isTrusted() -> Bool
    func focusedElement(pid: Int32) -> AXIdentity?
    func attribute(_ element: AXIdentity, _ name: String) -> String?
    func selectedRange(_ element: AXIdentity) -> CFRange?
    func string(_ element: AXIdentity, in range: CFRange) -> String?
    func value(_ element: AXIdentity) -> String?
}

/// The real thing: each AX message times out after `timeout`.
public struct SystemCaretAX: CaretAX {
    public let timeout: Float
    public init(timeout: Float = 0.05) { self.timeout = timeout }

    private func element(_ e: AXIdentity) -> AXUIElement? {
        CFGetTypeID(e.ref) == AXUIElementGetTypeID() ? (e.ref as! AXUIElement) : nil
    }
    public func isTrusted() -> Bool { AXIsProcessTrusted() }
    public func focusedElement(pid: Int32) -> AXIdentity? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        AXUIElementSetMessagingTimeout(ref as! AXUIElement, timeout)
        return AXIdentity(ref)
    }
    public func attribute(_ e: AXIdentity, _ name: String) -> String? {
        guard let el = element(e) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
    public func selectedRange(_ e: AXIdentity) -> CFRange? {
        guard let el = element(e) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(ref as! AXValue, .cfRange, &r) ? r : nil
    }
    public func string(_ e: AXIdentity, in range: CFRange) -> String? {
        guard let el = element(e) else { return nil }
        var want = range
        var ref: CFTypeRef?
        guard let axRange = AXValueCreate(.cfRange, &want),
              AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString,
                                                         axRange, &ref) == .success else { return nil }
        return ref as? String
    }
    public func value(_ e: AXIdentity) -> String? { attribute(e, kAXValueAttribute) }
}

/// The caret read itself, pure over `CaretAX` (so a spy can prove what is and is NOT read).
/// Privacy order (S1): the app exclusion is decided by the caller before any AX at all; then the
/// field's subrole / identifier / description decide the `CaretReadScope` BEFORE any text,
/// selection or value is read.
public enum CaretRead {
    public static func scope(subrole: String?, identifier: String?, description: String?) -> CaretReadScope {
        if subrole == (kAXSecureTextFieldSubrole as String) { return .nothing }
        if ContextPolicy.isURLField(identifier: identifier, description: description, value: nil) { return .spacingOnly }
        return .full
    }

    public static func read(ax: CaretAX, pid: Int32, maxChars: Int, maxSelection: Int,
                            deadline: ContinuousClock.Instant?) -> CaretContext {
        func over() -> Bool { deadline.map { ContinuousClock.now >= $0 } ?? false }
        guard ax.isTrusted(), let focused = ax.focusedElement(pid: pid) else { return .unavailable }
        let id = Int(bitPattern: UInt(CFHash(focused.ref)))
        if over() { return CaretContext(preceding: nil, elementID: id) }
        switch scope(subrole: ax.attribute(focused, kAXSubroleAttribute),
                     identifier: ax.attribute(focused, kAXIdentifierAttribute),
                     description: ax.attribute(focused, kAXDescriptionAttribute)) {
        case .nothing:
            return CaretContext(preceding: nil, elementID: id)
        case .spacingOnly:
            return CaretContext(preceding: textBeforeCaret(ax: ax, focused, maxChars: 1, deadline: deadline,
                                                           valueFallback: false), elementID: id)
        case .full:
            break
        }
        guard !over(), let sel = ax.selectedRange(focused), sel.location >= 0 else {
            return CaretContext(preceding: nil, elementID: id)
        }
        var selected: String? = sel.length == 0 ? "" : nil
        if sel.length > 0, sel.length <= maxSelection, !over() { selected = ax.string(focused, in: sel) }
        let preceding = textBeforeCaret(ax: ax, focused, selection: sel, maxChars: maxChars, deadline: deadline)
        return CaretContext(preceding: preceding, elementID: id, selectedText: selected)
    }

    /// Up to `maxChars` characters before the caret; "" at the start of the field; nil when
    /// unreadable or past `deadline`. `valueFallback` slices the whole value (UTF-16 offsets, as
    /// AX ranges are) when the range read fails — never used for a restricted scope.
    public static func textBeforeCaret(ax: CaretAX, _ focused: AXIdentity, selection: CFRange? = nil, maxChars: Int,
                                       deadline: ContinuousClock.Instant? = nil, valueFallback: Bool = true) -> String? {
        func over() -> Bool { deadline.map { ContinuousClock.now >= $0 } ?? false }
        guard let sel = selection ?? ax.selectedRange(focused), sel.location >= 0 else { return nil }
        if sel.location == 0 { return "" }
        if over() { return nil }
        let len = min(maxChars, sel.location)
        if let s = ax.string(focused, in: CFRange(location: sel.location - len, length: len)), !s.isEmpty || len == 0 {
            return s
        }
        guard valueFallback, !over(), let value = ax.value(focused) else { return nil }
        let ns = value as NSString
        guard sel.location <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: sel.location - len, length: len))
    }
}

/// Reads the caret context through the Accessibility API. Each AX message times out after
/// `timeout` (50 ms) and the whole read stops issuing messages once `timeout` has elapsed, so an
/// unresponsive app can never stall insertion; any failure → `.unavailable` (fallback policy).
/// The read runs on `AXQueue`, OFF the main actor, and the pipeline starts it while ASR runs.
/// PRIVACY (S1): the shared `AppReadPolicy` is applied FIRST — an excluded app (password
/// managers, Keychain, banking/finance) gets no AX message at all and joins by the no-AX
/// fallback; secure fields read nothing; URL bars read one character (`CaretRead`).
@MainActor public final class AXCaretContextReader: CaretContextReading {
    public var maxChars = 64
    /// Longest selection kept for the learning watcher (longer → nil).
    public var maxSelection = 1_000
    /// Per-message AX timeout AND overall budget for one read (seconds).
    public var timeout: Float = 0.05
    private let policy: AppReadPolicy
    private let ax: (@Sendable (Float) -> CaretAX)
    public init(policy: AppReadPolicy = .defaults, ax: @escaping @Sendable (Float) -> CaretAX = { SystemCaretAX(timeout: $0) }) {
        self.policy = policy; self.ax = ax
    }

    public func read(pid: Int32, bundleID: String?) async -> CaretContext {
        guard !policy.isExcluded(bundleID: bundleID, pid: pid) else { return .unavailable }
        let maxChars = self.maxChars, maxSelection = self.maxSelection, timeout = self.timeout
        let ax = self.ax(timeout)
        return await AXQueue.run {
            CaretRead.read(ax: ax, pid: pid, maxChars: maxChars, maxSelection: maxSelection,
                           deadline: ContinuousClock.now + .milliseconds(Int(timeout * 1000)))
        }
    }

    /// For callers already holding the element (`AXFocusProbe`, on `AXQueue`).
    nonisolated static func textBeforeCaret(_ focused: AXUIElement, maxChars: Int,
                                            deadline: ContinuousClock.Instant? = nil) -> String? {
        CaretRead.textBeforeCaret(ax: SystemCaretAX(), AXIdentity(focused), maxChars: maxChars, deadline: deadline)
    }
}
