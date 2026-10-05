import AppKit
import Testing
@testable import WisprLocalCore

/// SEC-6: the pairing code (the long-term key) is concealed on the clipboard and cleared.
@MainActor @Suite struct SecretPasteboardTests {
    static func board() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("wl-secret-\(UUID().uuidString)")) }

    @Test func writesConcealedTransientAndAutoClears() async {
        let pb = Self.board()
        let task = SecretPasteboard.write("WLR1-secret", to: pb, clearAfter: .milliseconds(30))
        #expect(pb.string(forType: .string) == "WLR1-secret")
        let types = Set(pb.pasteboardItems?.first?.types.map(\.rawValue) ?? [])
        #expect(types.contains("org.nspasteboard.ConcealedType"))
        #expect(types.contains("org.nspasteboard.TransientType"))
        #expect(await task.value == true)
        #expect(pb.string(forType: .string) == nil)
    }

    @Test func doesNotClearTheUsersNewerCopy() async {
        let pb = Self.board()
        let task = SecretPasteboard.write("WLR1-secret", to: pb, clearAfter: .milliseconds(30))
        pb.clearContents(); pb.setString("user copy", forType: .string)
        #expect(await task.value == false)
        #expect(pb.string(forType: .string) == "user copy")
    }

    @Test func senderClearsOnlyTheCodeItPaired() {
        let pb = Self.board()
        pb.clearContents(); pb.setString("WLR1-secret\n", forType: .string)
        #expect(SecretPasteboard.clearIfHolding("WLR1-secret", on: pb))
        #expect(pb.string(forType: .string) == nil)
        pb.setString("something else", forType: .string)
        #expect(!SecretPasteboard.clearIfHolding("WLR1-secret", on: pb))
        #expect(pb.string(forType: .string) == "something else")
    }
}
