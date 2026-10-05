import Testing
@testable import WisprLocalCore

@Suite struct RuleCleanerTests {
    let c = RuleCleaner()

    @Test(arguments: [
        // "like" survives everywhere except ", like,"
        ("I'd like us to meet on Tuesday.", "I'd like us to meet on Tuesday."),
        ("I like this approach.", "I like this approach."),
        ("It looks like rain.", "It looks like rain."),
        ("I'd like, if possible, a refund.", "I'd like, if possible, a refund."),
        ("It takes something like, 5 minutes.", "It takes something like, 5 minutes."),
        ("Like, I don't know.", "Like, I don't know."),
        ("It was, like, really big.", "It was really big."),
        ("So, like, you know, it's fine.", "So, you know, it's fine."),   // round 4: "So,"/"Well," carry meaning — kept
        ("It was fine, like, you know, really.", "It was fine, you know, really."),
        ("Well, the water is safe.", "Well, the water is safe."),
        ("Uh-huh, that works.", "Uh-huh, that works."),
        ("Uh-uh, don't do that.", "Uh-uh, don't do that."),
        ("Er the second one.", "Er the second one."),
        ("Er, the second one.", "The second one."),
        ("It took, like, 5 minutes.", "It took, like, 5 minutes."),
        ("It took, like, ten minutes.", "It took, like, ten minutes."),   // single number words stay
        ("It was, like, huge.", "It was huge."),
        ("The dose is 2.5 mg. Scratch that.", ""),
        ("Call Dr. Smith today. Scratch that, call Jones.", "Call Jones."),
        ("Ship it to the U.S. office. Scratch that. Ship it to Canada.", "Ship it to Canada."),
        ("Release v1.3 today. Scratch that.", ""),
        ("Should I scratch that? Scratch that?", "Should I scratch that? Scratch that?"),
        // Final: standalone "scratch that" deletes EVERYTHING before it (no cancelled fragments).
        ("Meet at 5 p.m. Friday. Scratch that.", ""),
        ("Cancel order No. 5. Scratch that.", ""),
        ("Do not ship to St. Louis. Scratch that.", ""),
        ("A. Scratch that. B.", "B."),
        ("Book Friday. Then lunch. Scratch that, book Thursday.", "Book Thursday."),
        ("Well water is safe.", "Well water is safe."),
        ("Send it Tuesday, no wait, Wednesday.", "Send it Tuesday, no wait, Wednesday."),   // corrections verbatim
        ("We sold three thousand fifty units.", "We sold 3050 units."),
        ("New line.", "\n"),
        ("new paragraph", "\n\n"),
        ("New paragraph!", "\n\n"),
        // fillers: lowercase tokens or Capitalised at sentence start; never ALL-CAPS
        ("Um, so I think we should go.", "So I think we should go."),
        ("I was, uh, going to call.", "I was going to call."),
        ("So, um, I think so.", "So I think so."),
        ("I think, um.", "I think."),
        ("Um.", ""),
        ("Hmm, let me think. Ah, right.", "Let me think. Right."),
        ("We took him to the ER last night.", "We took him to the ER last night."),
        ("UM is a university.", "UM is a university."),
        ("Her Ahmed and Erma.", "Her Ahmed and Erma."),
        // the maintainer's first real dictation: capitalised "Um" with no comma, mid-text "um"
        ("Um okay the", "Okay the"),
        ("It's kind of a little bit better now. Um okay, uh the", "It's kind of a little bit better now. Okay the"),
        ("Yeah, that's the um best one. Um can you update the icon?", "Yeah, that's the best one. Can you update the icon?"),
        ("Hmm okay. Uh so we go.", "Okay. So we go."),
        ("Erm let me check.", "Let me check."),
        ("I said Um to him.", "I said to him."),
        ("Uhm, right.", "Right."),
        ("UH is a hospital.", "UH is a hospital."),          // ALL-CAPS may be an acronym
        ("Uh-huh. Uh-uh.", "Uh-huh. Uh-uh."),
        ("Ah okay.", "Ah okay."),                            // ambiguous: capitalised w/o comma kept
        ("Ah, okay.", "Okay."),
        ("Erik and Umberto came.", "Erik and Umberto came."),
        ("Hummus and umbrellas.", "Hummus and umbrellas."),
        // commands only as standalone sentences
        ("Let's meet at noon. Scratch that. Let's meet at one.", "Let's meet at one."),
        ("First thing. Second thing. Scratch that.", ""),   // final: deletes everything before it
        ("Scratch that, let's go.", "Let's go."),
        ("Let's scratch that plan.", "Let's scratch that plan."),
        ("Buy milk scratch that", "Buy milk scratch that"),
        ("Hi Sam. New line. Thanks for the notes.", "Hi Sam.\nThanks for the notes."),
        ("First point. New paragraph. Second point.", "First point.\n\nSecond point."),
        ("Done! new line, next item.", "Done!\nNext item."),
        ("We launched a new line of products.", "We launched a new line of products."),
        ("Start a new paragraph here.", "Start a new paragraph here."),
        ("Dear John, new line, thanks.", "Dear John, new line, thanks."),
        // Parakeet's punctuation and casing untouched
        ("Deploy Kubernetes 1.30 e.g. on iPhone and macOS at 3 p.m.", "Deploy Kubernetes 1.30 e.g. on iPhone and macOS at 3 p.m."),
        ("You know what, that's fine.", "You know what, that's fine."),
        ("It's, you know, fine.", "It's fine."),
        ("I mean, it works.", "I mean, it works."),   // round 3: corrections/cues left verbatim
        ("I mean it.", "I mean it."),
    ])
    func cleans(_ input: String, _ expected: String) {
        #expect(c.cleanSync(input) == expected)
    }
}
