import Foundation

/// Reads pages through an MCP page-reader server — z.ai's Web Reader, or any server
/// advertising a compatible tool.
///
/// The reason to prefer this over fetching directly is not capability, it is *who
/// makes the request*: the reader service fetches the page, so the sites a question is
/// about never see the user's address. The cost is that the pages go through a third
/// party who does see both the URL and the answer it feeds.
///
/// Two things are discovered rather than assumed, because the published documentation
/// gives the endpoint and the tool name but not the tool's argument schema:
///
/// * **The tool**, by name, from `tools/list` — the same discipline `SearchMCPClient`
///   applies, and for the same reason: a server's own description cannot distinguish
///   fetching a page from deleting one.
/// * **The argument the URL goes in**, from that tool's advertised `inputSchema`. A
///   reader takes exactly one required string, and which word it is named is the
///   server's business; guessing `url` and being wrong would spend every request on a
///   schema error. `url` remains the fallback for a server that advertises no schema
///   at all.
///
/// Pages are read **one at a time**. `MCPSession` is one connection carrying one
/// JSON-RPC id sequence, which is the only shape the protocol documents — the
/// concurrency `DirectPageReader` gets is not available here.
final class ReaderMCPClient: PageReading {

    let readerName = "reader service"

    private let session: MCPSession
    private let trace: ResearchTrace
    private var toolName: String?
    private var urlArgument = "url"

    /// Tool names known to fetch a page. z.ai's first; the rest are the spellings the
    /// common reader servers ship. An unknown name is never assumed to be a reader.
    private static let knownReaderToolNames: [String] = [
        "webReader", "web_reader", "read_url", "readUrl", "fetch_url", "read_page", "fetch",
    ]

    /// Argument names a reader might put the URL under, in preference order. Only
    /// consulted against what the server actually advertised.
    private static let urlArgumentNames = ["url", "uri", "link", "page_url", "pageUrl", "target"]

    init(endpoint: URL, apiKey: String, trace: ResearchTrace, transport: HTTPTransport = .shared) {
        self.session = MCPSession(endpoint: endpoint, apiKey: apiKey, subject: "page reader",
                                  trace: trace, transport: transport)
        self.trace = trace
    }

    func connect() async throws {
        try await session.start()
        let listing = try await session.tools()
        guard let resolved = Self.resolveReaderTool(from: listing) else {
            // Names are provider-controlled; never copy them into a diagnostic.
            throw ResearchError("The page-reader endpoint did not advertise a recognized "
                                + "page-reading tool name.")
        }
        toolName = resolved.name
        urlArgument = resolved.urlArgument
        trace.log("Page reader ready")
    }

    func read(_ sources: [Source]) async -> [Int: String] {
        guard let toolName else { return [:] }
        var pages: [Int: String] = [:]
        for source in sources {
            // A cancelled turn must stop reading; the pages already read are kept,
            // because the turn keeps its partial answer too.
            if Task.isCancelled { break }
            do {
                let result = try await session.callTool(
                    name: toolName,
                    arguments: [urlArgument: source.url],
                    failure: "The page reader reported an error for this page.")
                let text = Self.pageText(from: result)
                if !text.isEmpty { pages[source.number] = text }
            } catch {
                // Best effort, exactly as in `DirectPageReader`: a page that could not
                // be read is a source that keeps its snippet.
                trace.log("Page read failed: \(ResearchError.safeLabel(for: error))")
            }
        }
        return pages
    }

    // MARK: Tool resolution

    struct ReaderTool: Equatable {
        let name: String
        let urlArgument: String
    }

    /// Picks the reader tool out of a `tools/list` reply and works out which argument
    /// the URL goes in.
    ///
    /// Pure, so the rules are unit-tested with fixture listings.
    static func resolveReaderTool(from tools: [[String: Any]]) -> ReaderTool? {
        for known in knownReaderToolNames {
            guard let entry = tools.first(where: { ($0["name"] as? String) == known }) else { continue }
            let schema = entry["inputSchema"] as? [String: Any] ?? [:]
            return ReaderTool(name: known, urlArgument: urlArgument(in: schema))
        }
        return nil
    }

