import Testing
import Foundation
@testable import WisprLocalCore

/// Opt-in backtrack: only unambiguous, adjacent, same-type slot corrections.
@Suite struct BacktrackTests {
    static let positives: [(String, String)] = [
        ("Coffee at 2, actually 3.", "Coffee at 3."),
        ("Coffee at 2 actually 3", "Coffee at 3"),
        ("Meet at two thirty, sorry, three thirty.", "Meet at three thirty."),
        ("Two thirty, sorry, three thirty works.", "Three thirty works."),
        ("Let's say 5, make that 6 people.", "Let's say 6 people."),
        ("Book a table for 5, make that 6.", "Book a table for 6."),
        ("Tuesday, no, Wednesday.", "Wednesday."),
        ("See you Tuesday, no, Wednesday.", "See you Wednesday."),
        ("Please tell Sam, I mean Alex.", "Please tell Alex."),
        ("Ask Sam, or rather Alex, to join.", "Ask Alex, to join."),
        ("The budget is $500, sorry, $600.", "The budget is $600."),
        ("Growth was 20%, actually 25%.", "Growth was 25%."),
        ("We need 2, no, 3, no, 4 chairs.", "We need 4 chairs."),
        ("Launch in March, actually April.", "Launch in April."),
        ("Call at 3:30, actually 4.", "Call at 4."),
        ("Call at 3pm, no, 4pm.", "Call at 4pm."),
        ("Let's meet at 3 pm, sorry, 4 pm.", "Let's meet at 4 pm."),
        ("I'll be there by five, actually six.", "I'll be there by six."),
        ("It costs 1.5, I mean 2.5 dollars.", "It costs 2.5 dollars."),
        ("Invite 10, or rather 12, guests.", "Invite 12, guests."),
        ("Ship it Friday, actually Monday.", "Ship it Monday."),
        ("Email Priya, sorry, Dana.", "Email Dana."),
        ("Lunch at noon, actually midnight.", "Lunch at midnight."),
    ]

    /// R7: thousands separators and decimals are part of the number token.
    static let numberFormats: [(String, String)] = [
        ("It costs 1,000, no, 2,000 dollars.", "It costs 2,000 dollars."),
        ("Pay $1,200, sorry, $1,300.", "Pay $1,300."),
        ("Budget 10,000, actually 12,500.", "Budget 12,500."),
        ("About 1,000,000, I mean 2,000,000 users.", "About 2,000,000 users."),
        ("It was 1,000.50, actually 1,200.75.", "It was 1,200.75."),
        ("Raise to £2,500, no, £3,000.", "Raise to £3,000."),
        ("It costs 1.5, I mean 2.5 dollars.", "It costs 2.5 dollars."),
        ("Set it to 0.25, actually 0.5.", "Set it to 0.5."),
        ("We need 1,000, no, 900 units.", "We need 900 units."),
        ("We need 900, no, 1,000 units.", "We need 1,000 units."),
        ("Growth was 2.5%, actually 3.5%.", "Growth was 3.5%."),
        ("Buy 5, no, 6.", "Buy 6."),
    ]

    @Test func numberFormatsAreWholeTokens() {
        for (input, expected) in Self.numberFormats {
            let r = Backtrack.apply(input)
            #expect(r.text == expected, "\(input) → \(r.text)")
            #expect(r.applied, "\(input)")
        }
        // A list of numbers is not a correction: nothing between the numbers is a cue.
        for s in ["Rows 1,000, 2,000 and 3,000.", "Take 1,5 and 2,000 apart."] {
            #expect(Backtrack.apply(s).applied == false, "\(s)")
        }
    }

    @Test func positivesAreCorrected() {
        #expect(Self.positives.count >= 20)
        for (input, expected) in Self.positives {
            let r = Backtrack.apply(input)
            #expect(r.text == expected, "\(input)")
            #expect(r.applied, "\(input)")
        }
    }

