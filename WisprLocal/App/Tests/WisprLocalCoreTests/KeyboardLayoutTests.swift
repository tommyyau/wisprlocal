import Testing
import CoreGraphics
@testable import WisprLocalCore

@Suite struct KeyboardLayoutTests {
    @Test func pasteKeyTypesVOnCurrentLayout() throws {
        let data = try #require(KeyboardLayoutMap.layoutData())
        let code = try #require(KeyboardLayoutMap.keyCode(for: "v", layoutData: data))
        #expect(KeyboardLayoutMap.character(for: code, layoutData: data) == "v")
        #expect(KeyboardLayoutMap.shared.pasteKeyCode == code)
        KeyboardLayoutMap.shared.invalidate()
        #expect(KeyboardLayoutMap.shared.pasteKeyCode == code)
    }

    @Test func fallbackIsANSIV() { #expect(KeyboardLayoutMap.fallbackV == 9) }
}
