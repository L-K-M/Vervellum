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

    private let endpoint: URL
    private let transport: HTTPTransport
    private let trace: ResearchTrace
    private var headers: [String: String]
    private var sequence = 0

    private(set) var tool: Tool?

    let backendName = "MCP server"

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

    /// Tool names known to be a web search: z.ai's two spellings first, then the names
    /// the common MCP search servers ship. Unknown operations are never inferred.
    private static let knownSearchToolNames: [String] = [
        "web_search_prime", "webSearchPrime",
        "brave_web_search", "tavily-search", "tavily_search", "web_search_exa",
        "searxng_web_search", "web_search",
    ]

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
            // Names are provider-controlled too; never copy them into diagnostics.
            throw ResearchError("The search provider did not advertise a recognized web-search tool name. "
                                + "Check the endpoint's compatibility with the supported search providers.")
        }
        tool = resolved
        trace.log("Search tool ready")
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

    /// Whether a gateway's own message describes a bad key rather than something else.
    ///
    /// "token" on its own is deliberately not a signal: quota and billing messages say
    /// "insufficient token balance" and "tokens per minute", and reading those as an
    /// invalid key tells the user to replace a key that works. The text is classified
    /// only; it is never shown.
    static func describesAuthenticationFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        let markers = ["auth", "api key", "apikey", "api-key", "invalid token", "token expired",
                       "expired token", "invalid key", "unauthorized", "unauthorised", "forbidden"]
        return markers.contains { lowered.contains($0) }
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
        let message = (body["msg"] as? String) ?? ""
        trace.log("Search gateway rejection method=\(method) code=\(code.map(String.init) ?? "unknown")")
        if Self.describesAuthenticationFailure(message) {
            throw ResearchError(
                "The search provider rejected the API key (authentication failed). "
                + "Replace the web-search key in Settings ▸ Providers.")
        }
        let suffix = code.map { " (code \($0))" } ?? ""
        throw ResearchError("The search gateway rejected \(method)\(suffix). "
                            + "Check the search key, plan access and quota.")
    }
}
