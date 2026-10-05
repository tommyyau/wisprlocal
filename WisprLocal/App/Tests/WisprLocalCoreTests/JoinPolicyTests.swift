import Testing
import Foundation
@testable import WisprLocalCore

/// Smart join at dictation boundaries (the maintainer's first real dictation: "theThat", "Go.Is").
@Suite struct JoinPolicyTests {
    @Test(arguments: [
        ("the", "That was a long turn.", " that was a long turn."),       // mid-sentence: space + lowercase
        ("Go.", "Is there anything else?", " Is there anything else?"),   // sentence end: space, keep capital
        ("", "Hello there.", "Hello there."),                            // empty field
        ("the ", "That was it.", "that was it."),                         // previous char is a space
        ("Line one.\n", "Next line.", "Next line."),                      // newline
        ("Hi Sam,", "Thanks for that.", " thanks for that."),            // comma = mid-sentence
        ("Really?", "Yes.", " Yes."),
        ("Done!", "Next.", " Next."),
        ("I said", "I think so.", " I think so."),                        // "I" kept
        ("I said", "I'm fine.", " I'm fine."),
        ("we use the", "API for that.", " API for that."),                 // acronym kept
        ("call", "McDonald today.", " McDonald today."),                  // inner capital kept
        ("ask", "Claude if Claude knows.", " Claude if Claude knows."),   // capitalised mid-raw → proper noun
        ("see (", "This one.", "This one."),                              // opener: no space (CC-6)
        ("ping @", "sam about it", "sam about it"),                   // Slack mention → "@sam"
        ("tag #", "release", "release"),
        ("costs $", "5 each", "5 each"),
        ("list [", "one", "one"),
        ("dict {", "key", "key"),
        ("he said \"", "Hello.", "Hello."),
        ("it's '", "quoted", "quoted"),
        ("he said \u{201C}", "Hello.", "Hello."),                        // opening curly double quote
        ("it's \u{2018}", "quoted", "quoted"),                           // opening curly single quote
        ("https://x.com/", "path", "path"),
        ("C:\\", "Users", "Users"),
        ("state-of-the-", "art", "art"),
        ("snake_", "case", "case"),
        ("Note:", "two eggs", " two eggs"),                         // colon is not an opener
        ("he said \"hi\"", "and", " and"),                  // closing straight quote
        ("dogs'", "bone", " bone"),                                  // apostrophe
        ("he said \u{201C}hi\u{201D}", "and", " and"),
        ("the dogs\u{2019}", "bone", " bone"),
        ("(\"", "Hello", "Hello"),                                        // quote after opener
        ("\"", "Hello", "Hello"),                                         // quote at start
        ("say '", "hi", "hi"),
        ("see )", "This one.", " This one."),                             // closer: space, case kept
        ("50%", "Off.", " Off."),
        ("the", "\n", "\n"),                                              // newline-only insert verbatim
        ("the", ", then", ", then"),                                      // punctuation start: no space
        ("version", "3 is out.", " 3 is out."),
    ])
    func axJoin(_ preceding: String, _ text: String, _ expected: String) {
        #expect(JoinPolicy.adjust(text, preceding: preceding) == expected)
    }

    @Test func dictionaryTermKeepsCapital() {
        #expect(JoinPolicy.adjust("Tailscale is up.", preceding: "check that", vocabulary: ["Tailscale"]) == " Tailscale is up.")
        #expect(JoinPolicy.adjust("Wispr Flow is off.", preceding: "make sure", vocabulary: ["Wispr Flow"]) == " Wispr Flow is off.")
    }

    // AX unavailable (Electron: Claude desktop, Slack) → fallback on our own last insertion.
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let last = LastInsertion(pid: 7, elementID: nil, text: "um okay the", at: t0)

    @Test func fallbackMidSentenceLowercases() {
        let out = JoinPolicy.adjust("That was it.", context: .unavailable, pid: 7, last: Self.last,
                                    now: Self.t0.addingTimeInterval(30))
        #expect(out == " that was it.")
    }

