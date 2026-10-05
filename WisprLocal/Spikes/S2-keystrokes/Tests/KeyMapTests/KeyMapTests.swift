import XCTest
import CoreGraphics
@testable import KeyMap

final class KeyMapTests: XCTestCase {
    func testASCIIPrintableCoverage() throws {
        let map = KeyMapBuilder.buildCurrent()
        try XCTSkipIf(map.isEmpty, "no layout data")
        var missing: [Character] = []
        for v in 0x20...0x7E {
            let c = Character(UnicodeScalar(UInt8(v)))
            if map[c] == nil { missing.append(c) }
        }
        // Non-US layouts may legitimately miss a few; report but require >= 90%.
        XCTAssertLessThanOrEqual(missing.count, 9, "unmapped ASCII: \(missing)")
    }

    func testUppercaseUsesShift() throws {
        let map = KeyMapBuilder.buildCurrent()
        try XCTSkipIf(map.isEmpty, "no layout data")
        for c in "ABCXYZ" {
            let s = try XCTUnwrap(map[c], "missing \(c)")
            XCTAssertTrue(s.flags.contains(.maskShift), "\(c) should use shift")
            let lower = try XCTUnwrap(map[Character(c.lowercased())])
            XCTAssertFalse(lower.flags.contains(.maskShift))
            XCTAssertEqual(s.keyCode, lower.keyCode)
        }
    }

    func testSpaceAndReturn() throws {
        let map = KeyMapBuilder.buildCurrent()
        try XCTSkipIf(map.isEmpty, "no layout data")
        XCTAssertEqual(map[" "]?.keyCode, 49)
        XCTAssertEqual(map["\n"]?.keyCode, 36)
    }
}
