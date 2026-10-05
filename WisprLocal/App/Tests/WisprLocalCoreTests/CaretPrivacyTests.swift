import Testing
import Foundation
import ApplicationServices
@testable import WisprLocalCore

/// Records every AX primitive the caret reader asks for; answers from a scripted field.
final class SpyCaretAX: CaretAX, @unchecked Sendable {
    enum Call: Equatable { case trusted, focused, attribute(String), selectedRange, string(location: Int, length: Int), value }
    private let lock = NSLock()
    private var log: [Call] = []
    var calls: [Call] { lock.withLock { log } }
    private func record(_ c: Call) { lock.withLock { log.append(c) } }

    let element: AXIdentity = AXIdentity("field-1" as NSString)
    var subrole: String?
    var identifier: String?
    var desc: String?
    var text = "Dear Sam, my PIN is 4321 and I said hello"
    var selection = CFRange(location: 41, length: 0)

    func isTrusted() -> Bool { record(.trusted); return true }
    func focusedElement(pid: Int32) -> AXIdentity? { record(.focused); return element }
    func attribute(_ e: AXIdentity, _ name: String) -> String? {
        record(.attribute(name))
        switch name {
        case kAXSubroleAttribute: return subrole
        case kAXIdentifierAttribute: return identifier
        case kAXDescriptionAttribute: return desc
        default: return nil
        }
    }
    func selectedRange(_ e: AXIdentity) -> CFRange? { record(.selectedRange); return selection }
    func string(_ e: AXIdentity, in r: CFRange) -> String? {
        record(.string(location: r.location, length: r.length))
        return (text as NSString).substring(with: NSRange(location: r.location, length: r.length))
    }
    func value(_ e: AXIdentity) -> String? { record(.value); return text }

    /// Every call that returns field CONTENT (text, selection, value).
    var contentReads: [Call] {
        calls.filter { if case .string = $0 { return true }; return $0 == .value }
    }
}

/// S1: the caret/selection read applies the shared exclusion policy FIRST.
@MainActor @Suite struct CaretPrivacyTests {
    func reader(_ spy: SpyCaretAX, denylist: [String] = ContextPolicy.defaultDenylist,
                category: String? = nil) -> AXCaretContextReader {
        AXCaretContextReader(policy: AppReadPolicy(denylist: { denylist }, appCategory: { _ in category }), ax: { _ in spy })
    }

    @Test func denylistedAppGetsNoAXMessageAtAll() async {
        let spy = SpyCaretAX()
        spy.selection = CFRange(location: 20, length: 4)   // "4321" selected
        let ctx = await reader(spy).read(pid: 42, bundleID: "com.1password.1password")
        #expect(spy.calls.isEmpty)                          // not even the focused element
        #expect(ctx == .unavailable)                        // → the no-AX fallback join
        #expect(ctx.selectedText == nil)
    }

    @Test func financeCategoryAppIsExcludedToo() async {
        let spy = SpyCaretAX()
        let ctx = await reader(spy, category: ContextPolicy.financeCategory).read(pid: 42, bundleID: "com.example.bank")
        #expect(spy.calls.isEmpty)
        #expect(ctx == .unavailable)
    }

    @Test func secureFieldReadsNothing() async {
        let spy = SpyCaretAX()
        spy.subrole = kAXSecureTextFieldSubrole as String
        spy.selection = CFRange(location: 20, length: 4)
        let ctx = await reader(spy).read(pid: 42, bundleID: "com.apple.Safari")
        #expect(spy.contentReads.isEmpty)
        #expect(!spy.calls.contains(.selectedRange))
        #expect(ctx.preceding == nil)
        #expect(ctx.selectedText == nil)
    }

    @Test func urlFieldReadsOnlyThePrecedingCharacter() async {
        let spy = SpyCaretAX()
        spy.identifier = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
        spy.selection = CFRange(location: 41, length: 0)
        let ctx = await reader(spy).read(pid: 42, bundleID: "com.apple.Safari")
        #expect(spy.contentReads == [.string(location: 40, length: 1)])
        #expect(ctx.preceding == "o")
        #expect(ctx.selectedText == nil)
    }

    @Test func urlFieldNeverReadsTheSelection() async {
        let spy = SpyCaretAX()
        spy.desc = "Address and search bar"
        spy.selection = CFRange(location: 20, length: 4)
        _ = await reader(spy).read(pid: 42, bundleID: "com.google.Chrome")
        #expect(spy.contentReads == [.string(location: 19, length: 1)])
    }

    @Test func ordinaryFieldReadsContextAndSelection() async {
        let spy = SpyCaretAX()
        spy.selection = CFRange(location: 36, length: 5)   // "hello"
        let ctx = await reader(spy).read(pid: 42, bundleID: "com.apple.TextEdit")
        #expect(ctx.selectedText == "hello")
        #expect(ctx.preceding == "Dear Sam, my PIN is 4321 and I said ")
        // The scope is decided before any content is read.
        let firstContent = spy.calls.firstIndex { if case .string = $0 { return true }; return false }!
        let lastScopeCheck = spy.calls.lastIndex { if case .attribute = $0 { return true }; return false }!
        #expect(lastScopeCheck < firstContent)
    }

    @Test func scopeDecision() {
        #expect(CaretRead.scope(subrole: kAXSecureTextFieldSubrole as String, identifier: nil, description: nil) == .nothing)
        #expect(CaretRead.scope(subrole: nil, identifier: nil, description: "URL") == .spacingOnly)
        #expect(CaretRead.scope(subrole: nil, identifier: "body", description: "Message") == .full)
    }
}
