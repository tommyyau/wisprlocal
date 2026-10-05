import Foundation

/// The small Markdown subset used by the bundled acknowledgements. Inline markup stays
/// intact for AttributedString; block markers never become displayed text.
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code([String])
    case bullets([String])
    case table(header: [String], rows: [[String]])
}

public enum MarkdownBlocks {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let rawLines = markdown.components(separatedBy: .newlines)
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }
        var blocks: [MarkdownBlock] = []
        var i = 0
        func cells(_ line: String) -> [String] {
            var body = line
            if body.hasPrefix("|") { body.removeFirst() }
            if body.hasSuffix("|") { body.removeLast() }
            return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func separator(_ line: String) -> Bool {
            let columns = cells(line)
            return line.contains("|") && !columns.isEmpty && columns.allSatisfy {
                let dashes = $0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return dashes.count >= 3 && dashes.allSatisfy { $0 == "-" }
            }
        }
        func heading(_ line: String) -> (Int, String)? {
            let count = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(count), line.dropFirst(count).hasPrefix(" ") else { return nil }
            return (count, String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces))
        }
        func bullet(_ line: String) -> String? {
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
            return String(line.dropFirst(2))
        }
        func fence(_ line: String) -> String? {
            if line.hasPrefix("```") { return String(line.prefix(while: { $0 == "`" })) }
            if line.hasPrefix("~~~") { return String(line.prefix(while: { $0 == "~" })) }
            return nil
        }
        func indented(_ line: String) -> String? {
            if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return nil
        }
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }
            if let marker = fence(line) {
                var code: [String] = []; i += 1
                while i < lines.count {
                    let closing = lines[i]
                    if closing.count >= marker.count, closing.allSatisfy({ $0 == marker.first! }) {
                        i += 1; break
                    }
                    code.append(rawLines[i]); i += 1
                }
                blocks.append(.code(code))
            } else if indented(rawLines[i]) != nil {
                var code: [String] = []
                while i < lines.count, let text = indented(rawLines[i]) {
                    code.append(text); i += 1
                }
                blocks.append(.code(code))
            } else if let (level, text) = heading(line) {
                blocks.append(.heading(level: level, text: text)); i += 1
            } else if i + 1 < lines.count, line.contains("|"), separator(lines[i + 1]) {
                let header = cells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].hasPrefix("|") {
                    var row = cells(lines[i])
                    // Keep Grid columns aligned even if a row omits trailing empty cells.
                    row = Array(row.prefix(header.count))
                    row += Array(repeating: "", count: header.count - row.count)
                    rows.append(row); i += 1
                }
                blocks.append(.table(header: header.allSatisfy { $0.isEmpty } ? [] : header, rows: rows))
            } else if bullet(line) != nil {
                var items: [String] = []
                while i < lines.count, let item = bullet(lines[i]) { items.append(item); i += 1 }
                blocks.append(.bullets(items))
            } else {
                var paragraph = [line]; i += 1
                while i < lines.count, !lines[i].isEmpty, heading(lines[i]) == nil,
                      bullet(lines[i]) == nil, fence(lines[i]) == nil, indented(rawLines[i]) == nil {
                    if i + 1 < lines.count, lines[i].contains("|"), separator(lines[i + 1]) { break }
                    paragraph.append(lines[i]); i += 1
                }
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
            }
        }
        return blocks
    }
}
