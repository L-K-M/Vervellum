import Foundation

/// A minimal Model Context Protocol client over HTTP: the transport, not the purpose.
///
/// Only the four messages Vervellum needs are implemented — `initialize`, the
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
/// Separate from the clients that use it because Vervellum now talks to two different
/// kinds of MCP server — a web-search server and a page-reader server — and the quirks
/// above are the server's, not the tool's. Duplicating them once per purpose is how one
/// copy quietly stops echoing a session header.
///
/// **Not safe to use from two tasks at once.** The JSON-RPC id sequence and the
/// negotiated headers are per-session state, and one connection carrying one id
/// sequence is the only shape the protocol documents. Callers that read several things
/// do so one after another.
final class MCPSession {

    private let endpoint: URL
    private let transport: HTTPTransport
    private let trace: ResearchTrace
    /// What this server is *for*, in the user's words — "search provider", "page
    /// reader". Every failure names it, because "the provider rejected the key" is not
    /// actionable when two providers are configured and only one is broken.
    private let subject: String
    private var headers: [String: String]
    private var sequence = 0

    init(endpoint: URL,
         apiKey: String,
         subject: String,
         trace: ResearchTrace,
         transport: HTTPTransport = .shared) {
        self.endpoint = endpoint
        self.transport = transport
        self.subject = subject
        self.trace = trace
        self.headers = ["Authorization": "Bearer " + apiKey]
    }

    // MARK: Handshake

    /// Performs `initialize` and acknowledges it. Must be called once before any tool
    /// call.
    func start() async throws {
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
    }

    /// The server's advertised tools.
    func tools() async throws -> [[String: Any]] {
        let listing = try await call("tools/list", params: [:])
        return listing["tools"] as? [[String: Any]] ?? []
    }

    /// Calls one tool. Throws when the server marks the result as an error, because a
    /// tool result flagged `isError` is a failure the caller must not read as evidence.
    func callTool(name: String, arguments: [String: Any], failure: String) async throws -> [String: Any] {
        let result = try await call("tools/call", params: ["name": name, "arguments": arguments])
        if (result["isError"] as? Bool) == true {
            throw ResearchError(failure)
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
            throw ResearchError("The \(subject) rejected \(method)\(suffix). "
                                + "Check its key, plan access and quota.")
        }
        guard (body["id"] as? Int) == id, let result = body["result"] as? [String: Any] else {
            throw ResearchError("The \(subject) returned an invalid response to \(method).")
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
        trace.log("MCP gateway rejection subject=\(subject) method=\(method) "
                  + "code=\(code.map(String.init) ?? "unknown")")
        if Self.describesAuthenticationFailure(message) {
            throw ResearchError(
                "The \(subject) rejected the API key (authentication failed). "
                + "Replace its key in Settings ▸ Providers.")
        }
        let suffix = code.map { " (code \($0))" } ?? ""
        throw ResearchError("The \(subject)'s gateway rejected \(method)\(suffix). "
                            + "Check its key, plan access and quota.")
    }
}
