import Foundation

/// Reads the pages behind a turn's sources, so the answer can rest on what a page says
/// rather than on a search engine's summary of it.
///
/// This is the one place in Vervellum where the honesty of the whole product is at
/// stake in a subtle way. A search snippet is a *summary*, and the prompts have always
/// said so: never claim to have read a page, never quote from a snippet. Reading the
/// page changes what is true — but only for the pages that were actually read, and only
/// for as much of each as was retrieved. So a reader returns text **per source**, the
/// runner attaches it only where it exists, and every layer downstream — the evidence
/// block, the source list, the process trail — distinguishes a source that was read
/// from one that was not. A source that is *shown* as read but whose text did not fit
/// the model's context would be exactly the lie this app exists to avoid.
///
/// Reading is best-effort by construction. `read` does not throw: a page behind a
/// consent wall, a 404, a PDF, a site that builds itself in JavaScript, a timeout —
/// none of those is a failure of the research turn, they are simply a source that keeps
/// its snippet. Failing the turn over a page that could not be fetched would trade a
/// good answer for no answer.
protocol PageReading: AnyObject {

    /// A name for the log and for user-facing prose. Never a provider's own text.
    var readerName: String { get }

    /// Establishes whatever the reader needs — a protocol handshake, a key check.
    /// Throwing here disables reading for the turn; it never fails the turn.
    func connect() async throws

    /// Reads what it can, returning page text keyed by `Source.number`. A source that
    /// could not be read is simply absent from the result.
    func read(_ sources: [Source]) async -> [Int: String]
}

/// Builds the reader a `ProviderSettings` describes, or nil when reading is off.
enum PageReaderFactory {

    /// The most pages one turn reads.
    ///
    /// Three, because that is where the returns fall off from both directions at once:
    /// the top few results are the ones an answer actually cites, each page costs a
    /// request and several thousand characters of the evidence budget, and a fourth
    /// page usually pushes the third one's text back out of context again.
    static let maxPages = 3

    static func make(settings: ProviderSettings,
                     readerKey: String?,
                     trace: ResearchTrace,
                     transport: any HTTPTransporting = HTTPTransport.shared) throws -> PageReading? {
        switch settings.pageReading {
        case .off:
            return nil
        case .direct:
            return DirectPageReader(trace: trace, transport: transport)
        case .reader:
            guard let url = ProviderSettings.validatedEndpointURL(settings.readerEndpoint) else {
                throw ResearchError("The page-reader endpoint is not a usable URL.")
            }
            guard let readerKey, !readerKey.isEmpty else {
                throw ResearchError("The page-reader key is missing.")
            }
            return ReaderMCPClient(endpoint: url, apiKey: readerKey, trace: trace, transport: transport)
        }
    }
}

/// Fetches each page itself and extracts its text.
///
/// **This is the only code in Vervellum that makes a request to a host the user did not
/// configure.** Everything else talks to the model provider, the search provider and
/// GitHub. The pages come from search results, so the sites learn the user's IP address
/// — which is why page reading is a setting with three states rather than a silent
/// improvement, and why `PRIVACY.md` says so in as many words.
///
/// Three rules follow from fetching arbitrary URLs:
///
/// * **No credentials, ever.** These requests carry no `Authorization` header, no
///   cookies (the shared session is configured never to store or send them) and no
///   `Referer`. There is nothing to leak to a host that redirects.
/// * **Redirects are re-issued, not followed.** `HTTPTransport` still refuses every
///   automatic redirect, because `URLSession` would re-send headers to the new host.
///   This reader instead reads the `Location` and starts a *fresh* request — which
///   preserves the rule's actual reason (a credential must never reach a host the user
///   did not configure) while letting `http → https` and `example.com → www.example.com`
///   resolve, which a large share of real links need. Two hops, http(s) only.
/// * **Only text is read.** A PDF, an image or a video is skipped on its content type
///   rather than fetched and discarded, and the body is capped well below the
///   transport's own limit.
final class DirectPageReader: PageReading {

    /// Hard ceiling on one page's bytes. A long article is well under this; anything
    /// above it is an application, not a document.
    static let maxPageBytes = 800_000
    /// Redirect hops. Two covers `http → https → www`; more is a chain that is trying
    /// to do something other than canonicalise.
    static let maxRedirects = 2
    /// How long one page may take. Short on purpose: a slow page must not add to the
    /// wall-clock of a turn that already has an answer to write, and the cost of
    /// giving up is a source that keeps its snippet.
    static let perPageTimeout: TimeInterval = 12

