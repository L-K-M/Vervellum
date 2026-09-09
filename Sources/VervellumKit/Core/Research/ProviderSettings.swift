import Foundation

/// How Vervellum reaches a web-search backend.
///
/// Two kinds, because the two are genuinely different protocols and pretending
/// otherwise would mean guessing: an MCP server is a JSON-RPC session that advertises
/// its own tool schema, while a SearXNG instance is a plain `GET /search?format=json`
/// with a schema Vervellum has to supply itself. See `SearchBackend`.
enum SearchProviderKind: String, Codable, CaseIterable, Identifiable, Equatable {
    /// A Model Context Protocol server over HTTP — z.ai, Brave, Tavily, Exa, or a
    /// SearXNG-to-MCP bridge. The tool and its argument schema are discovered.
    case mcp
    /// A SearXNG instance's own JSON API, with no MCP server in between. The instance
    /// must list `json` under `search.formats`; it is not enabled by default.
    case searxng
    /// The `kagi` command-line tool, run on this machine. The only backend that is not a
    /// server: Kagi sells its Search API separately, so the way to research against
    /// Kagi's index is the one its subscribers already use from a terminal. The
    /// credential belongs to the CLI (`kagi auth`), not to Vervellum.
    ///
    /// Its raw value is hyphenated rather than the case name, because it is also what a
    /// human types into `settings.json` on Linux.
    case kagiCLI = "kagi-cli"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mcp: return "MCP server"
        case .searxng: return "SearXNG"
        case .kagiCLI: return "Kagi CLI"
        }
    }

    /// Whether a run is refused without a key. A SearXNG instance is usually open, or
    /// fronted by a proxy rather than a token, so demanding one there would block the
    /// most common self-hosted setup; a key is still sent when there is one.
    var requiresKey: Bool {
        switch self {
        case .mcp: return true
        // The Kagi CLI holds its own credential — `kagi auth` puts it in the tool's
        // config, where the user's terminal already reads it. Vervellum demanding a
        // second copy would be asking for a secret it does not need.
        case .searxng, .kagiCLI: return false
        }
    }

    /// The placeholder its endpoint field shows.
    var endpointPlaceholder: String {
        switch self {
        case .mcp: return ProviderSettings.defaultSearchEndpoint
        case .searxng: return "https://searx.example.org"
        // Not a URL at all: for this kind the field holds a command, looked up the way a
        // shell would look it up, or an absolute path to one.
        case .kagiCLI: return ProviderSettings.defaultKagiCommand
        }
    }

    /// What the endpoint field holds, as a word for the label above it.
    var endpointLabel: String {
        switch self {
        case .mcp: return "Endpoint"
        case .searxng: return "Address"
        case .kagiCLI: return "Command"
        }
    }

    /// The label on its key field.
    var keyLabel: String {
        switch self {
        case .mcp: return "Search key"
        case .searxng: return "Token"
        case .kagiCLI: return "API key"
        }
    }

    /// What the key field's note says. Here rather than in the macOS settings pane
    /// because it is a fact about the provider kind, and Linux has to be able to
    /// document the same thing without a settings window to put it in.
    var keyNote: String {
        switch self {
        case .mcp:
            return "Required. Research cannot run without it."
        case .searxng:
            return "Optional — only for an instance behind an authenticating proxy. "
                + "SearXNG itself takes no key."
        case .kagiCLI:
            return "Optional. `kagi auth` normally holds the credential, and Vervellum "
                + "never sees it; a key stored here is passed to the tool as "
                + "KAGI_API_KEY instead."
        }
    }
}

/// One configured web-search provider.
///
/// The same shape as `ModelProfile` and for the same reasons — its own endpoint, its
/// own key slot, a name for the picker — plus the protocol it speaks, which is the one
/// thing a search provider has that a model provider does not.
struct SearchProfile: Codable, Equatable, Identifiable {

    var id: UUID
    var name: String
    var kind: SearchProviderKind
    /// An MCP endpoint, a SearXNG instance's address, or — for `kagiCLI` — the command
    /// to run. What it means is the `kind`'s business, which is why the picker sits
    /// above it in the settings pane.
    var endpoint: String
    /// The `SecretAccount` raw value holding this provider's key.
    var keyAccount: String

