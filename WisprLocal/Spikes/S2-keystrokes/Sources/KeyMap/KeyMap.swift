import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A (virtual keycode, modifier flags) pair that produces a character on a layout.
public struct KeyStroke: Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags
    public init(keyCode: CGKeyCode, flags: CGEventFlags) { self.keyCode = keyCode; self.flags = flags }
}

public enum KeyMapBuilder {
    /// Modifier combos tried, in preference order (fewest modifiers first).
    public static let combos: [(flags: CGEventFlags, carbon: UInt32)] = [
        ([], 0),
        (.maskShift, UInt32(shiftKey >> 8)),
        (.maskAlternate, UInt32(optionKey >> 8)),
        ([.maskShift, .maskAlternate], UInt32((shiftKey | optionKey) >> 8)),
    ]

    /// Layout data of the current keyboard layout (nil if input source has none, e.g. some IMEs).
    public static func currentLayoutData() -> Data? {
        var src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        var ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        if ptr == nil {
            src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
            ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        }
        guard let ptr else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }

    /// Build char -> stroke map from raw 'uchr' layout data. First (fewest-modifier, lowest keycode) wins.
    public static func build(layoutData: Data) -> [Character: KeyStroke] {
        var map: [Character: KeyStroke] = [:]
        let kbType = UInt32(LMGetKbdType())
        layoutData.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for combo in combos {
                for code in UInt16(0)...127 {
                    var dead: UInt32 = 0
                    var len = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), combo.carbon,
                                                kbType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                                &dead, 4, &len, &chars)
                    guard status == noErr, len > 0, dead == 0 else { continue }
                    let s = String(utf16CodeUnits: chars, count: len)
                    guard s.count == 1, let ch = s.first else { continue }
                    if let scalar = ch.unicodeScalars.first, scalar.value < 0x20 || scalar.value == 0x7F { continue }
                    if map[ch] == nil { map[ch] = KeyStroke(keyCode: CGKeyCode(code), flags: combo.flags) }
                }
            }
        }
        // Explicit control characters
        map["\n"] = KeyStroke(keyCode: 36, flags: [])
        map["\t"] = KeyStroke(keyCode: 48, flags: [])
        return map
    }

    public static func buildCurrent() -> [Character: KeyStroke] {
        guard let d = currentLayoutData() else { return [:] }
        return build(layoutData: d)
    }
}
