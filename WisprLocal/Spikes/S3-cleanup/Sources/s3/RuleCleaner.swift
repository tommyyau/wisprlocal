import Foundation
enum RuleCleaner {
  static func clean(_ s: String) -> String {
    var t = s.lowercased()
    // scratch that: drop previous clause (back to prior sentence punctuation or start)
    while let r = t.range(of: "scratch that") {
      let before = String(t[..<r.lowerBound]); let after = String(t[r.upperBound...])
      var cut = before.startIndex
      let trimmed = before.trimmingCharacters(in: .whitespaces)
      if let p = trimmed.lastIndex(where: { ".?!".contains($0) }) { cut = trimmed.index(after: p) }
      else { cut = before.startIndex }
      t = String(before[..<cut]) + after
    }
    let fillers = ["\\bum+\\b","\\buh+\\b","\\ber+m?\\b","\\bhmm+\\b","\\byou know\\b","\\bi mean\\b","\\blike,?\\s(?=\\w)"]
    for f in fillers { t = t.replacingOccurrences(of: f, with: "", options: .regularExpression) }
    // spoken punctuation
    for (w,p) in [(" comma",","),(" period","."),(" full stop","."),(" question mark","?"),(" exclamation mark","!"),(" new line","\n")] {
      t = t.replacingOccurrences(of: w, with: p) }
    t = t.replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " at ", with: " at ")
    t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    t = t.replacingOccurrences(of: " ([,.?!])", with: "$1", options: .regularExpression)
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    // capitalise sentence starts and standalone i
    var out = ""; var cap = true
    var prev: Character = " "
  for ch in t { if cap, ch.isLetter { out += ch.uppercased(); cap = false } else { out.append(ch); if ch == "\n" { cap = true } else if ch.isWhitespace { if ".?!".contains(prev) { cap = true } } else { cap = false } }; prev = ch }
    out = out.replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
    if let l = out.last, l.isLetter || l.isNumber { out += "." }
    return out
  }
}
