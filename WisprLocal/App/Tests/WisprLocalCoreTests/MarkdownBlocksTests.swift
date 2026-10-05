import Foundation
import Testing
@testable import WisprLocalCore

@Suite struct MarkdownBlocksTests {
    @Test func acknowledgementsHaveStructuredCredits() throws {
        let source = try String(contentsOf: HelpContentTests.repoRoot.appendingPathComponent("ACKNOWLEDGEMENTS.md"), encoding: .utf8)
        let blocks = MarkdownBlocks.parse(source)
        var runs: [String] = []
        var tables: [(header: [String], rows: [[String]])] = []
        for block in blocks {
            switch block {
            case .heading(_, let text), .paragraph(let text): runs.append(text)
            case .code(let lines):
                #expect(lines.count == 2)
                #expect(lines.allSatisfy { $0.hasPrefix("https://huggingface.co/") })
            case .bullets(let items): runs += items
            case .table(let header, let rows):
                tables.append((header, rows)); runs += header + rows.flatMap { $0 }
            }
        }
        #expect(blocks.first == .heading(level: 1, text: "Acknowledgements"))
        #expect(tables.count == 6)
        let components = try #require(tables.first)
        #expect(components.header == ["Component", "Role in WisprLocal", "Author and conversion", "Licence"])
        #expect(components.rows.count == 4)
        #expect(components.rows.allSatisfy { $0.count == 4 })
        #expect(tables.dropFirst().map { $0.header.count } == [0, 0, 0, 0, 2])
        #expect(tables.dropFirst().allSatisfy { $0.rows.allSatisfy { $0.count == 2 } })
        #expect(blocks.filter { if case .code = $0 { return true }; return false }.count == 1)
        #expect(tables.dropFirst().map { $0.rows.count } == [7, 5, 5, 5, 3])
        for run in runs {
            let rendered = String(try AttributedString(markdown: run, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)).characters)
            #expect(!rendered.hasPrefix("#"))
            #expect(!rendered.contains("|"))
        }
    }

    @Test func paragraphsListsAndTablePadding() {
        #expect(MarkdownBlocks.parse("## Title\n\nA **bold**\nparagraph.\n\n- First\n* Second\n\n| A | B |\n| :--- | ---: |\n| Cell |") == [
            .heading(level: 2, text: "Title"), .paragraph("A **bold** paragraph."),
            .bullets(["First", "Second"]), .table(header: ["A", "B"], rows: [["Cell", ""]]),
        ])
    }

    @Test func emptyTableHeadersAreOmittedWithoutLosingColumns() {
        #expect(MarkdownBlocks.parse("### Component\n\n| | |\n| --- | --- |\n| Author | Example |\n| Licence |") == [
            .heading(level: 3, text: "Component"),
            .table(header: [], rows: [["Author", "Example"], ["Licence", ""]]),
        ])
        #expect(MarkdownBlocks.parse("| | Licence |\n| --- | --- |\n| Example | MIT |") == [
            .table(header: ["", "Licence"], rows: [["Example", "MIT"]]),
        ])
    }

    @Test func codeBlocksKeepSeparateLiteralLines() {
        #expect(MarkdownBlocks.parse("Before.\n    first <file>\n        second **literal**\nAfter.") == [
            .paragraph("Before."), .code(["first <file>", "    second **literal**"]), .paragraph("After."),
        ])
        #expect(MarkdownBlocks.parse("Before.\n```text\nfirst <file>\n\n    second **literal**\n```\nAfter.") == [
            .paragraph("Before."), .code(["first <file>", "", "    second **literal**"]), .paragraph("After."),
        ])
        #expect(MarkdownBlocks.parse("~~~\nfirst\nsecond\n~~~") == [.code(["first", "second"])])
    }
}
