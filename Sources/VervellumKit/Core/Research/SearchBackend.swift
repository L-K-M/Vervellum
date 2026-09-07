import Foundation

/// What the research pipeline needs from a web-search provider, whatever protocol it
/// speaks.
///
/// The pipeline never knew much about search: it asks for a tool descriptor, hands that
/// to the planner so the model writes arguments against a real schema, and walks
/// whatever comes back with `EvidenceExtractor`, which matches on *shape* rather than
/// on one provider's field names. This protocol is that contract written down, so a
/// backend that is not an MCP server can be added without the runner learning about it.
///
/// The two implementations differ in exactly one interesting way. An MCP server
/// *advertises* its own tool and schema, and `SearchMCPClient` fetches it rather than
/// assuming; a SearXNG instance has no such advertisement, so `SearXNGClient` supplies
/// the schema itself. Either way the planner is given a real schema, and the arguments
/// it writes are checked against that schema before a request goes out.
protocol SearchBackend: AnyObject {

    /// A name for the log and for user-facing prose. Never a provider's own text.
    var backendName: String { get }

    /// The tool as the planner is shown it: `name`, an optional `description`, and an
    /// `inputSchema`. Meaningless before `connect()` has returned.
    var toolDescriptor: [String: Any] { get }

    /// Establishes whatever the backend needs before a search — a protocol handshake,
    /// a tool listing, a key check. Called once, before planning, so a rejected key
    /// fails before the billable planning call rather than after it.
    func connect() async throws

    /// Runs one search with arguments the model wrote. The result is handed to
    /// `EvidenceExtractor` untouched.
    func search(arguments: [String: Any]) async throws -> Any
}

extension SearchBackend {

    /// Checks model-written arguments against an advertised schema.
    ///
    /// A missing required key or an invented one means the model misread the schema,
    /// and sending it anyway spends a request to get a provider-side error back. Shared
    /// because the check belongs to the *contract*, not to either protocol.
    func validate(_ arguments: [String: Any],
                  required: [String],
                  properties: Set<String>) throws {
        let keys = Set(arguments.keys)
        guard required.allSatisfy({ keys.contains($0) }) else {
            throw ResearchError("The model omitted a required search argument. Try another model.")
        }
        if !properties.isEmpty, !keys.isSubset(of: properties) {
            throw ResearchError("The model produced unknown search arguments. Try another model.")
        }
    }
}

/// Builds the backend a `SearchProfile` describes.
///
/// A free function rather than a `SearchProviderKind` method: constructing one needs a
/// transport and a trace, and giving a `Codable` settings enum those dependencies would
/// drag the network layer into the settings file.
enum SearchBackendFactory {

    /// - Throws: when the profile's endpoint is not usable, or a key the kind requires
    ///   is missing. Both are configuration problems, reported before any request.
    static func make(profile: SearchProfile,
                     apiKey: String?,
                     trace: ResearchTrace,
                     transport: HTTPTransport = .shared) throws -> SearchBackend {
        switch profile.kind {
        case .mcp:
            guard let url = ProviderSettings.validatedEndpointURL(profile.endpoint) else {
                throw ResearchError("The search endpoint is not a usable URL. Check the provider settings.")
            }
            guard let apiKey, !apiKey.isEmpty else {
                throw ResearchError("The web-search key is missing. Check the provider settings.")
            }
            return SearchMCPClient(endpoint: url, apiKey: apiKey, trace: trace, transport: transport)
        case .searxng:
            guard let url = ProviderSettings.searxngSearchURL(from: profile.endpoint) else {
                throw ResearchError("The SearXNG address is not a usable URL. Check the provider settings.")
            }
            // The key stays optional: a SearXNG instance is usually open, or fronted by
            // a proxy that wants a bearer token. Demanding one would block the most
            // common self-hosted setup.
            return SearXNGClient(searchURL: url, apiKey: apiKey, trace: trace, transport: transport)
        }
    }
}
