import XCTest
@testable import Vervellum

final class CitationTextTests: XCTestCase {
    private let sources = [Source(number: 1, url: "https://retrieved.example", title: "Retrieved", snippet: "")]

    func testOnlyRetrievedCitationsCarryLinkAttributes() {
        let text = CitationText.render("[invented](https://evil.example) https://other.example [1]", sources: sources)
        let links = text.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://retrieved.example")!])
    }

    func testRawPlaceholdersCannotRelocateARealCitation() {
        let text = CitationText.render("\(CitationMask.placeholder)Wrong. Right [1].", sources: sources)
        XCTAssertEqual(String(text.characters), "Wrong. Right [1].")
        let linkedText = text.runs.filter { $0.link != nil }.map { String(text[$0.range].characters) }
        XCTAssertEqual(linkedText, ["[1]"])
    }

    func testMarkdownThatConsumesAPlaceholderFallsBackToLiteralText() {
        let text = CitationText.render("[hidden](https://evil.example/[1]) then [1]", sources: sources)
        XCTAssertTrue(String(text.characters).contains("then [1]"))
        XCTAssertEqual(text.runs.compactMap(\.link).count, 2)
    }

    func testRangeCitationRendersEveryMember() {
        let rangeSources = (1...3).map {
            Source(number: $0, url: "https://retrieved.example/\($0)", title: "Source \($0)", snippet: "")
        }
        let text = CitationText.render("Span [1-3].", sources: rangeSources)
        XCTAssertEqual(String(text.characters), "Span [1,2,3].")
        // A grouped chip is one link, to its first source; the rest are in the list.
        XCTAssertEqual(text.runs.compactMap(\.link), [URL(string: "https://retrieved.example/1")!])
    }
}