    init(id: UUID = UUID(), name: String, kind: SearchProviderKind, endpoint: String, keyAccount: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.keyAccount = keyAccount
    }

    static func new(name: String = "",
                    kind: SearchProviderKind = .mcp,
                    endpoint: String = "") -> SearchProfile {
        let id = UUID()
        return SearchProfile(id: id, name: name, kind: kind, endpoint: endpoint,
                             keyAccount: SecretAccount.derived(from: .searchAPIKey, for: id).rawValue)
    }

    var secretAccount: SecretAccount { SecretAccount(rawValue: keyAccount) }

    var displayName: String {
        let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return named }
        return ProviderSettings.host(of: endpoint) ?? kind.label
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey { case id, name, kind, endpoint, keyAccount }

    /// Lenient, for the reason `ModelProfile.init(from:)` is.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.id = id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        // An unrecognised kind reads as `.mcp` rather than failing the whole list: that
        // is what a settings file written by a build with more backends looks like, and
        // one unknown entry must not cost the user every other provider.
        let rawKind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = rawKind.flatMap { SearchProviderKind(rawValue: $0) } ?? .mcp
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        keyAccount = try container.decodeIfPresent(String.self, forKey: .keyAccount)
            ?? SecretAccount.derived(from: .searchAPIKey, for: id).rawValue
    }
}

/// How much of a source Vervellum reads before the model sees it.
///
/// A search result is a *summary*, and this whole app is built on not overstating what
/// it knows — so reading the page is an explicit mode with an explicit cost, not a
/// silent upgrade.
enum PageReadingMode: String, Codable, CaseIterable, Identifiable, Equatable {
    /// Snippets only. Nothing is fetched beyond the search call, which is what every
    /// build before page reading did.
    case off
    /// Vervellum fetches the pages itself and extracts their text. The requests carry
    /// no credentials, but the sites do learn the address they came from — this is the
    /// only case in which Vervellum contacts a host the user did not configure.
    case direct
    /// A reader service fetches the pages instead — z.ai's Web Reader MCP server, or any
    /// MCP server advertising a compatible tool. The sites see the service; the service
    /// sees the URLs.
    case reader

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Snippets only"
        case .direct: return "Fetch pages directly"
        case .reader: return "Use a reader service"
        }
    }
}

/// One configured model provider.
///
/// Several can exist, and which one answers is chosen at ask time — so a thread can be
/// researched with a local model and a follow-up checked against a frontier one, and
/// each turn records the model that produced it. The key lives in the secret store
/// under `keyAccount`, never here.
struct ModelProfile: Codable, Equatable, Identifiable {

    var id: UUID
    /// What the picker shows. Free text, because "the fast one" is a better label than
    /// a model identifier for the person choosing.
    var name: String
    /// An OpenAI-compatible Chat Completions endpoint, or the API base it hangs off.
    var endpoint: String
    /// The model identifier that endpoint accepts.
    var model: String
    /// The `SecretAccount` raw value holding this profile's API key.
    var keyAccount: String

    init(id: UUID = UUID(), name: String, endpoint: String, model: String, keyAccount: String) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.keyAccount = keyAccount
    }

    /// A new profile with a secret slot of its own.
    static func new(name: String = "", endpoint: String = "", model: String = "") -> ModelProfile {
        let id = UUID()
        return ModelProfile(id: id, name: name, endpoint: endpoint, model: model,
                            keyAccount: SecretAccount.derived(from: .modelAPIKey, for: id).rawValue)
    }

    var secretAccount: SecretAccount { SecretAccount(rawValue: keyAccount) }

    /// The label to show when the user never typed one. Falls back through the model
    /// identifier to the host, so a profile is never listed as a blank row.
    var displayName: String {
        let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return named }
        let identifier = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identifier.isEmpty { return identifier }
        return ProviderSettings.host(of: endpoint) ?? "Unnamed provider"
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey { case id, name, endpoint, model, keyAccount }

    /// Decoded leniently, for the reason `ResearchTurn` is: a field added later must not
    /// make an existing settings file unreadable, and the recovery from that is a user
    /// re-pasting every endpoint they had configured.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.id = id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        keyAccount = try container.decodeIfPresent(String.self, forKey: .keyAccount)
            ?? SecretAccount.derived(from: .modelAPIKey, for: id).rawValue
    }
}

