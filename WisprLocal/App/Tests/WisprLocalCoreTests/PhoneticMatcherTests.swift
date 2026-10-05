import Testing
import Foundation
@testable import WisprLocalCore

/// The spelling snapper's decision table (dictionary terms always; context names opt-in). Each
/// row runs the REAL `SpellingSnapper`, so the false-positive guards are part of the table:
/// common words never snap, ambiguous candidates never snap, identifiers only in code apps.
@Suite struct PhoneticMatcherTests {
    struct Row: CustomTestStringConvertible, Sendable {
        var heard: String
        var vocabulary: [String] = []
        var names: [String] = []
        var identifiers: [String] = []
        var handles: [String] = []
        var codeApp = false
        var expected: String
        var testDescription: String { "\"\(heard)\" → \"\(expected)\"" }
    }

    static func run(_ r: Row) -> String {
        let ctx: ContextSnapshot? = r.names.isEmpty && r.identifiers.isEmpty && r.handles.isEmpty ? nil : ContextSnapshot(
            candidates: r.names.map { ContextCandidate($0, kind: .name) } + r.identifiers.map { ContextCandidate($0, kind: .identifier) }
                + r.handles.map { ContextCandidate($0, kind: .handle) },
            isCodeApp: r.codeApp)
        return SpellingSnapper(vocabulary: r.vocabulary, context: ctx).apply(r.heard).text
    }

    static let snaps: [Row] = [
        // Dictionary terms (always on)
        Row(heard: "we deploy on kuber netties", vocabulary: ["Kubernetes"], expected: "we deploy on Kubernetes"),
        Row(heard: "kubernetties is down", vocabulary: ["Kubernetes"], expected: "Kubernetes is down"),
        Row(heard: "we use kubernetes", vocabulary: ["Kubernetes"], expected: "we use Kubernetes"),
        Row(heard: "connect via tail scale", vocabulary: ["Tailscale"], expected: "connect via Tailscale"),
        Row(heard: "the post gress database", vocabulary: ["Postgres"], expected: "the Postgres database"),
        Row(heard: "send it as jason", vocabulary: ["JSON"], expected: "send it as JSON"),
        Row(heard: "ask anthropik", vocabulary: ["Anthropic"], expected: "ask Anthropic"),
        Row(heard: "open x code", vocabulary: ["Xcode"], expected: "open Xcode"),
        Row(heard: "store it in mongo DB", vocabulary: ["MongoDB"], expected: "store it in MongoDB"),
        Row(heard: "write it in type script", vocabulary: ["TypeScript"], expected: "write it in TypeScript"),
        Row(heard: "plan with terra form", vocabulary: ["Terraform"], expected: "plan with Terraform"),
        Row(heard: "an app in next JS", vocabulary: ["Next.js"], expected: "an app in Next.js"),
        Row(heard: "ask chat GPT", vocabulary: ["ChatGPT"], expected: "ask ChatGPT"),
        Row(heard: "kuber netties, then docker", vocabulary: ["Kubernetes"], expected: "Kubernetes, then docker"),
        // Context names (opt-in)
        Row(heard: "Thanks Sean, see you", names: ["Shaun"], expected: "Thanks Shaun, see you"),
        Row(heard: "Shawn said yes", names: ["Shaun"], expected: "Shaun said yes"),
        Row(heard: "Sean's draft", names: ["Shaun"], expected: "Shaun's draft"),
        Row(heard: "cc Jon please", names: ["John"], expected: "cc John please"),
        Row(heard: "Steven agreed", names: ["Stephen"], expected: "Stephen agreed"),
        Row(heard: "Katherine will join", names: ["Catherine"], expected: "Catherine will join"),
        Row(heard: "Phillip is out", names: ["Philip"], expected: "Philip is out"),
        Row(heard: "Mohammed replied", names: ["Muhammad"], expected: "Muhammad replied"),
        Row(heard: "Bryan is late", names: ["Brian"], expected: "Brian is late"),
        Row(heard: "Kaitlyn sent it", names: ["Caitlin"], expected: "Caitlin sent it"),
        Row(heard: "Meghan called", names: ["Megan"], expected: "Megan called"),
        Row(heard: "Lindsey wrote", names: ["Lindsay"], expected: "Lindsay wrote"),
        Row(heard: "Geoff knows", names: ["Jeff"], expected: "Jeff knows"),
        Row(heard: "ask Alan", names: ["Allen"], expected: "ask Allen"),
        Row(heard: "Rachael is here", names: ["Rachel"], expected: "Rachel is here"),
        Row(heard: "tell Gemma", names: ["Jemma"], expected: "tell Jemma"),
        // Identifiers (code apps only, exact key) and handles (after "at", exact key)
        Row(heard: "call get user by id", identifiers: ["getUserById"], codeApp: true, expected: "call getUserById"),
        Row(heard: "check user id", identifiers: ["user_id"], codeApp: true, expected: "check user_id"),
        Row(heard: "ping at sam lee", handles: ["@sam_lee"], expected: "ping @sam_lee"),
    ]

