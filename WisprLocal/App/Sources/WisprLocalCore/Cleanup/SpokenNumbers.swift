import Foundation

/// Deterministic spoken-number parser + pre-pass (P2.1-final rule 1: numbers are NOT the
/// model's job). `convert` turns number words into digits only where the reading is unambiguous
/// (multi-word cardinals, decimals, percentages, version numbers after a name); anything else
/// ("nineteen ninety", "seven forty five", "one or two", single words in prose, ordinals) is
/// left exactly as spoken. See `convert` for the full rule list.
public enum SpokenNumbers {
    static let units: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                                       "seven": 7, "eight": 8, "nine": 9]
    static let teens: [String: Int] = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
                                       "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                                      "seventy": 70, "eighty": 80, "ninety": 90]
    static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil || w == "hundred" || scales[w] != nil
    }

    /// Parses a whole run of lowercase words as ONE cardinal, or nil if it isn't exactly one
    /// (e.g. "nineteen ninety" = two juxtaposed numbers → nil).
    public static func parse(_ words: [String]) -> Int? {
        enum Last { case none, unit, teen, ten, hundred, scale, and }
        guard !words.isEmpty else { return nil }
        var total = 0, group = 0, last = Last.none
        var groupHasHundred = false, tenHasUnit = false
        var lastScale = Int.max
        for (i, w) in words.enumerated() {
            if w == "and" {
                guard last == .hundred || last == .scale, i + 1 < words.count else { return nil }
                last = .and; continue
            }
            if w == "a" {
                guard i == 0, i + 1 < words.count, words[i + 1] == "hundred" || scales[words[i + 1]] != nil else { return nil }
                group = 1; last = .unit; continue
            }
            if let u = units[w] {
                switch last {
                case .none, .hundred, .scale, .and: group += u
                case .ten where !tenHasUnit: group += u; tenHasUnit = true
                default: return nil
                }
                last = .unit
            } else if let t = teens[w] {
                guard [.none, .hundred, .scale, .and].contains(last) else { return nil }
                group += t; last = .teen
            } else if let t = tens[w] {
                guard [.none, .hundred, .scale, .and].contains(last) else { return nil }
                group += t; last = .ten; tenHasUnit = false
            } else if w == "hundred" {
                guard [.unit, .teen, .ten].contains(last), !groupHasHundred, (1...99).contains(group) else { return nil }
                group *= 100; groupHasHundred = true; last = .hundred
            } else if let s = scales[w] {
                guard group >= 1, s < lastScale, [.unit, .teen, .ten, .hundred].contains(last) else { return nil }
                total += group * s; group = 0; groupHasHundred = false; lastScale = s; last = .scale
            } else {
                return nil
            }
        }
        guard last != .and else { return nil }
        return total + group
    }

    // MARK: - Pre-pass

    static let digitWords: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                                            "six": 6, "seven": 7, "eight": 8, "nine": 9]
    /// Words after which a bare "point five" (no integer part) is a quantity → "0.5".
    static let unitWords: Set<String> = [
        "percent", "per", "x",
        "mg", "milligram", "milligrams", "g", "gram", "grams", "kg", "kilo", "kilos", "kilogram", "kilograms",
        "ml", "millilitre", "millilitres", "milliliter", "milliliters", "litre", "litres", "liter", "liters",
        "mm", "millimetre", "millimetres", "millimeter", "millimeters", "cm", "centimetre", "centimetres",
        "centimeter", "centimeters", "metre", "metres", "meter", "meters", "km", "kilometre", "kilometres",
        "kilometer", "kilometers", "inch", "inches", "foot", "feet", "mile", "miles",
        "ms", "millisecond", "milliseconds", "second", "seconds", "minute", "minutes", "hour", "hours",
        "day", "days", "week", "weeks", "month", "months", "year", "years",
        "pound", "pounds", "dollar", "dollars", "euro", "euros", "pence", "cent", "cents",
        "kb", "mb", "gb", "tb", "kilobytes", "megabytes", "gigabytes", "terabytes", "degree", "degrees",
        "volt", "volts", "watt", "watts", "stars", "star", "points",
    ]
    /// Product words (any case) after which a number is a version: "GPT five" → "GPT 5".
    static let productWords: Set<String> = [
        "version", "gpt", "chatgpt", "ios", "ipados", "macos", "watchos", "visionos", "tvos", "iphone", "ipad",
        "xcode", "android",
    ]
    /// Product names that count only when Capitalised ("Swift six" yes, "a swift two weeks" no).
    static let capitalisedProducts: Set<String> = [
        "Windows", "Python", "Swift", "Sol", "Gemini", "Llama", "Opus", "Sonnet", "Haiku", "Ubuntu", "Java",
        "Kotlin", "Pixel", "Galaxy", "Fable",
    ]
    /// All-caps words that are not version-bearing names.
    static let nonNameAcronyms: Set<String> = ["OK", "AM", "PM"]

    static let wordRegex = try! NSRegularExpression(pattern: "[A-Za-z]+")
    /// "6 point 1" (digits already) → "6.1".
    static let digitPoint = try! NSRegularExpression(pattern: #"(?<![\w.])(\d+)[ \t]+point[ \t]+(\d+)(?![\w.])"#,
                                                     options: [.caseInsensitive])
    /// "50 percent" / "2.5 per cent" → "50%" / "2.5%".
    static let digitPercent = try! NSRegularExpression(pattern: #"(?<![\w.])(\d+(?:\.\d+)?)[ \t]+per[ \t]?cent\b"#,
                                                       options: [.caseInsensitive])

    enum NameKind { case none, weak, strong, joined }

    /// How a word before a number reads as a name:
    /// - `.joined`: "v" / "V" → "v2" (no space).
    /// - `.strong`: product word ("version", "GPT", "iPhone"), an acronym ("GPT"), a mixed-case
    ///   name ("macOS", "iPhone"), a known Capitalised product ("Sol", "Swift"), or a dictionary
    ///   term → the following number ALWAYS becomes digits.
    /// - `.weak`: any other Capitalised word that is not sentence-initial (and not "I") → digits
    ///   only when the number ends the clause ("I met Tom three times" stays; "on Sol six." → "Sol 6.").
    static func nameKind(_ surface: String, sentenceInitial: Bool, vocabulary: Set<String>) -> NameKind {
        if surface == "v" || surface == "V" { return .joined }
        if productWords.contains(surface.lowercased()) || capitalisedProducts.contains(surface)
            || vocabulary.contains(surface) { return .strong }
        guard let first = surface.first, first.isUppercase || surface.dropFirst().contains(where: \.isUppercase) else { return .none }
        if surface.count >= 2, surface.allSatisfy(\.isUppercase), !nonNameAcronyms.contains(surface) { return .strong }
        if surface.dropFirst().contains(where: \.isUppercase) && surface.contains(where: \.isLowercase) { return .strong }
        if surface == "I" || surface == "A" || sentenceInitial || isNumberWord(surface.lowercased()) { return .none }
        return .weak
    }

    /// Converts spoken numbers to digits (deterministic; English only — the language gate skips
    /// other languages). Rules:
    /// 1. A run of >= 2 number words that parses as ONE cardinal → digits ("twenty five" → 25,
    ///    "a hundred" → 100). "nineteen ninety", "seven forty five", "ten thirty", "one or two" stay.
    /// 2. Decimals: `<number> point <digit words>` → "6.1", "3.14", "0.5" ("zero point five"); each
    ///    digit after "point" is spoken singly ("one four" → 14), or one tens/teens number ("point
    ///    twenty five" → .25). A following scale stays a word ("2.5 million"). "at one point" stays.
    ///    A bare "point five" → "0.5" only before a unit or percent ("point five mg" → "0.5 mg");
    ///    "the point is", "on point", "point taken" stay.
    /// 3. Versions: a number after a name → digits, even a single word ("GPT five" → "GPT 5",
    ///    "iPhone seventeen" → "iPhone 17", "version two" → "version 2", "v two" → "v2"); see
    ///    `nameKind`. No hyphens are ever invented.
    /// 4. Percent: `<number> percent` → "50%" (also "5 percent" → "5%").
    /// 5. Units and currency words are never mapped to symbols ("five pounds" stays; "two point five
    ///    kilos" → "2.5 kilos"). Single number words in prose stay words, INCLUDING ten and above
    ///    ("one of the", "twelve people") — unchanged from the original pre-pass.
    /// Hyphens join a run ("twenty-five"); any other punctuation ends it ("five, six" stays).
    public static func convert(_ text: String, vocabulary: [String] = []) -> String {
        let ns = text as NSString
        let matches = wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let toks: [(w: String, s: String, r: NSRange)] = matches.map {
            let s = ns.substring(with: $0.range); return (s.lowercased(), s, $0.range)
        }
        let vocab = Set(vocabulary.compactMap { $0.split(separator: " ").last.map(String.init) })
        let n = toks.count
        func gap(_ a: Int, _ b: Int) -> String {
            let ra = toks[a].r, rb = toks[b].r
            return ns.substring(with: NSRange(location: ra.location + ra.length, length: rb.location - ra.location - ra.length))
        }
        func joinable(_ a: Int, _ b: Int) -> Bool { let g = gap(a, b); return !g.isEmpty && g.allSatisfy { $0 == " " || $0 == "-" } }
        func spaced(_ a: Int, _ b: Int) -> Bool { let g = gap(a, b); return !g.isEmpty && g.allSatisfy { $0 == " " || $0 == "\t" } }
        func next(_ k: Int) -> String? { k < n ? toks[k].w : nil }
        /// Fraction digits after a "point" at index `p`: (digits, index after them).
        func fraction(point p: Int) -> (String, Int)? {
            guard p < n, toks[p].w == "point", p + 1 < n, spaced(p, p + 1) else { return nil }
            var k = p + 1, digits = ""
            while k < n, let d = digitWords[toks[k].w], k == p + 1 || spaced(k - 1, k) { digits += String(d); k += 1 }
            if !digits.isEmpty { return (digits, k) }
            let w = toks[p + 1].w
            if let t = teens[w] { return (String(t), p + 2) }
            if let t = tens[w] {
                if p + 2 < n, let u = units[toks[p + 2].w], joinable(p + 1, p + 2) { return (String(t + u), p + 3) }
                return (String(t), p + 2)
            }
            return nil
        }
        func sentenceInitial(_ k: Int) -> Bool {
            let before = ns.substring(to: toks[k].r.location)
            let trimmed = before.reversed().drop(while: { " \t\"'(“‘".contains($0) })
            guard let c = trimmed.first else { return true }
            return ".!?\n:".contains(c)
        }
        func clauseEnds(after k: Int) -> Bool {
            let end = toks[k - 1].r.location + toks[k - 1].r.length
            guard let c = ns.substring(from: end).first(where: { $0 != " " && $0 != "\t" }) else { return true }
            return ".,!?;:\n)\"”".contains(c)
        }
        /// `<value> percent` → index after "percent" when it follows `k`.
        func percent(at k: Int) -> Int? {
            guard k < n, k > 0, spaced(k - 1, k) else { return nil }
            if toks[k].w == "percent" { return k + 1 }
            if toks[k].w == "per", k + 1 < n, toks[k + 1].w == "cent", spaced(k, k + 1) { return k + 2 }
            return nil
        }

        var out = "", cursor = 0, i = 0
        func emit(from a: Int, to b: Int, _ value: String, joinFrom: Int? = nil) {
            let start = joinFrom ?? toks[a].r.location
            let end = toks[b - 1].r.location + toks[b - 1].r.length
            out += ns.substring(with: NSRange(location: cursor, length: start - cursor)) + value
            cursor = end
        }
        while i < n {
            let w = toks[i].w
            // Bare "point five" before a unit / percent → "0.5".
            if w == "point", i == 0 || !(digitWords[toks[i - 1].w] != nil || isNumberWord(toks[i - 1].w)) || !spaced(i - 1, i),
               let (frac, k) = fraction(point: i), k < n, spaced(k - 1, k), unitWords.contains(toks[k].w) {
                if let pk = percent(at: k) { emit(from: i, to: pk, "0.\(frac)%"); i = pk } else { emit(from: i, to: k, "0.\(frac)"); i = k }
                continue
            }
            let startsRun = isNumberWord(w) || (w == "zero" && next(i + 1) == "point")
                || (w == "a" && i + 1 < n && (toks[i + 1].w == "hundred" || scales[toks[i + 1].w] != nil) && joinable(i, i + 1))
            guard startsRun else { i += 1; continue }
            var j = i + 1
            if w != "zero" {
                while j < n, joinable(j - 1, j),
                      isNumberWord(toks[j].w) || (toks[j].w == "and" && j + 1 < n && isNumberWord(toks[j + 1].w)) {
                    j += 1
                }
            }
            let run = toks[i..<j].map(\.w)
            let intValue = w == "zero" ? 0 : parse(run)
            // Name before the number ("GPT five", "v two").
            var kind = NameKind.none
            if i > 0, spaced(i - 1, i) {
                kind = nameKind(toks[i - 1].s, sentenceInitial: sentenceInitial(i - 1), vocabulary: vocab)
            }
            let joinFrom = kind == .joined ? toks[i - 1].r.location + toks[i - 1].r.length : nil
            guard let iv = intValue else { i = j; continue }
            // Decimal ("six point one"), except "at one point …".
            let atOnePoint = run == ["one"] && i > 0 && toks[i - 1].w == "at"
            if !atOnePoint, j < n, spaced(j - 1, j), let (frac, k) = fraction(point: j) {
                if let pk = percent(at: k) { emit(from: i, to: pk, "\(iv).\(frac)%", joinFrom: joinFrom); i = pk }
                else { emit(from: i, to: k, "\(iv).\(frac)", joinFrom: joinFrom); i = k }
                continue
            }
            if let pk = percent(at: j) { emit(from: i, to: pk, "\(iv)%", joinFrom: joinFrom); i = pk; continue }
            let named: Bool
            switch kind {
            case .none: named = false
            case .weak: named = clauseEnds(after: j)
            case .strong, .joined: named = !(run == ["one"] && next(j) == "of")
            }
            if run.count >= 2 || named { emit(from: i, to: j, String(iv), joinFrom: joinFrom) }
            i = j
        }
        out += ns.substring(from: cursor)
        out = replaceAll(out, digitPoint, "$1.$2")
        return replaceAll(out, digitPercent, "$1%")
    }

    static func replaceAll(_ s: String, _ re: NSRegularExpression, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}