    let readerName = "direct fetch"

    private let trace: ResearchTrace
    private let transport: any HTTPTransporting

    init(trace: ResearchTrace, transport: any HTTPTransporting = HTTPTransport.shared) {
        self.trace = trace
        self.transport = transport
    }

    /// Nothing to establish: there is no service and no key.
    func connect() async throws {}

    /// Fetches the pages concurrently.
    ///
    /// Concurrently because these are unrelated hosts and the alternative is three
    /// round trips in series in the middle of a turn the user is watching. The MCP
    /// reader cannot do this — one session, one id sequence — which is why the batch is
    /// the protocol's unit rather than the single page.
    func read(_ sources: [Source]) async -> [Int: String] {
        await withTaskGroup(of: (Int, String).self) { group in
            for source in sources {
                let number = source.number
                let url = source.url
                group.addTask { [weak self] in
                    guard let self else { return (number, "") }
                    return (number, await self.text(at: url))
                }
            }
            var pages: [Int: String] = [:]
            for await (number, text) in group where !text.isEmpty {
                pages[number] = text
            }
            return pages
        }
    }

    /// One page's text, or an empty string for anything that could not be read.
    private func text(at address: String) async -> String {
        var target = address
        for hop in 0...Self.maxRedirects {
            guard let url = Self.fetchableURL(target) else { return "" }
            do {
                var request = HTTPTransport.getRequest(url: url)
                request.timeoutInterval = Self.perPageTimeout
                // A page is a document, not an API. Some sites answer a request that
                // only accepts JSON with a 406.
                request.setValue("text/html,text/plain;q=0.9,*/*;q=0.1",
                                 forHTTPHeaderField: "Accept")
                let (response, data) = try await transport.fetch(request, limit: Self.maxPageBytes)

                if (300..<400).contains(response.statusCode) {
                    guard hop < Self.maxRedirects,
                          let location = response.value(forHTTPHeaderField: "Location"),
                          let next = URL(string: location, relativeTo: url)?.absoluteString
                    else { return "" }
                    target = next
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    // Only the status reaches the log. A page's own error body is
                    // untrusted content and a URL can carry a token in its query.
                    trace.log("Page read skipped: HTTP \(response.statusCode)")
                    return ""
                }
                let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                guard contentType.isEmpty || contentType.contains("text/") || contentType.contains("xml")
                else {
                    trace.log("Page read skipped: not a text document")
                    return ""
                }
                guard let html = Self.decode(data, contentType: contentType) else { return "" }
                return HTMLTextExtractor.text(from: html)
            } catch {
                // A page that will not load is a source that keeps its snippet. The
                // error is a type name only: a provider's text is never logged.
                trace.log("Page read failed: \(ResearchError.safeLabel(for: error))")
                return ""
            }
        }
        return ""
    }

    /// The URL to fetch, or nil for anything that is not an absolute http(s) address.
    ///
    /// A redirect target is attacker-influenced in the general case — the link came
    /// from a search result — so every hop is re-checked rather than trusted because
    /// the first one passed. `file:` and `data:` are the reason this is not a
    /// convenience.
    static func fetchableURL(_ raw: String) -> URL? {
        guard let normalized = SourceHarvester.normalized(raw, trimmingPunctuation: false),
              let url = URL(string: normalized) else { return nil }
        return url
    }

    /// Decodes a page's bytes, honouring the charset the response declared.
    ///
    /// UTF-8 first because it is nearly everything, then the declared charset, then
    /// Latin-1 — which cannot fail, so a page in an encoding nobody declared is read
    /// with mojibake in the accents rather than dropped entirely.
    static func decode(_ data: Data, contentType: String) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if contentType.contains("charset=") {
            let declared = contentType.components(separatedBy: "charset=").last?
                .components(separatedBy: ";").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) ?? ""
            switch declared.lowercased() {
            case "iso-8859-1", "latin1", "windows-1252":
                return String(data: data, encoding: .isoLatin1)
            case "utf-16", "utf-16le", "utf-16be":
                return String(data: data, encoding: .utf16)
            default:
                break
            }
        }
        return String(data: data, encoding: .isoLatin1)
    }
}
