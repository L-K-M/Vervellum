import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class EvidenceExtractorTests: XCTestCase {

    func testExtractsAndNumbersHits() {
        let payload: [String: Any] = ["results": [
            ["title": "First", "url": "https://a.example.com/1", "snippet": "One."],
            ["title": "Second", "link": "https://b.example.com/2", "content": "Two."],
        ]]
        let sources = EvidenceExtractor.sources(from: [payload])
        XCTAssertEqual(sources.map(\.number), [1, 2])
        XCTAssertEqual(sources[0].title, "First")
        XCTAssertEqual(sources[1].snippet, "Two.")
        XCTAssertEqual(sources[1].domain, "b.example.com")
    }

    /// Two searches routinely surface the same page; giving it two citation numbers
    /// would make the source list lie about how much evidence there is.
    func testCollapsesDuplicateURLs() {
        let first: [String: Any] = ["results": [["title": "X", "url": "https://a.example.com/1"]]]
        let second: [String: Any] = ["results": [["title": "X again", "url": "https://a.example.com/1"]]]
        XCTAssertEqual(EvidenceExtractor.sources(from: [first, second]).count, 1)
    }

    func testReadsHitsFromAnMCPTextBlock() {
        let inner = #"{"results":[{"title":"Inner","url":"https://c.example.com/3","snippet":"Three."}]}"#
        let payload: [String: Any] = ["content": [["type": "text", "text": inner]]]
        let sources = EvidenceExtractor.sources(from: [payload])
        XCTAssertEqual(sources.first?.title, "Inner")
    }

    func testStripsWWWFromTheDisplayedDomain() {
        let payload: [String: Any] = ["results": [["title": "T", "url": "https://www.example.com/x"]]]
        XCTAssertEqual(EvidenceExtractor.sources(from: [payload]).first?.domain, "example.com")
    }

    func testFallsBackToAReadableTitleWhenNoneIsGiven() {
        let payload: [String: Any] = ["results": [["url": "https://example.com/some-long-slug"]]]
        let title = EvidenceExtractor.sources(from: [payload]).first?.title ?? ""
        XCTAssertTrue(title.contains("example.com"))
        XCTAssertTrue(title.contains("some long slug"))
    }

    func testTruncatesLongSnippetsOnAWordBoundary() {
        let long = String(repeating: "word ", count: 500)
        let payload: [String: Any] = ["results": [["title": "T", "url": "https://e.example.com/x",
                                                   "snippet": long]]]
        let snippet = EvidenceExtractor.sources(from: [payload]).first?.snippet ?? ""
        XCTAssertLessThanOrEqual(snippet.count, EvidenceExtractor.maxSnippetLength + 1)
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testCapsTheNumberOfSources() {
        let hits = (0..<80).map { ["title": "T\($0)", "url": "https://e\($0).example.com/x"] }
        let payload: [String: Any] = ["results": hits]
        XCTAssertEqual(EvidenceExtractor.sources(from: [payload]).count, EvidenceExtractor.maxSources)
    }

    func testIgnoresIconFieldsAndUnusableLinks() {
        let payload: [String: Any] = ["results": [
            ["title": "Icon only", "favicon": "https://cdn.example.com/f.ico"],
            ["title": "Bad scheme", "url": "ftp://example.com/x"],
            ["title": "Good", "url": "https://good.example.com/x"],
        ]]
        let sources = EvidenceExtractor.sources(from: [payload])
        XCTAssertEqual(sources.map(\.title), ["Good"])
    }

    /// A server may return its results as prose rather than JSON. A link in prose is
    /// still evidence, and the words around it are its snippet.
    func testHarvestsHitsFromAProseTextBlock() {
        let prose = """
            1. **Patton's nose** — an unusually specific claim.
               https://history.example.com/patton-nose
               The general's medical records mention no such measurement.

            2. Obama's age
               https://bio.example.com/obama
               Born August 4, 1961.
            """
        let payload: [String: Any] = ["content": [["type": "text", "text": prose]]]
        let sources = EvidenceExtractor.sources(from: [payload])
        XCTAssertEqual(sources.map(\.url),
                       ["https://history.example.com/patton-nose", "https://bio.example.com/obama"])
        XCTAssertEqual(sources[0].title, "Patton's nose — an unusually specific claim.")
        XCTAssertTrue(sources[0].snippet.contains("medical records"))
        XCTAssertFalse(sources[0].snippet.contains("https://"))
        XCTAssertEqual(sources[1].title, "Obama's age")
        XCTAssertTrue(sources[1].snippet.contains("1961"))
    }

    /// A list with no blank lines between entries still yields one hit per link.
    func testSplitsADenseProseListPerLink() {
        let prose = "Result A https://a.example.com/1 summary a\nResult B https://b.example.com/2 summary b"
        let payload: [String: Any] = ["content": [["type": "text", "text": prose]]]
        let sources = EvidenceExtractor.sources(from: [payload])
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources[0].snippet.contains("summary a"))
        XCTAssertFalse(sources[0].snippet.contains("summary b"))
    }

    /// A link mentioned inside a source's own summary is not a second source.
    func testDoesNotMineASourcesOwnSummaryForLinks() {
        let payload: [String: Any] = ["results": [
            ["title": "T", "url": "https://a.example.com/1",
             "snippet": "See also https://elsewhere.example.com/x for context."],
        ]]
        XCTAssertEqual(EvidenceExtractor.sources(from: [payload]).map(\.url), ["https://a.example.com/1"])
    }

    /// The shape description exists for the log, which must never contain a result.
    func testShapeDescribesStructureWithoutContent() {
        let inner = #"[{"title":"Secret title","link":"https://s.example.com/x"}]"#
        let payload: [String: Any] = ["content": [["type": "text", "text": inner]], "isError": false]
        let shape = EvidenceExtractor.shape(of: payload)
        XCTAssertTrue(shape.contains("content"))
        XCTAssertTrue(shape.contains("link"))
        XCTAssertTrue(shape.contains("json-string"))
        XCTAssertFalse(shape.contains("Secret title"))
        XCTAssertFalse(shape.contains("s.example.com"))
    }

    func testHandlesAnEmptyResult() {
        XCTAssertTrue(EvidenceExtractor.sources(from: []).isEmpty)
        XCTAssertTrue(EvidenceExtractor.sources(from: [[String: Any]()]).isEmpty)
    }

    func testHonoursAStartingNumber() {
        let payload: [String: Any] = ["results": [["title": "T", "url": "https://e.example.com/x"]]]
        XCTAssertEqual(EvidenceExtractor.sources(from: [payload], startingAt: 5).first?.number, 5)
    }
}

/// Two people with the same server response must see the same source numbers.
final class EvidenceNumberingTests: XCTestCase {

    func testNumberingFollowsSortedKeysNotDictionaryOrder() {
        let result: [String: Any] = [
            "results": [["url": "https://b.example.com/", "title": "B"]],
            "related": [["url": "https://a.example.com/", "title": "A"]],
        ]
        let numbered = (0..<20).map { _ in EvidenceExtractor.sources(from: [result]).map(\.url) }
        XCTAssertEqual(Set(numbered.map { $0.joined(separator: " ") }).count, 1, "numbering varied between runs")
        // "related" sorts before "results".
        XCTAssertEqual(numbered[0], ["https://a.example.com/", "https://b.example.com/"])
    }
}
