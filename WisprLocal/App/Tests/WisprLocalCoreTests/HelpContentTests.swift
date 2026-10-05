import Testing
import Foundation
@testable import WisprLocalCore

/// The in-app FAQ (`FAQ.items`) and the readme's "## FAQ" section say the same thing, and the
/// ⓘ popover copy follows DESIGN.md (2–4 plain sentences).
@Suite struct HelpContentTests {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The readme's FAQ section: "### question" headings, each followed by answer paragraphs.
    static func readmeFAQ() throws -> [(q: String, a: [String])] {
        let md = try String(contentsOf: repoRoot.appendingPathComponent("readme.md"), encoding: .utf8)
        let start = try #require(md.range(of: "\n## FAQ\n"), "readme.md has no ## FAQ section")
        var body = md[start.upperBound...]
        if let next = body.range(of: "\n## ") { body = body[..<next.lowerBound] }
        var out: [(q: String, a: [String])] = []
        for block in body.components(separatedBy: "\n### ").dropFirst() {
            let lines = block.components(separatedBy: "\n")
            let paras = lines.dropFirst().joined(separator: "\n").components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("<!--") }
            out.append((lines[0].trimmingCharacters(in: .whitespaces), paras))
        }
        return out
    }

    @Test func readmeFAQMatchesTheApp() throws {
        let readme = try Self.readmeFAQ()
        #expect(readme.map(\.q) == FAQ.items.map(\.question), "question titles differ (keep readme.md ## FAQ in sync with HelpContent.swift)")
        for (r, item) in zip(readme, FAQ.items) {
            #expect(r.a == item.answer, "answer differs for “\(item.question)”")
        }
    }

    @Test func faqHasTheAgreedQuestions() {
        #expect(FAQ.items.count == 11)
        #expect(FAQ.items.contains { $0.question == "Why is the orange mic dot on after I dictate?" })
        #expect(Set(FAQ.items.map(\.id)).count == FAQ.items.count)
    }

    @Test func everyInfoTopicIsTwoToFourSentences() {
        for t in InfoTopic.allCases {
            #expect((2...4).contains(t.sentences.count), "\(t)")
            #expect(!t.title.isEmpty)
        }
    }

    /// The noise-reduction help explains both noise layers and the unbuilt speaker focus.
    @Test func noiseHelpExplainsBothLayers() {
        let s = InfoTopic.noiseReduction.sentences.joined(separator: " ")
        let faq = FAQ.items.first { $0.id == "model" }!.answer.joined(separator: " ")
        for needle in ["Apple voice processing", "fans", "competing voices", "planned but not built"] { #expect(faq.contains(needle), "FAQ: \(needle)") }
        for needle in ["Apple's voice processing", "fans", "Noisy room / other languages (Parakeet Ultra)", "planned but not built"] {
            #expect(s.contains(needle), "\(needle)")
        }
    }

    /// Wherever the TV-speech gap (7.6 vs 19.0 %) is quoted, the voice-processing caveat follows.
    @Test(arguments: ["readme.md", "CHANGELOG.md", "WisprLocal/docs/TEST_REPORT.md", "WisprLocal/docs/RELEASE_NOTES_v1.0.md",
                     "WisprLocal/Spikes/S1b-models/RESULTS.md"])
    func tvNumbersCarryTheCaveat(_ path: String) throws {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        let caveat = "without the app's voice processing; real-world gaps may differ"
        #expect(text.contains(caveat), "\(path) quotes TV-speech numbers without the caveat")
        #expect(FAQ.items.first { $0.id == "model" }!.answer.joined().contains(caveat))
    }

    @Test func privacyCopyExplainsTheNetworkBoundaryAndOfflineExceptions() throws {
        let answer = try #require(FAQ.items.first { $0.id == "offline" }).answer.joined(separator: " ")
        for detail in ["learning and history", "finished text, never audio", "Tailscale", "HMAC",
                       "types locally", "the tests (socket-dependent and opt-in tests are skipped)"] {
            #expect(answer.contains(detail), "Missing privacy detail: \(detail)")
        }
    }

    @Test func warmAudioCopyDistinguishesUnusedAudioFromRecordedPreRoll() throws {
        let faq = try #require(FAQ.items.first { $0.id == "micdot" }).answer.joined(separator: " ")
        for text in [faq, InfoTopic.micReady.sentences.joined(separator: " ")] {
            #expect(text.contains("last ~0.3 s"))
            #expect(text.contains("part of that dictation and its recording"))
            #expect(text.contains("Unused warm audio is never saved"))
        }
        #expect(InfoTopic.micReady.sentences.joined().contains("Always on"))
        for topic in [InfoTopic.micReady] {
            #expect(topic.sentences.joined().contains("a cold start can still clip it"))
        }
    }

    @Test func retentionCopyExplainsDefaultAndFailedAudioWithoutText() throws {
        let data = try #require(FAQ.items.first { $0.id == "data" }).answer.joined(separator: " ")
        #expect(data.contains("Recordings are on by default"))
        #expect(data.contains("no text or audio is kept; History shows only the time, the outcome and the app"))
        #expect(data.contains("Failed dictations (no speech heard, transcription failed, the app refused the text) keep audio if Keep last 20 recordings is on, but never text"))
        #expect(data.contains("not saved in History or recordings"))
        #expect(data.contains("kept in memory until you quit for ⌃⌥⌘V"))
        #expect(data.contains("blocked while WisprLocal is holding off for Wispr Flow, or cancelled"))
        #expect(data.contains("Turn them off in Settings › Privacy"))
    }

    @Test func learningAndLanguageCopyStatesTheLimits() throws {
        for topic in [InfoTopic.learnCorrections, .contextNames] {
            let text = topic.sentences.joined(separator: " ")
            #expect(text.contains("Never read: address bars"))
            #expect(text.contains("defaults you can remove"))
            #expect(text.contains("does not recognise every banking website"))
        }
        let cleanup = try #require(FAQ.items.first { $0.id == "cleanup" }).answer.joined(separator: " ")
        #expect(cleanup.contains("everything you said before it in the current dictation"))
        #expect(cleanup.contains("at least three words"))
        #expect(cleanup.contains("Short or uncertain text gets English cleanup"))
    }
    @Test func formattingAndCaretCopyDisclosesAutomaticReads() throws {
        let cleanup = try #require(FAQ.items.first { $0.id == "cleanup" }).answer.joined()
        #expect(cleanup.contains("Spoken list cues use it even when AI formatting is off"))
        #expect(InfoTopic.aiFormatting.sentences.joined().contains("even when AI formatting is off"))
        let data = try #require(FAQ.items.first { $0.id == "data" }).answer.joined()
        for detail in ["64 characters", "1,000 selected characters", "memory only", "never saved",
                       "Secure fields", "Never read list", "banking/finance", "one preceding character"] {
            #expect(data.contains(detail))
        }
        #expect(InfoTopic.backtrack.sentences.joined().contains(PipelineNotice.correctedCopyOnly))
        #expect(InfoTopic.micReady.sentences.joined().contains("holding off for Wispr Flow"))
    }

    @Test func microphoneUsageMatchesPermissions() throws {
        let script = try String(contentsOf: Self.repoRoot.appendingPathComponent("WisprLocal/App/scripts/build_app.sh"), encoding: .utf8)
        #expect(script.contains("<key>NSMicrophoneUsageDescription</key><string>" + Permission.microphone.why + "</string>"))
        let receiver = try String(contentsOf: Self.repoRoot.appendingPathComponent("WisprLocal/App/scripts/build_receiver.sh"), encoding: .utf8)
        #expect(!receiver.contains("NSMicrophoneUsageDescription"))
        #expect(MicReadiness.always.caption.count <= 90)
    }

}
