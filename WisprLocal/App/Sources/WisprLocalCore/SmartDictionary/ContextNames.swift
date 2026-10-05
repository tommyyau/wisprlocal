import AppKit
import ApplicationServices
import Foundation

/// A proper noun or identifier seen near the cursor at recording start. IN MEMORY ONLY: it lives
/// in one `ContextSnapshot` for one dictation and is never logged, stored or written to History
/// (History records `contextSnaps`, a count).
public struct ContextCandidate: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Capitalised word or acronym ("Shaun", "NASA").
        case name
        /// CamelCase / snake_case ("getUserById", "user_id"): code apps only.
        case identifier
        /// "@sam_lee": matched only after a spoken "at".
        case handle
    }
    public var surface: String
    public var kind: Kind
    public init(_ surface: String, kind: Kind) { self.surface = surface; self.kind = kind }
}

/// What one dictation may snap to. Built at recording start, dropped when the dictation ends.
public struct ContextSnapshot: Sendable, Equatable {
    public var candidates: [ContextCandidate]
    /// The target is a code editor or terminal: identifiers may be snapped.
    public var isCodeApp: Bool
    public init(candidates: [ContextCandidate], isCodeApp: Bool) { self.candidates = candidates; self.isCodeApp = isCodeApp }
}

/// The raw text the reader saw. Transient: `ContextProvider` turns it into candidates at once
/// and lets it go; it is never stored.
public struct ContextSource: Sendable, Equatable {
    public var fieldText: String?
    public var windowTitle: String?
    /// Mail / Outlook To, From and Cc names, when exposed through Accessibility.
    public var mailNames: [String]
    public init(fieldText: String? = nil, windowTitle: String? = nil, mailNames: [String] = []) {
        self.fieldText = fieldText; self.windowTitle = windowTitle; self.mailNames = mailNames
    }
}

/// Pulls candidate names and identifiers out of text (deterministic, no model).
public enum ContextExtractor {
    public static let maxCandidates = 400

    public static func candidates(from texts: [String], limit: Int = maxCandidates) -> [ContextCandidate] {
        var out: [ContextCandidate] = []
        var seen = Set<String>()
        for text in texts {
            for raw in tokens(text) {
                guard let c = classify(raw), seen.insert(c.surface).inserted else { continue }
                out.append(c)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "@" || $0 == "'" || $0 == "\u{2019}") })
            .map(String.init)
    }

    static func classify(_ token: String) -> ContextCandidate? {
        var t = token
        // Possessives and stray quotes: "Shaun's" → "Shaun".
        for suffix in ["'s", "\u{2019}s"] where t.hasSuffix(suffix) { t.removeLast(2) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}_"))
        guard t.count >= 2, t.count <= 64, t.first.map({ $0.isLetter || $0 == "@" }) == true else { return nil }
        if t.hasPrefix("@") {
            let body = t.dropFirst()
            guard body.count >= 2, body.first?.isLetter == true, body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
            return ContextCandidate(t, kind: .handle)
        }
        guard !t.contains("@"), !t.contains("'"), !t.contains("\u{2019}") else { return nil }
        if t.contains("_") {
            let parts = t.split(separator: "_")
            guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } }) else { return nil }
            return ContextCandidate(t, kind: .identifier)
        }
        guard t.allSatisfy({ $0.isLetter || $0.isNumber }), t.first!.isLetter else { return nil }
        let letters = Array(t)
        let upperInside = letters.dropFirst().contains(where: \.isUppercase)
        let lowerInside = letters.contains(where: \.isLowercase)
        if upperInside && lowerInside {
            return ContextCandidate(t, kind: .identifier)                  // getUserById, HistoryStore, iPhone
        }
        if letters[0].isUppercase {
            if !lowerInside {                                               // acronym
                guard (2...8).contains(t.count), t.allSatisfy(\.isLetter) else { return nil }
                return ContextCandidate(t, kind: .name)
            }
            guard !CommonWords.contains(t) else { return nil }              // "There", "Hello" at a sentence start
            return ContextCandidate(t, kind: .name)
        }
        return nil
    }
}

/// What may and may not be read for context names. The ⓘ copy (`InfoTopic.contextNames`) states
/// exactly this.
public enum ContextPolicy {
    /// Characters read on each side of the caret.
    public static let radius = 2_000

