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
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

    init(url: URL, apiKey: String?, trace: ResearchTrace, transport: HTTPTransport = .shared) {
        self.url = url
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.trace = trace
        self.transport = transport
    }

    /// - Returns: the model identifiers the endpoint lists, sorted.
    /// - Throws: a `ResearchError` naming the likely fix. An endpoint that answers but
    ///   lists nothing is a failure rather than an empty list: silently showing an empty
    ///   picker looks like a bug, and the user needs to know to keep typing.
    func fetch() async throws -> [String] {
        var headers: [String: String] = [:]
        if let apiKey { headers["Authorization"] = "Bearer " + apiKey }
        let request = HTTPTransport.getRequest(url: url, headers: headers)

        let (_, body) = try await trace.stage("List models") {
            try await self.transport.sendJSON(request)
        }
        let models = ModelCatalog.parse(body)
        guard !models.isEmpty else {
            throw ResearchError("The endpoint answered but listed no models. "
                                + "Type the model name instead.")
        }
        trace.log("Listed \(models.count) models")
        return models
    }
}
