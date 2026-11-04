import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class CitationValidatorTests: XCTestCase {

    func testInlineCodeCannotCrossRenderedBlockBoundaries() {
        let answers = [
            "- `open [1]\n- [2] close`",
            "# `open [1]\n[2] close`",
            "| `open [1] | [2] close` |\n| --- | --- |",
        ]
        for answer in answers {
            let result = CitationValidator.validate(answer: answer, sourceCount: 2)
            XCTAssertEqual(result.citedSourceIndices, [0, 1], answer)
            XCTAssertFalse(ResearchContext.withoutCitationMarkers(answer).contains("[1]"))
        }
    }

    func testCRLFFencesDoNotHideFollowingProseCitations() {
        let answer = "```swift\r\nitems[0]\r\n```\r\nFact [1]."
        let result = CitationValidator.validate(answer: answer, sourceCount: 1)
        XCTAssertEqual(result.citedSourceIndices, [0])
        XCTAssertTrue(result.outOfRangeCitations.isEmpty)
    }

    func testEscapedBackticksRemainProse() {
        let answer = #"Escaped \` prose [1] \`."#
        XCTAssertEqual(CitationValidator.validate(answer: answer, sourceCount: 1).citedSourceIndices, [0])
    }

    func testMultilineInlineCodeDoesNotBecomeACitation() {
        let answer = "`items\n[0]` then fact [1]."
        let result = CitationValidator.validate(answer: answer, sourceCount: 1)
        XCTAssertEqual(result.citedSourceIndices, [0])
        XCTAssertTrue(result.outOfRangeCitations.isEmpty)
    }

    func testSplitsTextAndCitations() {
        let result = CitationValidator.validate(answer: "Swift is fast [1] and safe [2].", sourceCount: 3)
        XCTAssertEqual(result.spans, [
            .text("Swift is fast "),
            .citation(sourceIndices: [0], raw: "[1]"),
            .text(" and safe "),
            .citation(sourceIndices: [1], raw: "[2]"),
            .text("."),
        ])
        XCTAssertEqual(result.citedSourceIndices, [0, 1])
        XCTAssertTrue(result.isClean)
    }

    func testParsesMultiNumberCitations() {
        let result = CitationValidator.validate(answer: "Both agree [1, 3].", sourceCount: 3)
        XCTAssertEqual(result.citedSourceIndices, [0, 2])
        XCTAssertTrue(result.isClean)
    }

    /// An out-of-range number is a fabricated citation. It must be reported, and the
    /// marker must degrade to plain text rather than becoming a chip to nowhere.
    func testFlagsOutOfRangeCitations() {
        let result = CitationValidator.validate(answer: "As shown [7].", sourceCount: 2)
        XCTAssertEqual(result.outOfRangeCitations, [7])
        XCTAssertFalse(result.isClean)
        XCTAssertEqual(result.spans, [.text("As shown "), .text("[7]"), .text(".")])
    }

    func testKeepsValidNumbersFromAPartlyInventedMarker() {
        let result = CitationValidator.validate(answer: "Mixed [1, 9].", sourceCount: 2)
        XCTAssertEqual(result.citedSourceIndices, [0])
        XCTAssertEqual(result.outOfRangeCitations, [9])
    }

    /// The answer prompt forbids URLs outright, so one appearing is a prompt
    /// violation the UI has to warn about.
    func testFlagsLiteralURLs() {
        let result = CitationValidator.validate(
            answer: "See https://example.com/made-up for details.", sourceCount: 2)
        XCTAssertEqual(result.literalURLs, ["https://example.com/made-up"])
        XCTAssertFalse(result.isClean)
    }

    /// The prompt forbids every syntax by which the model could smuggle a destination
    /// into its prose, not only the lowercase absolute-URL spelling.
    func testFlagsSchemesMarkdownLinksAndBareDomains() {
        let answers = [
            "See HTTPS://evil.example/path.",
            "Fetch FTP://evil.example/path or mailto:user@evil.example.",
            "Fetch gemini://evil.example, ipfs://evil.example, or s3://bucket/key.",
            "Fetch x://host or abcdefghijklmnopqrstuvwxyzabcdefghi://host.",
            "See //evil.example/path.",
            "See //例子.中国/path or //intranet-server/guide.",
            "See //192.0.2.1/path or 198.51.100.4/details.",
            "See [2001:db8::1], [::ffff:192.0.2.1], or 例子.中国.",
            "See [the documentation](//evil.example/path).",
            "See [the documentation](evil.example/path).",
            "See [the section](#details).",
            "See [nested [label]](#details).",
            "See [arbitrarily [deeply [nested]]](#details).",
            "See [a label\nwith a soft break](#details).",
            "See [the `API`](#details).",
            "See [the documentation][docs].\n[docs]: ./relative-page",
            "Reference definition only:\n[docs]: ./relative-page",
            "Contact <user@evil.example>.",
            "Contact user@evil.com.",
            "Contact 用户@例子.中国.",
            "See evil.example or www.other.example/path.",
            "See www.evil.host or evil.unlisted/path.",
            "See service.localhost.",
            "See evil.photography or download.zip.",
            "See EVIL.COM.",
            "See com.evil.com, evil.id, EVIL.MD, or com.example.app.",
        ]

        for answer in answers {
            let result = CitationValidator.validate(answer: answer, sourceCount: 1)
            XCTAssertFalse(result.literalURLs.isEmpty, answer)
            XCTAssertFalse(result.isClean, answer)
        }
    }

    func testRepeatedDestinationsAreReportedOnceWithoutProsePunctuation() {
        let answer = "(See https://evil.example/path) and https://evil.example/path."

        XCTAssertEqual(CitationValidator.validate(answer: answer, sourceCount: 0).literalURLs,
                       ["https://evil.example/path"])
    }

    func testBalancedParenthesesInsideAURLArePreserved() {
        let answer = "See https://en.wikipedia.org/wiki/Mercury_(planet)."

        XCTAssertEqual(CitationValidator.validate(answer: answer, sourceCount: 0).literalURLs,
                       ["https://en.wikipedia.org/wiki/Mercury_(planet)"])
    }

    /// Dotted identifiers whose final component is not an actual root-zone label are
    /// not destinations. Values ending in a real TLD are rejected even when they look
    /// like filenames or reverse-DNS identifiers: allowing that ambiguity would give a
    /// prompted model a reliable spelling for a fabricated destination.
    func testDottedIdentifiersAndFilenamesAreNotBareDomains() {
        let answer = "Use Foundation.URL with os.Logger; edit config.json, "
            + "config.prod.json and archive.tar.gz for v1.2.3, release v1.2.3.4, "
            + "ratio [1:2], map [a:b], package tool@1.2.34, or 1.2.3.444. "
            + "Neither //[1:2] nor [Note]: this is ordinary prose is a link."
        XCTAssertTrue(CitationValidator.validate(answer: answer, sourceCount: 0).literalURLs.isEmpty)
    }

    func testManyUnmatchedMarkdownOpenersRemainOrdinaryText() {
        let answer = String(repeating: "[", count: 10_000) + " ordinary prose"
        XCTAssertTrue(CitationValidator.validate(answer: answer, sourceCount: 0).literalURLs.isEmpty)
    }

    /// Bracket and call syntax inside code is not Markdown. Actual destinations in the
    /// same code remain forbidden by `testURLsInsideCodeRemainForbidden` below.
    func testMarkdownLikeCodeSyntaxIsNotAForbiddenLink() {
        let answer = "```swift\n//TODO\nlet value = matrix[row][column]\nhandlers[key](value)\n```"
        XCTAssertTrue(CitationValidator.validate(answer: answer, sourceCount: 0).literalURLs.isEmpty)
    }

    /// Code is rendered literally, but it is still model output. Letting a destination
    /// through there would reintroduce an expressible syntax for a fabricated link.
    func testURLsInsideCodeRemainForbidden() {
        let answer = "```sh\ncurl HTTPS://evil.example/path\n```"
        XCTAssertFalse(CitationValidator.validate(answer: answer, sourceCount: 0).isClean)
    }

    /// Inline scope exists only for citation masking during streaming; final document
    /// validation performs the destination scan once.
    func testInlineScopeDoesNotRepeatDestinationValidation() {
        let answer = "See evil.example."
        XCTAssertTrue(CitationValidator.validate(answer: answer, sourceCount: 0,
                                                 scope: .inline).literalURLs.isEmpty)
        XCTAssertFalse(CitationValidator.validate(answer: answer, sourceCount: 0).literalURLs.isEmpty)
    }

    /// A markdown link is not a citation marker, and neither is a bracketed aside.
    func testDoesNotMatchMarkdownLinksOrProseBrackets() {
        let markdown = CitationValidator.validate(answer: "[docs](https://example.com)", sourceCount: 3)
        XCTAssertEqual(markdown.citedSourceIndices, [])
        let aside = CitationValidator.validate(answer: "an aside [see below] here", sourceCount: 3)
        XCTAssertEqual(aside.citedSourceIndices, [])
    }

    func testHandlesEmptyAnswer() {
        let result = CitationValidator.validate(answer: "", sourceCount: 0)
        XCTAssertEqual(result.spans, [.text("")])
        XCTAssertTrue(result.isClean)
    }

    func testZeroSourcesMakesEveryCitationInvalid() {
        let result = CitationValidator.validate(answer: "Claim [1].", sourceCount: 0)
        XCTAssertEqual(result.outOfRangeCitations, [1])
        XCTAssertEqual(result.citedSourceIndices, [])
    }

    // MARK: Code is not prose

    /// `argv[0]` in a code sample is an index, not an invented source 0.
    func testBracketsInsideAFencedBlockAreNotCitations() {
        let answer = "Use the first argument [1].\n\n```python\nfirst = sys.argv[0]\nnext = items[1]\n```\n\nDone [2]."
        let result = CitationValidator.validate(answer: answer, sourceCount: 2)
        XCTAssertEqual(result.outOfRangeCitations, [])
        XCTAssertEqual(result.citedSourceIndices, [0, 1])
        XCTAssertTrue(result.isClean)
    }

    func testBracketsInsideInlineCodeAreNotCitations() {
        let result = CitationValidator.validate(answer: "Read `argv[1]` first [2].", sourceCount: 2)
        XCTAssertEqual(result.citedSourceIndices, [1])
        XCTAssertEqual(result.spans, [.text("Read `argv[1]` first "),
                                      .citation(sourceIndices: [1], raw: "[2]"),
                                      .text(".")])
    }

    /// A double-backtick span may contain a single backtick.
    func testDoubleBacktickSpansAreCode() {
        let result = CitationValidator.validate(answer: "``a ` b[1]`` and [1].", sourceCount: 1)
        XCTAssertEqual(result.spans.filter { if case .citation = $0 { return true } else { return false } }.count, 1)
    }

    /// Mid-stream the closing fence has not arrived; everything after the opener is
    /// code, exactly as the renderer draws it.
    func testAnUnterminatedFenceIsCodeToTheEnd() {
        let result = CitationValidator.validate(answer: "Intro [1].\n```\nx = a[2]\ny = b[3", sourceCount: 1)
        XCTAssertEqual(result.citedSourceIndices, [0])
        XCTAssertEqual(result.outOfRangeCitations, [])
    }

    /// A lone backtick is a literal backtick, not a span that swallows the line.
    func testAnUnclosedBacktickDoesNotHideProse() {
        let result = CitationValidator.validate(answer: "A stray ` here, then a real citation [1].", sourceCount: 1)
        XCTAssertEqual(result.citedSourceIndices, [0])
    }

    func testCodeRangesCoverFencesAndSpans() {
        let text = "a `b` c\n~~~\nd\n~~~\ne"
        let ranges = CitationValidator.codeRanges(in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["`b`", "~~~\nd\n~~~"])
    }
}
