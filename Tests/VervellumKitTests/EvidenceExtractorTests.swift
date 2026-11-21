import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class EvidenceExtractorTests: XCTestCase {

    func testPublicationMetadataCannotCrowdLaterSourcesOutOfEvidence() {
        let results = [
            ["url": "https://first.example", "date": String(repeating: "x", count: 100_000)],
            ["url": "https://second.example", "publishedAt": "3\u{202E} Mai\n2026"],
        ]
        let sources = EvidenceExtractor.sources(from: results)
        XCTAssertEqual(sources.map(\.publishedAt), [nil, "3 Mai 2026"])
        let evidence = ResearchContext.evidence(from: sources)
        XCTAssertEqual(evidence.entries.compactMap { $0["number"] as? Int }, [1, 2])
        XCTAssertNil(evidence.entries.first?["published"])
    }

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

    /// Wikipedia's disambiguated titles end in a parenthesis; a source link that lost
    /// it would open the wrong page.
    func testKeepsParenthesesInAStructuredURL() {
        let planet = "https://en.wikipedia.org/wiki/Mercury_(planet)"
        let payload: [String: Any] = ["results": [["title": "Mercury (planet)", "url": planet]]]
        XCTAssertEqual(EvidenceExtractor.sources(from: [payload]).first?.url, planet)
    }

    /// Two searches routinely surface the same page; giving it two citation numbers
    /// would make the source list lie about how much evidence there is.
    func testCollapsesDuplicateURLs() {
        let first: [String: Any] = ["results": [["title": "X", "url": "https://a.example.com/1"]]]
        let second: [String: Any] = ["results": [["title": "X again", "url": "https://a.example.com/1"]]]
        XCTAssertEqual(EvidenceExtractor.sources(from: [first, second]).count, 1)
    }

    func testURLVariantsAcrossSearchesShareOneNumber() {
        let first = "https://a.example/page?utm_source=first#section"
        let results: [Any] = [
            ["url": first, "title": "First spelling"],
            ["url": "https://a.example/page", "title": "Same page"],
            "Same page: https://a.example/page?utm_campaign=second",
            ["url": "https://a.example/page?id=2", "title": "Different page"],
        ]
        let sources = EvidenceExtractor.sources(from: results, startingAt: 5)
        XCTAssertEqual(sources.map(\.number), [5, 6])
        XCTAssertEqual(sources.map(\.url), [first, "https://a.example/page?id=2"])
        XCTAssertEqual(sources.first?.title, "First spelling")
    }

    /// Search rank is not a diversity policy: one well-ranked domain can fill the top
    /// of the list with several spellings of the same page, which the answer then
    /// reads as independent agreement. The cap keeps any single voice a minority, and
    /// the wider collection pool is what lets the varied hits below the farm in.
    func testCapsOneDomainsShareOfTheList() {
        let farm = (1...30).map { ["title": "Farm \($0)",
                                   "url": "https://farm.example.com/\($0)"] }
        let varied = (1...6).map { ["title": "Varied \($0)",
                                    "url": "https://site\($0).example.org/\($0)"] }
        let payload: [String: Any] = ["results": farm + varied]
        let sources = EvidenceExtractor.sources(from: [payload])

        XCTAssertEqual(sources.filter { $0.domain == "farm.example.com" }.count,
                       EvidenceExtractor.maxSourcesPerDomain)
        // The varied hits sat below 30 same-domain hits: only a pool wider than
        // maxSources reaches them at all.
        XCTAssertEqual(sources.count, EvidenceExtractor.maxSourcesPerDomain + 6)
        // Rank order survives the filter — the first four are the farm's top hits,
        // then the varied sites in the order they were ranked. The numbering alone
        // would pass under any permutation.
        XCTAssertEqual(sources.prefix(EvidenceExtractor.maxSourcesPerDomain).map(\.domain),
                       Array(repeating: "farm.example.com",
                             count: EvidenceExtractor.maxSourcesPerDomain))
        XCTAssertEqual(sources.dropFirst(EvidenceExtractor.maxSourcesPerDomain).map(\.domain),
                       (1...6).map { "site\($0).example.org" })
    }

    /// The displayed domain and the key the cap counts are the same computation —
    /// pinned, because a drift between them would group citations by one domain while
    /// showing the reader another.
    func testDisplayedDomainAndCapKeyCannotDrift() {
        let cases: [(url: String, domain: String)] = [
            ("https://WWW.Example.COM/a", "example.com"),
            ("https://www.example.com/b", "example.com"),
            ("https://example.com:8443/c", "example.com"),
            ("https://en.example.org/d", "en.example.org"),
            ("not a url", "not a url"),
        ]
        for (url, domain) in cases {
            XCTAssertEqual(Source(number: 1, url: url, title: "", snippet: "").domain,
                           domain, url)
            XCTAssertEqual(EvidenceExtractor.domainKey(for: url), domain, url)
        }
    }

    /// The cap is a ceiling, not a quota: a topic that lives on one site keeps what
    /// that site has, up to the cap.
    func testADomainBelowTheCapKeepsEverything() {
        let payload: [String: Any] = ["results": [
            ["title": "One", "url": "https://docs.example.com/1"],
            ["title": "Two", "url": "https://docs.example.com/2"],
        ]]
        XCTAssertEqual(EvidenceExtractor.sources(from: [payload]).count, 2)
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

    /// A hostile or broken result can carry a bidi override in its title (so the row
    /// displays something other than what was read) or a NUL (which truncates a GTK
    /// C string mid-title). Neither survives the harvest.
    func testBidiAndNULCharactersAreDroppedFromTitlesAndSnippets() {
        let payload: [String: Any] = ["results": [
            ["title": "Trust\u{202E}me", "url": "https://a.example/1", "snippet": "S\u{0}afe"],
        ]]
        let source = EvidenceExtractor.sources(from: [payload]).first
        XCTAssertEqual(source?.title, "Trustme")
        XCTAssertEqual(source?.snippet, "Safe")
    }

    /// The URL is display text as well as a fetch target: an override in the path
    /// spoofs the domain the panel shows, and a NUL truncates a GTK label. Both
    /// survive `URLComponents` — and so `normalized` — so they must be stripped at
    /// the same place the title and snippet are.
    func testBidiAndNULCharactersAreDroppedFromURLs() {
        let payload: [String: Any] = ["results": [
            ["title": "T", "url": "https://a.example/pa\u{202E}ge\u{0}"],
        ]]
        let source = EvidenceExtractor.sources(from: [payload]).first
        XCTAssertEqual(source?.url, "https://a.example/page")
        XCTAssertEqual(source?.domain, "a.example")
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

    /// Prose backends use the same parenthesized Wikipedia paths as structured ones.
    /// The closing parenthesis is part of this address, not punctuation around it.
    func testKeepsParenthesesInAProseURL() {
        let planet = "https://en.wikipedia.org/wiki/Mercury_(planet)"
        let prose = "Mercury (planet)\n\(planet)\nThe smallest planet in the Solar System."
        let payload: [String: Any] = ["content": [["type": "text", "text": prose]]]

        let source = EvidenceExtractor.sources(from: [payload]).first

        XCTAssertEqual(source?.url, planet)
        XCTAssertFalse(source?.snippet.contains("https://") ?? true,
                       "the complete repaired address should be removed from the snippet")
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
