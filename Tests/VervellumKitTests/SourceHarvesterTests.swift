import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class SourceHarvesterTests: XCTestCase {

    func testFindsLinkKeysAtAnyDepth() {
        let payload: [String: Any] = [
            "results": [
                ["title": "One", "url": "https://example.com/a"],
                ["title": "Two", "link": "https://example.org/b"],
                ["nested": ["deep": ["href": "https://example.net/c"]]],
            ],
        ]
        XCTAssertEqual(SourceHarvester.urls(in: payload),
                       ["https://example.com/a", "https://example.org/b", "https://example.net/c"])
    }

    /// The z.ai MCP server returns its real payload as a JSON string inside a text
    /// content block. Missing that would leave the allow-list empty and reject every
    /// citation the model made.
    func testParsesJSONEmbeddedInAnMCPTextBlock() {
        let inner = #"{"results":[{"url":"https://example.com/inner"}]}"#
        let payload: [String: Any] = ["content": [["type": "text", "text": inner]]]
        XCTAssertEqual(SourceHarvester.urls(in: payload), ["https://example.com/inner"])
    }

    func testFindsBareURLsInProse() {
        let payload = ["summary": "See https://example.com/page, and https://example.org/other."]
        XCTAssertEqual(SourceHarvester.urls(in: payload),
                       ["https://example.com/page", "https://example.org/other"])
    }

    /// A favicon is not a source. Allowing icon fields through would let a model
    /// "cite" a CDN image.
    func testSkipsIconFields() {
        let payload: [String: Any] = [
            "icon": "https://cdn.example.com/favicon.ico",
            "favicon": "https://cdn.example.com/fav.png",
            "site_icon": "https://cdn.example.com/site.png",
            "url": "https://example.com/real",
        ]
        XCTAssertEqual(SourceHarvester.urls(in: payload), ["https://example.com/real"])
    }

    func testRejectsNonHTTPAndHostlessURLs() {
        XCTAssertNil(SourceHarvester.normalized("ftp://example.com/x"))
        XCTAssertNil(SourceHarvester.normalized("javascript:alert(1)"))
        XCTAssertNil(SourceHarvester.normalized("https://"))
        XCTAssertNil(SourceHarvester.normalized("not a url"))
        XCTAssertNotNil(SourceHarvester.normalized("http://localhost:8080/x"))
    }

    func testRejectsUserinfoInStructuredAndProseSources() {
        let links = [
            "https://user:password@example.com/page",
            "https://user@example.com/page",
            "https://:password@example.com/page",
            "https://@example.com/page",
            "https://user%40name:secret@example.com/page",
        ]
        for link in links {
            XCTAssertNil(SourceHarvester.normalized(link, trimmingPunctuation: false), link)
            XCTAssertTrue(SourceHarvester.urls(in: ["url": link]).isEmpty, link)
            XCTAssertTrue(SourceHarvester.bareURLs(in: "See \(link) today.").isEmpty, link)
            XCTAssertNil(DirectPageReader.fetchableURL(link), link)
        }
    }

    /// A URL that ends a sentence picks up the punctuation. The allow-list and the
    /// audit scan must strip it identically or a legitimate citation fails.
    func testTrimsTrailingPunctuation() {
        XCTAssertEqual(SourceHarvester.normalized("https://example.com/a."), "https://example.com/a")
        XCTAssertEqual(SourceHarvester.normalized("https://example.com/a),"), "https://example.com/a")
        XCTAssertEqual(SourceHarvester.normalized("https://example.com/a\""), "https://example.com/a")
    }

    /// A structured field is an address, not prose: its closing parenthesis is part of
    /// the path, and trimming it would point at a page that does not exist.
    func testKeepsTheAddressOfAStructuredField() {
        let planet = "https://en.wikipedia.org/wiki/Mercury_(planet)"
        XCTAssertEqual(SourceHarvester.normalized(planet, trimmingPunctuation: false), planet)
        XCTAssertEqual(SourceHarvester.normalized("https://example.com/a.", trimmingPunctuation: false),
                       "https://example.com/a.")
        XCTAssertNil(SourceHarvester.normalized("ftp://example.com/(x)", trimmingPunctuation: false))
        XCTAssertEqual(SourceHarvester.urls(in: ["results": [["url": planet]]]), [planet])
    }

    func testDeeplyNestedPayloadTerminates() {
        var nested: Any = ["url": "https://example.com/deep"]
        for _ in 0..<200 { nested = ["next": nested] }
        // The depth guard means the innermost URL is not found; what matters is that
        // this returns at all rather than recursing until the stack gives out.
        XCTAssertTrue(SourceHarvester.urls(in: nested).isEmpty)
    }

    func testHandlesEmptyAndScalarInput() {
        XCTAssertTrue(SourceHarvester.urls(in: nil).isEmpty)
        XCTAssertTrue(SourceHarvester.urls(in: 42).isEmpty)
        XCTAssertTrue(SourceHarvester.urls(in: [String: Any]()).isEmpty)
    }

    /// Every click path that opens an address a thread carries goes through
    /// `openableURL`, so the answer chips, the source rows and the finding chips all
    /// agree. A stored `threads.json` is decoded without re-validation, which is why
    /// the check belongs at the click and not only at harvest time.
    func testOnlyAbsoluteHTTPAddressesAreOpenable() {
        XCTAssertNotNil(SourceHarvester.openableURL("https://example.com/a"))
        XCTAssertNotNil(SourceHarvester.openableURL("http://localhost:3000/a"))
        XCTAssertNotNil(SourceHarvester.openableURL("https://example.com/a(1)"))
        XCTAssertNil(SourceHarvester.openableURL("file:///etc/passwd"))
        XCTAssertNil(SourceHarvester.openableURL("javascript:alert(1)"))
        XCTAssertNil(SourceHarvester.openableURL("ftp://example.com/a"))
        XCTAssertNil(SourceHarvester.openableURL("https://user:pass@example.com/a"))
        // Percent-encoded userinfo is still userinfo: `URLComponents` exposes it as a
        // user, and a click must not carry it either way.
        XCTAssertNil(SourceHarvester.openableURL("https://user%40x:pass@example.com/a"))
        XCTAssertNil(SourceHarvester.openableURL("https:///a"))
        XCTAssertNil(SourceHarvester.openableURL("example.com"))
        XCTAssertNil(SourceHarvester.openableURL(""))
    }
}
