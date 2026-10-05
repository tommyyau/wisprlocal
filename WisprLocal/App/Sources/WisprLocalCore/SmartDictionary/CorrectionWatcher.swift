import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Reads a bounded window of the focused field of `pid` for correction watching (AX in the app,
/// fakes in tests). nil = unreadable (Electron, no AX, no focused text element). Called OFF the
/// main actor, so a hung target app can't stall the hotkey path (P1).
public protocol FocusedFieldReading: Sendable {
    func read(pid: Int32, window: FieldWindow) -> FieldSnapshot?
}

/// What the pipeline reports after a successful paste (in memory only).
public struct InsertedDictation: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    public var elementID: Int?
    public var text: String
    /// The caret context was readable through AX at insertion (false: Electron & co.).
    public var axReadable: Bool
    /// The selection the paste replaced ("" = none, nil = unknown): lets the watcher tell the
    /// user's own ⌘Z from a correction (R9).
    public var replaced: String?
    public init(pid: Int32, bundleID: String?, elementID: Int?, text: String, axReadable: Bool, replaced: String? = nil) {
        self.pid = pid; self.bundleID = bundleID; self.elementID = elementID; self.text = text; self.axReadable = axReadable
        self.replaced = replaced
    }
}

/// Polls the same focused element every second for up to 15 s after a paste and reports the
/// first stable correction. One watch at a time: a new dictation replaces the previous watch.
/// Never watches an app the shared `AppReadPolicy` excludes (password managers, Keychain,
/// banking/finance apps, the user's "Never read" list); the reader skips secure and URL fields.
/// Nothing it reads is logged or stored.
@MainActor public final class CorrectionWatcher {
    private let reader: FocusedFieldReading
    private let clock: PipelineClock
    private let policy: AppReadPolicy
    private let lexicon: EnglishLexicon
    private var task: Task<Void, Never>?
    private var generation = 0
    public private(set) var isWatching = false

    public init(reader: FocusedFieldReading = AXFocusedFieldReader(), clock: PipelineClock = SystemPipelineClock(),
                policy: AppReadPolicy = .defaults, lexicon: EnglishLexicon = SystemEnglishLexicon.shared) {
        self.reader = reader; self.clock = clock; self.policy = policy; self.lexicon = lexicon
    }

    public func watch(_ d: InsertedDictation, onFound: @escaping @MainActor (Correction) -> Void) {
        cancel()
        guard d.axReadable else { return }   // Electron / unreadable: History "Fix a Word…" instead
        guard !policy.isExcluded(bundleID: d.bundleID, pid: d.pid) else { return }   // S1: same list as context names
        isWatching = true
        generation &+= 1
        let gen = generation
        let reader = self.reader, clock = self.clock, lexicon = self.lexicon
        task = Task { @MainActor [weak self] in
            var session = CorrectionWatchSession(inserted: d.text, elementID: d.elementID, replaced: d.replaced, lexicon: lexicon)
            let start = clock.now
            while !Task.isCancelled {
                try? await clock.sleep(until: clock.now + CorrectionWatchSession.pollInterval)
                guard !Task.isCancelled else { break }
                let snap = await Self.read(reader, pid: d.pid, window: session.window)
                guard !Task.isCancelled else { break }
                let elapsed = clock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                switch session.observe(snap, elapsed: seconds) {
                case .keepWatching: continue
                case .stop: break
                case .found(let c): onFound(c)
                }
                break
            }
            if let self, self.generation == gen { self.isWatching = false }
        }
    }

    /// The AX read, on `AXQueue` (the one off-main-actor AX executor) rather than the main actor.
    private static func read(_ reader: FocusedFieldReading, pid: Int32, window: FieldWindow) async -> FieldSnapshot? {
        await AXQueue.run { reader.read(pid: pid, window: window) }
    }

    /// Waits for the current watch (if any) to end. Test hook: deterministic, no polling.
    public func waitUntilFinished() async { await task?.value }

    public func cancel() {
        task?.cancel(); task = nil
        isWatching = false
    }
}

/// AX reader for watching. Reads ONLY the requested window (`kAXStringForRangeParameterizedAttribute`);
/// the whole value only when the field is no longer than that window. Secure text fields and
/// Secure Event Input report `isSecure`, address/URL bars `isExcluded` (the session stops at once,
/// nothing is read). Each AX message times out after 50 ms. Thread-safe: no mutable state.
public final class AXFocusedFieldReader: FocusedFieldReading {
    public let timeout: Float
    public init(timeout: Float = 0.05) { self.timeout = timeout }

    public func read(pid: Int32, window: FieldWindow) -> FieldSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let el = element(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(el, timeout)
        let id = Int(bitPattern: UInt(CFHash(el)))
        if IsSecureEventInputEnabled() || string(el, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            return FieldSnapshot(elementID: id, text: "", isSecure: true)
        }
        if ContextPolicy.isURLField(identifier: string(el, kAXIdentifierAttribute), description: string(el, kAXDescriptionAttribute), value: nil) {
            return FieldSnapshot(elementID: id, text: "", isExcluded: true)
        }
        var countRef: CFTypeRef?, rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let count = countRef as? Int, count >= 0 else { return nil }
        var sel = CFRange(location: count, length: 0)
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            _ = AXValueGetValue(rangeRef as! AXValue, .cfRange, &sel)
        }
        let r = Self.range(window, count: count, caret: sel.location + sel.length)
        guard r.length <= CorrectionWatchSession.maxChars, sel.length <= CorrectionWatchSession.maxChars else {
            return FieldSnapshot(elementID: id, text: "", selectionLength: max(sel.length, r.length))
        }
        var want = CFRange(location: r.location, length: r.length)
        if let axRange = AXValueCreate(.cfRange, &want) {
            var strRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, axRange, &strRef) == .success,
               let s = strRef as? String {
                return FieldSnapshot(elementID: id, text: s, selectionLength: sel.length, windowLocation: r.location, totalLength: count)
            }
        }
        // No range reads: the whole value, but only when the window IS the whole field.
        guard r.location == 0, r.length == count, let value = string(el, kAXValueAttribute) else { return nil }
        return FieldSnapshot(elementID: id, text: value, selectionLength: sel.length, windowLocation: 0, totalLength: count)
    }

    /// The UTF-16 range to read for `window`, clamped to the field.
    static func range(_ window: FieldWindow, count: Int, caret: Int) -> (location: Int, length: Int) {
        switch window {
        case .aroundCaret(let before, let after):
            let c = min(max(0, caret), count)
            let lo = max(0, c - before), hi = min(count, c + after)
            return (lo, hi - lo)
        case .tracking(let location, let length, let baseTotal):
            let lo = min(max(0, location), count)
            let hi = min(count, lo + max(0, length + (count - baseTotal)))
            return (lo, max(0, hi - lo))
        }
    }

    private func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func string(_ e: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