    @Test func fallbackAfterTerminalPunctuationKeepsCapital() {
        let go = LastInsertion(pid: 7, elementID: nil, text: "I'm sure that is accurate. Go.", at: Self.t0)
        #expect(JoinPolicy.adjust("Is there anything else?", context: .unavailable, pid: 7, last: go,
                                  now: Self.t0.addingTimeInterval(9)) == " Is there anything else?")
        let q = LastInsertion(pid: 7, elementID: nil, text: "Ready?", at: Self.t0)
        #expect(JoinPolicy.adjust("Yes.", context: .unavailable, pid: 7, last: q, now: Self.t0) == " Yes.")
    }

    @Test func fallbackAfterWindowIsVerbatim() {
        let out = JoinPolicy.adjust("That was it.", context: .unavailable, pid: 7, last: Self.last,
                                    now: Self.t0.addingTimeInterval(121))
        #expect(out == "That was it.")
    }

    @Test func fallbackDifferentAppIsVerbatim() {
        let out = JoinPolicy.adjust("That was it.", context: .unavailable, pid: 8, last: Self.last,
                                    now: Self.t0.addingTimeInterval(5))
        #expect(out == "That was it.")
    }

    @Test func fallbackDifferentElementIsVerbatim() {
        let ctx = CaretContext(preceding: nil, elementID: 99)
        let last = LastInsertion(pid: 7, elementID: 42, text: "hello", at: Self.t0)
        #expect(JoinPolicy.adjust("Next.", context: ctx, pid: 7, last: last, now: Self.t0.addingTimeInterval(5)) == "Next.")
        let same = LastInsertion(pid: 7, elementID: 99, text: "hello.", at: Self.t0)
        #expect(JoinPolicy.adjust("Next.", context: ctx, pid: 7, last: same, now: Self.t0.addingTimeInterval(5)) == " Next.")
    }

    @Test func fallbackAfterNewlineOrNoHistoryIsVerbatim() {
        let nl = LastInsertion(pid: 7, elementID: nil, text: "Hi Sam,\n", at: Self.t0)
        #expect(JoinPolicy.adjust("Thanks.", context: .unavailable, pid: 7, last: nl, now: Self.t0.addingTimeInterval(5)) == "Thanks.")
        #expect(JoinPolicy.adjust("Thanks.", context: .unavailable, pid: 7, last: nil, now: Self.t0) == "Thanks.")
    }

    @Test func readableContextWinsOverFallback() {
        // AX says the field is empty (e.g. message was sent) → verbatim even right after our insert.
        let out = JoinPolicy.adjust("Is there more?", context: CaretContext(preceding: "", elementID: nil),
                                    pid: 7, last: Self.last, now: Self.t0.addingTimeInterval(5))
        #expect(out == "Is there more?")
    }
}

/// The pipeline applies the join and remembers its last insertion.
@MainActor @Suite struct PipelineJoinTests {
    func dictate(_ p: DictationPipeline) async {
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
    }

    @Test func axContextJoinsWithSpaceAndCase() async {
        let (e, p) = await makeEnv(text: "That was a long turn.")
        e.caret.context = CaretContext(preceding: "um okay the", elementID: 1)
        await dictate(p)
        #expect(e.inserter.inserted == [" that was a long turn."])
        #expect(e.history.entries.last?.final == "That was a long turn.")
        #expect(e.history.entries.last?.join == "ax: that was a long turn.")
    }

    @Test func fallbackJoinsConsecutiveDictationsInSameApp() async {
        let (e, p) = await makeEnv(text: "Is it accurate? Go.")
        e.caret.context = .unavailable
        await dictate(p)
        await dictate(p)
        #expect(e.inserter.inserted == ["Is it accurate? Go.", " Is it accurate? Go."])
        #expect(e.history.entries.last?.join == "fallback: Is it accurate? Go.")
    }
}
