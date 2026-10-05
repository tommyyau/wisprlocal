import Foundation
/// Deterministic guard on LLM cleanup output. Pure function; no FoundationModels dependency.
public enum OutputGuard {
  public enum Verdict: Equatable { case ok, lengthRatio(Double), lowOverlap(Double), empty }
  /// Length ratio is measured in words (output/raw). Bounds loose enough for backtrack/scratch-that (shrink)
  /// and number/email formatting; tight enough to catch poems, answers, refusals.
  public static func check(raw: String, output: String, minRatio: Double = 0.25, maxRatio: Double = 1.4, minOverlap: Double = 0.5) -> Verdict {
    let o = tokens(output), r = tokens(raw)
    if o.isEmpty { return .empty }
    if r.isEmpty { return .ok }
    let ratio = Double(o.count) / Double(r.count)
    if ratio < minRatio || ratio > maxRatio { return .lengthRatio(ratio) }
    // fraction of output tokens that appear in raw (catches added content / answers)
    let rs = Set(r); let hit = o.filter { rs.contains($0) }.count
    let overlap = Double(hit) / Double(o.count)
    return overlap < minOverlap ? .lowOverlap(overlap) : .ok
  }
  static func tokens(_ s: String) -> [String] {
    s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
  }
}
