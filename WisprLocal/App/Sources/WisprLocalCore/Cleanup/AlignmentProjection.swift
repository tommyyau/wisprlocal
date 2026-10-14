import Foundation

/// Model prose supplies evidence for omissions and formatting, never replacement words.
public enum AlignmentProjection {
    static let auxiliaries: Set<String> = ["am", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did", "can", "could", "may", "might", "must", "shall", "should", "will", "would", "i'm", "it's", "we're", "they're"]
    static func isVerbContinuation(_ word: String) -> Bool {
        word.hasSuffix("ing") || word.hasSuffix("ed") || ["go", "send", "call", "email", "meet", "want", "need", "sign", "pay", "bring", "eat", "leave", "come", "agree", "work", "sent", "went", "goes", "wants", "needs", "sends", "meets", "loves", "says", "said"].contains(word)
    }
    public struct Result: Sendable {
        public let text: String
        public let plan: EditPlan
        public let verdicts: [String: Int]
    }

    public static func apply(input: String, output: String, level: CleanupLevel,
                             dictionary: [String] = [], contextNames: [String] = []) -> Result {
        let source = PlanTokens(input)
        // Strip list markers before tokenization: numbered markers are not dictated numbers.
        let lines = output.components(separatedBy: "\n")
        let header = lines.first?.trimmingCharacters(in: .whitespaces).hasSuffix(":") == true ? 1 : 0
        let items = Array(lines.dropFirst(header))
        let numbered = items.enumerated().allSatisfy { index, line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("\(index + 1). ")
        }
        let bullets = items.allSatisfy { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return ["- ", "• ", "* "].contains { value.hasPrefix($0) }
        }
        let isList = items.count > 1 && (numbered || bullets)
        let prose = isList ? lines.enumerated().map { index, line in
            guard index >= header else { return line }
            let value = line.trimmingCharacters(in: .whitespaces)
            return String(value.dropFirst(numbered ? (value.firstIndex(of: " ").map { value.distance(from: value.startIndex, to: $0) + 1 } ?? 0) : 2))
        }.joined(separator: "\n") : output
        let target = PlanTokens(prose), n = source.keys.count, m = target.keys.count
        let unchanged = EditPlan(spans: n == 0 ? [] : [EditSpan(start: 0, end: n, disposition: .keep)])
        guard level != .verbatim, n > 0, n <= 600, m <= 1264 else {
            return Result(text: input, plan: unchanged, verdicts: [:])
        }
        // Prefix LCS in one flat buffer. Backtracking from the end favours the final
        // restatement when a correction repeats the original clause scaffolding.
        var aligned = [Int?](repeating: nil, count: n)
        var sourceIndex = n, targetIndex = m
        while sourceIndex > 0 && targetIndex > 0 {
            sourceIndex -= 1
            if source.keys[sourceIndex] == target.keys[targetIndex - 1] {
                targetIndex -= 1; aligned[sourceIndex] = targetIndex
            }
        }
        // If all output tokens are a subsequence, this is already a maximal LCS.
        // This linear path covers ordinary deletions and keeps debug latency bounded.
        if targetIndex > 0 {
            aligned = [Int?](repeating: nil, count: n)
            let width = m + 1
            var dp = [Int](repeating: 0, count: (n + 1) * width)
            var ids: [String: Int] = [:]
            func id(_ word: String) -> Int {
                if let value = ids[word] { return value }
                let value = ids.count; ids[word] = value; return value
            }
            let sourceIDs = source.keys.map(id), targetIDs = target.keys.map(id)
            dp.withUnsafeMutableBufferPointer { buffer in
                sourceIDs.withUnsafeBufferPointer { left in
                    targetIDs.withUnsafeBufferPointer { right in
                        let cells = buffer.baseAddress!
                        let leftWords = left.baseAddress!
                        let rightWords = right.baseAddress
                        var row = 1
                        while row <= n {
                            var col = 1
                            let offset = row * width, previous = offset - width
                            while col <= m {
                                cells[offset + col] = leftWords[row - 1] == rightWords![col - 1]
                                    ? cells[previous + col - 1] + 1
                                    : max(cells[previous + col], cells[offset + col - 1])
                                col += 1
                            }
                            row += 1
                        }
                    }
                }
            }
            var i = n, j = m
            while i > 0 && j > 0 {
                if source.keys[i - 1] == target.keys[j - 1] {
                    aligned[i - 1] = j - 1; i -= 1; j -= 1
                } else if dp[(i - 1) * width + j] >= dp[i * width + j - 1] { i -= 1 }
                else { j -= 1 }
            }
        }
        var i = 0
        guard m > 0, aligned.compactMap({ $0 }).count * 100 >= m * 60 else {
            return Result(text: input, plan: unchanged, verdicts: ["restored:low-alignment": 1])
        }
        let terms = Set((dictionary + contextNames).flatMap { Tokenizer.semanticWords($0) })
        var cueStarts = Set<Int>(), clauseStarts = Set([0])
        for index in source.keys.indices {
            if source.gaps[index].contains(where: { ".!?;,\n".contains($0) }) { clauseStarts.insert(index + 1) }
            if let cue = (PlanValidator.cuesByHead[source.keys[index]] ?? []).first(where: { index + $0.count <= n && source.keys[index..<index + $0.count].elementsEqual($0) }) {
                cueStarts.insert(index); clauseStarts.insert(index + cue.count)
            }
        }
        var followingEnds = [Int](repeating: n, count: n + 1), nextEnd = n
        for index in source.keys.indices.reversed() {
            if source.gaps[index].contains(where: { ".!?;,\n".contains($0) }) { nextEnd = index + 1 }
            followingEnds[index] = nextEnd
            if cueStarts.contains(index) { nextEnd = index }
        }
        var decisions: [(range: Range<Int>, spans: [EditSpan], reason: String)] = []
        var verdicts: [String: Int] = [:]
        func retraction(_ start: Int, _ cue: Int, _ end: Int) -> String? {
            guard !(start..<end).contains(where: { source.quotedIndices.contains($0) }) else { return "quoted-content" }
            return PlanValidator.retractionReason(source, range: start..<cue, cueEnd: end,
                                                  postEnd: followingEnds[end], clauseStarts: clauseStarts, terms: terms)
        }
        i = 0
        while i < n {
            if aligned[i] != nil { i += 1; continue }
            let start = i
            while i < n && aligned[i] == nil { i += 1 }
            // A cue kept by the model still licenses a deletion, but is consumed
            // with a validated retraction rather than delivered as a dangling aside.
            var adjacentAccepted = false
            for cue in (i < n ? PlanValidator.cuesByHead[source.keys[i]] ?? [] : []) where i + cue.count <= n && source.keys[i..<i + cue.count].elementsEqual(cue) {
                let end = i + cue.count
                let spans = [EditSpan(start: start, end: i, disposition: .retracted, correctionCueIndex: i),
                             EditSpan(start: i, end: end, disposition: .filler)]
                if retraction(start, i, end) == nil {
                    decisions.append((start..<end, spans, "retracted")); i = end; adjacentAccepted = true; break
                }
            }
            if adjacentAccepted { continue }
            let range = start..<i
            var choices: [([EditSpan], String)] = []
            // A correction cue inside the omitted run belongs to its retraction.
            for cueIndex in range {
                for cue in PlanValidator.cuesByHead[source.keys[cueIndex]] ?? [] where cueIndex > start && cueIndex + cue.count <= i &&
                    source.keys[cueIndex..<cueIndex + cue.count].elementsEqual(cue) {
                    // The remainder may itself contain another correction; conservatively
                    // require this candidate to end immediately after its cue.
                    if cueIndex + cue.count == i {
                        choices.append(([EditSpan(start: start, end: cueIndex, disposition: .retracted, correctionCueIndex: cueIndex),
                                         EditSpan(start: cueIndex, end: i, disposition: .filler)], "retracted"))
                    }
                }
            }
            choices += [([EditSpan(start: start, end: i, disposition: .filler)], range.allSatisfy { FillerContext.strong.contains(source.keys[$0]) } ? "hesitation" : "filler"),
                        ([EditSpan(start: start, end: i, disposition: .falseStart)], "falseStart")]
            var failure = "content", accepted = false
            for (spans, reason) in choices {
                let failureReason: String?
                switch reason {
                case "filler", "hesitation":
                    failureReason = PlanValidator.removableFiller(source, range: range, terms: terms) ? nil : "filler-content"
                case "falseStart":
                    failureReason = PlanValidator.falseStartReason(source, range: range,
                        isClauseStart: clauseStarts.contains(start), restartEnd: followingEnds[i], terms: terms)
                default:
                    failureReason = retraction(start, spans[0].end, i)
                }
                if range.contains(where: { source.quotedIndices.contains($0) }) {
                    failure = "quoted-content"; continue
                }
                if failureReason == nil { decisions.append((range, spans, reason)); accepted = true; break }
                if failure == "content" { failure = failureReason ?? failure }
            }
            if !accepted { verdicts["restored:\(failure)", default: 0] += 1 }
        }
        func countsTowardCap(_ decision: (range: Range<Int>, spans: [EditSpan], reason: String)) -> Bool {
            decision.reason != "retracted" && !(decision.reason == "falseStart" && PlanValidator.incompletePlacement(source, range: decision.range))
        }
        var capped = decisions.filter(countsTowardCap).reduce(0) { $0 + $1.range.count }
        // Restore whole spans, largest first, until the global 35% budget is met.
        for decision in decisions.filter(countsTowardCap).sorted(by: { $0.range.count > $1.range.count }) {
            if capped <= max(3, n * 35 / 100) { break }
            decisions.removeAll { $0.range == decision.range }
            capped -= decision.range.count
            verdicts["restored:deletion-cap", default: 0] += 1
        }
        var removed = [Bool](repeating: false, count: n)
        for decision in decisions {
            for index in decision.range { removed[index] = true }
            verdicts["accepted:\(decision.reason)", default: 0] += 1
        }
        if !removed.contains(false) && !PlanValidator.fillerOnly(source.keys[...]) {
            removed = [Bool](repeating: false, count: n); decisions = []
            verdicts = ["restored:empty-output": 1]
        }
        let restored = verdicts.filter { $0.key.hasPrefix("restored:") }.values.reduce(0, +)
        if restored > decisions.count {
            // Counts describe the delivered plan, including accepted candidates that
            // this low-trust fallback ultimately restores.
            for key in verdicts.keys.filter({ $0.hasPrefix("accepted:") }) { verdicts.removeValue(forKey: key) }
            if !decisions.isEmpty { verdicts["restored:low-trust", default: 0] += decisions.count }
            return Result(text: input, plan: unchanged, verdicts: verdicts)
        }
        var spans: [EditSpan] = [], boundaries: [Int: EditBoundary] = [:], articles: [Int: String] = [:]
        i = 0
        while i < n {
            if let decision = decisions.first(where: { $0.range.lowerBound == i }) {
                spans += decision.spans; i = decision.range.upperBound
            } else {
                let start = i; i += 1
                while i < n && !removed[i] { i += 1 }
                spans.append(EditSpan(start: start, end: i, disposition: .keep))
            }
        }
        let outputAligned = Set(aligned.compactMap { $0 })
        for index in 0..<n where !removed[index] {
            guard let out = aligned[index] else { continue }
            // A restored span keeps both its surrounding original gaps.
            guard index + 1 == n || aligned[index + 1] != nil || removed[index + 1] else { continue }
            guard source.gaps[index].allSatisfy({ $0.isWhitespace || ",.!?:;".contains($0) }) else { continue }
            let gap = target.gaps[out]
            guard gap.allSatisfy({ $0.isWhitespace || ",.!?:;".contains($0) }) else { continue }
            var punctuation: PlanPunctuation = gap.first.flatMap { ch in
                [.comma, .period, .question, .exclamation, .colon, .semicolon].first { $0.text == String(ch) }
            } ?? .none
            let original = source.gaps[index].trimmingCharacters(in: .whitespacesAndNewlines)
            // Existing terminators and non-comma punctuation belong to the input.
            // A comma must never become a model-supplied terminator.
            if let terminal = original.first(where: { ".?!".contains($0) }) {
                punctuation = terminal == "." ? .period : terminal == "?" ? .question : .exclamation
            } else if !original.isEmpty && original != "," {
                continue
            } else if original == "," && ([.period, .question, .exclamation].contains(punctuation) ||
                        punctuation == .none && (index + 1 == n || !removed[index + 1])) {
                punctuation = .comma
            }
            if [.period, .question, .exclamation].contains(punctuation),
               !original.contains(where: { ".?!".contains($0) }), index + 1 < n,
               Tokenizer.isNegator(source.keys[index]) || Self.auxiliaries.contains(source.keys[index]) ||
                (source.surfaces[index + 1].first?.isLowercase == true && Self.isVerbContinuation(source.keys[index + 1])) {
                punctuation = original == "," ? .comma : .none
            }
            let lineBreak: PlanBreak = gap.contains("\n\n") ? .paragraph : gap.contains("\n") ? (isList ? .listItem : .newline) : .none
            boundaries[index] = EditBoundary(afterToken: index, punctuation: punctuation, lineBreak: lineBreak)
            if level == .medium, (index == 0 || aligned[index - 1] != nil || removed[index - 1]), out > 0, !outputAligned.contains(out - 1), let article = PlanArticle(rawValue: target.keys[out - 1]) {
                articles[index] = article.rawValue
            }
        }
        // Ignore punctuation leading into hallucinated suffixes; supply a safe terminal.
        if let last = removed.indices.last(where: { !removed[$0] }), let out = aligned[last], (out < m - 1 || !isList && !target.gaps[out].contains(where: { ".?!".contains($0) })) {
            if source.gaps[last].contains(where: { ".?!".contains($0) }) {
                boundaries.removeValue(forKey: last)
            } else {
                let punctuation: PlanPunctuation = source.gaps[last].trimmingCharacters(in: .whitespacesAndNewlines) == "," ? .comma : .period
                boundaries[last] = EditBoundary(afterToken: last, punctuation: punctuation)
            }
        }
        let plan = EditPlan(spans: spans, boundaries: boundaries.values.sorted { $0.afterToken < $1.afterToken },
                            articles: articles.keys.sorted().compactMap { index in PlanArticle(rawValue: articles[index]!).map { ArticleInsertion(beforeToken: index, article: $0) } }, leadingList: isList && header == 0 && removed.indices.first(where: { !removed[$0] }).map { aligned[$0] == 0 } == true)
        let rendered = ProjectionRenderer.render(source, removed: removed, boundaries: boundaries, articles: articles, dictionary: dictionary, contextNames: contextNames, leadingList: plan.leadingList)
        return Result(text: rendered, plan: plan, verdicts: verdicts)
    }
}