    /// The advertised property the URL belongs in.
    ///
    /// A required property matching a known name wins; then any advertised property
    /// matching one; then the sole required property, whatever it is called, because a
    /// reader with exactly one required argument has told us what it is even if it
    /// spelled it unusually. `url` is the last resort, for a server that advertised no
    /// schema at all.
    static func urlArgument(in schema: [String: Any]) -> String {
        let properties = Set(((schema["properties"] as? [String: Any]) ?? [:]).keys)
        let required = schema["required"] as? [String] ?? []

        for candidate in urlArgumentNames where required.contains(candidate) { return candidate }
        for candidate in urlArgumentNames where properties.contains(candidate) { return candidate }
        if required.count == 1, let only = required.first { return only }
        return "url"
    }

    // MARK: Result

    /// The page text inside a reader's tool result.
    ///
    /// A reader returns "the page title, main content, metadata, list of links, and
    /// more" — and the shape of that varies the way search results do, so this walks
    /// for the *content*, in the same spirit as `EvidenceExtractor`: MCP `content` text
    /// blocks first (the standard envelope), then the content-shaped keys, then a
    /// re-parse of a text block that is itself JSON. Whatever is found is put through
    /// the HTML reader, because a reader that returns markup rather than text is common
    /// and markup in the evidence block is worse than useless.
    ///
    /// Pure, so it is unit-tested with fixture results.
    static func pageText(from result: [String: Any]) -> String {
        let raw = longestText(in: result, depth: 0)
        guard !raw.isEmpty else { return "" }
        // Always through the reader, without first guessing whether this is markup. A
        // reader that returns HTML is common and markup in the evidence block is worse
        // than useless; running text that was already plain through it costs nothing but
        // the whitespace normalising and the same length cap every page gets.
        return HTMLTextExtractor.text(from: raw)
    }

    private static let contentKeys = ["content", "text", "markdown", "body", "page_content", "article"]
    private static let maxDepth = 8

    /// The longest content-shaped string reachable in the result.
    ///
    /// Longest rather than first, because a reader that returns the title, a
    /// description *and* the article puts all three under content-shaped keys and only
    /// one of them is the page.
    private static func longestText(in value: Any?, depth: Int) -> String {
        guard depth <= maxDepth else { return "" }
        switch value {
        case let dictionary as [String: Any]:
            var best = ""
            // Sorted, because Swift randomises dictionary order per process and two runs
            // of the same reply must not disagree about which field was longest.
            for key in dictionary.keys.sorted() {
                let value = dictionary[key]
                var candidate = ""
                if contentKeys.contains(key.lowercased()), let text = value as? String {
                    candidate = text
                } else if value is [String: Any] || value is [Any] {
                    // Only containers are walked. A bare string under some *other* key is
                    // not content — taking it would let a long URL or a metadata blob win
                    // over the article it sits beside.
                    candidate = longestText(in: value, depth: depth + 1)
                }
                if candidate.count > best.count { best = candidate }
            }
            return best
        case let array as [Any]:
            // Concatenated, not "the longest": the standard MCP envelope splits one
            // document across several text blocks, and taking the biggest would return
            // one chapter of it.
            let parts = array.compactMap { item -> String? in
                let text = longestText(in: item, depth: depth + 1)
                return text.isEmpty ? nil : text
            }
            return parts.joined(separator: "\n\n")
        case let text as String:
            // Reached only from an array, where a bare string element of a `content`
            // block really is content.
            if let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               parsed is [String: Any] || parsed is [Any] {
                return longestText(in: parsed, depth: depth + 1)
            }
            return text
        default:
            return ""
        }
    }
}
