import Testing
import Carbon.HIToolbox
@testable import WisprLocalCore

@Suite struct TypingSafetyTests {
    /// A bare Return SENDS in chat apps — newlines must be Shift+Return.
    @Test func newlinesAreShiftReturnNeverBareReturn() {
        let plan = UnicodeTypingInserter.plan("Hi\nthere\r\nbye")
        #expect(plan.contains(.key(code: UInt16(kVK_Return), shift: true)))
        #expect(!plan.contains(.key(code: UInt16(kVK_Return), shift: false)))
        #expect(plan.filter { if case .key = $0 { return true } else { return false } }.count == 2)
        #expect(plan.first == .unicode(Array("Hi".utf16)))
    }
}
