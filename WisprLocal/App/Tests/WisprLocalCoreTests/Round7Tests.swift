import Testing
import Carbon.HIToolbox
@testable import WisprLocalCore

/// Probe round 7 (architecture held; concrete holes closed).
@Suite struct Round7GuardTests {
    static let rejects: [(String, String, String)] = [
        ("C1 cannot → can not", "We cannot go today.", "We can not go today."),
        ("C2 its → it's", "the dog wagged its tail", "The dog wagged it's tail."),
        ("C3 we'll → well", "we'll see", "Well, see."),
        ("C4 Tom's → Tom is", "Tom's car is here.", "Tom is car is here."),
        ("U1 zero-width space", "Send it now.", "Send it\u{200B} now."),
        ("U2 bidi control", "Send it now.", "Send it \u{202E}now."),
        ("U3 en dash range value changed", "Expect 10-20 people.", "Expect 10–21 people."),
        ("U4 em dash added", "I came I saw", "I came — I saw."),
        ("U5 currency swapped", "It costs $5.", "It costs £5."),
        ("S1 terminal type changed", "Is it ready. Yes it is.", "Is it ready? Yes it is."),
        ("S2 terminal removed", "Send it. Now.", "Send it now."),
        ("S3 terminal moved", "Send the report. To Sam today.", "Send the report to Sam. Today."),
        ("K1 WHO → Who", "The WHO said so.", "The Who said so."),
        ("K2 IT → It", "IT is down again.", "It is down again."),
        ("K3 US → us", "Ask the US team.", "Ask the us team."),
        ("K4 lower→upper mid-sentence", "send it to the team", "Send it to the Team."),
        ("N1 newline mid-sentence", "please send the report today", "Please send the\nreport today."),
    ]
    static let accepts: [(String, String)] = [
        ("Expect 10-20 people.", "Expect 10–20 people."),
        ("see you on tuesday", "See you on Tuesday."),
        ("the launch is in march", "The launch is in March."),
        ("thanks for that see you soon", "Thanks for that.\nSee you soon."),
        ("i think it works", "I think it works."),
        ("i'll call you back", "I'll call you back."),
    ]

    @Test func rejectsAll() {
        for (id, raw, out) in Self.rejects { #expect(!OutputGuard.check(raw: raw, output: out).isOK, "\(id)") }
    }

    @Test func acceptsAll() {
        for (raw, out) in Self.accepts {
            let v = OutputGuard.check(raw: raw, output: out)
            #expect(v.isOK, "\(raw) → \(out): \(v.summary)")
        }
    }

    /// The 10 everyday probe dictations (Parakeet-style input): target ≤ 1 false reject.
    static let everyday10: [(String, String)] = [
        ("can you send me the slides before the meeting", "Can you send me the slides before the meeting?"),
        ("thanks for the update i'll review it today", "Thanks for the update. I'll review it today."),
        ("see you on monday at 10", "See you on Monday at 10."),
        ("the build is green let's merge it", "The build is green. Let's merge it."),
        ("um can we push the release to friday", "Can we push the release to Friday?"),
        ("it costs twenty five pounds", "It costs 25 pounds."),
        ("don't merge until the tests pass", "Don't merge until the tests pass."),
        ("send it to John no wait to Mary", "Send it to John, no wait, to Mary."),
        ("first buy milk second call the plumber", "First, buy milk.\nSecond, call the plumber."),
        ("dear Sarah thanks for the quick turnaround best Sam", "Dear Sarah, thanks for the quick turnaround. Best, Sam."),
    ]

    @Test func everydayFalseRejectsAtMostOne() {
        let rejected = Self.everyday10.filter { !OutputGuard.check(raw: $0.0, output: $0.1).isOK }
        print("EVERYDAY10 false rejects: \(rejected.count) \(rejected.map(\.0))")
        #expect(rejected.count <= 1)
    }
}

@Suite struct TypingSafetyTests {
    /// A bare Return SENDS in chat apps — newlines must be Shift+Return.
    @Test func newlinesAreShiftReturnNeverBareReturn() {
        let plan = UnicodeTypingInserter.plan("Hi\nthere\r\nbye")
        #expect(plan.contains(.key(code: UInt16(kVK_Return), shift: true)))
        #expect(!plan.contains(.key(code: UInt16(kVK_Return), shift: false)))
        #expect(plan.filter { if case .key = $0 { return true } else { return false } }.count == 2)
        #expect(plan.first == .unicode(Array("Hi".utf16)))
    }
}
