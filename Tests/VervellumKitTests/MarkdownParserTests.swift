import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class MarkdownParserTests: XCTestCase {

    func testBlockRangesReferToTheOriginalUnicodeAndCRLFInput() {
        let markdown = "# Héading\r\n\r\nπ paragraph\r\ncontinued\r\n\r\n```\r\n[9]\r\n```"
        let blocks = MarkdownParser.parse(markdown)
        XCTAssertEqual(blocks.map { String(markdown[$0.sourceRange]) },
                       ["# Héading", "π paragraph\r\ncontinued", "```\r\n[9]\r\n```"])
        XCTAssertEqual(blocks[1].text, "π paragraph\ncontinued")
    }

    func testSplitsParagraphs() {
        let blocks = MarkdownParser.parse("First para.\nStill first.\n\nSecond para.")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .paragraph)
        XCTAssertEqual(blocks[0].text, "First para.\nStill first.")
        XCTAssertEqual(blocks[1].text, "Second para.")
    }

    func testParsesHeadingsAndClampsTheLevel() {
        let blocks = MarkdownParser.parse("# One\n## Two\n#### Four")
        XCTAssertEqual(blocks.map(\.kind), [.heading(1), .heading(2), .heading(3)])
        XCTAssertEqual(blocks[2].text, "Four")
    }

    /// "#hashtag" is not a heading. ATX requires a space after the hashes.
    func testRequiresASpaceAfterTheHashes() {
        XCTAssertEqual(MarkdownParser.parse("#nothashtag").first?.kind, .paragraph)
    }

    func testStripsAClosingHashSequence() {
        XCTAssertEqual(MarkdownParser.parse("## Title ##").first?.text, "Title")
    }

    /// A trailing `#` is only a closing sequence when a space precedes it —
    /// "# C#" is a heading reading "C#", not a heading "C" with a closer.
    func testKeepsATrailingHashThatIsNotAClosingSequence() {
        XCTAssertEqual(MarkdownParser.parse("# C#").first?.text, "C#")
        XCTAssertEqual(MarkdownParser.parse("## Version 2#").first?.text, "Version 2#")
    }

    func testParsesBulletsAndOrderedItems() {
        let blocks = MarkdownParser.parse("- one\n* two\n+ three\n1. first\n2) second")
        XCTAssertEqual(blocks.map(\.kind), [
            .bullet(depth: 0), .bullet(depth: 0), .bullet(depth: 0),
            .ordered(number: 1, depth: 0), .ordered(number: 2, depth: 0),
        ])
        XCTAssertEqual(blocks[3].text, "first")
    }

    func testTracksListIndentDepth() {
        let blocks = MarkdownParser.parse("- top\n  - nested\n    - deeper")
        XCTAssertEqual(blocks.map(\.kind), [
            .bullet(depth: 0), .bullet(depth: 1), .bullet(depth: 2),
        ])
    }

    func testMergesConsecutiveQuoteLines() {
        let blocks = MarkdownParser.parse("> one\n> two")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .quote)
        XCTAssertEqual(blocks[0].text, "one\ntwo")
    }

    func testParsesAFencedCodeBlockWithItsLanguage() {
        let blocks = MarkdownParser.parse("```swift\nlet x = 1\n```")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .code(language: "swift"))
        XCTAssertEqual(blocks[0].text, "let x = 1")
    }

    /// The parser runs on every streamed chunk, so a fence that has not closed yet is
    /// the normal case — it must render what has arrived rather than hiding it.
    func testEmitsAnUnterminatedFence() {
        let blocks = MarkdownParser.parse("Intro\n\n```json\n{\"a\": 1")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1].kind, .code(language: "json"))
        XCTAssertEqual(blocks[1].text, "{\"a\": 1")
    }

    func testMarkersInsideAFenceAreLiteral() {
        let blocks = MarkdownParser.parse("```\n# not a heading\n- not a bullet\n```")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "# not a heading\n- not a bullet")
    }

    func testParsesHorizontalRules() {
        XCTAssertEqual(MarkdownParser.parse("---").first?.kind, .rule)
        XCTAssertEqual(MarkdownParser.parse("***").first?.kind, .rule)
        XCTAssertEqual(MarkdownParser.parse("--").first?.kind, .paragraph)
    }

    /// Windows line endings must not insert a paragraph break after every line.
    func testHandlesCRLF() {
        let blocks = MarkdownParser.parse("one\r\ntwo\r\n\r\nthree")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].text, "one\ntwo")
    }

    func testHandlesEmptyAndWhitespaceInput() {
        XCTAssertTrue(MarkdownParser.parse("").isEmpty)
        XCTAssertTrue(MarkdownParser.parse("   \n\n  ").isEmpty)
    }

    /// A partially-arrived emphasis marker must not blank the paragraph; it is simply
    /// literal text until its partner arrives.
    func testUnterminatedEmphasisStaysInTheParagraph() {
        let blocks = MarkdownParser.parse("This is **bold and unclosed")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "This is **bold and unclosed")
    }

    func testBlockIDsAreUnique() {
        let blocks = MarkdownParser.parse("# H\n\npara\n\n- item\n\n```\ncode\n```")
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
    }

    // MARK: Tables

    func testParsesATable() {
        let markdown = "Intro.\n\n| Name | Value |\n| --- | ---: |\n| a | 1 |\n| b | 2 |\n\nOutro."
        let blocks = MarkdownParser.parse(markdown)
        XCTAssertEqual(blocks.count, 3)
        guard case .table(let headers, let rows) = blocks[1].kind else {
            return XCTFail("expected a table, got \(blocks[1].kind)")
        }
        XCTAssertEqual(headers, ["Name", "Value"])
        XCTAssertEqual(rows, [["a", "1"], ["b", "2"]])
        XCTAssertEqual(blocks[2].text, "Outro.")
    }

    /// A pipe in prose is not a table until a delimiter row confirms it.
    func testPipesWithoutADelimiterStayProse() {
        let blocks = MarkdownParser.parse("a | b\nfollow-up line")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
    }

    /// The delimiter and header must agree on the column count (CommonMark), so a
    /// rule line ("---") cannot pair with a stray pipe above it: the pipe line
    /// stays prose and the dashes parse as the rule they are.
    func testMismatchedDelimiterColumnCountStaysProse() {
        let blocks = MarkdownParser.parse("a | b\n---")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .rule])
        XCTAssertEqual(blocks[0].text, "a | b")
    }

    /// A header with no delimiter yet is normal mid-stream input: emit it as a
    /// paragraph now, and re-parse into a table when the delimiter arrives.
    func testAHeaderStillStreamingIsAParagraph() {
        let partial = MarkdownParser.parse("| Name | Value |")
        XCTAssertEqual(partial.first?.kind, .paragraph)
    }

    func testEscapedPipesInsideCells() {
        let markdown = "| Code | Meaning |\n| --- | --- |\n| `a \\| b` | either |"
        guard case .table(let headers, let rows) = MarkdownParser.parse(markdown).first?.kind else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(headers, ["Code", "Meaning"])
        XCTAssertEqual(rows, [["`a | b`", "either"]])
    }

    /// Rows are normalised to the header's width: a short row pads, a long row
    /// drops its tail, so renderers never see a ragged table.
    func testRaggedRowsAreNormalised() {
        let markdown = "| A | B |\n| --- | --- |\n| 1 |\n| 1 | 2 | 3 |"
        guard case .table(_, let rows) = MarkdownParser.parse(markdown).first?.kind else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(rows, [["1", ""], ["1", "2"]])
    }

    /// A repeated delimiter row inside the body is decoration, not a data row.
    func testRepeatedDelimiterInsideTheBodyIsSkipped() {
        let markdown = "| A |\n| --- |\n| 1 |\n| --- |\n| 2 |"
        guard case .table(_, let rows) = MarkdownParser.parse(markdown).first?.kind else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(rows, [["1"], ["2"]])
    }

    /// Rows without outer pipes are still rows.
    func testTableWithoutOuterPipes() {
        let markdown = "Name | Value\n--- | ---\na | 1"
        guard case .table(let headers, let rows) = MarkdownParser.parse(markdown).first?.kind else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(headers, ["Name", "Value"])
        XCTAssertEqual(rows, [["a", "1"]])
    }
}
