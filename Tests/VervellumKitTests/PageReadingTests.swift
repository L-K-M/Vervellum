import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The page-reading path's pure parts: turning HTML into readable text, deciding what
/// is fetchable, and reading a reader server's reply.
final class PageReadingTests: XCTestCase {

    // MARK: HTML → text

    func testExtractsProseAndKeepsBlockBoundaries() {
        let html = """
            <html><body><p>First paragraph.</p><p>Second paragraph.</p>
            <ul><li>One</li><li>Two</li></ul></body></html>
            """
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("First paragraph."))
        XCTAssertTrue(text.contains("Second paragraph."))
        // Without block breaks the model reads "First paragraph.Second paragraph." as
        // one sentence, which is how a summary becomes a misquotation.
        XCTAssertFalse(text.contains("paragraph.Second"))
        XCTAssertTrue(text.contains("One"))
        XCTAssertTrue(text.contains("Two"))
    }

    /// Script and style content is never prose, and a page's script can be most of its
    /// bytes — spending the evidence budget on it would crowd out a whole source.
    func testDropsScriptStyleAndChrome() {
        let html = """
            <html><head><style>body { color: red }</style></head>
            <body><nav><a href="/x">Nav link</a></nav>
            <script>var secret = "do not read me";</script>
            <p>The actual sentence.</p>
            <footer>Copyright notice</footer></body></html>
            """
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("The actual sentence."))
        XCTAssertFalse(text.contains("do not read me"))
        XCTAssertFalse(text.contains("color: red"))
        XCTAssertFalse(text.contains("Nav link"))
        XCTAssertFalse(text.contains("Copyright notice"))
    }

    /// A page that says where its content is has told us; a model shown the site's
    /// sidebar under four sources finds agreement between them that does not exist.
    func testPrefersTheArticleWhenThePageMarksOne() {
        let filler = String(repeating: "The article body goes on. ", count: 20)
        let html = """
            <html><body><div>Sidebar clutter that is not the article at all.</div>
            <main><p>\(filler)</p></main></body></html>
            """
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("The article body goes on."))
        XCTAssertFalse(text.contains("Sidebar clutter"))
    }

    /// A `<main>` holding only a heading is a page whose content is elsewhere: trusting
    /// the marker there loses the page.
    func testAnEmptyArticleMarkerFallsBackToTheDocument() {
        let filler = String(repeating: "Real content lives out here. ", count: 20)
        let html = "<html><body><main><h1>Title</h1></main><p>\(filler)</p></body></html>"
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("Real content lives out here."))
    }

    func testDecodesTheEntitiesThatAppearInProse() {
        let html = "<p>Ben &amp; Jerry&rsquo;s &mdash; 20&nbsp;&deg;C &#8212; &#x41;.</p>"
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("Ben & Jerry’s"))
        XCTAssertTrue(text.contains("—"))
        XCTAssertTrue(text.contains("°C"))
        XCTAssertTrue(text.contains("A."))
    }

    /// An unknown entity survives as its own text rather than as a wrong character.
    func testAnUnknownEntityIsLeftAlone() {
        let body = String(repeating: "padding sentence. ", count: 10)
        let text = HTMLTextExtractor.text(from: "<p>&notarealentity; \(body)</p>", limit: 4_000)
        XCTAssertTrue(text.contains("&notarealentity;"))
    }

    /// "a < b" in prose is not a tag, and treating it as one eats the rest of the page.
    func testAStrayLessThanIsNotTreatedAsATag() {
        let body = String(repeating: "padding sentence. ", count: 10)
        let text = HTMLTextExtractor.text(from: "<p>If a < b then something. \(body)</p>",
                                          limit: 4_000)
        XCTAssertTrue(text.contains("If a < b then something."))
    }

    /// A page cut off mid-argument that does not say so is one a model will treat as
    /// complete.
    func testTruncationIsMarked() {
        let html = "<p>" + String(repeating: "word ", count: 4_000) + "</p>"
        let text = HTMLTextExtractor.text(from: html, limit: 500, minimum: 0)
        XCTAssertLessThanOrEqual(text.count, 520)
        XCTAssertTrue(text.hasSuffix("[…]"))
    }

    /// Whatever came back was navigation, a consent wall, or a page that builds itself
    /// in JavaScript. Offering it as "the page" would be a lie with a label on it.
    func testAPageWithNoRealTextReadsAsNothing() {
        XCTAssertEqual(HTMLTextExtractor.text(from: "<html><body><div></div></body></html>"), "")
        XCTAssertEqual(HTMLTextExtractor.text(from: "<html><body><p>Enable JS</p></body></html>"), "")
    }

    // MARK: Fetchable addresses

    /// A redirect target came, ultimately, from a search result. Every hop is checked
    /// rather than trusted because the first one passed.
    func testOnlyAbsoluteHTTPAddressesAreFetchable() {
        XCTAssertNotNil(DirectPageReader.fetchableURL("https://example.com/a"))
        XCTAssertNotNil(DirectPageReader.fetchableURL("http://example.com/a"))
        XCTAssertNil(DirectPageReader.fetchableURL("file:///etc/passwd"))
        XCTAssertNil(DirectPageReader.fetchableURL("data:text/html,<p>x</p>"))
        XCTAssertNil(DirectPageReader.fetchableURL("/relative/path"))
        XCTAssertNil(DirectPageReader.fetchableURL(""))
    }

    /// A page in an encoding nobody declared is read with mojibake in the accents
    /// rather than dropped entirely.
    func testDecodingFallsBackRatherThanFailing() {
        let latin1 = Data([0x3C, 0x70, 0x3E, 0xE9, 0x3C, 0x2F, 0x70, 0x3E]) // <p>é</p> in Latin-1
        XCTAssertNotNil(DirectPageReader.decode(latin1, contentType: "text/html; charset=iso-8859-1"))
        XCTAssertNotNil(DirectPageReader.decode(latin1, contentType: "text/html"))
        XCTAssertEqual(DirectPageReader.decode(Data("<p>ok</p>".utf8), contentType: "text/html"),
                       "<p>ok</p>")
    }

    // MARK: The reader server's reply

    /// The published documentation names the endpoint and the tool but not the argument
    /// schema, so the argument the URL goes in is read from what the server advertised.
    func testTheURLArgumentComesFromTheAdvertisedSchema() {
        XCTAssertEqual(ReaderMCPClient.urlArgument(in: [
            "properties": ["uri": ["type": "string"]], "required": ["uri"],
        ]), "uri")
        XCTAssertEqual(ReaderMCPClient.urlArgument(in: [
            "properties": ["page_url": ["type": "string"], "format": ["type": "string"]],
        ]), "page_url")
        // A reader with exactly one required argument has told us what it is, even
        // spelled unusually.
        XCTAssertEqual(ReaderMCPClient.urlArgument(in: ["required": ["address"]]), "address")
        // No schema at all: the documented spelling is the last resort.
        XCTAssertEqual(ReaderMCPClient.urlArgument(in: [:]), "url")
    }

    func testTheReaderToolIsResolvedByKnownNameOnly() {
        let listing: [[String: Any]] = [
            ["name": "delete_page"],
            ["name": "webReader", "inputSchema": ["required": ["url"]]],
        ]
        XCTAssertEqual(ReaderMCPClient.resolveReaderTool(from: listing),
                       ReaderMCPClient.ReaderTool(name: "webReader", urlArgument: "url"))
        XCTAssertNil(ReaderMCPClient.resolveReaderTool(from: [["name": "do_something"]]))
    }

    /// The standard MCP envelope splits one document across several text blocks, so the
    /// blocks are joined rather than the biggest one taken.
    func testTheStandardContentEnvelopeIsJoined() {
        let body = String(repeating: "Sentence of the page. ", count: 8)
        let result: [String: Any] = ["content": [
            ["type": "text", "text": "First half. " + body],
            ["type": "text", "text": "Second half. " + body],
        ]]
        let text = ReaderMCPClient.pageText(from: result)
        XCTAssertTrue(text.contains("First half."))
        XCTAssertTrue(text.contains("Second half."))
    }

    /// A reader returns a title, a description *and* the article under content-shaped
    /// keys; only one of them is the page.
    func testTheLongestContentFieldWins() {
        let article = String(repeating: "The article itself. ", count: 20)
        let result: [String: Any] = ["structuredContent": [
            "title": "Short", "text": "A one-line description.", "content": article,
        ]]
        XCTAssertTrue(ReaderMCPClient.pageText(from: result).contains("The article itself."))
    }

    /// A long URL sitting beside a short article must not win: only content-shaped keys
    /// are candidates.
    func testAMetadataStringIsNotMistakenForThePage() {
        let article = String(repeating: "Body sentence. ", count: 10)
        let result: [String: Any] = [
            "url": "https://example.com/" + String(repeating: "x", count: 4_000),
            "content": article,
        ]
        let text = ReaderMCPClient.pageText(from: result)
        XCTAssertTrue(text.contains("Body sentence."))
        XCTAssertFalse(text.contains("xxxx"))
    }

    /// A reader that returns markup is common, and markup in the evidence block is
    /// worse than useless.
    func testMarkupFromAReaderIsRead() {
        let body = String(repeating: "<p>A real sentence.</p>", count: 10)
        let result: [String: Any] = ["content": "<html><body>\(body)</body></html>"]
        let text = ReaderMCPClient.pageText(from: result)
        XCTAssertTrue(text.contains("A real sentence."))
        XCTAssertFalse(text.contains("<p>"))
    }

    // MARK: Settings

    /// Off is off: no reader is built, so nothing is fetched.
    func testNoReaderIsBuiltWhenReadingIsOff() throws {
        var settings = ProviderSettings(modelEndpoint: "https://a.example.com/v1", modelName: "m")
        settings.pageReading = .off
        XCTAssertNil(try PageReaderFactory.make(settings: settings, readerKey: nil,
                                                trace: ResearchTrace(sink: SilentLog())))
    }

    func testTheFactoryBuildsTheReaderTheSettingsName() throws {
        var settings = ProviderSettings(modelEndpoint: "https://a.example.com/v1", modelName: "m")
        let trace = ResearchTrace(sink: SilentLog())

        settings.pageReading = .direct
        let direct = try PageReaderFactory.make(settings: settings, readerKey: nil, trace: trace)
        XCTAssertNotNil(direct as? DirectPageReader)

        settings.pageReading = .reader
        let hosted = try PageReaderFactory.make(settings: settings, readerKey: "k", trace: trace)
        XCTAssertNotNil(hosted as? ReaderMCPClient)
        XCTAssertThrowsError(try PageReaderFactory.make(settings: settings, readerKey: nil,
                                                        trace: ResearchTrace(sink: SilentLog())),
                             "A hosted reader with no key is a configuration problem, not a fetch")
    }

    /// A source is "read" only when the answer could have used the page — which is why
    /// the runner clears the text rather than keeping it for the record.
    func testASourceIsOnlyReadWhenItCarriesText() {
        var source = Source(number: 1, url: "https://a.example.com", title: "T", snippet: "S")
        XCTAssertFalse(source.wasRead)
        source.fullText = ""
        XCTAssertFalse(source.wasRead)
        source.fullText = "The page."
        XCTAssertTrue(source.wasRead)
    }
}
