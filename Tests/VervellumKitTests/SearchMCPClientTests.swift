import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class SearchMCPClientTests: XCTestCase {

    /// A gateway's own message is only ever *classified*, never shown. The
    /// classification must not tell a user with an exhausted balance to replace a key
    /// that works.
    func testQuotaMessagesAreNotReadAsABadKey() {
        XCTAssertFalse(SearchMCPClient.describesAuthenticationFailure("Insufficient token balance"))
        XCTAssertFalse(SearchMCPClient.describesAuthenticationFailure("tokens per minute limit exceeded"))
        XCTAssertFalse(SearchMCPClient.describesAuthenticationFailure("token quota exhausted"))
    }

    func testKeyMessagesAreReadAsABadKey() {
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("Authentication failed"))
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("Invalid API key"))
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("invalid token"))
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("Token expired"))
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("Unauthorized"))
    }

    // MARK: Tool selection

    private func tool(_ name: String, description: String? = nil,
                      properties: [String: Any]? = ["query": ["type": "string"]]) -> [String: Any] {
        var entry: [String: Any] = ["name": name]
        if let description { entry["description"] = description }
        if let properties { entry["inputSchema"] = ["type": "object", "properties": properties] }
        return entry
    }

    func testPrefersTheKnownZAIName() {
        let tools = [tool("fetch_page"), tool("web_search_prime", properties: ["search_query": ["type": "string"]])]
        XCTAssertEqual(SearchMCPClient.resolveSearchTool(from: tools)?.name, "web_search_prime")
    }

    /// The names the common MCP search servers ship all pass the handshake.
    func testAcceptsOtherVendorsKnownNames() {
        for name in ["brave_web_search", "tavily-search", "web_search_exa", "searxng_web_search"] {
            let tools = [tool("brave_local_search"), tool(name)]
            XCTAssertEqual(SearchMCPClient.resolveSearchTool(from: tools)?.name, name, name)
        }
    }

    func testASingleUnknownToolIsNotAssumedToBeWebSearch() {
        for name in ["lookup", "delete_everything", "search_history"] {
            XCTAssertNil(SearchMCPClient.resolveSearchTool(from: [tool(name)]))
        }
    }

    func testAmbiguousWebSearchToolsRequireAnExplicitKnownName() {
        let tools = [tool("web_search_alpha"), tool("web_search_beta")]
        XCTAssertNil(SearchMCPClient.resolveSearchTool(from: tools))
    }

    /// Among several unknown tools, the one that says "search" and takes a query wins.
    func testFallsBackToAToolThatSearchesWithAQuery() {
        let tools = [
            tool("get_page", description: "Fetch a URL", properties: ["url": ["type": "string"]]),
            tool("find_pages", description: "Search the web", properties: ["query": ["type": "string"]]),
        ]
        XCTAssertEqual(SearchMCPClient.resolveSearchTool(from: tools)?.name, "find_pages")
    }

    /// "search" in the name is not enough on its own: a tool with no query argument is
    /// not a web search, and choosing it would send the model's query into the void.
    func testAToolThatSearchesWithoutAQueryIsNotChosen() {
        let tools = [
            tool("search_history", properties: ["days": ["type": "integer"]]),
            tool("fetch_page", properties: ["url": ["type": "string"]]),
        ]
        XCTAssertNil(SearchMCPClient.resolveSearchTool(from: tools))
    }

    func testAQueryPropertyMayBeAUnionType() {
        let tools = [tool("a"), tool("web_search_thing", description: "search",
                                     properties: ["query": ["type": ["string", "null"]]])]
        XCTAssertEqual(SearchMCPClient.resolveSearchTool(from: tools)?.name, "web_search_thing")
    }

    func testAnUnknownToolWithoutAQuerySchemaIsRejected() {
        let tools = [tool("a"), tool("web_search_beta", description: "search", properties: nil)]
        XCTAssertNil(SearchMCPClient.resolveSearchTool(from: tools))
    }

    func testAnEmptyOrNamelessListingResolvesNothing() {
        XCTAssertNil(SearchMCPClient.resolveSearchTool(from: []))
        XCTAssertNil(SearchMCPClient.resolveSearchTool(from: [["description": "search"]]))
    }

    /// The resolved tool keeps the schema the model will be asked to follow.
    func testTheResolvedToolCarriesItsSchema() throws {
        let tools = [tool("web_search_prime", properties: ["search_query": ["type": "string"]])]
        let resolved = try XCTUnwrap(SearchMCPClient.resolveSearchTool(from: tools))
        XCTAssertEqual(resolved.propertyKeys, ["search_query"])
    }
}
