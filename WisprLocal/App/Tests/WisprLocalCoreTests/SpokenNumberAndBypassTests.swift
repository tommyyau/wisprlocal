import Testing
@testable import WisprLocalCore

@Suite struct SpokenNumberTests {
    @Test(arguments: [
        ("three thousand fifty", 3050), ("two thousand and five", 2005), ("one million two hundred", 1_000_200),
        ("five hundred twenty", 520), ("twenty five", 25), ("a hundred", 100), ("twelve hundred and fifty", 1250),
        ("one hundred and five", 105), ("ninety nine", 99), ("a thousand", 1000),
    ])
    func parses(_ s: String, _ v: Int) {
        #expect(SpokenNumbers.parse(s.split(separator: " ").map(String.init)) == v)
    }

    @Test(arguments: ["nineteen ninety", "seven forty five", "twenty twenty seven", "five six", "one and two",
                      "hundred", "thousand five thousand", "five hundred hundred", "and five"])
    func ambiguousOrInvalidIsNil(_ s: String) {
        #expect(SpokenNumbers.parse(s.split(separator: " ").map(String.init)) == nil, "\(s)")
    }

    @Test func convertOnlyUnambiguousRuns() {
        #expect(SpokenNumbers.convert("We sold three thousand fifty units.") == "We sold 3050 units.")
        #expect(SpokenNumbers.convert("Need twenty-five chairs") == "Need 25 chairs")
        #expect(SpokenNumbers.convert("Back in nineteen ninety.") == "Back in nineteen ninety.")
        #expect(SpokenNumbers.convert("one or two of them") == "one or two of them")
        #expect(SpokenNumbers.convert("the one I like") == "the one I like")
        #expect(SpokenNumbers.convert("Music from the 1990s.") == "Music from the 1990s.")
        #expect(SpokenNumbers.convert("five, six, seven") == "five, six, seven")
        #expect(SpokenNumbers.convert("A hundred people came.") == "100 people came.")
        #expect(SpokenNumbers.convert("It costs twenty pounds.") == "It costs twenty pounds.")   // single words stay
    }
}

/// P2.1-final probe round 2: the bypasses must reject; the corrected forms must accept.
@Suite struct GuardBypassTests {
    static let rejects: [(String, String, String)] = [
        ("B01 3050 → 350", "We sold three thousand fifty units.", "We sold 350 units."),
        ("B02 520 → 50020", "Order five hundred twenty parts.", "Order 50020 parts."),
        ("B03 1990s → 1990", "Music from the 1990s.", "Music from the 1990."),
        ("B04 pounds → £", "It costs twenty pounds.", "It costs £20."),
        ("B05 currency symbol added", "It costs twenty.", "It costs $20."),
        ("B06 transfer over-deleted", "Transfer five hundred dollars to Alice, no wait, to Bob.", "Transfer to Bob."),
        ("B07 back up over-deleted", "Always back up the files, I mean, the photos.", "The photos."),
        ("B08 scratch across and", "Pay Alice two hundred dollars and email Bob, scratch that, email Carol.", "Email Carol."),
        ("B09 unpunctuated scratch > 8", "book the big room for friday and invite the whole design team and order lunch scratch that just cancel it", "Just cancel it."),
        ("B10 inch-mark quote trick", "Cut it to 12″, I mean the whole board, to 14″ wide.", "Cut it to 14″ wide."),
        ("B11 quoted cue", "He said \"send it to Sam, no wait, to Bob\" yesterday.", "He said \"send it to Bob\" yesterday."),
        ("B12 everything you know", "Tell me everything you know about it.", "Tell me everything about it."),
        ("B13 well water", "Well water is safe to drink.", "Water is safe to drink."),
        ("B14 unpunctuated like", "customers like the design", "Customers the design."),
        ("B15 trial period", "Start the trial period today.", "Start the trial today."),
        ("B16 inserted is", "um the server down", "Is the server down?"),
        ("B17 nineteen ninety converted", "Back in nineteen ninety.", "Back in 1990."),
        ("B18 one or two converted", "Bring one or two chairs.", "Bring 1 or 2 chairs."),
        ("B19 content cap", "Add milk, eggs, bread, butter, cheese, jam and tea, I mean, add coffee.", "Add coffee."),
        ("B20 number changed in correction", "Send five, I mean six, copies.", "Send 7 copies."),
    ]
    static let accepts: [(String, String, String)] = [
        ("A01 transfer aligned", "Transfer five hundred dollars to Alice, no wait, to Bob.", "Transfer five hundred dollars to Bob."),
        ("A02 transfer aligned (digits)", "Transfer five hundred dollars to Alice, no wait, to Bob.", "Transfer 500 dollars to Bob."),
        ("A03 back up aligned", "Always back up the files, I mean, the photos.", "Always back up the photos."),
        ("A04 scratch clause only", "Pay Alice two hundred dollars and email Bob, scratch that, email Carol.", "Pay Alice 200 dollars and email Carol."),
        ("A05 3050", "We sold three thousand fifty units.", "We sold 3050 units."),
        ("A06 520", "Order five hundred twenty parts.", "Order 520 parts."),
        ("A07 1990s kept", "Music from the 1990s.", "Music from the 1990s."),
        ("A08 pounds kept", "It costs twenty five pounds.", "It costs 25 pounds."),
        ("A09 you know delimited", "So, you know, it's fine.", "So it's fine."),
        ("A10 Well, kept (round 4)", "Well, the water is safe.", "Well, the water is safe."),
        ("A11 scratch terminal sentence", "Let's book the room for Friday. Scratch that. Book it for Thursday.", "Book it for Thursday."),
    ]

    @Test func bypassesReject() {
        for (id, raw, out) in Self.rejects {
            #expect(!OutputGuard.check(raw: raw, output: out).isOK, "\(id) should reject")
        }
        #expect(Self.rejects.count >= 18)
    }

    /// Round 3: corrections are no longer applied by anyone → A01–A04 (correction forms) now reject;
    /// the RuleCleaner text (corrections left verbatim) is inserted instead.
    static let nowRejected: Set<String> = ["A01", "A02", "A03", "A04"]

    @Test func correctedFormsAccept() {
        for (id, raw, out) in Self.accepts {
            let v = OutputGuard.check(raw: raw, output: out)
            if Self.nowRejected.contains(String(id.prefix(3))) { #expect(!v.isOK, "\(id) now rejected by design"); continue }
            #expect(v.isOK, "\(id) should accept, got \(v.summary)")
        }
    }
}
