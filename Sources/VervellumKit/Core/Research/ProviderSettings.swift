import Foundation

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
    /// The web-search MCP endpoint. Configurable so a self-hosted or proxied gateway can
    /// be substituted, but it defaults to the documented one.
    var searchEndpoint: String

    static let defaultSearchEndpoint = "https://api.z.ai/api/mcp/web_search_prime/mcp"

    // MARK: Initializers

    init(modelProfiles: [ModelProfile],
         selectedModelID: UUID? = nil,
         searchEndpoint: String = ProviderSettings.defaultSearchEndpoint) {
        self.modelProfiles = modelProfiles
        self.selectedModelID = selectedModelID
        self.searchEndpoint = searchEndpoint
    }

    /// The single-provider spelling: one model profile, on the account every
    /// pre-profiles build wrote.
    ///
    /// Both the migration path for an existing settings file and the shape the Linux
    /// front end and the tests construct, so it is a real initializer rather than a
    /// test helper.
    init(modelEndpoint: String = "",
         modelName: String = "",
         searchEndpoint: String = ProviderSettings.defaultSearchEndpoint) {
        let profile = ModelProfile(name: "", endpoint: modelEndpoint, model: modelName,
                                   keyAccount: SecretAccount.modelAPIKey.rawValue)
        self.init(modelProfiles: [profile],
                  selectedModelID: profile.id,
                  searchEndpoint: searchEndpoint)
    }

    // MARK: Selection

    /// The profile a new turn uses. Falls back to the first configured one, so a stale
    /// or missing selection degrades to "the one at the top" rather than to "not
    /// configured".
    var selectedModel: ModelProfile? {
        modelProfiles.first { $0.id == selectedModelID } ?? modelProfiles.first
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
            if Self.validatedEndpointURL(searchEndpoint) == nil {
                problems.append("The search endpoint must be an HTTPS URL.")
            }
            if !hasSearchKey {
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

    enum CodingKeys: String, CodingKey { case modelProfiles, selectedModelID, searchEndpoint }

    /// Lenient for the same reason `ModelProfile.init(from:)` is.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelProfiles = try container.decodeIfPresent([ModelProfile].self, forKey: .modelProfiles) ?? []
        selectedModelID = try container.decodeIfPresent(UUID.self, forKey: .selectedModelID)
        searchEndpoint = try container.decodeIfPresent(String.self, forKey: .searchEndpoint)
            ?? Self.defaultSearchEndpoint
    }
}