    /// Password managers and Keychain Access. Editable in Settings; finance apps are excluded
    /// separately (by App Store category) and always.
    public static let defaultDenylist: [String] = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "com.dashlane.Dashlane", "org.keepassxc.keepassxc", "in.sinew.Enpass-Desktop", "com.nordpass.macos.NordPass",
        "com.callpod.keepermac.lite",
    ]

    /// Banking and other money apps declare this App Store category.
    public static let financeCategory = "public.app-category.finance"

    public static let mailBundleIDs: Set<String> = ["com.apple.mail", "com.microsoft.Outlook"]

    /// Code editors and terminals: identifiers (CamelCase / snake_case) may be snapped here only.
    public static let codeAppBundleIDs: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.sublimetext.4", "com.barebones.bbedit", "com.panic.Nova", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.exafunction.windsurf", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm",
        "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.rider", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
    ]

    public static func isCodeApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return codeAppBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    /// Never read this app at all.
    public static func isDenied(bundleID: String?, appCategory: String?, denylist: [String]) -> Bool {
        if appCategory == financeCategory { return true }
        guard let bundleID else { return false }
        return denylist.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Address / URL bars: never read.
    public static func isURLField(identifier: String?, description: String?, value: String?) -> Bool {
        let labels = [identifier, description].compactMap { $0?.lowercased() }
        if labels.contains(where: { $0.contains("address") || $0.contains("url") || $0.contains("location") }) { return true }
        if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.contains(" "), v.contains("://") || v.hasPrefix("www.") {
            return true
        }
        return false
    }
}

/// ONE exclusion policy for every read of another app's text — context names at recording start
/// AND the correction watcher after a paste (S1). An excluded app is never read at all: the
/// password managers and Keychain Access in the user's editable "Never read" list
/// (`SmartDictionarySettings.contextDenylist`), and every finance-category (banking) app.
/// Secure fields and address/URL bars are refused by the readers themselves.
@MainActor public struct AppReadPolicy {
    public let denylist: @MainActor () -> [String]
    public let appCategory: @MainActor (Int32) -> String?

    public init(denylist: @escaping @MainActor () -> [String],
                appCategory: @escaping @MainActor (Int32) -> String? = ContextProvider.systemAppCategory) {
        self.denylist = denylist; self.appCategory = appCategory
    }

    /// The built-in list, for callers without settings.
    public static var defaults: AppReadPolicy { AppReadPolicy(denylist: { ContextPolicy.defaultDenylist }) }

    public func isExcluded(bundleID: String?, pid: Int32) -> Bool {
        ContextPolicy.isDenied(bundleID: bundleID, appCategory: appCategory(pid), denylist: denylist())
    }
}

/// Reads the raw context of the frontmost app (AX in the app, fakes in tests). Implementations
/// MUST return nil for a secure (password) field and must not read URL fields. Called OFF the
/// main actor (`ContextProvider`), so a hung target app can't stall the hotkey path (P1).
public protocol ContextReading: Sendable {
    func read(pid: Int32, bundleID: String?, includeMailNames: Bool) -> ContextSource?
}

/// What the pipeline asks at recording start.
@MainActor public protocol ContextProviding: AnyObject {
    /// nil = feature off, app excluded, secure input, or nothing readable.
    func snapshot(for target: FrontmostApp) async -> ContextSnapshot?
}

/// The gatekeeper in front of the reader: the opt-in switch, Secure Event Input, the denylist
/// and finance apps are checked BEFORE anything is read. Raw text becomes candidates here and is
/// dropped on return.
@MainActor public final class ContextProvider: ContextProviding {
    private let settings: SmartDictionarySettings
    private let reader: ContextReading
    private let secureInput: SecureInputChecking
    /// The exclusion policy, shared with the correction watcher (`SmartDictionaryController`).
    public let readPolicy: AppReadPolicy

    public init(settings: SmartDictionarySettings, reader: ContextReading = AXContextReader(),
                secureInput: SecureInputChecking = SystemSecureInput(),
                appCategory: @escaping @MainActor (Int32) -> String? = ContextProvider.systemAppCategory) {
        self.settings = settings; self.reader = reader; self.secureInput = secureInput
        readPolicy = AppReadPolicy(denylist: { settings.contextDenylist }, appCategory: appCategory)
    }

    public func snapshot(for target: FrontmostApp) async -> ContextSnapshot? {
        guard settings.contextNamesEnabled, !secureInput.isSecureInputActive else { return nil }
        guard !readPolicy.isExcluded(bundleID: target.bundleID, pid: target.pid) else { return nil }
        let includeMail = target.bundleID.map(ContextPolicy.mailBundleIDs.contains) ?? false
        guard let src = await Self.read(reader, target: target, includeMail: includeMail) else { return nil }
        let texts = [src.fieldText, src.windowTitle].compactMap { $0 } + src.mailNames
        let candidates = ContextExtractor.candidates(from: texts)
        guard !candidates.isEmpty else { return nil }
        return ContextSnapshot(candidates: candidates, isCodeApp: ContextPolicy.isCodeApp(target.bundleID))
    }

