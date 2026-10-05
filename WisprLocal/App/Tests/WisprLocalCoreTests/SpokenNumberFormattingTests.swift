import Testing
@testable import WisprLocalCore

/// Spoken-number formatting in the deterministic pre-pass (`SpokenNumbers.convert`, run by
/// `RuleCleaner` before the FM formatter): decimals, version names, percentages, units, prose.
@Suite struct SpokenNumberFormattingTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let input: String, expected: String
        var testDescription: String { input }
        init(_ input: String, _ expected: String) { self.input = input; self.expected = expected }
    }

    static let cases: [Case] = [
        // 1. Decimals
        Case("Sol six point one", "Sol 6.1"),
        Case("it was six point one", "it was 6.1"),
        Case("zero point five", "0.5"),
        Case("about two point five million users", "about 2.5 million users"),
        Case("pi is three point one four", "pi is 3.14"),
        Case("three point one four one five nine", "3.14159"),
        Case("a ratio of one point twenty five", "a ratio of 1.25"),
        Case("twenty five point five degrees", "25.5 degrees"),
        Case("take point five mg twice a day", "take 0.5 mg twice a day"),
        Case("rates fell point two five percent", "rates fell 0.25%"),
        Case("Count to point five and stop.", "Count to point five and stop."),
        Case("The 6 point 1 build.", "The 6.1 build."),
        // "point" not between number words stays a word
        Case("The point is we ship today.", "The point is we ship today."),
        Case("Your answer was on point.", "Your answer was on point."),
        Case("Point taken, thanks.", "Point taken, thanks."),
        Case("That's a fair point five times over.", "That's a fair point five times over."),
        Case("At one point five people left.", "At one point five people left."),
        Case("We reached a point where nothing worked.", "We reached a point where nothing worked."),
        Case("bullet point five is wrong", "bullet point five is wrong"),
        // 2. Version and model names
        Case("GPT five is out", "GPT 5 is out"),
        Case("gpt five is out", "gpt 5 is out"),
        Case("Ask Sol six to help", "Ask Sol 6 to help"),
        Case("upgrade to macOS twenty six", "upgrade to macOS 26"),
        Case("my iPhone seventeen arrived", "my iPhone 17 arrived"),
        Case("ship version two point three today", "ship version 2.3 today"),
        Case("ship version two today", "ship version 2 today"),
        Case("the v two API", "the v2 API"),
        Case("the v two point one release", "the v2.1 release"),
        Case("I run Python three.", "I run Python 3."),
        Case("We moved to Kubernetes three.", "We moved to Kubernetes 3."),
        Case("Windows eleven broke it", "Windows 11 broke it"),
        Case("GPT four o", "GPT 4 o"),
        Case("No GPT-5 style hyphen is invented: GPT five turbo", "No GPT-5 style hyphen is invented: GPT 5 turbo"),
        // weak names (Capitalised, not a product) only at a clause end
        Case("I met Tom three times.", "I met Tom three times."),
        Case("Ask Claude two questions", "Ask Claude two questions"),
        Case("We tried Claude four.", "We tried Claude 4."),
        Case("Two people came.", "Two people came."),
        Case("The three of us went.", "The three of us went."),
        Case("I three times said no.", "I three times said no."),
        Case("ask GPT one of the questions", "ask GPT one of the questions"),
        // 3. Percentages
        Case("growth was fifty percent", "growth was 50%"),
        Case("five percent of users", "5% of users"),
        Case("twelve point five percent last quarter", "12.5% last quarter"),
        Case("a hundred percent sure", "100% sure"),
        Case("we hit 50 percent", "we hit 50%"),
        Case("we hit 2.5 per cent", "we hit 2.5%"),
        Case("the percent sign", "the percent sign"),
        // 4. Units, time and money
        Case("It costs five pounds.", "It costs five pounds."),
        Case("It costs twenty five pounds.", "It costs 25 pounds."),
        Case("it weighs two point five kilos", "it weighs 2.5 kilos"),
        Case("five hundred dollars", "500 dollars"),
        Case("meet at ten thirty", "meet at ten thirty"),
        Case("the train at seven forty five", "the train at seven forty five"),
        // 5. Keep prose
        Case("one of the best", "one of the best"),
        Case("two people came", "two people came"),
        Case("I have three ideas", "I have three ideas"),
        Case("twelve people came", "twelve people came"),
        Case("one or two of them", "one or two of them"),
        Case("Back in nineteen ninety.", "Back in nineteen ninety."),
        // Mixed
        Case("Ask Sol six point one to run version two point three at fifty percent",
             "Ask Sol 6.1 to run version 2.3 at 50%"),
        Case("GPT five scored ninety two percent, up from eighty seven point five percent.",
             "GPT 5 scored 92%, up from 87.5%."),
    ]

    @Test(arguments: cases)
    func converts(_ c: Case) {
        #expect(SpokenNumbers.convert(c.input) == c.expected)
    }

    @Test func atLeastFortyCases() { #expect(Self.cases.count >= 40) }

    /// The pre-pass is idempotent (the guard re-runs it on the model input).
    @Test(arguments: cases)
    func idempotent(_ c: Case) {
        #expect(SpokenNumbers.convert(c.expected) == c.expected)
    }

    /// A dictionary term followed by a number is a version name (only via the vocabulary).
    @Test func dictionaryTermIsAName() {
        #expect(SpokenNumbers.convert("we use foobar two now", vocabulary: ["foobar"]) == "we use foobar 2 now")
        #expect(SpokenNumbers.convert("we use foobar two now") == "we use foobar two now")
        #expect(RuleCleaner().cleanSync("We use Acme Widget two now.", vocabulary: ["Acme Widget"]) == "We use Acme Widget 2 now.")
    }

    @Test func ruleCleanerFormatsNumbers() {
        #expect(RuleCleaner().cleanSync("Um, ask Sol six point one, uh, to run it.") == "Ask Sol 6.1 to run it.")
    }

    /// Rule 6: the FM output keeping "6.1" / "50%" / "v2" passes the guard; altering them rejects.
    @Test func guardKeepsDecimalsAttached() {
        let raw = "ask Sol six point one to run version two point three at fifty percent"
        #expect(OutputGuard.check(raw: raw, output: "Ask Sol 6.1 to run version 2.3 at 50%.").isOK)
        #expect(!OutputGuard.check(raw: raw, output: "Ask Sol 6 to run version 2.3 at 50%.").isOK)
        #expect(!OutputGuard.check(raw: raw, output: "Ask Sol 6.1 to run version 2.3 at 50 percent.").isOK)
        #expect(!OutputGuard.check(raw: raw, output: "Ask Sol six point one to run version 2.3 at 50%.").isOK)
        #expect(OutputGuard.tokens("Sol 6.1 at -0.5 and 50%").map(\.surface) == ["Sol", "6.1", "at", "-0.5", "and", "50%"])
        #expect(OutputGuard.check(raw: "the v two api is live", output: "The v2 API is live.", vocabulary: ["API"]).isOK)
    }
}

/// AI formatting OFF (default): the pipeline's RuleCleaner path receives the user's dictionary
/// terms, so a number after a user term becomes digits end to end.
@MainActor @Suite struct RulesPathDictionaryNumberTests {
    @Test func dictionaryTermVersionThroughPipeline() async throws {
        let store = tempDictionary()
        try store.update(UserDictionary(vocabulary: ["Zephyr"]))
        let (e, p) = await makeEnv(text: "We should try Zephyr two with the team", dictionary: store)
        #expect(!p.userFormattingEnabled)
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["We should try Zephyr 2 with the team"])
        #expect(e.history.entries.last?.cleaner == "rules")
    }

    @Test func withoutTheTermPlainNameStaysWords() async {
        let (e, p) = await makeEnv(text: "We should try Zephyr two with the team")
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["We should try Zephyr two with the team"])
    }
}
