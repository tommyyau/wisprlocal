import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Resolves which virtual keycode produces a character on the CURRENT keyboard layout (via
/// UCKeyTranslate), so our synthesized Cmd-V is "Cmd + the key that types v" on Dvorak/AZERTY/etc.
/// Cached; invalidated on `kTISNotifySelectedKeyboardInputSourceChanged`.
public final class KeyboardLayoutMap: @unchecked Sendable {
    public static let shared = KeyboardLayoutMap()
    public static let fallbackV = CGKeyCode(kVK_ANSI_V)  // 9

    private let lock = NSLock()
    private var cachedV: CGKeyCode?
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: nil
        ) { [weak self] _ in self?.invalidate() }
    }

    public func invalidate() { lock.withLock { cachedV = nil } }

    /// Keycode for "v" on the current layout, or 9 if it can't be resolved.
    public var pasteKeyCode: CGKeyCode {
        lock.withLock {
            if let v = cachedV { return v }
            let v = Self.layoutData().flatMap { Self.keyCode(for: "v", layoutData: $0) } ?? Self.fallbackV
            cachedV = v
            return v
        }
    }

    /// Current layout's 'uchr' data; falls back to the ASCII-capable layout (IMEs such as
    /// Japanese/Chinese have none of their own).
    public static func layoutData() -> Data? {
        for src in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let source = src?.takeRetainedValue(),
                  let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        }
        return nil
    }

    /// Character produced by `keyCode` with no modifiers on `layoutData`.
    public static func character(for keyCode: CGKeyCode, layoutData: Data) -> String? {
        layoutData.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var len = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, 4, &len, &chars)
            guard status == noErr, len > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: len)
        }
    }

    /// Lowest keycode (0...127) that types `char` unmodified.
    public static func keyCode(for char: String, layoutData: Data) -> CGKeyCode? {
        for code in CGKeyCode(0)...127 where character(for: code, layoutData: layoutData) == char {
            return code
        }
        return nil
    }
}
