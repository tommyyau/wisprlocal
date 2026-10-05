import Testing
import Foundation
@testable import WisprLocalCore

/// A fixed word list standing in for the system spell checker.
struct FixedLexicon: EnglishLexicon {
    var words: Set<String>
    init(_ words: Set<String>) { self.words = words }
    func isWord(_ lowercased: String) -> Bool { words.contains(lowercased) }
}

/// The real-word guard (R2) with an injected lexicon, the snapper index (P2) and its budget.
@Suite struct SnapperLexiconTests {
    static let lex = FixedLexicon(["the", "cloud", "tail", "scale", "pie", "torch", "post", "some", "slack", "on", "we", "deploy"])

    func snap(_ s: String, _ vocab: [String], lexicon: EnglishLexicon = lex, tombstones: Set<String> = []) -> String {
        SpellingSnapper(vocabulary: vocab, tombstones: tombstones, lexicon: lexicon).apply(s).text
    }

    @Test func aWordTheLexiconKnowsIsNeverSnapped() {
        #expect(snap("upload to the cloud", ["Claude"]) == "upload to the cloud")
        // The same sound, not a word: snapped.
        #expect(snap("upload to the claud", ["Claude"]) == "upload to the Claude")
        // Nothing is a word → the old behaviour (the guard is the ONLY thing that changed).
        #expect(snap("upload to the cloud", ["Claude"], lexicon: FixedLexicon([])) == "upload to the Claude")
    }

    @Test func caseOnlyFixesOnlyForNonWords() {
        #expect(snap("cut me some slack", ["Slack"]) == "cut me some slack")
        #expect(snap("we deploy kubernetes", ["Kubernetes"]) == "we deploy Kubernetes")
    }

    @Test func phrasesNeedANonWordOrAnExactJoinedTerm() {
        #expect(snap("we deploy on kuber netties", ["Kubernetes"]) == "we deploy on Kubernetes")   // non-words
        #expect(snap("connect via tail scale", ["Tailscale"]) == "connect via Tailscale")           // exact joined term
        #expect(snap("the post gress db", ["Postgres"]) == "the Postgres db")                       // one non-word
        #expect(snap("train in pie torch", ["PyTorch"]) == "train in pie torch")                    // all words, fuzzy
    }

    @Test func closedClassWordsNeverSnap() {
        // The system lexicon calls lowercase "tuesday" a misspelt proper noun; it still never snaps.
        #expect(snap("meet on tuesday", ["Tuesdei"], lexicon: FixedLexicon([])) == "meet on tuesday")
        #expect(snap("about fifteen", ["Fifteenn"], lexicon: FixedLexicon([])) == "about fifteen")
    }

    /// The index changes cost, not answers: the snapper agrees with a brute-force scan of every
    /// candidate through `PhoneticMatcher.isStrongMatch` (with the real-word guard off).
    @Test func indexMatchesBruteForce() {
        let vocab = ["Kubernetes", "Tailscale", "Postgres", "Claude", "Shaun", "Stephen", "Catherine", "Philip",
                     "Megan", "Brian", "Anthropic", "JSON", "Terraform", "Lindsay", "Caitlin", "Muhammad"]
        let heard = ["kubernetties", "kubernetes", "tailscail", "postgress", "claud", "clowd", "cloud", "sean", "shawn",
                     "steven", "katherine", "phillip", "meghan", "bryan", "brain", "anthropik", "jason", "teraform",
                     "lindsey", "kaitlyn", "mohammed", "zebra", "keyboard", "shine", "stiffen"]
        let none = FixedLexicon([])
        let s = SpellingSnapper(vocabulary: vocab, lexicon: none)
        for h in heard where !CommonWords.contains(h) {
            let brute = vocab.filter { PhoneticMatcher.isStrongMatch(heard: h, candidate: $0) }
            let expected = brute.count == 1 && brute[0] != h ? brute[0] : h
            #expect(s.apply(h).text == expected, "\(h)")
        }
    }

    /// P2 budget: 200 words against 600 terms in under 5 ms of CPU, in the DEBUG test build.
    /// Measured on a user-interactive thread (performance cores) as the minimum of at least 10
    /// runs. (Before the index the review measured ~46 ms even with -O.)
    @Test func snapperBudget() async {
        var terms: [String] = []
        let syll = ["ka", "lo", "mi", "ter", "zan", "qu", "vex", "bor", "nix", "dal", "pra", "sho"]
        var n = 0
        outer: for a in syll { for b in syll { for c in syll {
            terms.append((a + b + c).capitalized); n += 1
            if n == 600 { break outer }
        } } }
        let words = ["we", "deploy", "kuber", "netties", "to", "the", "kalomi", "cluster", "and", "ask", "shaun",
                     "about", "terzan", "tomorrow", "please", "quvex", "bornix", "dalpra", "on", "monday"]
        let text = (0..<10).map { _ in words.joined(separator: " ") }.joined(separator: " ")
        #expect(text.split(separator: " ").count == 200)
        let s = SpellingSnapper(vocabulary: terms + ["Kubernetes", "Shaun"], lexicon: FixedLexicon([]))
        let best: Double = await withCheckedContinuation { cont in
            let t = Thread {
                _ = s.apply(text)
                var best = Double.infinity
                // While the rest of the suite runs in parallel, CPU time inflates (shared caches,
                // malloc contention), so keep sampling — up to 8 s — until one quiet run is seen.
                let deadline = Date().addingTimeInterval(8)
                var runs = 0
                while runs < 10 || (best >= 5 * TimingBudget.scale && Date() < deadline) {
                    let t0 = Self.cpuNanos()
                    _ = s.apply(text)
                    best = min(best, Double(Self.cpuNanos() - t0) / 1e6)
                    runs += 1
                    if runs >= 10, best >= 5 * TimingBudget.scale { Thread.sleep(forTimeInterval: 0.05) }
                }
                cont.resume(returning: best)
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
        #expect(best < 5 * TimingBudget.scale, "snapper took \(best) ms CPU (budget scale \(TimingBudget.scale))")
    }

    static func cpuNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
}

/// The real system lexicon: offline (this suite also runs under `scripts/test_offline.sh` with all
/// network denied), English, and the lowercase rule the guard relies on.
@Suite struct SystemLexiconTests {
    @Test func knowsOrdinaryWordsAndFlagsInventedOnes() {
        let l = SystemEnglishLexicon()
        for w in ["cloud", "cluster", "slack", "linear", "their", "there", "brain", "mirror"] { #expect(l.isWord(w), "\(w)") }
        for w in ["kubernetties", "kuber", "netties", "anthropik", "tailscale", "sean", "shawn"] { #expect(!l.isWord(w), "\(w)") }
    }
}