    static let neverSnaps: [Row] = [
        // Common words are protected, whatever the candidates say
        Row(heard: "put it over their", vocabulary: ["There"], expected: "put it over their"),
        Row(heard: "over there now", names: ["Their"], expected: "over there now"),
        Row(heard: "their car", vocabulary: ["there"], expected: "their car"),
        Row(heard: "mark it done", names: ["Marc"], expected: "mark it done"),
        Row(heard: "a new man", names: ["Newman"], expected: "a new man"),
        Row(heard: "the cat sat", names: ["Kat"], expected: "the cat sat"),
        Row(heard: "hello again", vocabulary: ["Hallo"], expected: "hello again"),
        // Ambiguous: two strong candidates → no change
        Row(heard: "Sean said", names: ["Shaun", "Shane"], expected: "Sean said"),
        Row(heard: "Shawn said", names: ["Shaun", "Sean"], expected: "Shawn said"),
        // Too different / too short / too long
        Row(heard: "kuber is fine", vocabulary: ["Kubernetes"], expected: "kuber is fine"),
        Row(heard: "Dan agreed", names: ["Diane"], expected: "Dan agreed"),
        Row(heard: "Kate agreed", names: ["Tate"], expected: "Kate agreed"),
        Row(heard: "Alice agreed", names: ["Alex"], expected: "Alice agreed"),
        Row(heard: "Steve agreed", names: ["Stephen"], expected: "Steve agreed"),
        // Already right: unchanged, no count
        Row(heard: "Stephen agreed", names: ["Steven", "Stephen"], expected: "Stephen agreed"),
        Row(heard: "we use Kubernetes", vocabulary: ["Kubernetes"], expected: "we use Kubernetes"),
        // Identifiers never outside code apps, never fuzzy; handles never without "at"
        Row(heard: "call get user by id", identifiers: ["getUserById"], codeApp: false, expected: "call get user by id"),
        Row(heard: "call get user by ids", identifiers: ["getUserById"], codeApp: true, expected: "call get user by ids"),
        Row(heard: "sam lee is here", handles: ["@sam_lee"], expected: "sam lee is here"),
        // R2: every heard word is a real English word and the joined form isn't the term
        // exactly, so it is never guessed (a Replacement rule fixes these for good).
        Row(heard: "ask claud about it", vocabulary: ["Claude"], expected: "ask claud about it"),
        Row(heard: "train it in pie torch", vocabulary: ["PyTorch"], expected: "train it in pie torch"),
        Row(heard: "push to get hub", vocabulary: ["GitHub"], expected: "push to get hub"),
        // Numbers are never touched
        Row(heard: "version 26 ships", vocabulary: ["Version26"], expected: "version 26 ships"),
    ]

    @Test(arguments: snaps) func snapsStrongUniqueMatches(_ r: Row) {
        #expect(Self.run(r) == r.expected)
    }

    @Test(arguments: neverSnaps) func neverSnapsFalsePositives(_ r: Row) {
        #expect(Self.run(r) == r.expected)
    }

    @Test func tableIsBigEnough() {
        #expect(Self.snaps.count + Self.neverSnaps.count >= 40)
        #expect(Self.neverSnaps.count >= 15)
    }

    @Test func countsVocabularyAndContextSeparately() {
        let ctx = ContextSnapshot(candidates: [ContextCandidate("Shaun", kind: .name)], isCodeApp: false)
        let r = SpellingSnapper(vocabulary: ["Kubernetes"], context: ctx).apply("Sean runs kuber netties")
        #expect(r.text == "Shaun runs Kubernetes")
        #expect(r.contextSnaps == 1)
        #expect(r.vocabularySnaps == 1)
    }

    @Test func phoneticCodes() {
        #expect(Phonetics.code("Kubernetes") == "KPRNTS")
        #expect(Phonetics.code("kubernetties") == "KPRNTS")
        #expect(Phonetics.looseCode("Sean") == Phonetics.looseCode("Shaun"))
        #expect(Phonetics.code("Knight") == "NT")
        #expect(Phonetics.code("Philip") == "FLP")
        #expect(Phonetics.code("Xavier") == "SFR")
        #expect(Phonetics.editDistance("kitten", "sitting") == 3)
        #expect(Phonetics.key("get_user-By ID!") == "getuserbyid")
    }

    @Test func matcherIsSymmetricAndRejectsNonsense() {
        for (a, b) in [("Sean", "Shaun"), ("kubernetties", "Kubernetes"), ("Jon", "John")] {
            #expect(PhoneticMatcher.isStrongMatch(heard: a, candidate: b))
            #expect(PhoneticMatcher.isStrongMatch(heard: b, candidate: a))
        }
        #expect(!PhoneticMatcher.isStrongMatch(heard: "", candidate: "x"))
        #expect(!PhoneticMatcher.isStrongMatch(heard: "meeting", candidate: "call"))
    }

    @Test func commonWordsAreProtected() {
        for w in ["their", "there", "they're", "the", "and", "mark", "new", "user"] { #expect(CommonWords.contains(w), "\(w)") }
        for w in ["Kubernetes", "Shaun", "Tailscale"] { #expect(!CommonWords.contains(w), "\(w)") }
    }
}