/// Where Vervellum sends its two kinds of request, and the rules those endpoints
/// must satisfy before a single byte leaves the machine.
///
/// Every key lives in the secret store and is injected at call time, so this value is
/// safe to log, encode, or show in Settings — it holds no secrets.
///
/// The model side is a *list* with a selection rather than one endpoint, because which
/// model answered is a property of a turn and not of the app: a thread outlives a
/// settings change, and a verdict is only meaningful with the model attached. The
/// single-provider spellings — `modelEndpoint` and `modelName` — are kept as accessors
/// over the selected profile, which is what the Linux front end, the command line and
/// every older settings file still speak.
struct ProviderSettings: Equatable, Codable {

    /// Configured model providers, in the order the picker shows them.
    var modelProfiles: [ModelProfile]
    /// Which of them a new turn uses. Nil, or an id no longer in the list, falls back to
    /// the first: a settings file that lost its selection must not stop research.
    var selectedModelID: UUID?

    /// Configured web-search providers, in the order the picker shows them.
    var searchProfiles: [SearchProfile]
    /// Which of them a run searches with. Same fallback rule as the model selection.
    var selectedSearchID: UUID?

    /// Whether a model provider that fails hands the turn to the next one configured.
    ///
    /// On by default, but never silent: the turn records the provider that actually
    /// answered and carries a `modelFellBack` notice, because "which model said this"
    /// is part of what an answer means here. Off restores the single-provider
    /// behaviour, where a failing provider fails the turn.
    ///
    /// It governs *failures*, not configuration. `problems(hasModelKey:...)` still runs
    /// against the selection alone and still fails the turn before a chain exists, so an
    /// empty endpoint or model name on the selected provider is a turn that never
    /// starts — even with a complete spare beside it. That is the boundary, and it is
    /// deliberate: the picker points at that provider, so a blank field there is
    /// something to go and fix rather than weather to route around. A key is not part of
    /// it; a local server takes none, and `problems` ignores `hasModelKey` for exactly
    /// that reason.
    var modelFallback: Bool

    /// How much of each source is read. See `PageReadingMode`.
    var pageReading: PageReadingMode
    /// The MCP endpoint used when `pageReading` is `.reader`.
    var readerEndpoint: String

    /// One home for the fallback default. It was written out as a literal in five
    /// places — two initialisers, the lenient decoder, `CorePreferences.Default`, and
    /// the Settings pane's `@State` — and a default that disagrees with itself across
    /// a load path is a setting that changes when nobody touched it.
    static let defaultModelFallback = true

    static let defaultSearchEndpoint = "https://api.z.ai/api/mcp/web_search_prime/mcp"

    /// The command a Kagi provider uses when its field is left blank. A bare name,
    /// resolved against `PATH` and the places a CLI installs itself — see
    /// `CommandRunner.searchDirectories` for why `PATH` alone is not enough for an app
    /// that `launchd` started.
    static let defaultKagiCommand = "kagi"

    /// z.ai's Web Reader MCP server, documented at
    /// <https://docs.z.ai/devpack/mcp/reader-mcp-server>. Configurable so any MCP server
    /// advertising a compatible reader tool can stand in.
    static let defaultReaderEndpoint = "https://api.z.ai/api/mcp/web_reader/mcp"

    // MARK: Initializers

    init(modelProfiles: [ModelProfile],
         selectedModelID: UUID? = nil,
         searchProfiles: [SearchProfile] = [],
         selectedSearchID: UUID? = nil,
         modelFallback: Bool = ProviderSettings.defaultModelFallback,
         pageReading: PageReadingMode = .direct,
         readerEndpoint: String = ProviderSettings.defaultReaderEndpoint) {
        self.modelProfiles = modelProfiles
        self.selectedModelID = selectedModelID
        self.searchProfiles = searchProfiles
        self.selectedSearchID = selectedSearchID
        self.modelFallback = modelFallback
        self.pageReading = pageReading
        self.readerEndpoint = readerEndpoint
    }

