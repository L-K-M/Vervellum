import Foundation

/// Asks an OpenAI-compatible endpoint which models it serves.
///
/// Typing a model identifier by hand is the step most likely to go wrong when adding a
/// provider: `gpt-4o` and `gpt4o`, `glm-4.7` and `glm-4-7`, a name that was right last
/// quarter. Nothing validates it until a question fails, and the error that comes back
/// is the provider's HTTP 400 rather than "no such model".
///
/// So the list is fetched instead. `GET <base>/models` is the one route every
/// OpenAI-compatible server publishes — llama.cpp, Ollama's compatibility layer, vLLM,
/// LM Studio and the hosted vendors all answer it — and it needs no request body, which
/// makes it a cheap way to confirm the endpoint is right.
///
/// It confirms the *endpoint*, not necessarily the key. Several of the servers named
/// above serve `/models` unauthenticated, so a list can arrive over a key that the first
/// real question will reject. A hosted vendor that does check will refuse the list, and
/// that refusal is worth having early — but a list is not a promise.
///
/// Manual entry stays. This supplements the field, it never replaces it: a gateway that
/// does not list its models, one that lists a hundred aliases, or a name only reachable
/// through a routing prefix all have to remain typeable.
enum ModelCatalog {

    /// The model identifiers in a `/models` reply.
    ///
    /// Matched on *shape* rather than on one vendor's schema, for the reason
    /// `EvidenceExtractor` is: the OpenAI shape is `{"data": [{"id": …}]}`, but servers
    /// in the wild put the array under `models`, fill it with bare strings, or name the
    /// field `name`. Reading all of those costs a few lines and saves a provider being
    /// unusable over a key nobody agreed on.
    ///
    /// Blank entries are dropped, duplicates collapse, and the result is sorted — a list
    /// the user picks from should not depend on the order a gateway happened to enumerate
    /// its routing table in.
    static func parse(_ body: [String: Any]) -> [String] {
        let candidates = (body["data"] as? [Any]) ?? (body["models"] as? [Any]) ?? []
        var seen = Set<String>()
        var names: [String] = []
        for entry in candidates {
            guard let name = identifier(in: entry) else { continue }
            guard seen.insert(name).inserted else { continue }
            names.append(name)
        }
        // Not the *localized* compare: it consults the user's locale, so the same reply
        // could sort differently on two machines — which is the opposite of what the
        // paragraph above promises. Model identifiers are ASCII; there is nothing here
        // for a collation to be clever about, and a Turkish dotless i deciding the order
        // of a model list would be a bug nobody could reproduce.
        //
        // A total order, not just a case-insensitive one. Dedup above is exact, so
        // `GPT-4o` and `gpt-4o` can both survive — and they compare as the same under a
        // case-insensitive comparison, which leaves their order to whatever the sort
        // happened to do. The tie-break makes the list depend on the names alone, which
        // is the whole claim of the paragraph above.
        return names.sorted {
            let order = $0.caseInsensitiveCompare($1)
            return order == .orderedAscending || (order == .orderedSame && $0 < $1)
        }
    }

