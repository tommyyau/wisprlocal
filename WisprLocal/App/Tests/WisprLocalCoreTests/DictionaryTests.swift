import Testing
import Foundation
@testable import WisprLocalCore

@Suite struct DictionaryTests {
    @Test(arguments: [
        ("Please open Whisperflow, then connect.", "Please open Wispr Flow, then connect."),
        ("I love whisper flow.", "I love Wispr Flow."),
        ("WHISPER   FLOW is great", "Wispr Flow is great"),
        ("Two nodes lost their tail scale connection.", "Two nodes lost their Tailscale connection."),
        ("Whisperflow's settings", "Wispr Flow's settings"),
        ("whisperflows", "whisperflows"),          // whole word only
        ("cocktail scale", "cocktail scale"),      // boundary inside a word
    ])
    func seedReplacements(_ input: String, _ expected: String) {
        #expect(UserDictionary.seed.apply(to: input) == expected)
    }

    @Test func caseSensitiveAndPartialRules() {
        let d = UserDictionary(replacements: [
            ReplacementRule(from: "Go", to: "Golang", caseInsensitive: false),
            ReplacementRule(from: "k8", to: "K8s", wholeWord: false),
            ReplacementRule(from: "dollar", to: "$1 literal"),
        ])
        #expect(d.apply(to: "Go and go") == "Golang and go")
        #expect(d.apply(to: "use k8 clusters") == "use K8s clusters")
        #expect(d.apply(to: "a dollar") == "a $1 literal")
    }

    @Test func storeSeedsRoundTripsAndNeverOverwritesCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("dictionary.json")
        let s = DictionaryStore(url: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(s.dictionary == .seed)
        var d = s.dictionary
        d.replacements.append(ReplacementRule(from: "foo", to: "Bar"))
        try s.update(d)
        #expect(DictionaryStore(url: url).dictionary.replacements.count == UserDictionary.seed.replacements.count + 1)
        // JSON shape
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(json["vocabulary"] is [String])
        #expect((json["replacements"] as! [[String: Any]]).first?["from"] as? String == "whisperflow")
        // corrupt file left untouched
        try Data("{not json".utf8).write(to: url)
        let s2 = DictionaryStore(url: url)
        #expect(s2.loadError != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{not json")
    }
}