    /// The single-provider spelling: one model profile and one MCP search provider, on
    /// the two accounts every pre-profiles build wrote.
    ///
    /// Both the migration path for an existing settings file and the shape the Linux
    /// front end and the tests construct, so it is a real initializer rather than a
    /// test helper.
    init(modelEndpoint: String = "",
         modelName: String = "",
         searchEndpoint: String = ProviderSettings.defaultSearchEndpoint,
         searchKind: SearchProviderKind = .mcp,
         modelFallback: Bool = ProviderSettings.defaultModelFallback,
         pageReading: PageReadingMode = .direct,
         readerEndpoint: String = ProviderSettings.defaultReaderEndpoint) {
        let model = ModelProfile(name: "", endpoint: modelEndpoint, model: modelName,
                                 keyAccount: SecretAccount.modelAPIKey.rawValue)
        let search = SearchProfile(name: "", kind: searchKind, endpoint: searchEndpoint,
                                   keyAccount: SecretAccount.searchAPIKey.rawValue)
        self.init(modelProfiles: [model],
                  selectedModelID: model.id,
                  searchProfiles: [search],
                  selectedSearchID: search.id,
                  modelFallback: modelFallback,
                  pageReading: pageReading,
                  readerEndpoint: readerEndpoint)
    }

    // MARK: Selection

    /// The profile a new turn uses. Falls back to the first configured one, so a stale
    /// or missing selection degrades to "the one at the top" rather than to "not
    /// configured".
    var selectedModel: ModelProfile? {
        modelProfiles.first { $0.id == selectedModelID } ?? modelProfiles.first
    }

    var selectedSearch: SearchProfile? {
        searchProfiles.first { $0.id == selectedSearchID } ?? searchProfiles.first
    }

    /// The model providers a turn may use, in the order it will try them.
    ///
    /// The selected profile is always the head — a chain that did not start where the
    /// picker points would make the picker a lie — and the rest follow in the order the
    /// Providers list shows them, which is the only ordering the user can already see
    /// and rearrange. There is deliberately no second, hidden ordering to configure.
    ///
    /// With fallback off this is just the selection, so every caller can be written
    /// against a chain and the single-provider behaviour is the one-element case rather
    /// than a separate path.
    var modelChain: [ModelProfile] {
        guard let selected = selectedModel else { return [] }
        guard modelFallback else { return [selected] }
        return Self.chainOrder(modelProfiles, selectedID: selectedModelID)
    }

    /// The order a chain tries providers in: the selection first, then the rest as the
    /// Providers list shows them.
    ///
    /// The order fallback *would* take, which is not the same as the order a turn takes:
    /// this does not consult `modelFallback`, because it is the ordering rule and the
    /// setting is a separate question. A caller showing it has to ask that question
    /// itself — `ProvidersView.fallbackExplanation` does, and says "nothing else is
    /// tried" when the answer is no.
    ///
    /// Static and separate from `modelChain` because the Settings pane prints this order
    /// back to the reader, and it was deriving it a second time from the same rule. Two
    /// copies of an ordering is how a caption ends up describing a chain the runner does
    /// not walk. A selection that no longer exists degrades to the first profile, the
    /// same way `selectedModel` does, so the caption cannot claim an order the chain
    /// would not take.
    static func chainOrder(_ profiles: [ModelProfile], selectedID: UUID?) -> [ModelProfile] {
        guard let selected = profiles.first(where: { $0.id == selectedID }) ?? profiles.first
        else { return [] }
        return [selected] + profiles.filter { $0.id != selected.id }
    }

