import Testing
import Foundation
@testable import WisprLocalCore

@Suite struct SnippetMatcherTests {
    static let snippets = [
        Snippet(trigger: "my email", expansion: "sam.jones@example.com"),
        Snippet(trigger: "sign off", expansion: "Best,\nSam"),
        Snippet(trigger: "what's my address", expansion: "1 Example Street"),
    ]

    @Test(arguments: [
        ("My email.", "my email"),
        ("my email", "my email"),
        ("MY EMAIL!", "my email"),
        ("Insert my email.", "my email"),
        ("insert, my email", "my email"),
        ("Sign off.", "sign off"),
        ("  sign   off  ", "sign off"),
        ("What's my address?", "what's my address"),
        ("whats my address", "what's my address"),
    ])
    func matchesWholeUtterance(_ utterance: String, _ trigger: String) {
        #expect(SnippetMatcher.match(utterance, snippets: Self.snippets)?.trigger == trigger)
    }

    @Test(arguments: [
        "Send my email to Sam.",
        "Please check my email.",
        "my email is broken",
        "Insert my email here.",
        "Sign off on the budget.",
        "",
        "...",
        "insert",
    ])
    func neverMatchesMidSentence(_ utterance: String) {
        #expect(SnippetMatcher.match(utterance, snippets: Self.snippets) == nil)
    }

    @Test func emptyTriggerNeverMatches() {
        #expect(SnippetMatcher.match("anything", snippets: [Snippet(trigger: " ", expansion: "x")]) == nil)
    }

    @Test func multilineExpansionPreserved() {
        #expect(SnippetMatcher.match("sign off", snippets: Self.snippets)?.expansion == "Best,\nSam")
    }
}

@Suite struct DictionarySchemaTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("dictionary.json")
    }

    @Test func writesVersionedSchemaWithSnippets() throws {
        let url = tempURL()
        let s = DictionaryStore(url: url)
        var d = s.dictionary
        d.snippets = [Snippet(trigger: "my email", expansion: "a@b.c\nline 2")]
        try s.update(d)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(json["schemaVersion"] as? Int == UserDictionary.currentSchemaVersion)
        #expect((json["snippets"] as? [[String: Any]])?.first?["expansion"] as? String == "a@b.c\nline 2")
        #expect(DictionaryStore(url: url).dictionary.snippets.first?.trigger == "my email")
        #expect(DictionaryStore(url: url).snippet(for: "Insert my email.")?.expansion == "a@b.c\nline 2")
    }

    @Test func migratesV1FileWithoutVersion() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"vocabulary":["Tailscale"],"replacements":[{"from":"tail scale","to":"Tailscale"}]}"#.utf8).write(to: url)
        let s = DictionaryStore(url: url)
        #expect(s.loadError == nil)
        #expect(s.dictionary.vocabulary == ["Tailscale"])
        #expect(s.dictionary.snippets.isEmpty)
        try s.update(s.dictionary)  // rewritten as current version
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(json["schemaVersion"] as? Int == 2)
    }

    @Test func newerSchemaIsNeverOverwritten() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = #"{"schemaVersion":99,"vocabulary":["X"],"replacements":[],"snippets":[],"newThing":1}"#
        try Data(future.utf8).write(to: url)
        let s = DictionaryStore(url: url)
        #expect(s.loadError?.contains("v99") == true)
        #expect(s.dictionary == .seed)
        #expect(throws: DictionaryError.self) { try s.update(.seed) }
        #expect(try String(contentsOf: url, encoding: .utf8) == future)
    }

    @Test func addTermAndReplacementDedupe() {
        var d = UserDictionary()
        let r1 = d.addTerm(" Kubernetes "), r2 = d.addTerm("kubernetes"), r3 = d.addTerm("  ")
        #expect(r1 && !r2 && !r3)
        #expect(d.vocabulary == ["Kubernetes"])
        let a1 = d.addReplacement(from: "cooper netties", to: "Kubernetes")
        let a2 = d.addReplacement(from: "Cooper Netties", to: "K8s")
        let a3 = d.addReplacement(from: "same", to: "same")
        #expect(a1 && !a2 && !a3)
        #expect(d.apply(to: "restart cooper netties now") == "restart Kubernetes now")
    }
}

