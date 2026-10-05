import Testing
@testable import WisprLocalCore

@Suite struct InsertionRouterTests {
    @Test func selection() {
        let r = InsertionRouter()
        #expect(r.strategy(forBundleID: "com.apple.TextEdit") == .paste)
        #expect(r.strategy(forBundleID: nil) == .paste)
        #expect(r.strategy(forBundleID: "com.apple.ScreenSharing") == .remote)
        let o = InsertionRouter(overrides: ["com.example.weird": .unicodeTyping, "com.apple.ScreenSharing": .paste])
        #expect(o.strategy(forBundleID: "com.example.weird") == .unicodeTyping)
        #expect(o.strategy(forBundleID: "com.apple.ScreenSharing") == .paste)
    }

    @MainActor @Test func remoteStrategyIsRemoteInserterAndSwappable() {
        let paste = FakeInserter(name: "paste"), typing = FakeInserter(name: "typing")
        let ri = RoutingInserter(router: InsertionRouter(), paste: paste, typing: typing)
        #expect(ri.inserter(forBundleID: "com.apple.ScreenSharing") is RemoteInserter)
        #expect(ri.inserter(forBundleID: "com.apple.Notes") === paste)
        let remote = FakeInserter(name: "remote")
        ri.remoteStrategy = remote
        #expect(ri.inserter(forBundleID: "com.apple.ScreenSharing") === remote)
    }
}
