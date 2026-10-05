import AppKit
import Foundation
import Testing
@testable import WisprLocalCore

@Suite struct DataSafetyReviewTests {
    @Test(arguments: [false, true])
    func staleRecordingSaveCannotRecreateDeletedPair(clear: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-generation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DebugRecordingStore(directory: root)
        let entry = HistoryEntry(final: "example words", outcome: .inserted)
        let queuedGeneration = store.saveGeneration
        if clear { store.deleteAll() } else { store.delete(id: entry.id) }
        #expect(store.save(samples: [0.1], entry: entry, generation: queuedGeneration) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.wavURL(entry.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.jsonURL(entry.id).path))
    }

    @Test func disabledRecordingSaveWritesNothing() {
        final class Enabled: @unchecked Sendable {
            let lock = NSLock()
            var value = true
            func disable() { lock.withLock { value = false } }
            func read() -> Bool { lock.withLock { value } }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-disabled-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = Enabled()
        let store = DebugRecordingStore(directory: root, isEnabled: { enabled.read() })
        let generation = store.saveGeneration
        enabled.disable()
        #expect(store.save(samples: [0.1], entry: HistoryEntry(outcome: .inserted), generation: generation) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func editorChangesPreserveLearningAndOtherFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-editor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        let old = UserDictionary(replacements: [ReplacementRule(from: "heard", to: "written")],
                                 snippets: [Snippet(trigger: "example", expansion: "original")])
        try await store.updateAsync(old)
        try await store.updateAsync { $0.addTerm("Learned") }
        var first = old, second = old, third = old
        first.replacements[0].from = "new heard"
        second.replacements[0].to = "new written"
        third.snippets[0].expansion = "new expansion"
        let a = store.enqueueEditorChanges(from: old, to: first)
        let b = store.enqueueEditorChanges(from: old, to: second)
        let c = store.enqueueEditorChanges(from: old, to: third)
        try await a.value; try await b.value; try await c.value
        #expect(store.dictionary.vocabulary == ["Learned"])
        #expect(store.dictionary.replacements[0].from == "new heard")
        #expect(store.dictionary.replacements[0].to == "new written")
        #expect(store.dictionary.snippets[0].expansion == "new expansion")
    }

    @Test func contextOverlayIsNeverRetainedByStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-retention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        let context = ContextSnapshot(candidates: [.init("PrivateExampleName", kind: .name)], isCodeApp: false)
        _ = store.snapper(context: context, tombstones: [])
        let state = Mirror(reflecting: store).children
        #expect(!state.contains { $0.value is ContextSnapshot || $0.label == "snapperCache" })
        #expect(!store.dictionary.vocabulary.contains("PrivateExampleName"))
        #expect(store.snapper(context: nil, tombstones: []).apply("private example name").text == "private example name")
    }

    @Test @MainActor func terminationRestoresOnlyOwnedClipboard() {
        let pb = NSPasteboardShim.make()
        defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString("original", forType: .string)
        let snapshot = PasteboardSnapshot.capture(pb)
        pb.clearContents(); pb.setString("dictation", forType: .string)
        ClipboardRestore.hold(snapshot, on: pb, ourChange: pb.changeCount)
        ClipboardRestore.restorePending(on: pb)
        #expect(pb.string(forType: .string) == "original")
        pb.clearContents(); pb.setString("dictation", forType: .string)
        ClipboardRestore.hold(snapshot, on: pb, ourChange: pb.changeCount)
        pb.clearContents(); pb.setString("new user copy", forType: .string)
        ClipboardRestore.restorePending(on: pb)
        #expect(pb.string(forType: .string) == "new user copy")
        #expect(!ClipboardRestore.isPending(pb))
    }
}
