import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A (virtual keycode, modifiers) pair that types one character on the current layout.
public struct KeyStroke: Equatable, Sendable {
    public let keyCode: UInt16
    public let flags: CGEventFlags
    public init(keyCode: UInt16, flags: CGEventFlags) { self.keyCode = keyCode; self.flags = flags }
}

/// Reverse keyboard map (character → keystroke) built with UCKeyTranslate over keycodes 0…127
/// and modifier combos none/Shift/Option/Shift+Option (fewest modifiers, then lowest keycode,
/// wins). Ported from the S2 spike's `KeyMapBuilder`. Cached; rebuilt when the input source
/// changes. Dead-key sequences are skipped (those characters fall back to Unicode).
public final class KeyStrokeMap: @unchecked Sendable {
    public static let shared = KeyStrokeMap()

    static let combos: [(flags: CGEventFlags, carbon: UInt32)] = [
        ([], 0),
        (.maskShift, UInt32(shiftKey >> 8)),
        (.maskAlternate, UInt32(optionKey >> 8)),
        ([.maskShift, .maskAlternate], UInt32((shiftKey | optionKey) >> 8)),
    ]

    private let lock = NSLock()
    private var cached: [Character: KeyStroke]?
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: nil
        ) { [weak self] _ in self?.invalidate() }
    }

    public func invalidate() { lock.withLock { cached = nil } }

    /// Map for the current layout (empty if the input source has no layout data). Main thread
    /// only: the TIS input-source APIs abort off the main thread.
    @MainActor public var current: [Character: KeyStroke] {
        lock.withLock {
            if let c = cached { return c }
            let m = KeyboardLayoutMap.layoutData().map(Self.build(layoutData:)) ?? [:]
            cached = m
            return m
        }
    }

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
                    if map[ch] == nil { map[ch] = KeyStroke(keyCode: code, flags: combo.flags) }
                }
            }
        }
        map["\t"] = KeyStroke(keyCode: UInt16(kVK_Tab), flags: [])
        return map
    }
}
