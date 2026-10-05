import Foundation
import Testing
@testable import WisprLocalCore

@Suite struct DictionaryCacheTests {
    @Test func cachedRulesMatchFreshCompilationAndOnlyChangedContentCompiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        var dictionary = UserDictionary(vocabulary: ["Kubernetes", "Tailscale"], replacements: [
            ReplacementRule(from: "cooper netties", to: "Kubernetes"),
            ReplacementRule(from: "tail scale", to: "Tailscale")
        ], snippets: [Snippet(trigger: "MY résumé", expansion: "First"), Snippet(trigger: "insert my resume", expansion: "Second")])
        try await store.updateAsync(dictionary)
        #expect(!store.lastCompilationOnMainThread)
        let compiled = store.compilationCount
        for text in ["cooper  netties tail scale", "COOPER NETTIES", "tailscale", "other words"] {
            #expect(store.apply(to: text) == CompiledDictionary(dictionary).apply(to: text))
            #expect(store.snippet(for: text) == SnippetMatcher.match(text, snippets: dictionary.snippets))
            #expect(store.snapper(context: nil, tombstones: []).apply(text) == SpellingSnapper(vocabulary: dictionary.vocabulary).apply(text))
        }
        for query in ["my résumé", "INSERT MY RÉSUMÉ", "insert my resume", "no match"] {
            #expect(store.snippet(for: query) == SnippetMatcher.match(query, snippets: dictionary.snippets))
        }
        #expect(store.compilationCount == compiled)
        dictionary.replacements[0].id = UUID()
        dictionary.vocabulary.append("Postgres")
        try await store.updateAsync(dictionary)
        #expect(store.compilationCount == compiled)
        dictionary.replacements[0].to = "New spelling"
        try await store.updateAsync(dictionary)
        #expect(store.compilationCount == compiled + 1)
    }

    @Test func contextOverlayAndTombstonesMatchAFullSnapper() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-overlay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        let dictionary = UserDictionary(vocabulary: ["Kubernetes", "Tailscale", "Postgres"])
        try await store.updateAsync(dictionary)
        let contexts: [ContextSnapshot?] = [nil,
            ContextSnapshot(candidates: [.init("Kubernetes", kind: .name), .init("Newman", kind: .name)], isCodeApp: false),
            ContextSnapshot(candidates: [.init("getUserById", kind: .identifier), .init("@sam_lee", kind: .handle)], isCodeApp: true)]
        for context in contexts {
            for tombstones: Set<String> in [[], ["Kubernetes"], ["kubernetties", "Postgres"]] {
                let cached = store.snapper(context: context, tombstones: tombstones)
                let fresh = SpellingSnapper(vocabulary: dictionary.vocabulary, context: context, tombstones: tombstones)
                for text in ["kubernetties", "tail scale", "post gress", "new man", "get user by id", "at sam lee", "ordinary text"] {
                    #expect(cached.apply(text) == fresh.apply(text))
                }
            }
        }
    }
    @Test func concurrentLearningUpdatesKeepBothTerms() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-updates-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        async let first: Void = store.updateAsync { $0.addTerm("Kubernetes") }
        async let second: Void = store.updateAsync { $0.addTerm("Postgres") }
        _ = try await (first, second)
        #expect(store.dictionary.vocabulary.contains("Kubernetes"))
        #expect(store.dictionary.vocabulary.contains("Postgres"))
    }

    @Test func rapidBackToBackMutationsPersistLastSubmissionEveryTrial() async throws {
        for _ in 0..<20 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-order-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
            var saves: [DictionaryStore.Save] = []
            var last = UserDictionary()
            for revision in 0..<20 {
                var dictionary = UserDictionary()
                dictionary.addTerm("revision \(revision)")
                last = dictionary
                saves.append(store.enqueueUpdate(dictionary))
            }
            // Waiters may start in any order; submission order has already been recorded.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for save in saves.reversed() { group.addTask { try await save.value } }
                try await group.waitForAll()
            }
            #expect(store.dictionary == last)
            #expect(DictionaryStore(url: root.appendingPathComponent("dictionary.json")).dictionary == last)
        }
    }

}
