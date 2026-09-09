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
/// The implementations differ in one interesting way. An MCP server *advertises* its own
/// tool and schema, and `SearchMCPClient` fetches it rather than assuming; a SearXNG
/// instance and the Kagi CLI have no such advertisement, so those clients supply the
/// schema themselves. Either way the planner is given a real schema, and the arguments it
/// writes are checked against that schema before a request goes out.
///
/// One of them is not a server at all. `KagiCLIClient` runs a program on the user's own
/// machine, which is why this protocol says nothing about transports: what a backend
/// needs to reach its index is the backend's business, and the pipeline's business is a
/// schema, a call and a result.
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
    /// because the check belongs to the *contract*, not to any one protocol.
    ///
    /// Names only. What a value is *allowed to be* — an enum, a format, a range — is
    /// described by the schema and not enforced here, so a backend that turns a value
    /// into something more dangerous than a query parameter has to check it itself. See
    /// `KagiCLIClient.command(for:)`, where a value becomes a command-line argument.
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
                     transport: any HTTPTransporting = HTTPTransport.shared,
                     commandRunner: any CommandRunning = CommandRunner.shared) throws -> SearchBackend {
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
        case .kagiCLI:
            // Resolved here, so "you have not installed it" is reported with the rest of
            // the configuration problems and before the turn's first billable call —
            // rather than surfacing as a failed search a minute into a run.
            guard let executable = commandRunner.resolve(command: profile.endpoint) else {
                throw ResearchError(
                    "Vervellum could not find the Kagi command-line tool. Install it from "
                    + "https://github.com/Microck/kagi-cli, or put its full path in the "
                    + "provider settings.")
            }
            // The key stays optional, and is usually absent: `kagi auth` holds the
            // credential. One stored here is passed to the tool as `KAGI_API_KEY`.
            return KagiCLIClient(executable: executable, apiKey: apiKey, trace: trace,
                                 runner: commandRunner)
        }
    }
}