    /// The AX read, on `AXQueue` (the one off-main-actor AX executor) rather than the main actor (P1).
    private static func read(_ reader: ContextReading, target: FrontmostApp, includeMail: Bool) async -> ContextSource? {
        await AXQueue.run { reader.read(pid: target.pid, bundleID: target.bundleID, includeMailNames: includeMail) }
    }

    /// `LSApplicationCategoryType` of the running app (nil when unknown).
    public static func systemAppCategory(_ pid: Int32) -> String? {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
    }
}

/// Accessibility reader with a hard time budget (each AX message ≤ 50 ms, the whole read
/// ≤ 150 ms). Secure text fields abort the read; URL fields are skipped. Thread-safe: no
/// mutable state (it runs off the main actor).
public final class AXContextReader: ContextReading {
    public let timeout: Float
    public let budget: Duration
    /// Injectable AX operations let read() privacy boundaries be tested without live TCC.
    struct Access: Sendable {
        var trusted: @Sendable () -> Bool
        var element: @Sendable (AXUIElement, String) -> AXUIElement?
        var string: @Sendable (AXUIElement, String) -> String?
        var text: @Sendable (AXUIElement) -> String?
    }
    private let access: Access?
    init(access: Access) { self.access = access; timeout = 0.05; budget = .milliseconds(150) }
    public init(timeout: Float = 0.05, budget: Duration = .milliseconds(150)) { self.timeout = timeout; self.budget = budget; access = nil }

    public func read(pid: Int32, bundleID: String?, includeMailNames: Bool) -> ContextSource? {
        guard access?.trusted() ?? AXIsProcessTrusted() else { return nil }
        let deadline = ContinuousClock.now + budget
        func over() -> Bool { ContinuousClock.now >= deadline }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var src = ContextSource()

        if let focused = element(app, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, timeout)
            if string(focused, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return nil }  // never
            let ident = string(focused, kAXIdentifierAttribute)
            let desc = string(focused, kAXDescriptionAttribute)
            guard !ContextPolicy.isURLField(identifier: ident, description: desc, value: nil) else { return nil }
            if !over() { src.fieldText = Self.readAllowedField(identifier: ident, description: desc) { textNearCaret(focused) } }
        }
        if !over(), let window = element(app, kAXFocusedWindowAttribute) {
            AXUIElementSetMessagingTimeout(window, timeout)
            src.windowTitle = string(window, kAXTitleAttribute)
            if includeMailNames, !over() { src.mailNames = mailNames(in: window, deadline: deadline) }
        }
        return src
    }

    /// Check metadata before invoking any AX text read (also exercised with fake fields).
    static func readAllowedField(identifier: String?, description: String?, readText: () -> String?) -> String? {
        guard !ContextPolicy.isURLField(identifier: identifier, description: description, value: nil) else { return nil }
        guard let text = readText(),
              !ContextPolicy.isURLField(identifier: nil, description: nil, value: text) else { return nil }
        return text
    }

    private func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        if let access { return access.element(e, attr) }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func string(_ e: AXUIElement, _ attr: String) -> String? {
        if let access { return access.string(e, attr) }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// ±`ContextPolicy.radius` characters around the caret (UTF-16 ranges, as AX uses).
    private func textNearCaret(_ e: AXUIElement) -> String? {
        if let access { return access.text(e) }
        var countRef: CFTypeRef?, rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let count = countRef as? Int, count > 0,
              AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &sel) else { return nil }
        let start = max(0, sel.location - ContextPolicy.radius)
        let end = min(count, sel.location + ContextPolicy.radius)
        guard end > start else { return nil }
        var want = CFRange(location: start, length: end - start)
        guard let axRange = AXValueCreate(.cfRange, &want) else { return nil }
        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString,
                                                         axRange, &strRef) == .success else { return nil }
        return strRef as? String
    }

    /// Best effort: values of elements labelled To / From / Cc in the focused Mail / Outlook
    /// window (breadth-first, ≤ 300 elements, within the read budget).
    private func mailNames(in window: AXUIElement, deadline: ContinuousClock.Instant) -> [String] {
        let labels: Set<String> = ["to", "to:", "from", "from:", "cc", "cc:"]
        var queue: [AXUIElement] = [window]
        var visited = 0
        var out: [String] = []
        while !queue.isEmpty, visited < 300, ContinuousClock.now < deadline {
            let e = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(e, timeout)
            let label = (string(e, kAXDescriptionAttribute) ?? string(e, kAXTitleAttribute) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if labels.contains(label) {
                if let v = string(e, kAXValueAttribute), !v.isEmpty { out.append(v) }
                for child in children(e) {
                    if let v = string(child, kAXValueAttribute) ?? string(child, kAXTitleAttribute), !v.isEmpty { out.append(v) }
                }
                continue
            }
            if string(e, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { continue }
            queue.append(contentsOf: children(e))
        }
        return out
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }
}
