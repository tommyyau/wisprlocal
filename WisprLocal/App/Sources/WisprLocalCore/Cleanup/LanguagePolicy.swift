import Foundation
import NaturalLanguage

/// What a language detector reports about a piece of text. CONTENT-FREE: a language code and a
/// confidence only, so it may be logged.
public struct DetectedLanguage: Sendable, Equatable {
    /// BCP-47 code of the most likely language ("en", "sv", …), nil when undetermined.
    public var code: String?
    /// Probability of `code` (0…1).
    public var confidence: Double

    public init(code: String?, confidence: Double) {
        self.code = code; self.confidence = confidence
    }

    /// "sv 0.98" / "und" — for logs and history notes.
    public var logDescription: String {
        guard let code else { return "und" }
        return "\(code) \(String(format: "%.2f", confidence))"
    }
}

public protocol LanguageDetecting: Sendable {
    func detect(_ text: String) -> DetectedLanguage
}

/// Apple's on-device `NLLanguageRecognizer` (no network, no model download).
public struct NLLanguageDetector: LanguageDetecting {
    public init() {}
    public func detect(_ text: String) -> DetectedLanguage {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let top = r.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }) else {
            return DetectedLanguage(code: nil, confidence: 0)
        }
        return DetectedLanguage(code: top.key.rawValue, confidence: top.value)
    }
}

/// STRUCTURAL: cleanup is English-only. Every cleanup rule (filler removal, backtracks,
/// "scratch that", spoken numbers) and the Foundation Models formatter are written for English;
/// on another language they would delete or rewrite real words. When the raw ASR text is
/// confidently NOT English, the pipeline inserts the raw text plus dictionary replacements plus
/// the smart join, and nothing else. Non-English output is never rejected or re-decoded: with
/// "Noisy room / other languages (Parakeet Ultra)" it may be exactly what the user said.
public enum CleanupLanguagePolicy {
    /// Fewer words than this are treated as English (too short for a reliable call; "Danke schön"
    /// in an English sentence stream is more likely a quote than a language switch).
    public static let minimumWords = 3
    /// Tuned on NLLanguageRecognizer (macOS 26): ordinary English, even jargon-heavy ("Grafana
    /// dashboards Tailscale Kubernetes" → en 0.21), never has a non-English top hypothesis at or
    /// above this; plain Swedish, German and French sentences score 1.00.
    public static let nonEnglishConfidence = 0.80

    public enum Verdict: Sendable, Equatable {
        /// Clean as usual.
        case english
        /// Too short to judge: treated as English.
        case tooShort
        /// Confidently another language: skip every cleanup stage.
        case nonEnglish(DetectedLanguage)

        public var allowsCleanup: Bool { if case .nonEnglish = self { return false } else { return true } }
    }

    public static func decide(_ text: String, detector: LanguageDetecting) -> (Verdict, DetectedLanguage?) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= minimumWords else { return (.tooShort, nil) }
        let d = detector.detect(text)
        if let code = d.code, !isEnglish(code), d.confidence >= nonEnglishConfidence {
            return (.nonEnglish(d), d)
        }
        return (.english, d)
    }

    static func isEnglish(_ code: String) -> Bool { code == "en" || code.hasPrefix("en-") || code.hasPrefix("en_") }
}
