import XCTest
#if canImport(VervellumKit)
@testable import VervellumKit
#else
@testable import Vervellum
#endif

final class CitationMaskTests: XCTestCase {
    func testRawPlaceholdersCannotMoveOrCreateCitations() {
        let marker = String(CitationMask.placeholder)
        let mask = CitationMask("\(marker)Wrong. Right [2, 1].\(marker) Last [1]\(marker)", sourceCount: 2)
        XCTAssertEqual(mask.text, "Wrong. Right \(marker). Last \(marker)")
        XCTAssertEqual(mask.sourceIndices, [[1, 0], [0]])
        XCTAssertEqual(mask.text.filter { $0 == CitationMask.placeholder }.count, mask.sourceIndices.count)
    }

    func testPlaceholderOnlyTextHasNoCitations() {
        let mask = CitationMask(String(repeating: String(CitationMask.placeholder), count: 3), sourceCount: 2)
        XCTAssertEqual(mask.text, "")
        XCTAssertTrue(mask.sourceIndices.isEmpty)
    }

    func testInlineFragmentsDoNotInventBlockFences() {
        let mask = CitationMask("```items[0]``` claim [1]", sourceCount: 1)
        XCTAssertEqual(mask.text, "```items[0]``` claim \(CitationMask.placeholder)")
        XCTAssertEqual(mask.sourceIndices, [[0]])
    }

    func testCodeAndUnknownCitationsRemainLiteral() {
        let mask = CitationMask("`items[0]` [9] fact [1]", sourceCount: 1)
        XCTAssertEqual(mask.text, "`items[0]` [9] fact \(CitationMask.placeholder)")
        XCTAssertEqual(mask.sourceIndices, [[0]])
    }

    func testRangeBecomesOneChipWithEveryMember() {
        let mask = CitationMask("Span [1-3].", sourceCount: 3)
        XCTAssertEqual(mask.text, "Span \(CitationMask.placeholder).")
        XCTAssertEqual(mask.sourceIndices, [[0, 1, 2]])
    }

    func testReversedRangeStaysLiteral() {
        let mask = CitationMask("Backwards [9-2].", sourceCount: 9)
        XCTAssertEqual(mask.text, "Backwards [9-2].")
        XCTAssertTrue(mask.sourceIndices.isEmpty)
    }
}