    private static func identifier(in entry: Any) -> String? {
        let raw: String?
        switch entry {
        case let text as String:
            raw = text
        case let object as [String: Any]:
            raw = (object["id"] as? String) ?? (object["name"] as? String)
        default:
            raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Fetches `ModelCatalog` over the network.
///
/// Separate from the parsing so the shapes above are testable without a transport, and
/// so this stays what it is: one GET, one parse, no session and no state.
final class ModelCatalogClient {

    private let url: URL
    private let apiKey: String?
    private let trace: ResearchTrace
    private let transport: HTTPTransport

    /// How long to wait for a list of model names.
    ///
    /// Not the transport's default. That one is ten minutes, sized for a local model
    /// chewing through an evidence block; this is a small JSON document a server either
    /// has or does not. Someone sitting in Settings watching a spinner is the wrong
    /// person to make wait on a generation deadline.
    ///
    /// Handed to `sendCheapJSON`, which sets both clocks from it. Two are needed and
    /// only one is a bound: `URLRequest.timeoutInterval` is an *idle* timeout that
    /// restarts on every byte, so a host trickling one byte every 29 seconds satisfies
    /// it forever, and the wall clock is what stops that. They were two arguments at two
    /// call sites until a comment was the only thing keeping them equal.
    ///
    /// The number is a bound on each half rather than on the exchange: `sendJSON` starts
    /// its wall clock after `open` returns, so connecting and receiving the headers is
    /// covered by the idle timeout and only the body read is covered by the clock. The
    /// honest worst case is about twice this, which is still the right order of magnitude
    /// for somebody watching a spinner and nothing like the ten minutes it replaced.
    /// Bounding the whole exchange means a deadline through `open`, which is every
    /// caller's contract and not this one's to change.
    static let listTimeout: TimeInterval = 30

    init(url: URL, apiKey: String?, trace: ResearchTrace, transport: HTTPTransport = .shared) {
        self.url = url
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.trace = trace
        self.transport = transport
    }

    /// - Returns: the model identifiers the endpoint lists, sorted.
    /// - Throws: a `ResearchError` naming the likely fix. An endpoint that answers but
    ///   lists nothing is a failure rather than an empty list: silently showing an empty
    ///   picker looks like a bug, and the user needs to know to keep typing. A 200 whose
    ///   body is not JSON is the same failure wearing a different hat — a home page, a
    ///   captive portal, a gateway's HTML error — and is translated here rather than
    ///   reaching the reader as the transport's generic "could not read".
    func fetch() async throws -> [String] {
        // `Accept: application/json` is not set here because `getRequest` sets it for
        // every GET it builds. The same header `ChatCompletionsClient` builds, deliberately: a key that lists
        // models and a key that answers questions have to be presented the same way, or
        // a provider that accepts one refuses the other and the refusal reads as a bad
        // key. If chat ever learns a second scheme, this has to learn it too.
        var headers: [String: String] = [:]
        if let apiKey { headers["Authorization"] = "Bearer " + apiKey }
        let body: [String: Any]
        do {
            body = try await trace.stage("List models") {
                try await self.transport.sendCheapJSON(url: self.url, headers: headers,
                                                       within: Self.listTimeout).body
            }
        } catch let error as ResearchError where error == .invalidResponse {
            // The 200-with-HTML case, and the likeliest mistake this button exists to
            // catch: this is the field where people paste a URL by hand, and a host that
            // answers a GET with its home page is the ordinary shape of getting it
            // slightly wrong. `invalidResponse` is true and says nothing to do about it,
            // so it becomes the same sentence as the empty list — which is the honest
            // reading either way, since both mean no names could be read from the reply.
            throw ResearchError("The endpoint answered, but not with a list of models. "
                                + "Check the address, or type the model name instead.")
        }
        let models = ModelCatalog.parse(body)
        // Only a 2xx reply reaches here: `sendJSON` calls `checkStatus` before it
        // returns, and every non-2xx becomes a Vervellum-authored `ResearchError` —
        // 401 and 403 as `rejectedCredential`, 404 naming the path. So "listed no
        // models" cannot be a rejected key wearing the wrong message. Written down
        // because the guarantee lives in another file and reads like an omission here.
        guard !models.isEmpty else {
            // Not "listed no models", which claims to know more than this does. `parse`
            // reads the two shapes it knows; a server answering in a third leaves the
            // same empty array as one that really has nothing, and telling a reader
            // their provider is empty sends them to check the wrong thing. The half
            // that is actionable is true either way.
            throw ResearchError("The endpoint answered, but no model names could be read "
                                + "from it. Type the model name instead.")
        }
        trace.log("Listed \(models.count) models")
        return models
    }
}
