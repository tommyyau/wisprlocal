import Foundation

/// Deterministic, on-device phonetic matching used by the smart dictionary (spelling snapping,
/// correction learning). No model, no network: a Double Metaphone–style consonant skeleton
/// (primary code, the common English rules) plus a normalised Levenshtein distance.
///
/// "Strong match" (`PhoneticMatcher.isStrongMatch`) is deliberately conservative:
/// - both keys have ≥ 3 letters and their lengths are within 60 % of each other;
/// - the loose phonetic codes are IDENTICAL (sibilants S/SH and T/TH folded together);
/// - the normalised edit distance of the letter keys is ≤ 0.45.
/// Exact key equality ("get user by id" ↔ `getUserById`) is always strong.
public enum Phonetics {
    /// Lowercased letters and digits only: "Kubernetes," → "kubernetes", "get_user" → "getuser".
    public static func key(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// Metaphone-style primary code of one word (or a joined phrase key). Letters only.
    /// Works on ASCII bytes (it runs for every snapper window: P2); the rules are unchanged.
    public static func code(_ word: String) -> String {
        var w: [UInt8] = []
        w.reserveCapacity(word.utf8.count)
        if word.utf8.allSatisfy({ $0 < 128 }) {
            for b in word.utf8 {
                if b >= 97, b <= 122 { w.append(b - 32) } else if b >= 65, b <= 90 { w.append(b) }
            }
        } else {
            // Non-ASCII: uppercase first ("ß" → "SS"), then keep the ASCII letters.
            for ch in word.uppercased() where ch.isASCII && ch.isLetter { w.append(ch.asciiValue!) }
        }
        var out: [UInt8] = []
        codeBytes(w, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// The code of `w` (UPPERCASE ASCII letters only) into `out`, which is cleared first. No
    /// allocation once `out` has capacity: the snapper calls it for every window (P2).
    static func codeBytes(_ w: [UInt8], into out: inout [UInt8]) {
        out.removeAll(keepingCapacity: true)
        guard !w.isEmpty else { return }
        let n = w.count
        let A = UInt8(ascii: "A"), B = UInt8(ascii: "B"), C = UInt8(ascii: "C"), D = UInt8(ascii: "D"),
            E = UInt8(ascii: "E"), F = UInt8(ascii: "F"), G = UInt8(ascii: "G"), H = UInt8(ascii: "H"),
            I = UInt8(ascii: "I"), J = UInt8(ascii: "J"), K = UInt8(ascii: "K"), M = UInt8(ascii: "M"),
            N = UInt8(ascii: "N"), O = UInt8(ascii: "O"), P = UInt8(ascii: "P"), Q = UInt8(ascii: "Q"),
            R = UInt8(ascii: "R"), S = UInt8(ascii: "S"), T = UInt8(ascii: "T"), U = UInt8(ascii: "U"),
            V = UInt8(ascii: "V"), W = UInt8(ascii: "W"), X = UInt8(ascii: "X"), Y = UInt8(ascii: "Y"),
            Z = UInt8(ascii: "Z"), zero = UInt8(ascii: "0")
        func at(_ i: Int) -> UInt8 { i >= 0 && i < n ? w[i] : 0 }
        func vowel(_ b: UInt8) -> Bool { b == A || b == E || b == I || b == O || b == U }
        func isVowel(_ i: Int) -> Bool { vowel(at(i)) }
        func front(_ b: UInt8) -> Bool { b == I || b == E || b == Y }
        var i = 0
        // Initial exceptions.
        if n >= 2 {
            let (f0, f1) = (w[0], w[1])
            if (f0 == K && f1 == N) || (f0 == G && f1 == N) || (f0 == P && f1 == N) || (f0 == W && f1 == R) || (f0 == A && f1 == E) { i = 1 }
            else if f0 == W && f1 == H { out.append(W); i = 2 }
        }
        if i == 0, w[0] == X { out.append(S); i = 1 }
        while i < n {
            let c = w[i]
            if i > 0, c == w[i - 1], c != C { i += 1; continue }   // doubled letters
            switch c {
            case A, E, I, O, U:
                if i == 0 { out.append(A) }
            case B:
                if !(i == n - 1 && at(i - 1) == M) { out.append(P) }
            case C:
                if at(i + 1) == I, at(i + 2) == A { out.append(X) }
                else if at(i + 1) == H {
                    out.append(at(i - 1) == S ? K : X); i += 1
                } else if front(at(i + 1)) {
                    if at(i - 1) != S { out.append(S) }
                } else if at(i + 1) == K || (at(i + 1) == C && !front(at(i + 2))) {
                    out.append(K); i += 1
                } else { out.append(K) }
            case D:
                if at(i + 1) == G, at(i + 2) == E || at(i + 2) == I || at(i + 2) == Y { out.append(J); i += 2 }
                else { out.append(T) }
            case G:
                if at(i + 1) == H {
                    if i == 0 || isVowel(i + 2) { out.append(K) }
                    i += 1
                } else if at(i + 1) == N {
                    // silent in "sign", "gnome" (initial handled above)
                } else if front(at(i + 1)) {
                    out.append(J)
                } else { out.append(K) }
            case H:
                let prev = at(i - 1)
                if isVowel(i + 1), i == 0 || !(prev == C || prev == G || prev == P || prev == S || prev == T) { out.append(H) }
            case K:
                if at(i - 1) != C { out.append(K) }
            case P:
                if at(i + 1) == H { out.append(F); i += 1 } else { out.append(P) }
            case Q: out.append(K)
            case S:
                if at(i + 1) == H { out.append(X); i += 1 }
                else if at(i + 1) == I, at(i + 2) == O || at(i + 2) == A { out.append(X) }
                else if at(i + 1) == C, at(i + 2) == H { out.append(S); out.append(K); i += 2 }
                else { out.append(S) }
            case T:
                if at(i + 1) == I, at(i + 2) == O || at(i + 2) == A { out.append(X) }
                else if at(i + 1) == H { out.append(zero); i += 1 }
                else if at(i + 1) == C, at(i + 2) == H { /* "tch": the CH codes it */ }
                else { out.append(T) }
            case V: out.append(F)
            case W, Y:
                // Consonantal only at the start ("Will", "Yvonne"); otherwise a vowel ("Bryan").
                if i == 0, isVowel(i + 1) { out.append(c) }
            case X: out.append(K); out.append(S)
            case Z: out.append(S)
            default: out.append(c)   // F J L M N R
            }
            i += 1
        }
        _ = (R, F, J, N)
        // Collapse runs produced by different letters ("CK" → "K" already; "SS" from "SZ").
        collapseRuns(&out)
    }

    /// Removes consecutive duplicates in place.
    static func collapseRuns(_ out: inout [UInt8]) {
        guard out.count > 1 else { return }
        var k = 1
        for j in 1..<out.count where out[j] != out[k - 1] { out[k] = out[j]; k += 1 }
        out.removeLast(out.count - k)
    }

    /// Folds a code in place into its loose form (X → S, 0 → T, runs collapsed).
    static func loosen(_ code: inout [UInt8]) {
        for j in code.indices {
            if code[j] == UInt8(ascii: "X") { code[j] = UInt8(ascii: "S") } else if code[j] == UInt8(ascii: "0") { code[j] = UInt8(ascii: "T") }
        }
        collapseRuns(&code)
    }

    /// The code with sibilants (X → S) and TH (0 → T) folded: "Sean" ≈ "Shaun", "Thom" ≈ "Tom".
    public static func looseCode(_ word: String) -> String {
        var c = Array(code(word).utf8)
        loosen(&c)
        return String(decoding: c, as: UTF8.self)
    }

    /// Levenshtein distance.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Edit distance divided by the longer length (0 = identical, 1 = nothing in common).
    public static func normalisedDistance(_ a: String, _ b: String) -> Double {
        let m = max(a.count, b.count)
        return m == 0 ? 0 : Double(editDistance(a, b)) / Double(m)
    }
}

/// The one place the snapping / learning thresholds live (`PhoneticMatcherTests` pins them).
public enum PhoneticMatcher {
    public static let maxNormalisedDistance = 0.45
    public static let minKeyLength = 3
    public static let minLengthRatio = 0.6

    /// Conservative "sounds like and is spelled close to". `heard` and `candidate` are any
    /// strings; they are compared by `Phonetics.key` (letters/digits, joined).
    public static func isStrongMatch(heard: String, candidate: String) -> Bool {
        let c = Phonetics.key(candidate)
        return isStrongMatch(heardKey: Phonetics.key(heard), candidateKey: c, candidateLoose: Phonetics.looseCode(c))
    }

    /// Same, on precomputed keys (`SpellingSnapper`'s index stores each candidate's loose code).
    static func isStrongMatch(heardKey h: String, candidateKey c: String, candidateLoose cc: String) -> Bool {
        guard !h.isEmpty, !c.isEmpty else { return false }
        if h == c { return true }
        guard h.count >= minKeyLength, c.count >= minKeyLength else { return false }
        let ratio = Double(min(h.count, c.count)) / Double(max(h.count, c.count))
        guard ratio >= minLengthRatio else { return false }
        guard cc.count >= 2, Phonetics.looseCode(h) == cc else { return false }
        // Short names differ by at most one letter ("Jon" ↔ "John", never "Dan" ↔ "Diane").
        if min(h.count, c.count) <= 3, Phonetics.editDistance(h, c) > 1 { return false }
        return Phonetics.normalisedDistance(h, c) <= maxNormalisedDistance
    }
}
