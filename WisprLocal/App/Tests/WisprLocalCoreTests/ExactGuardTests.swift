import Testing
@testable import WisprLocalCore

/// P2.1-final round 3: "the LLM may not delete content words, ever" — exact-sequence guard.
@Suite struct ExactGuardTests {
    static let vocab = ["Kubernetes", "Tailscale", "Wispr Flow"]

    /// Probe round 5 HIGH bypasses + LOW casing changes: all must reject.
    static let bypasses: [(String, String, String)] = [
        ("H1 sign dropped", "Set the offset to -500.", "Set the offset to 500."),
        ("H2 leading decimal dropped", "Take .5 mg twice a day.", "Take 5 mg twice a day."),
        ("H3 I mean deletes except", "Ship everything except the API, I mean, the docs.", "Ship everything, the docs."),
        ("H4 no wait deletes unless", "Deploy now unless tests fail, no wait, deploy tomorrow.", "Deploy now, deploy tomorrow."),
        ("H5 I mean deletes by Friday", "Finish the report by Friday, I mean, the slides.", "Finish the slides."),
        ("H6 has no wait taken as cue", "The clinic has no wait times today.", "The clinic times today."),
        ("H7 wait, no across a comma", "Wait, no one told me.", "One told me."),
        ("L1 US→us", "Ask the US team.", "Ask the us team."),
        ("L2 Polish→polish", "I speak Polish at home.", "I speak polish at home."),
        ("L3 May→may", "We launch in May.", "We launch in may."),
        ("L4 sign changed", "Dial +44 for the UK office.", "Dial 44 for the UK office."),
        ("L5 range split", "It takes 10-20 minutes.", "It takes 10 minutes."),
    ]

    @Test func bypassesReject() {
        for (id, raw, out) in Self.bypasses {
            #expect(!OutputGuard.check(raw: raw, output: out, vocabulary: Self.vocab).isOK, "\(id)")
        }
    }

    @Test func signsDecimalsAndRangesStayAttached() {
        #expect(OutputGuard.words("-500 .5 +44 10-20 12.5% 1990s 7:45 1,250") == ["-500", ".5", "+44", "10-20", "12.5%", "1990s", "7:45", "1,250"])
        #expect(OutputGuard.words("Don’t stop.") == ["don't", "stop"])   // surface tokens, apostrophe normalised
        #expect(SpokenNumbers.convert("Set it to -500 and .5 mg") == "Set it to -500 and .5 mg")
    }

    /// 12 everyday dictations: punctuation / sentence casing / list layout only → accept.
    static let everyday: [(String, String)] = [
        ("can you send me the slides before the meeting", "Can you send me the slides before the meeting?"),
        ("thanks for the update I'll review it today", "Thanks for the update. I'll review it today."),
        ("so I think we should move the stand-up to 10:30 tomorrow", "So I think we should move the stand-up to 10:30 tomorrow."),
        ("the build is green let's merge it", "The build is green. Let's merge it."),
        ("first buy milk second call the plumber third finish the report", "First, buy milk.\nSecond, call the plumber.\nThird, finish the report."),
        ("I'm running five minutes late start without me", "I'm running five minutes late. Start without me."),
        ("um can we push the release to Friday", "Can we push the release to Friday?"),
        ("restart the Kubernetes pod and check Tailscale", "Restart the Kubernetes pod and check Tailscale."),
        ("it costs twenty five pounds", "It costs 25 pounds."),
        ("Don't merge until the tests pass", "Don't merge until the tests pass."),
        ("send it to John no wait to Mary", "Send it to John, no wait, to Mary."),
        ("dear Sarah thanks for the quick turnaround best Sam", "Dear Sarah, thanks for the quick turnaround. Best, Sam."),
    ]

    @Test func everydayDictationsAccept() {
        for (raw, out) in Self.everyday {
            let v = OutputGuard.check(raw: raw, output: out, vocabulary: Self.vocab)
            #expect(v.isOK, "\(raw) → \(out): \(v.summary)")
        }
    }

