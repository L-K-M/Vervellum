import Foundation

/// A minimal Model Context Protocol client for the z.ai web-search server.
///
/// Only the four messages a search needs are implemented — `initialize`, the
/// `notifications/initialized` acknowledgement, `tools/list`, and `tools/call` — but
/// the transport quirks of a real MCP-over-HTTP gateway all have to be honored:
///
/// * The server picks its own **protocol version** in the `initialize` result, and
///   every later request must echo it back in `MCP-Protocol-Version`.
/// * It may open a **session** by returning `Mcp-Session-Id`, which likewise has to
///   be echoed, and which can appear on any response, not just the first.
/// * A response may arrive as **JSON or as an SSE stream**, chosen per request.
/// * `notifications/initialized` carries no `id`, so its acknowledgement is an empty
///   `202` — not an error, though it looks like one.
/// * The gateway in front of the MCP server has its **own error envelope**
///   (`{"success": false, "code": …}`) returned with HTTP 200, so a request can fail
///   without ever reaching the protocol layer.
///
/// The tool's real `inputSchema` is fetched rather than assumed: the model is given
/// that schema to write its query arguments against, and the arguments are checked
/// back against it before the call goes out.
///
/// The client was written against z.ai's server but is not tied to it. The search tool
/// is resolved by *shape* — see `resolveSearchTool` — so a Brave, Tavily, Exa or
/// SearXNG MCP server, whose tools are named differently, passes the same handshake.
/// Everything downstream is already backend-agnostic: the planner writes arguments
/// against whatever schema was advertised, and `EvidenceExtractor` walks any result.
final class SearchMCPClient {

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