    /// Selects the profile whose name or model identifier matches `name`, exactly first
    /// and then by prefix, case-insensitively. Returns false and changes nothing when
    /// none matches — the caller says so, rather than researching with a model the user
    /// did not name.
    mutating func selectModel(named name: String) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return false }
        let match = modelProfiles.first {
            $0.displayName.lowercased() == wanted || $0.model.lowercased() == wanted
        } ?? modelProfiles.first {
            $0.displayName.lowercased().hasPrefix(wanted) || $0.model.lowercased().hasPrefix(wanted)
        }
        guard let match else { return false }
        selectedModelID = match.id
        return true
    }

    // MARK: Single-provider accessors

    /// The selected provider's endpoint.
    ///
    /// Writing through it edits the selected profile rather than replacing the list, so
    /// a Linux settings file that only knows `modelEndpoint` keeps working and a macOS
    /// user's other profiles are left alone.
    var modelEndpoint: String {
        get { selectedModel?.endpoint ?? "" }
        set { mutateSelectedModel { $0.endpoint = newValue } }
    }

    var modelName: String {
        get { selectedModel?.model ?? "" }
        set { mutateSelectedModel { $0.model = newValue } }
    }

    /// The selected search provider's endpoint. Same rules as `modelEndpoint`: this is
    /// what the Linux settings file and every older one speak.
    var searchEndpoint: String {
        get { selectedSearch?.endpoint ?? Self.defaultSearchEndpoint }
        set { mutateSelectedSearch { $0.endpoint = newValue } }
    }

    /// The protocol the selected search provider speaks.
    var searchKind: SearchProviderKind {
        get { selectedSearch?.kind ?? .mcp }
        set { mutateSelectedSearch { $0.kind = newValue } }
    }

    private mutating func mutateSelectedModel(_ body: (inout ModelProfile) -> Void) {
        if let selected = selectedModel,
           let index = modelProfiles.firstIndex(where: { $0.id == selected.id }) {
            body(&modelProfiles[index])
            selectedModelID = modelProfiles[index].id
            return
        }
        // An empty list: create the one profile the write describes, on the legacy
        // account, so a fresh install and an upgraded one end up in the same state.
        var profile = ModelProfile(name: "", endpoint: "", model: "",
                                   keyAccount: SecretAccount.modelAPIKey.rawValue)
        body(&profile)
        modelProfiles = [profile]
        selectedModelID = profile.id
    }

    private mutating func mutateSelectedSearch(_ body: (inout SearchProfile) -> Void) {
        if let selected = selectedSearch,
           let index = searchProfiles.firstIndex(where: { $0.id == selected.id }) {
            body(&searchProfiles[index])
            selectedSearchID = searchProfiles[index].id
            return
        }
        var profile = SearchProfile(name: "", kind: .mcp, endpoint: Self.defaultSearchEndpoint,
                                    keyAccount: SecretAccount.searchAPIKey.rawValue)
        body(&profile)
        searchProfiles = [profile]
        selectedSearchID = profile.id
    }

    /// Applies the rules that must hold however the value was assembled, before it is
    /// stored.
    ///
    /// One rule today: an **MCP** search endpoint left blank reverts to the documented
    /// default, because an app with no search at all is worse than one pointed at z.ai.
    /// A blank SearXNG address stays blank — there is no default instance, and quietly
    /// substituting an MCP endpoint would research against a provider the row does not
    /// name, which is the worst of both.
    func normalized() -> ProviderSettings {
        var copy = self
        for index in copy.searchProfiles.indices {
            let trimmed = copy.searchProfiles[index].endpoint
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch (trimmed.isEmpty, copy.searchProfiles[index].kind) {
            case (true, .mcp):
                copy.searchProfiles[index].endpoint = Self.defaultSearchEndpoint
            // A blank command is the *common* case here rather than a mistake: almost
            // nobody renames the binary, so the field exists for the few who did.
            case (true, .kagiCLI):
                copy.searchProfiles[index].endpoint = Self.defaultKagiCommand
            default:
                copy.searchProfiles[index].endpoint = trimmed
            }
        }
        return copy
    }

    // MARK: Validation

    /// Everything that stops a research run from starting, as user-facing prose.
    /// Returns an empty array when the settings are usable.
    ///
    /// Only the *selected* provider is validated. A second profile the user is halfway
    /// through configuring must not block a question asked with the first one.
    ///
    /// `requiresSearch` is false for the `/direct` mode, which never contacts the search
    /// server. Validating the search endpoint there would block the one mode that works
    /// when search is misconfigured — which is exactly when a user reaches for it.
    func problems(hasModelKey: Bool, hasSearchKey: Bool, requiresSearch: Bool = true) -> [String] {
        var problems: [String] = []
        if modelEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("The model endpoint is empty.")
        } else if Self.chatCompletionsURL(from: modelEndpoint) == nil {
            problems.append("The model endpoint must be an HTTPS URL (HTTP is allowed only for localhost).")
        }
        if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("The model name is empty.")
        }
        if requiresSearch {
            let kind = searchKind
            switch kind {
            case .mcp:
                if Self.validatedEndpointURL(searchEndpoint) == nil {
                    problems.append("The search endpoint must be an HTTPS URL.")
                }
            case .searxng:
                if Self.searxngSearchURL(from: searchEndpoint) == nil {
                    problems.append("The SearXNG address must be an HTTPS URL (HTTP is "
                                    + "allowed only for localhost).")
                }
            case .kagiCLI:
                // Only that there is something to look for. Whether a program of that
                // name exists is a question for the machine, and it is asked where the
                // answer can be acted on — `SearchBackendFactory`, before the turn's
                // first billable call — rather than here, where these settings may be
                // being edited on a machine that is not the one that will run them.
                if searchEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    problems.append("The Kagi command is empty.")
                }
            }
            // A SearXNG instance is usually open, or fronted by a proxy rather than a
            // token; demanding a key there would block the most common self-hosted setup.
            if kind.requiresKey, !hasSearchKey {
                problems.append("The web-search key is missing.")
            }
        }
        // A model key is optional: a local llama.cpp or Ollama server takes none.
        _ = hasModelKey
        return problems
    }

    // MARK: Persistence helpers

    /// The profile list as JSON text, for a `SettingsStore` that only holds strings.
    ///
    /// Encoded here rather than in `CorePreferences` so both platforms produce the same
    /// bytes, and sorted-key so a settings file does not churn between writes that
    /// changed nothing.
    static func encodeModelProfiles(_ profiles: [ModelProfile]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads back `encodeModelProfiles`. Nil for text that will not parse, which the
    /// caller treats as "no list yet" and falls back to the single-provider keys —
    /// a corrupted list costs the extra profiles, never the ability to launch.
    static func decodeModelProfiles(_ text: String) -> [ModelProfile]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ModelProfile].self, from: data)
    }

    static func encodeSearchProfiles(_ profiles: [SearchProfile]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeSearchProfiles(_ text: String) -> [SearchProfile]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([SearchProfile].self, from: data)
    }

    // MARK: URL shaping

    /// The Chat Completions URL to POST to.
    ///
    /// Providers publish their endpoint at three different levels of completeness —
    /// a bare host, a versioned base (`/v1`, `/api/paas/v4`), or the full path — and
    /// users paste whichever their provider's docs show. Appending the well-known
    /// suffix only to a bare or version-suffixed path handles all three without
    /// mangling a genuinely custom route.
    static func chatCompletionsURL(from raw: String) -> URL? {
        guard var components = validatedURLComponents(raw) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty || versionSuffix.firstMatch(
            in: path, range: NSRange(path.startIndex..<path.endIndex, in: path)) != nil {
            path += "/chat/completions"
        }
        components.path = path
        return components.url
    }

    private static let versionSuffix = try! NSRegularExpression(pattern: #"/v[0-9]+$"#)

    /// The model-list URL for whatever the user pasted as their chat endpoint.
    ///
    /// The same three shapes `chatCompletionsURL` accepts, in reverse. A bare host or a
    /// versioned base (`/v1`) gains `/models`; a full chat path (`/v1/chat/completions`)
    /// has that suffix removed first, because appending to it would ask for
    /// `/chat/completions/models`, which is nothing.
    ///
    /// The append is idempotent, because the model-list URL is itself a plausible paste:
    /// it is the address the provider's documentation prints, and a reader who has just
    /// been told Vervellum can list models may well copy that line into the endpoint
    /// field. Appending blindly would ask for `/v1/models/models` and 404.
    ///
    /// Azure's deployment-scoped route is the one shape whose model list is not its own
    /// sibling. `chatCompletionsURL` accepts `/openai/deployments/<name>/chat/completions`
    /// as a custom path and leaves it alone, but Azure lists every deployment at
    /// `/openai/models` — so appending beside the deployment asks for a route that has
    /// never existed, and the reader gets a 404 on an address whose questions work.
    ///
    /// The shape is handled; Azure is not claimed. Its classic surface authenticates with
    /// an `api-key` header and Vervellum sends `Authorization: Bearer` everywhere, so that
    /// surface needs a credential scheme this app does not have — its own piece of work.
    /// What the fold is worth today is any gateway presenting Azure's path layout over
    /// bearer auth, and not asking a route that cannot exist.
    ///
    /// The query string is carried over, because `chatCompletionsURL` carries it and the
    /// two addresses have to describe the same provider. Azure's OpenAI-compatible
    /// surface is the case that makes this concrete: it requires `?api-version=` on every
    /// call, so dropping it here produced the worst failure this feature can have —
    /// questions work, listing 404s, and the message says nothing about a stripped
    /// parameter. The fragment is still dropped, since it is never sent to a server.
    ///
    /// Here rather than on `ModelCatalog` so the endpoint rules — HTTPS, no credentials
    /// in the URL, a host — stay in one place and keep their validator private.
    static func modelListURL(from raw: String) -> URL? {
        guard var components = validatedURLComponents(raw) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(chatCompletionsSuffix) { path.removeLast(chatCompletionsSuffix.count) }
        while path.hasSuffix("/") { path.removeLast() }
        // Only a deployment name — one segment, nothing after it — is folded away. A
        // deeper path under `deployments/` is somebody else's routing scheme, and
        // guessing at it would be worse than appending beside it.
        if let deployments = path.range(of: deploymentsInfix),
           path[deployments.upperBound...].firstIndex(of: "/") == nil {
            path = String(path[..<deployments.lowerBound]) + "/openai"
        }
        components.path = path.hasSuffix(modelsSuffix) ? path : path + modelsSuffix
        components.fragment = nil
        return components.url
    }

    private static let chatCompletionsSuffix = "/chat/completions"
    private static let modelsSuffix = "/models"
    private static let deploymentsInfix = "/openai/deployments/"

    /// The SearXNG JSON search URL for an instance address.
    ///
    /// Users paste the instance's home page (`https://searx.example.org`), because that
    /// is what a SearXNG instance advertises, so `/search` is appended when it is not
    /// already there. A full path is used as typed, which is what an instance behind a
    /// prefix (`https://example.org/searx/search`) needs, without a second setting.
    ///
    /// Any query string or fragment the user pasted along with the address is dropped:
    /// merging it with the search arguments would send a filter nobody asked for, and a
    /// pasted `?q=test` would fight the real query.
    static func searxngSearchURL(from raw: String) -> URL? {
        guard var components = validatedURLComponents(raw) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/search") { path += "/search" }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// A validated absolute endpoint URL, or nil.
    static func validatedEndpointURL(_ raw: String) -> URL? {
        validatedURLComponents(raw)?.url
    }

    /// The host of an endpoint, for a label. Nil when it is not a usable URL.
    static func host(of raw: String) -> String? {
        guard let host = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
              !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Shared endpoint hygiene.
    ///
    /// * **HTTPS required**, with an exception for loopback so a local model server
    ///   works without a certificate. Plain HTTP to a remote host would put the API
    ///   key on the wire in clear text.
    /// * **No userinfo.** A `https://key@host/` URL leaks the credential into every
    ///   log line and `Referer`; Vervellum sends keys in headers only.
    /// * **A host is required**, so a typo like `https:/v1` can't resolve to
    ///   something unexpected.
    private static func validatedURLComponents(_ raw: String) -> URLComponents? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        if scheme == "https" { return components }
        if scheme == "http", isLoopback(host) { return components }
        return nil
    }

    private static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case modelProfiles, selectedModelID, searchProfiles, selectedSearchID
        case modelFallback, pageReading, readerEndpoint
    }

    /// Lenient for the same reason `ModelProfile.init(from:)` is.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelProfiles = try container.decodeIfPresent([ModelProfile].self, forKey: .modelProfiles) ?? []
        selectedModelID = try container.decodeIfPresent(UUID.self, forKey: .selectedModelID)
        searchProfiles = try container.decodeIfPresent([SearchProfile].self, forKey: .searchProfiles) ?? []
        selectedSearchID = try container.decodeIfPresent(UUID.self, forKey: .selectedSearchID)
        // Absent in anything written before the chain existed, and the default there is
        // the same as the default for a fresh install: on.
        // Lenient like `pageReading` below and every other field here: a strict decode
        // throws on a value of the wrong type, and a throw from this initializer costs
        // the reader every provider in the file — the whole-document failure the
        // `.unknown` notice comment records as having emptied a library once already.
        modelFallback = ((try? container.decodeIfPresent(Bool.self, forKey: .modelFallback)) ?? nil)
            ?? Self.defaultModelFallback
        let rawMode = (try? container.decodeIfPresent(String.self, forKey: .pageReading)) ?? nil
        pageReading = rawMode.flatMap { PageReadingMode(rawValue: $0) } ?? .direct
        readerEndpoint = try container.decodeIfPresent(String.self, forKey: .readerEndpoint)
            ?? Self.defaultReaderEndpoint
    }
}