    /// Property test: any single-token deletion, substitution or insertion must reject.
    @Test func propertySingleTokenEditsAlwaysReject() {
        var rng = SplitMix(seed: 0x5EED)
        let pool = ["the", "report", "is", "not", "ready", "send", "it", "to", "Sam", "by", "Friday", "we", "can",
                    "never", "ship", "500", "-500", ".5", "only", "except", "unless", "today", "please", "call", "me"]
        var checked = 0
        for _ in 0..<600 {
            let n = 3 + Int(rng.next() % 10)
            var words = (0..<n).map { _ in pool[Int(rng.next() % UInt64(pool.count))] }
            words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
            let raw = words.joined(separator: " ") + "."
            var edited = words
            switch rng.next() % 3 {
            case 0: edited.remove(at: Int(rng.next() % UInt64(n)))
            case 1:
                let i = Int(rng.next() % UInt64(n))
                var w = edited[i]
                while w.lowercased() == edited[i].lowercased() { w = pool[Int(rng.next() % UInt64(pool.count))] }
                edited[i] = w
            default: edited.insert(pool[Int(rng.next() % UInt64(pool.count))], at: Int(rng.next() % UInt64(n + 1)))
            }
            guard !edited.isEmpty else { continue }
            edited[0] = edited[0].prefix(1).uppercased() + edited[0].dropFirst()
            let out = edited.joined(separator: " ") + "."
            #expect(!OutputGuard.check(raw: raw, output: out).isOK, "accepted: \(raw) → \(out)")
            checked += 1
        }
        #expect(checked > 500)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite struct ContentSymbolGuardTests {
    @Test func currencyDoesNotIncreaseWordCount() {
        #expect(OutputGuard.words("pay $5 now") == ["pay", "5", "now"])
    }


    @Test(arguments: [
        ("pay $500 today", "Pay 500 today."), ("a + b", "a - b"), ("a + b", "a b"),
        ("the total is 10 + 5", "The total is 10 - 5."), ("x > 5", "x < 5"), ("x = 5", "x 5"),
        ("follow #tag now", "Follow tag now."), ("50 % off", "50 off."),
        ("3. buy milk\n4. buy eggs", "1. Buy milk\n2. Buy eggs"),
        ("50%", "50"), ("-5", "5"), ("pay $5", "Pay €5."), ("it's not", "it's"),
        (["a", "b.com"].joined(separator: "@"), "a b.com"), ("x * y", "x y"),
        ("2 * 3", "2 3"), ("buy milk", "*Buy milk"),
        ("buy milk*", "Buy milk"), ("buy milk", "Buy * milk"),
        ("buy milk and eggs", "* Buy milk\n* Sell eggs"),
        ("buy milk and eggs", "* Buy milk\n* Buy bread"),
        ("buy milk and eggs", "Buy milk\nBuy eggs"),
        ("buy milk and eggs", "* Buy milk\n* Buy eggs"),
        ("never take ibuprofen and aspirin", "- Never take ibuprofen\n- Never take aspirin"),
        ("do not mix bleach and ammonia", "- Do not mix bleach\n- Do not mix ammonia"),
        ("i hate cats and love dogs", "- I hate cats\n- I hate love dogs"),
        ("first buy milk second buy eggs", "1. Buy milk\n2. Buy eggs"),
        ("10 - 5", "10 5"), ("2 × 3", "2 3"), ("10 – 5", "10 5."),
        ("5 − 3", "5 3"), ("x ≠ 5", "x 5"), ("x ≤ 5", "x 5"),
        ("the balance is -$50", "The balance is $50."), ("x = -y", "x = y"),
        ("x + -y", "x + y"), ("x - -y", "x - y"), ("x = - y", "x = y"),
        ("±5", "5"), ("20°", "20"),
    ]) func meaningChangesReject(_ pair: (String, String)) {
        #expect(!OutputGuard().check(raw: pair.0, output: pair.1, vocabulary: []).isOK)
    }
    @Test(arguments: [
        ("a-b", "a b"), ("a b", "a-b"), ("a - b", "a b"), ("a b", "a - b"),
        ("a  -  b", "a b"),
        ("follow up long term to do", "Follow-up long-term to-do."),
        ("follow-up long-term to-do", "Follow up long term to do."),
        ("the balance is -$50", "The balance is -$50."), ("x = -y", "x = -y"),
        ("-5", "-5"), ("10–20", "10-20"), ("10 - 5", "10 – 5"),
        ("10 – 5", "10 - 5"), ("5 − 3", "5 - 3"),
        ("email a@example.com", "Email a@example.com"), ("pay $5 now", "Pay $5 now."),
        ("it's 5 o'clock", "It's 5 o'clock."),
        ("first, buy milk. second, buy eggs", "1. First, buy milk.\n2. Second, buy eggs."),
        ("buy milk", "* Buy milk"),
        ("buy milk\nbuy eggs", "* Buy milk\n* Buy eggs"),
        ("buy milk\nbuy eggs", "1. Buy milk\n2. Buy eggs"),
        ("buy milk\nbuy eggs", "- Buy milk\n• Buy eggs"),
        ("3. buy milk\n4. buy eggs", "3. Buy milk\n4. Buy eggs"),
        ("pay $500 today", "Pay $500 today."), ("a + b", "A + b."),
    ]) func contentPreservingLayoutAccepts(_ pair: (String, String)) {
        let verdict = OutputGuard().check(raw: pair.0, output: pair.1, vocabulary: [])
        #expect(verdict.isOK, "\(verdict.summary)")
    }

}

@Suite struct OperatorSequenceTests {
    @Test(arguments: ["$", "€", "£", "¥", "₹", "+", "=", "<", ">", "#", "%", "&", "@", "*", "/", "^", "~", "|", "\\"])
    func deletingContentSymbolRejects(_ symbol: String) {
        #expect(!OutputGuard.check(raw: "a \(symbol) b", output: "A b.").isOK)
    }
    @Test func movingCurrencyRejects() {
        #expect(!OutputGuard.check(raw: "pay $500 today", output: "Pay 500$ today.").isOK)
    }
}
