import Testing
import Foundation
@testable import WisprLocalCore

@Suite struct RenameTests {
    @Test func identity() {
        #expect(AppPaths.bundleID == "com.tommyyau.wisprlocal")
        #expect(AppPaths.displayName == "WisprLocal")
        #expect(AppPaths.appSupport.lastPathComponent == "WisprLocal")
    }

    /// Our own app (bundle path now contains "Wispr") must never be detected as Wispr Flow.
    @Test func conflictDetectorNeverMatchesOurselves() {
        let us = RunningAppInfo(bundleID: "com.tommyyau.wisprlocal", bundlePath: "/Users/x/Applications/WisprLocal.app")
        let usNested = RunningAppInfo(bundleID: "com.tommyyau.wisprlocal", bundlePath: "/Volumes/Wispr Flow.app copy/WisprLocal.app")
        let oldUs = RunningAppInfo(bundleID: "com.tommyyau.wisprlite", bundlePath: "/Users/x/Applications/WisprLite.app")
        let wispr = RunningAppInfo(bundleID: "com.electron.wispr-flow", bundlePath: "/Applications/Wispr Flow.app")
        let helper = RunningAppInfo(bundleID: nil, bundlePath: "/Applications/Wispr Flow.app/Contents/Resources/swift-helper")
        let lookalike = RunningAppInfo(bundleID: "com.example.wispr", bundlePath: "/Applications/WisprNotes.app")
        #expect(!WisprFlowMatcher.isWisprFlow(us))
        #expect(!WisprFlowMatcher.isWisprFlow(usNested))
        #expect(!WisprFlowMatcher.isWisprFlow(oldUs))
        #expect(!WisprFlowMatcher.isWisprFlow(lookalike))
        #expect(WisprFlowMatcher.isWisprFlow(wispr))
        #expect(WisprFlowMatcher.isWisprFlow(helper))
        #expect(WisprFlowMatcher.detect(in: [us, wispr, lookalike]).map(\.bundleID) == ["com.electron.wispr-flow"])
    }

    @Test func migratesDictionaryAndHistoryOnlyAndNeverDeletesOld() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = base.appendingPathComponent("WisprLite"), new = base.appendingPathComponent("WisprLocal")
        try fm.createDirectory(at: old.appendingPathComponent("Models/parakeet-ultra"), withIntermediateDirectories: true)
        try Data("{\"vocabulary\":[\"X\"]}".utf8).write(to: old.appendingPathComponent("dictionary.json"))
        try Data("line\n".utf8).write(to: old.appendingPathComponent("history.jsonl"))
        #expect(AppPaths.migrateLegacyData(from: old, to: new).sorted() == ["dictionary.json", "history.jsonl"])
        #expect(fm.fileExists(atPath: new.appendingPathComponent("dictionary.json").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("Models").path))          // models not copied
        #expect(fm.fileExists(atPath: old.appendingPathComponent("dictionary.json").path))  // old kept
        // Never overwrites the new folder's files on a second run.
        try Data("{\"vocabulary\":[\"NEW\"]}".utf8).write(to: new.appendingPathComponent("dictionary.json"))
        #expect(AppPaths.migrateLegacyData(from: old, to: new).isEmpty)
        #expect(try String(contentsOf: new.appendingPathComponent("dictionary.json"), encoding: .utf8).contains("NEW"))
        // No legacy folder → nothing.
        #expect(AppPaths.migrateLegacyData(from: base.appendingPathComponent("nope"), to: new).isEmpty)
    }
}
