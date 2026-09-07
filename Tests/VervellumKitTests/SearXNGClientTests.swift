import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The SearXNG backend's pure parts: the address it derives, the URL it builds, and the
/// schema it advertises to the planner.
final class SearXNGClientTests: XCTestCase {

    // MARK: Instance address

    /// Users paste the instance's home page, because that is what a SearXNG instance
    /// advertises.
    func testAppendsSearchToAnInstanceAddress() {
        XCTAssertEqual(ProviderSettings.searxngSearchURL(from: "https://searx.example.org")?.absoluteString,
                       "https://searx.example.org/search")
        XCTAssertEqual(ProviderSettings.searxngSearchURL(from: "https://searx.example.org/")?.absoluteString,
                       "https://searx.example.org/search")
    }

    /// An instance behind a path prefix must work without a second setting.
    func testKeepsAPathPrefixAndDoesNotDoubleTheSearchSegment() {
        XCTAssertEqual(
            ProviderSettings.searxngSearchURL(from: "https://example.org/searx")?.absoluteString,
            "https://example.org/searx/search")
        XCTAssertEqual(
            ProviderSettings.searxngSearchURL(from: "https://example.org/searx/search")?.absoluteString,
            "https://example.org/searx/search")
    }

    /// A query pasted with the address would be merged with the search arguments, which
    /// is a confusing way to send a filter nobody asked for.
    func testDropsAPastedQueryAndFragment() {
        XCTAssertEqual(
            ProviderSettings.searxngSearchURL(from: "https://searx.example.org/search?q=test#top")?
                .absoluteString,
            "https://searx.example.org/search")
    }

    /// The same hygiene every endpoint gets: HTTPS, no credentials in the URL, a host.
    func testRejectsUnusableAddresses() {
        XCTAssertNil(ProviderSettings.searxngSearchURL(from: "http://searx.example.org"))
        XCTAssertNil(ProviderSettings.searxngSearchURL(from: "https://user:pass@searx.example.org"))
        XCTAssertNil(ProviderSettings.searxngSearchURL(from: ""))
        XCTAssertNil(ProviderSettings.searxngSearchURL(from: "not a url"))
    }

    /// A self-hosted instance on the same machine has no certificate, exactly like a
    /// local model server.
    func testAllowsHTTPOnLoopback() {
        XCTAssertEqual(ProviderSettings.searxngSearchURL(from: "http://localhost:8888")?.absoluteString,
                       "http://localhost:8888/search")
    }

    // MARK: Request URL

    private func base() throws -> URL {
        try XCTUnwrap(ProviderSettings.searxngSearchURL(from: "https://searx.example.org"))
    }

    func testAlwaysAsksForJSONAndSortsItsParameters() throws {
        let url = try XCTUnwrap(SearXNGClient.requestURL(
            base: base(), arguments: ["q": "swift concurrency", "time_range": "month"]))
        XCTAssertEqual(url.absoluteString,
                       "https://searx.example.org/search?format=json&q=swift%20concurrency&time_range=month")
    }

    /// A query holding `&` or `#` must not split into extra parameters: a search for
    /// "rust & c++" is one query, not a query plus a stray filter.
    func testPercentEncodesAQueryThatLooksLikeMoreParameters() throws {
        let url = try XCTUnwrap(SearXNGClient.requestURL(
            base: base(), arguments: ["q": "rust & c++ #perf"]))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.count, 2, "format plus one query, not four parameters")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "rust & c++ #perf")
        XCTAssertNil(url.fragment)
    }

    /// The model does not get to choose the response format: a `format` argument is not
    /// in the schema, and one that arrived anyway must not turn the reply into HTML.
    func testAModelSuppliedFormatIsIgnored() throws {
        let url = try XCTUnwrap(SearXNGClient.requestURL(
            base: base(), arguments: ["q": "x", "format": "html"]))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "format" }.map(\.value), ["json"])
    }

    /// An empty or whitespace-only argument is left out rather than sent blank, which
    /// some engines treat as an explicit "match nothing".
    func testBlankArgumentsAreLeftOut() throws {
        let url = try XCTUnwrap(SearXNGClient.requestURL(
            base: base(), arguments: ["q": "x", "categories": "   ", "language": ""]))
        let names = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            .map(\.name)
        XCTAssertEqual(names, ["format", "q"])
    }

    /// A model that wrote a number where the schema says string misread the schema, but
    /// the request is better spent than refused.
    func testNonStringArgumentsAreRendered() throws {
        let url = try XCTUnwrap(SearXNGClient.requestURL(
            base: base(), arguments: ["q": "x", "categories": ["news", "science"], "language": 1]))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "categories" }?.value, "news,science")
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "1")
    }

    // MARK: Advertised schema

    /// The planner writes its arguments against this, and they are checked back against
    /// it — so it has to be a real schema, with the query required.
    func testTheAdvertisedSchemaRequiresAQuery() throws {
        let descriptor = SearXNGClient(searchURL: try base(), apiKey: nil,
                                       trace: ResearchTrace(sink: SilentLog())).toolDescriptor
        XCTAssertEqual(descriptor["name"] as? String, SearXNGClient.toolName)
        let schema = try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["q"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertTrue(properties.keys.contains("q"))
        XCTAssertTrue(properties.keys.contains("time_range"))
    }

    /// The same tool name the SearXNG MCP bridge advertises, so a plan and a process
    /// trail read identically whichever way the instance is reached — and so the name is
    /// one the MCP client would itself accept.
    func testTheToolNameMatchesTheMCPBridge() {
        XCTAssertEqual(SearXNGClient.toolName, "searxng_web_search")
        let listing: [[String: Any]] = [[
            "name": SearXNGClient.toolName,
            "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]]],
        ]]
        XCTAssertNotNil(SearchMCPClient.resolveSearchTool(from: listing))
    }

    // MARK: Argument checking

    func testArgumentsAreCheckedAgainstTheAdvertisedSchema() throws {
        let client = SearXNGClient(searchURL: try base(), apiKey: nil,
                                   trace: ResearchTrace(sink: SilentLog()))
        XCTAssertNoThrow(try client.validate(["q": "x"], required: ["q"], properties: ["q", "language"]))
        XCTAssertThrowsError(try client.validate([:], required: ["q"], properties: ["q"]),
                             "A missing required argument is the model misreading the schema")
        XCTAssertThrowsError(try client.validate(["q": "x", "invented": "y"],
                                                 required: ["q"], properties: ["q"]),
                             "An invented argument would spend a request to get an error back")
    }
}