    static let negatives: [String] = [
        // Cue words in ordinary use
        "I actually think so.",
        "No, I don't.",
        "Actually, that works.",
        "Sorry, I'm late.",
        "I mean it.",
        "No problem at all.",
        "There are no 3 ways about it.",
        "It was actually 5 years ago.",
        "We actually have 3 kids.",
        "Make that call tomorrow.",
        "Or rather not.",
        "Tell Sam, no, I didn't.",
        "Sam, sorry, I'm running late.",
        "Thanks Sam, sorry Alex couldn't come.",
        "Sam, actually Alex is here.",
        // Different types
        "Tuesday, no, 3.",
        "At 2, actually Wednesday.",
        "Ask Sam, actually 5.",
        "March, actually 4.",
        "5, I mean Tuesday.",
        // Not adjacent
        "At 2 we met, actually 3 times.",
        "5 people, make that 6 people.",
        "We met on Tuesday and, no, Wednesday was busy.",
        "Room 5 is fine. Actually 6 is better.",
        "Is it 5? No, 6.",
        // Same value restated
        "It's 5, actually 5 is too many.",
        "Call Sam, actually, Sam is out.",
        // Months that are words
        "I may, actually, may not.",
        "We march, no, 5 miles.",
        // No restated value
        "We have 2 actually.",
        "Give me 2, no more.",
        "Tuesday, I mean it.",
        "The no-shows were 5, actually.",
    ]

    @Test func negativesStayVerbatim() {
        #expect(Self.negatives.count >= 30)
        for input in Self.negatives {
            let r = Backtrack.apply(input)
            #expect(r.text == input, "\(input) → \(r.text)")
            #expect(!r.applied, "\(input)")
        }
    }

    @Test func finalPassesKeepTheUncorrectedTextForUndo() {
        let r = FinalPasses.apply("Coffee at 2, actually 3.", style: .casual, backtrack: true, vocabulary: [], names: FixedNames())
        #expect(r.text == "Coffee at 3")
        #expect(r.uncorrected == "Coffee at 2, actually 3")
        let off = FinalPasses.apply("Coffee at 2, actually 3.", style: nil, backtrack: false, vocabulary: [], names: FixedNames())
        #expect(off.text == "Coffee at 2, actually 3.")
        #expect(off.uncorrected == nil)
    }
}

/// Pipeline wiring: styles and backtrack are the last passes, backtrack is off by default,
/// history records it, and Undo replaces the inserted text through the injected inserter.
@MainActor @Suite struct BacktrackPipelineTests {
    @Test func offByDefault() async throws {
        let (e, p) = await makeEnv(text: "Coffee at 2, actually 3.")
        await dictate(p)
        #expect(e.inserter.inserted == ["Coffee at 2, actually 3."])
        #expect(e.history.entries.last?.backtrackApplied == nil)
        #expect(p.pendingCorrection == nil)
        #expect(!e.notices.contains(PipelineNotice.corrected))
        // The app's store also defaults OFF.
        let suite = "bt-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(StyleSettingsStore(defaults: d).backtrackEnabled == false)
        #expect(StyleSettingsStore.backtrackDefault == false)
    }

    @Test func appliedCorrectionIsRecordedAndOffersUndo() async {
        let (e, p) = await makeEnv(text: "Coffee at 2, actually 3.")
        p.backtrackEnabled = { true }
        await dictate(p)
        #expect(e.inserter.inserted == ["Coffee at 3."])
        let h = e.history.entries.last!
        #expect(h.backtrackApplied == true)
        #expect(h.raw == "Coffee at 2, actually 3.")
        #expect(h.final == "Coffee at 3.")
        #expect(e.notices.last == PipelineNotice.corrected)
        #expect(p.pendingCorrection?.original == "Coffee at 2, actually 3.")
    }

    @Test func undoPostsUndoThenPastesTheOriginal() async {
        let (e, p) = await makeEnv(text: "Coffee at 2, actually 3.")
        p.backtrackEnabled = { true }
        p.undoSettle = .zero
        var events: [String] = []
        p.postUndo = { events.append("⌘Z") }
        await dictate(p)
        let ok = await p.undoLastCorrection()
        #expect(ok)
        #expect(events == ["⌘Z"])
        #expect(e.inserter.inserted == ["Coffee at 3.", "Coffee at 2, actually 3."])
        #expect(p.lastInsertion?.text == "Coffee at 2, actually 3.")
        #expect(p.pendingCorrection == nil)
        // Only once.
        #expect(await p.undoLastCorrection() == false)
        #expect(events.count == 1)
    }