        /// Whether the schema declares a string property that reads as the query text.
        /// A schema with no `properties` at all counts: a bare tool cannot be checked,
        /// and refusing it would lose a server that simply did not publish one.
        var hasQueryProperty: Bool {
            guard let properties = inputSchema["properties"] as? [String: Any] else { return true }
            return properties.contains { name, schema in
                guard SearchMCPClient.queryPropertyNames.contains(name.lowercased()) else { return false }
                let type = (schema as? [String: Any])?["type"]
                return type == nil || (type as? String) == "string"
                    || ((type as? [String])?.contains("string") ?? false)
            }
        }
    }

    private let endpoint: URL
    private let transport: HTTPTransport
    private let trace: ResearchTrace
    private var headers: [String: String]
    private var sequence = 0

    private(set) var tool: Tool?

    /// Tool names known to be a web search: z.ai's two spellings first, then the names
    /// the common MCP search servers ship. Matched exactly, before any guessing.
    static let knownSearchToolNames: [String] = [
        "web_search_prime", "webSearchPrime",
        "brave_web_search", "tavily-search", "tavily_search", "web_search_exa",
        "searxng_web_search", "web_search", "search",
    ]

    /// Argument names a search tool's schema uses for the query text.
    private static let queryPropertyNames: Set<String> = ["search_query", "query", "q", "keywords", "keyword", "text"]

    init(endpoint: URL, apiKey: String, trace: ResearchTrace, transport: HTTPTransport = .shared) {
        self.endpoint = endpoint
        self.transport = transport
        self.trace = trace
        self.headers = ["Authorization": "Bearer " + apiKey]
    }

    // MARK: Handshake

    /// Performs the handshake and resolves the search tool. Must be called once
    /// before `search(arguments:)`.
    func connect() async throws {
        // `[:]` alone has no inferable type in an `Any` position, and the nested
        // dictionaries need their type spelled for the same reason.
        let result = try await call("initialize", params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": ["name": AppIdentity.name,
                           "version": AppIdentity.version] as [String: Any],
        ])
        if let negotiated = result["protocolVersion"] as? String {
            headers["MCP-Protocol-Version"] = negotiated
        } else {
            headers["MCP-Protocol-Version"] = "2025-03-26"
        }

        try await notify("notifications/initialized")

        let listing = try await call("tools/list", params: [:])
        let tools = listing["tools"] as? [[String: Any]] ?? []
        guard let resolved = Self.resolveSearchTool(from: tools) else {
            // Tool names are the server's public interface, not secrets, and naming them
            // is what lets the user see that they pointed at the wrong kind of server.
            let advertised = tools.compactMap { $0["name"] as? String }
            let listed = advertised.isEmpty ? "no tools at all" : advertised.joined(separator: ", ")
            throw ResearchError("The search provider did not advertise a web-search tool "
                                + "(it offered \(listed)). Check the search endpoint in the "
                                + "provider settings.")
        }
        tool = resolved
        trace.log("Search tool ready: \(resolved.name)")
    }

    /// Picks the web-search tool out of a `tools/list` reply.
    ///
    /// By shape rather than by one vendor's name, in this order:
    ///
    /// 1. A tool whose name is one of `knownSearchToolNames`, in that list's order.
    /// 2. The only tool, if the server advertises exactly one — a search server with
    ///    one tool is offering a search.
    /// 3. The first tool whose name or description mentions "search" and whose schema
    ///    has a string property that reads as the query, so a "search_history" or
    ///    "research_notes" tool with no query cannot be mistaken for one.
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
        if candidates.count == 1 { return candidates[0] }
        return candidates.first { tool in
            let text = (tool.name + " " + (tool.description ?? "")).lowercased()
            return text.contains("search") && tool.hasQueryProperty
        }
    }

    // MARK: Search

    /// Runs one search. `arguments` come from the model, so they are checked against
    /// the advertised schema first: a missing required key or an invented key means
    /// the model misread the schema, and sending it anyway would spend a request to
    /// get a provider-side error back.
    func search(arguments: [String: Any]) async throws -> [String: Any] {
        guard let tool else { throw ResearchError("The search connection was not established.") }
        let keys = Set(arguments.keys)
        guard tool.requiredKeys.allSatisfy({ keys.contains($0) }) else {
            throw ResearchError("The model omitted a required search argument. Try another model.")
        }
        if !tool.propertyKeys.isEmpty, !keys.isSubset(of: tool.propertyKeys) {
            throw ResearchError("The model produced unknown search arguments. Try another model.")
        }
        let result = try await call("tools/call", params: ["name": tool.name, "arguments": arguments])
        if (result["isError"] as? Bool) == true {
            throw ResearchError("The web search failed. Check the search key and its quota.")
        }
        return result
    }

    // MARK: JSON-RPC

    private func call(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        sequence += 1
        let id = sequence
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        // An MCP server chooses JSON or SSE per response, so both are advertised.
        let request = try HTTPTransport.request(url: endpoint, payload: payload, headers: headers,
                                                acceptsEventStream: true)

        let (responseHeaders, body) = try await trace.stage("MCP \(method)") {
            try await self.transport.sendJSON(request, expectedID: id)
        }
        captureSession(from: responseHeaders)
        try checkGatewayEnvelope(body, method: method)

        if let error = body["error"] as? [String: Any] {
            let code = error["code"] as? Int
            let suffix = code.map { " (code \($0))" } ?? ""
            trace.log("MCP rejected \(method)\(suffix)")
            throw ResearchError("The search provider rejected \(method)\(suffix). "
                                + "Check the search key, plan access and quota.")
        }
        guard (body["id"] as? Int) == id, let result = body["result"] as? [String: Any] else {
            throw ResearchError("The search provider returned an invalid response to \(method).")
        }
        return result
    }

    /// Sends a notification — a JSON-RPC message with no `id`, which is acknowledged
    /// with an empty body rather than a result.
    private func notify(_ method: String) async throws {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        let request = try HTTPTransport.request(url: endpoint, payload: payload, headers: headers,
                                                acceptsEventStream: true)
        let (responseHeaders, body) = try await trace.stage("MCP \(method)") {
            try await self.transport.sendJSON(request, isNotification: true)
        }
        captureSession(from: responseHeaders)
        try checkGatewayEnvelope(body, method: method)
    }

    private func captureSession(from responseHeaders: [String: String]) {
        for (name, value) in responseHeaders where name.lowercased() == "mcp-session-id" {
            headers["Mcp-Session-Id"] = value
        }
    }

    /// The gateway can answer HTTP 200 with its own failure envelope, before the
    /// request reaches the MCP server. Its `msg` is never shown: gateway messages
    /// have been seen echoing request data and credentials back.
    private func checkGatewayEnvelope(_ body: [String: Any], method: String) throws {
        guard (body["success"] as? Bool) == false else { return }
        let code = body["code"] as? Int
        let message = ((body["msg"] as? String) ?? "").lowercased()
        trace.log("Search gateway rejection method=\(method) code=\(code.map(String.init) ?? "unknown")")
        if message.contains("auth") || message.contains("api key") || message.contains("token") {
            throw ResearchError(
                "The search provider rejected the API key (authentication failed). "
                + "Replace the web-search key in Settings ▸ Providers.")
        }
        let suffix = code.map { " (code \($0))" } ?? ""
        throw ResearchError("The search gateway rejected \(method)\(suffix). "
                            + "Check the search key, plan access and quota.")
    }
}
