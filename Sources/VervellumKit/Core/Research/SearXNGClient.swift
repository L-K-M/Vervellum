import Foundation

/// Searches a SearXNG instance through its own JSON API, with no MCP server in
/// between.
///
/// SearXNG is a metasearch engine people self-host, and reaching one used to mean
/// standing up an MCP bridge in front of it for no reason: the instance already answers
/// `GET /search?q=…&format=json` with exactly the fields the evidence extractor wants —
/// `url`, `title`, `content`, `publishedDate`.
///
/// Three things about that API shape the client:
///
/// * **JSON is off by default.** A stock `settings.yml` lists only `html` under
///   `search.formats`, and an instance without `json` answers **403**. That is the
///   single most common setup mistake, and a message about a rejected API key would
///   send the user looking in exactly the wrong place — so it is named specifically.
/// * **There is no handshake and no session**, so `connect()` does nothing. Probing
///   would mean spending a real search against someone's instance to learn what the
///   first search learns anyway.
/// * **There is no advertised schema**, unlike an MCP server, so this client supplies
///   one. The planner writes its arguments against it, and they are checked back
///   against it before the request goes out — the same contract, from the other side.
///
/// Authentication is optional and is *not* SearXNG's own: the instance takes no key.
/// A bearer token is sent when one is stored, for an instance behind an authenticating
/// proxy, which is how a private instance is usually exposed.
final class SearXNGClient: SearchBackend {

    /// The fully-formed `/search` URL. Query parameters are added per request.
    private let searchURL: URL
    private let apiKey: String?
    private let trace: ResearchTrace
    private let transport: HTTPTransport

    let backendName = "SearXNG"

    init(searchURL: URL, apiKey: String?, trace: ResearchTrace, transport: HTTPTransport = .shared) {
        self.searchURL = searchURL
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.trace = trace
        self.transport = transport
    }

    // MARK: Schema

    /// The tool name the planner is shown.
    ///
    /// It matches the name the SearXNG MCP bridge advertises, so a plan written for one
    /// reads identically to a plan written for the other and the process trail does not
    /// change wording when a user switches between them.
    static let toolName = "searxng_web_search"

    /// The arguments this client accepts, as a JSON Schema.
    ///
    /// Deliberately small. Every parameter here is one SearXNG documents and one a
    /// research plan can actually use; a schema that mirrored the whole API would invite
    /// the model to write engine selections and page numbers that only narrow the
    /// evidence.
    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "q": [
                "type": "string",
                "description": "The search query.",
            ] as [String: Any],
            "categories": [
                "type": "string",
                "description": "Optional comma-separated SearXNG categories, such as "
                    + "\"general\", \"news\", \"science\" or \"it\".",
            ] as [String: Any],
            "language": [
                "type": "string",
                "description": "Optional language code such as \"en\", \"de\" or \"all\".",
            ] as [String: Any],
            "time_range": [
                "type": "string",
                "enum": ["day", "month", "year"],
                "description": "Optional recency filter. Use it for a question about a "
                    + "current state of affairs.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["q"],
    ]

    var toolDescriptor: [String: Any] {
        [
            "name": Self.toolName,
            "description": "Search the web through a SearXNG metasearch instance. Returns "
                + "titles, links and short summaries.",
            "inputSchema": Self.inputSchema,
        ]
    }

    private static var propertyKeys: Set<String> {
        guard let properties = inputSchema["properties"] as? [String: Any] else { return [] }
        return Set(properties.keys)
    }

    // MARK: SearchBackend

    /// Nothing to do. See the type's documentation for why this is a no-op rather than
    /// a reachability probe.
    func connect() async throws {
        trace.log("Search backend ready (SearXNG)")
    }

    func search(arguments: [String: Any]) async throws -> Any {
        try validate(arguments,
                     required: Self.inputSchema["required"] as? [String] ?? ["q"],
                     properties: Self.propertyKeys)
        guard let url = Self.requestURL(base: searchURL, arguments: arguments) else {
            throw ResearchError("Vervellum could not build the SearXNG request URL. "
                                + "Check the address in the provider settings.")
        }

        var headers: [String: String] = [:]
        if let apiKey { headers["Authorization"] = "Bearer " + apiKey }
        let request = HTTPTransport.getRequest(url: url, headers: headers)

        do {
            let (_, body) = try await trace.stage("SearXNG search") {
                try await self.transport.sendJSON(request)
            }
            return body
        } catch let error as ResearchError where error == ResearchError.rejectedCredential(403) {
            // The overwhelmingly likely cause, and the one a "check your API key"
            // message would hide. A private instance behind a proxy answers 401, which
            // keeps the original wording.
            throw ResearchError(
                "The SearXNG instance refused a JSON search (HTTP 403). Most instances "
                + "do not enable JSON results: add `json` to `search.formats` in its "
                + "settings.yml, or use an instance that already has.")
        }
    }

    // MARK: Request

    /// The `/search` URL with `format=json` and the model's arguments as query items.
    ///
    /// Built with `URLComponents` rather than string concatenation, so a query holding a
    /// `&`, a `#` or a space is percent-encoded rather than silently splitting into two
    /// parameters — a search for "rust & c++ performance" must not become a search for
    /// "rust " with a stray `c++ performance` filter.
    ///
    /// Non-string values are rendered rather than rejected: a model that wrote
    /// `"time_range": 7` misread the schema, but the schema check has already run and
    /// the request is better spent than refused.
    ///
    /// Pure and static, so it is unit-testable without a transport.
    static func requestURL(base: URL, arguments: [String: Any]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // Sorted, so a fixture can assert a URL and two runs of the same search produce
        // the same one. Dictionary order is randomised per process.
        var items = [URLQueryItem(name: "format", value: "json")]
        for key in arguments.keys.sorted() {
            guard key != "format" else { continue }
            guard let value = queryValue(arguments[key]), !value.isEmpty else { continue }
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        return components.url
    }

    /// Numbers are matched *before* booleans on purpose. These arguments arrive from
    /// `JSONSerialization`, which on Darwin hands every number back as an `NSNumber` —
    /// and an `NSNumber` holding `7` will bridge to `Bool` as well as to `Int`. Testing
    /// `Bool` first would turn a `"time_range": 7` into `1`.
    private static func queryValue(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as Int: return String(number)
        case let number as Double: return number == number.rounded() ? String(Int(number)) : String(number)
        case let flag as Bool: return flag ? "1" : "0"
        case let values as [Any]: return values.compactMap { queryValue($0) }.joined(separator: ",")
        default: return nil
        }
    }
}