    @Test func undoAfterFocusMovedCopiesInstead() async {
        let (e, p) = await makeEnv(text: "Tuesday, no, Wednesday.")
        p.backtrackEnabled = { true }
        var undos = 0
        p.postUndo = { undos += 1 }
        await dictate(p)
        e.front = FrontmostApp(pid: 77, bundleID: "com.tinyspeck.slackmacgap")
        #expect(await p.undoLastCorrection() == false)
        #expect(undos == 0)
        #expect(e.clipboard.strings.last == "Tuesday, no, Wednesday.")
        #expect(e.inserter.inserted == ["Wednesday."])
    }

    @Test func undoExpiresAndIsClearedByTheNextDictation() async {
        let (e, p) = await makeEnv(text: "At 2, actually 3.")
        p.backtrackEnabled = { true }
        var undos = 0
        p.postUndo = { undos += 1 }
        let t0 = Date()
        p.currentDate = { t0 }
        await dictate(p)
        p.currentDate = { t0.addingTimeInterval(PendingCorrection.window + 1) }
        #expect(await p.undoLastCorrection() == false)
        #expect(undos == 0)
        p.currentDate = { t0 }
        await dictate(p)
        #expect(p.pendingCorrection != nil)
        p.backtrackEnabled = { false }
        await dictate(p)
        #expect(e.inserter.inserted.last == "At 2, actually 3.")
        #expect(p.pendingCorrection == nil)
    }

    @Test func undoNotOfferedForTyping() async {
        let env = await makeEnv(text: "At 2, actually 3.", strategy: .unicodeTyping)
        env.1.backtrackEnabled = { true }
        await dictate(env.1)
        #expect(env.0.inserter.inserted == ["At 3."])
        #expect(env.1.pendingCorrection == nil)
        #expect(env.0.history.entries.last?.backtrackApplied == true)
    }

    @Test func undoFailsSafelyWhenUndoKeystrokeThrows() async {
        let (e, p) = await makeEnv(text: "At 2, actually 3.")
        p.backtrackEnabled = { true }
        p.postUndo = { throw InsertionError.notTrusted }
        await dictate(p)
        #expect(await p.undoLastCorrection() == false)
        #expect(e.inserter.inserted == ["At 3."])
    }

    @Test func styleRunsLastAndPerApp() async {
        let (e, p) = await makeEnv(text: "See you at 3.")
        let config = ConfigBox()
        p.styleFor = { config.value.style(forBundleID: $0) }
        e.front = FrontmostApp(pid: 42, bundleID: "com.tinyspeck.slackmacgap")
        await dictate(p)
        #expect(e.inserter.inserted.last == "See you at 3")
        #expect(e.history.entries.last?.style == "casual")
        config.value.appOverrides["com.tinyspeck.slackmacgap"] = .formal
        await dictate(p)
        #expect(e.inserter.inserted.last == "See you at 3.")
        config.value.enabled = false
        await dictate(p)
        #expect(e.history.entries.last?.style == nil)
    }

    @Test func stylesSkipSnippetsAndOtherLanguages() async {
        let (e, p) = await makeEnv(text: "Hej, vi ses klockan tre i morgon.")
        p.languageDetector = FixedLanguage(code: "sv", confidence: 0.99)
        p.styleFor = { _ in .veryCasual }
        p.backtrackEnabled = { true }
        await dictate(p)
        #expect(e.inserter.inserted == ["Hej, vi ses klockan tre i morgon."])
        #expect(e.history.entries.last?.style == nil)
    }

    @Test func historyLineRoundTrips() throws {
        var h = HistoryEntry(outcome: .inserted)
        h.backtrackApplied = true; h.style = "code"
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(HistoryEntry.self, from: enc.encode(h))
        #expect(back.backtrackApplied == true)
        #expect(back.style == "code")
    }

    private func dictate(_ p: DictationPipeline) async {
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
    }
}

@MainActor final class ConfigBox { var value = StyleConfiguration() }

struct FixedLanguage: LanguageDetecting {
    let code: String, confidence: Double
    func detect(_ text: String) -> DetectedLanguage { DetectedLanguage(code: code, confidence: confidence) }
}
