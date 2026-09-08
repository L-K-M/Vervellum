import Foundation

/// The web-search half of a Model Context Protocol server.
///
/// The protocol plumbing — the handshake, the negotiated version header, the session
/// header, JSON-or-SSE responses, the gateway's own error envelope — lives in
/// `MCPSession`, which is shared with the page reader. What is left here is the part
/// that is about *searching*: deciding which advertised tool is a web search, and
/// checking the model's arguments against the schema that tool published.
///
/// The tool's real `inputSchema` is fetched rather than assumed: the model is given
/// that schema to write its query arguments against, and the arguments are checked
/// back against it before the call goes out.
///
/// Recognized names cover z.ai, Brave, Tavily, Exa and SearXNG. Unknown operations
/// are never inferred from descriptions or query-shaped arguments.
/// Everything downstream is already backend-agnostic: the planner writes arguments
/// against whatever schema was advertised, and `EvidenceExtractor` walks any result.
///
/// One of two `SearchBackend`s. The interesting difference from `SearXNGClient` is that
/// an MCP server advertises its own tool and schema and this client *fetches* it, where
/// a bare JSON search API has nothing to advertise and its client supplies the schema.
final class SearchMCPClient: SearchBackend {

    /// One MCP tool as advertised by `tools/list`.
    struct Tool {
        let name: String
        let description: String?
        let inputSchema: [String: Any]

        var requiredKeys: [String] { inputSchema["required"] as? [String] ?? [] }
        var propertyKeys: Set<String> {
            guard let properties = inputSchema["properties"] as? [String: Any] else { return [] }
            return Set(properties.keys)
        }

    }

    private let session: MCPSession
    private let trace: ResearchTrace

    private(set) var tool: Tool?

    let backendName = "MCP server"

    /// Tool names known to be a web search: z.ai's two spellings first, then the names
    /// the common MCP search servers ship. Unknown operations are never inferred.
    private static let knownSearchToolNames: [String] = [
        "web_search_prime", "webSearchPrime",
        "brave_web_search", "tavily-search", "tavily_search", "web_search_exa",
        "searxng_web_search", "web_search",
    ]

    init(endpoint: URL, apiKey: String, trace: ResearchTrace,
         transport: any HTTPTransporting = HTTPTransport.shared) {
        self.session = MCPSession(endpoint: endpoint, apiKey: apiKey, subject: "search provider",
                                  trace: trace, transport: transport)
        self.trace = trace
    }

    // MARK: Handshake

    /// Performs the handshake and resolves the search tool. Must be called once
    /// before `search(arguments:)`.
    func connect() async throws {
        try await session.start()
        let listing = try await session.tools()
        guard let resolved = Self.resolveSearchTool(from: listing) else {
            // Names are provider-controlled too; never copy them into diagnostics.
            throw ResearchError("The search provider did not advertise a recognized web-search tool name. "
                                + "Check the endpoint's compatibility with the supported search providers.")
        }
        tool = resolved
        trace.log("Search tool ready")
    }

    /// The resolved tool as the planner is shown it.
    ///
    /// Built here rather than in the runner because only this client knows which fields
    /// the server actually supplied — an absent description must be left out, not sent
    /// as an empty string the model then tries to satisfy.
    var toolDescriptor: [String: Any] {
        // Built up rather than written as a nested literal: a heterogeneous literal in
        // an `Any` position cannot be inferred.
        var descriptor: [String: Any] = ["name": tool?.name ?? ""]
        if let description = tool?.description, !description.isEmpty {
            descriptor["description"] = description
        }
        descriptor["inputSchema"] = tool?.inputSchema ?? [String: Any]()
        return descriptor
    }

    /// Picks the web-search tool out of a `tools/list` reply.
    ///
    /// Accept known names in preference order.
    /// Unknown names are rejected: a query field and "web search" in a description
    /// cannot distinguish searching from deleting search history.
    ///
    /// Pure, so the rules are unit-tested with fixture listings.
    static func resolveSearchTool(from tools: [[String: Any]]) -> Tool? {
        let candidates = tools.compactMap { entry -> Tool? in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            return Tool(name: name,
                        description: entry["description"] as? String,
                        inputSchema: entry["inputSchema"] as? [String: Any] ?? [:])
        }
        for known in knownSearchToolNames {
            if let match = candidates.first(where: { $0.name == known }) { return match }
        }
        return nil
    }

    // MARK: Search

    /// Runs one search. `arguments` come from the model, so they are checked against
    /// the advertised schema first: a missing required key or an invented key means
    /// the model misread the schema, and sending it anyway would spend a request to
    /// get a provider-side error back.
    func search(arguments: [String: Any]) async throws -> Any {
        guard let tool else { throw ResearchError("The search connection was not established.") }
        try validate(arguments, required: tool.requiredKeys, properties: tool.propertyKeys)
        return try await session.callTool(
            name: tool.name, arguments: arguments,
            failure: "The web search failed. Check the search key and its quota.")
    }
}
