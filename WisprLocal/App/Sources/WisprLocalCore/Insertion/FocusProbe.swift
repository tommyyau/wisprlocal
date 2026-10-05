import ApplicationServices
import Foundation

/// Accessibility work for the hotkey / insert path runs on this serial queue, never on the main
/// actor: an unresponsive target app (each AX message may wait for its timeout) can then never
/// stall hotkey handling, Esc, or the HUD.
public enum AXQueue {
    static let queue = DispatchQueue(label: "WisprLocal.ax", qos: .userInitiated)

    public static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { k in queue.async { k.resume(returning: body()) } }
    }
}

/// An opaque CF identity compared with `CFEqual` (an `AXUIElement` in the app; any CF object in
/// tests). Hash values are NOT identities: two different elements may share a `CFHash`.
public struct AXIdentity: @unchecked Sendable, Equatable {
    public let ref: CFTypeRef
    public init(_ ref: CFTypeRef) { self.ref = ref }
    public static func == (a: AXIdentity, b: AXIdentity) -> Bool { CFEqual(a.ref, b.ref) }
}

/// The focused element of an app, its window, and (when asked) the text right before the caret.
public struct FocusSnapshot: Sendable, Equatable {
    public var element: AXIdentity
    public var window: AXIdentity?
    /// Text immediately before the caret (nil = not asked for, or unreadable).
    public var preceding: String?
    public init(element: AXIdentity, window: AXIdentity?, preceding: String? = nil) {
        self.element = element; self.window = window; self.preceding = preceding
    }

    /// The SAME focused element in the SAME window (`CFEqual` on both).
    public func isSameFocus(as other: FocusSnapshot) -> Bool { element == other.element && window == other.window }
}

/// Reads the focus of `pid` (AX in the app, fakes in tests). nil = no AX permission, nothing
/// focused, or the app did not answer in time. `precedingChars` > 0 also reads that many
/// characters before the caret.
@MainActor public protocol FocusProbing: AnyObject {
    func snapshot(pid: Int32, precedingChars: Int) async -> FocusSnapshot?
}

/// AX implementation; every message times out after `timeout` and the read runs on `AXQueue`.
@MainActor public final class AXFocusProbe: FocusProbing {
    public var timeout: Float = 0.05
    public init() {}

    public func snapshot(pid: Int32, precedingChars: Int) async -> FocusSnapshot? {
        let timeout = self.timeout
        return await AXQueue.run { Self.read(pid: pid, precedingChars: precedingChars, timeout: timeout) }
    }

    nonisolated static func read(pid: Int32, precedingChars: Int, timeout: Float) -> FocusSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, timeout)
        var windowRef: CFTypeRef?
        var window: AXIdentity?
        if AXUIElementCopyAttributeValue(focused, kAXWindowAttribute as CFString, &windowRef) == .success,
           let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
            window = AXIdentity(windowRef)
        }
        var snap = FocusSnapshot(element: AXIdentity(focused), window: window)
        guard precedingChars > 0 else { return snap }
        snap.preceding = AXCaretContextReader.textBeforeCaret(focused, maxChars: precedingChars)
        return snap
    }
}
