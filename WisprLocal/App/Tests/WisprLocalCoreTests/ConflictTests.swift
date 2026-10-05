import Testing
import Foundation
@testable import WisprLocalCore

@Suite struct ConflictDetectorTests {
    static let wispr = RunningAppInfo(bundleID: "com.electron.wispr-flow", bundlePath: "/Applications/Wispr Flow.app")
    static let helper = RunningAppInfo(bundleID: "com.example.helper",
                                       bundlePath: "/Applications/Wispr Flow.app/Contents/Resources/swift-helper.app")
    static let other = RunningAppInfo(bundleID: "com.apple.TextEdit", bundlePath: "/System/Applications/TextEdit.app")

    @Test func matcher() {
        #expect(WisprFlowMatcher.isWisprFlow(Self.wispr))
        #expect(WisprFlowMatcher.isWisprFlow(Self.helper))
        #expect(!WisprFlowMatcher.isWisprFlow(Self.other))
        #expect(!WisprFlowMatcher.isWisprFlow(RunningAppInfo(bundleID: "com.tommyyau.wisprlite", bundlePath: "/Applications/WisprLite.app")))
    }

    @MainActor @Test func detectsAndGatesUntilIgnoredOrQuit() {
        final class Box { var apps: [RunningAppInfo] = [] }
        let box = Box(); box.apps = [Self.other, Self.wispr]
        let d = ConflictDetector(runningApps: { box.apps }, fnUsageReader: { 0 })
        d.refresh()
        #expect(d.wisprFlowRunning)
        #expect(d.insertionBlockReason() != nil)
        d.useAnyway = true
        #expect(d.insertionBlockReason() == nil)
        box.apps = [Self.other]
        d.refresh()
        #expect(!d.wisprFlowRunning)
        #expect(!d.useAnyway)  // ignore resets once it quits
        box.apps = [Self.helper]
        d.refresh()
        #expect(d.insertionBlockReason() != nil)
    }

    @Test func globeUsageMapping() {
        #expect(GlobeKeyConflict(fnUsageType: 0) == .doNothing)
        #expect(!GlobeKeyConflict(fnUsageType: 0).isConflict)
        #expect(GlobeKeyConflict(fnUsageType: 2).isConflict)
        #expect(GlobeKeyConflict(fnUsageType: 3) == .startDictation)
        #expect(GlobeKeyConflict(fnUsageType: nil) == .unknown)
        #expect(GlobeKeyConflict(fnUsageType: nil).isConflict)
    }
}
