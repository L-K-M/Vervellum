import SwiftUI

/// Where the providers are configured.
///
/// The key fields follow one rule borrowed from every credential form that gets this
/// right: **a blank field means "keep what is stored", never "erase it"**. A user who
/// opens Settings to change the model name must not silently wipe their keys by
/// saving a form whose password fields rendered empty. Clearing is a separate,
/// explicit button.
///
/// The model side is a list. Several providers can be configured — a local model, a
/// fast hosted one, a frontier one — each with its own endpoint and its own key, and
/// the one at the top of the pane is the one that answers the next question. Nothing
/// here is written until Save, including the removal of a provider's key: a form the
/// user might still cancel out of must not have already deleted a credential.
struct ProvidersView: View {

    @ObservedObject var preferences: Preferences

    /// Typed as the shared protocol so this pane is one rename away from being
    /// reusable, and so it can say which backend is in use rather than assuming.
    private let keychain: SecretStore = KeychainStore()

    @State private var profiles: [ModelProfile] = []
    @State private var selectedID: UUID?
    /// Keys typed but not yet saved, per provider. Empty means "leave the stored one".
    @State private var keyEntries: [UUID: String] = [:]
    /// Providers that already have a key in the secret store.
    @State private var storedKeys: Set<UUID> = []
    /// Accounts belonging to providers removed in this session. Deleted on Save, not on
    /// the click — see the type's documentation.
    @State private var accountsToDelete: [SecretAccount] = []

    @State private var searchProfiles: [SearchProfile] = []
    @State private var selectedSearchID: UUID?
    @State private var searchKeyEntries: [UUID: String] = [:]
    @State private var storedSearchKeys: Set<UUID> = []

    @State private var pageReading: PageReadingMode = .direct
    @State private var readerEndpoint = ""
    @State private var readerKeyEntry = ""
    @State private var hasReaderKey = false

    /// What each provider's model list is doing. Keyed by profile id because a card is
    /// fetched on its own — one provider being down must not blank another's list.
    @State private var catalogues: [UUID: CatalogueState] = [:]

    @State private var status: String?
    @State private var statusIsProblem = false

    /// A provider's model list, and why it is not showing one.
    enum CatalogueState: Equatable {
        case loading
        case loaded([String])
        /// The reason, already user-facing. The field stays editable underneath it.
        case failed(String)
    }

    var body: some View {
        SettingsPane {
            SettingsSection(
                title: "Models",
                footnote: "Any OpenAI-compatible Chat Completions endpoint. A bare host or a "
                    + "versioned base such as /v1 gets /chat/completions appended; a full path is "
                    + "used as typed. HTTPS is required, except for a model server on localhost. "
                    + "Each provider keeps its own key, so a local server and a hosted one can be "
                    + "configured side by side.") {

                if profiles.count > 1 {
                    Picker("Ask with", selection: Binding(
                        get: { selectedID ?? profiles.first?.id },
                        set: { selectedID = $0 })) {
                        ForEach(profiles) { profile in
                            Text(profile.displayName).tag(Optional(profile.id))
                        }
                    }
                    .help("The provider the next question is asked with. Also switchable "
                          + "from the panel and with /model.")
                }

                ForEach($profiles) { $profile in
                    providerCard($profile)
                }

                Button {
                    let added = ModelProfile.new()
                    profiles.append(added)
                    // Selected straight away: adding a provider and then having to pick it
                    // is a step nobody wants, and the previous one is one click back.
                    selectedID = added.id
                } label: {
                    Label("Add a provider", systemImage: "plus")
                }
            }

            SettingsSection(
                title: "Web search",
                footnote: "An MCP server — z.ai's hosted web search is the default and needs a "
                    + "Coding Plan key — or a SearXNG instance queried directly. A SearXNG "
                    + "instance must list `json` under `search.formats` in its settings.yml; most "
                    + "do not by default, and one that does not answers HTTP 403.") {

                if searchProfiles.count > 1 {
                    Picker("Search with", selection: Binding(
                        get: { selectedSearchID ?? searchProfiles.first?.id },
                        set: { selectedSearchID = $0 })) {
                        ForEach(searchProfiles) { profile in
                            Text(profile.displayName).tag(Optional(profile.id))
                        }
                    }
                }

                ForEach($searchProfiles) { $profile in
                    searchCard($profile)
                }

                Button {
                    let added = SearchProfile.new(kind: .searxng)
                    searchProfiles.append(added)
                    selectedSearchID = added.id
                } label: {
                    Label("Add a search provider", systemImage: "plus")
                }
            }

            SettingsSection(
                title: "Reading the page",
                footnote: "A search result is a summary, and a citation to a page nobody read "
                    + "is the weakest link in the chain — so Vervellum reads the pages behind "
                    + "the top few sources and marks in the source list which ones it got. "
                    + "Fetching them directly is the only thing Vervellum does that contacts a "
                    + "site you did not configure; those requests carry no key, no cookie and "
                    + "no referrer, but the site does see your address. A reader service fetches "
                    + "them instead, so the sites see the service and the service sees the URLs.") {
                Picker("Sources", selection: $pageReading) {
                    ForEach(PageReadingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                if pageReading == .reader {
                    LabeledContent("Reader endpoint") {
                        TextField(ProviderSettings.defaultReaderEndpoint, text: $readerEndpoint)
                            .textFieldStyle(.roundedBorder)
                    }
                    keyRow(title: "Reader key",
                           entry: $readerKeyEntry,
                           hasStored: hasReaderKey,
                           note: "Required for a hosted reader. z.ai's Web Reader takes the same "
                               + "Coding Plan key as its web search, stored separately.") {
                        try? keychain.delete(.readerAPIKey)
                        hasReaderKey = keychain.hasValue(for: .readerAPIKey)
                        statusIsProblem = false
                        status = "Key removed."
                    }
                }
            }

            HStack {
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                if let status {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(statusIsProblem ? Color.red : Color.secondary)
                }
                Spacer()
            }

            SettingsSection(title: "Where the keys live",
                            footnote: "Keys are stored in \(keychain.backendDescription), never in "
                                + "Vervellum's preferences file and never in a thread. They are sent "
                                + "only to the endpoints above, over HTTPS, and Vervellum never "
                                + "follows a redirect with a key attached.") { EmptyView() }
        }
        .onAppear(perform: load)
    }

    // MARK: Rows

    /// One model provider's fields.
    @ViewBuilder
    private func providerCard(_ profile: Binding<ModelProfile>) -> some View {
        let id = profile.wrappedValue.id
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name (optional)", text: profile.name)
                    .textFieldStyle(.roundedBorder)
                if profiles.count > 1 {
                    Button("Remove") { remove(id) }
                        .help("Remove this provider and, on Save, its stored key")
                }
            }
            LabeledContent("Endpoint") {
                TextField("https://api.example.com/v1", text: profile.endpoint)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Model") {
                modelRow(profile)
            }
            keyRow(title: "API key",
                   entry: Binding(get: { keyEntries[id] ?? "" },
                                  set: { keyEntries[id] = $0 }),
                   hasStored: storedKeys.contains(id),
                   note: "Optional — a local model server usually needs none.") {
                try? keychain.delete(profile.wrappedValue.secretAccount)
                storedKeys.remove(id)
                statusIsProblem = false
                status = "Key removed."
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// The model field, plus whatever the endpoint will tell us about itself.
    ///
    /// The text field never goes away. Fetching is an offer, not a replacement: a gateway
    /// that lists nothing, one that lists a hundred routing aliases, or a name reachable
    /// only through a prefix all have to stay typeable, and a picker that had swallowed
    /// the field would make those providers unusable.
    @ViewBuilder
    private func modelRow(_ profile: Binding<ModelProfile>) -> some View {
        let id = profile.wrappedValue.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("model-name", text: profile.model)
                    .textFieldStyle(.roundedBorder)

                if case .loading = catalogues[id] {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await loadModels(for: profile.wrappedValue) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    // `.help` is a hint, not a label: without this the button reads as
                    // "arrow clockwise", which says nothing about what it does.
                    .accessibilityLabel("List this provider's models")
                    .help("Ask this endpoint which models it serves")
                    .disabled(ProviderSettings.modelListURL(from: profile.wrappedValue.endpoint) == nil)
                }
            }

            switch catalogues[id] {
            case .loaded(let models):
                Picker("", selection: profile.model) {
                    // Every value the field can hold needs a row, or the menu draws
                    // blank and SwiftUI complains that the selection matches no tag.
                    if profile.wrappedValue.model.isEmpty {
                        Text("Type or choose a model").tag("")
                    } else if !models.contains(profile.wrappedValue.model) {
                        // The typed value is offered back as a row of its own when the
                        // endpoint did not list it, so choosing from the menu cannot
                        // silently discard a name that works.
                        Text(profile.wrappedValue.model).tag(profile.wrappedValue.model)
                    }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .help("\(models.count) models listed by this endpoint")
            case .failed(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loading, .none:
                EmptyView()
            }
        }
        // A list belongs to the endpoint it came from. Editing the address makes it
        // stale, and a picker still offering the old host's models would be worse than
        // offering none.
        .onChange(of: profile.wrappedValue.endpoint) { _, _ in
            catalogues[id] = nil
        }
        // It belongs to the key just as much. Multi-tenant gateways filter `/models` by
        // entitlement, so a list fetched with the wrong key describes a different account
        // than the one the question will be asked with. Save clears the field too, which
        // discards a list that was in fact fetched with the key now stored — a click to
        // rebuild, and the same price this view already pays on every open.
        .onChange(of: keyEntries[id] ?? "") { _, _ in
            catalogues[id] = nil
        }
    }

    /// Asks one provider for its model list.
    ///
    /// Uses the key typed in this session when there is one and the stored key otherwise,
    /// so a provider can be verified before Save — which is the moment the list is most
    /// useful. A list proves the address, not the key: plenty of local servers answer
    /// `/models` without looking at one. A hosted vendor that does check will refuse
    /// here, and that is worth catching early, but a loaded list is not a working key.
    @MainActor
    private func loadModels(for profile: ModelProfile) async {
        guard let url = ProviderSettings.modelListURL(from: profile.endpoint) else { return }
        catalogues[profile.id] = .loading
        let typed = (keyEntries[profile.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? keychain.value(for: profile.secretAccount) : typed
        let client = ModelCatalogClient(url: url, apiKey: key,
                                        trace: ResearchTrace(sink: SilentLog()))
        do {
            let models = try await client.fetch()
            guard stillCurrent(profile, entry: typed) else { return }
            catalogues[profile.id] = .loaded(models)
        } catch {
            guard stillCurrent(profile, entry: typed) else { return }
            // The provider's own text is never shown — only a `ResearchError` Vervellum
            // wrote, and a bare type name for anything else.
            catalogues[profile.id] = .failed(
                (error as? ResearchError)?.message
                    ?? "Could not list models. Type the model name instead.")
        }
    }

    /// Whether the row still asks what it asked when the request went out — same
    /// address, same typed key.
    ///
    /// Editing an endpoint clears its list, but a request already in flight would resume
    /// afterwards and write the *old* host's models under the new address — which is
    /// exactly the "a picker still offering the old host's models" outcome that clearing
    /// exists to prevent. It also settles two overlapping fetches: whichever finishes
    /// last, only the one matching what is on screen is allowed to land.
    ///
    /// The key entry is compared for the same reason, one field over: a fetch made with
    /// a rejected key must not repopulate the picker after the key has been corrected.
    private func stillCurrent(_ profile: ModelProfile, entry: String) -> Bool {
        guard profiles.first(where: { $0.id == profile.id })?.endpoint == profile.endpoint
        else { return false }
        return (keyEntries[profile.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines) == entry
    }

    /// One search provider's fields. The protocol picker comes first, because it decides
    /// what the address below it means and whether a key is needed at all.
    @ViewBuilder
    private func searchCard(_ profile: Binding<SearchProfile>) -> some View {
        let id = profile.wrappedValue.id
        let kind = profile.wrappedValue.kind
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name (optional)", text: profile.name)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: profile.kind) {
                    ForEach(SearchProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if searchProfiles.count > 1 {
                    Button("Remove") { removeSearch(id) }
                        .help("Remove this provider and, on Save, its stored key")
                }
            }
            LabeledContent(kind == .searxng ? "Address" : "Endpoint") {
                TextField(kind.endpointPlaceholder, text: profile.endpoint)
                    .textFieldStyle(.roundedBorder)
            }
            keyRow(title: kind.requiresKey ? "Search key" : "Token",
                   entry: Binding(get: { searchKeyEntries[id] ?? "" },
                                  set: { searchKeyEntries[id] = $0 }),
                   hasStored: storedSearchKeys.contains(id),
                   note: kind.requiresKey
                       ? "Required. Research cannot run without it."
                       : "Optional — only for an instance behind an authenticating proxy. "
                         + "SearXNG itself takes no key.") {
                try? keychain.delete(profile.wrappedValue.secretAccount)
                storedSearchKeys.remove(id)
                statusIsProblem = false
                status = "Key removed."
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func keyRow(title: String,
                        entry: Binding<String>,
                        hasStored: Bool,
                        note: String,
                        onClear: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    SecureField(hasStored ? "Stored — type to replace" : "Paste your key",
                                text: entry)
                        .textFieldStyle(.roundedBorder)
                    if hasStored {
                        Button("Clear", action: onClear)
                            .help("Remove the stored key from the Keychain")
                    }
                }
                Text(hasStored ? "A key is stored. \(note)" : note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Actions

    private func load() {
        let settings = preferences.providerSettings
        // Never an empty list: a pane with no rows offers nothing to type into, and the
        // one-provider case is what a first launch and an upgraded install both start in.
        profiles = settings.modelProfiles.isEmpty
            ? [ModelProfile(name: "", endpoint: "", model: "",
                            keyAccount: SecretAccount.modelAPIKey.rawValue)]
            : settings.modelProfiles
        selectedID = settings.selectedModel?.id ?? profiles.first?.id
        searchProfiles = settings.searchProfiles.isEmpty
            ? [SearchProfile(name: "", kind: .mcp, endpoint: ProviderSettings.defaultSearchEndpoint,
                             keyAccount: SecretAccount.searchAPIKey.rawValue)]
            : settings.searchProfiles
        selectedSearchID = settings.selectedSearch?.id ?? searchProfiles.first?.id
        keyEntries = [:]
        searchKeyEntries = [:]
        accountsToDelete = []
        // Not carried across an open: the endpoints may have changed elsewhere, and a
        // list is one click away.
        catalogues = [:]
        storedKeys = Set(profiles.filter { keychain.hasValue(for: $0.secretAccount) }.map(\.id))
        storedSearchKeys = Set(searchProfiles
            .filter { keychain.hasValue(for: $0.secretAccount) }.map(\.id))
        pageReading = settings.pageReading
        readerEndpoint = settings.readerEndpoint
        readerKeyEntry = ""
        hasReaderKey = keychain.hasValue(for: .readerAPIKey)
    }

    private func remove(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles.count > 1 else { return }
        // Recorded, not deleted: Save commits the removal, so closing Settings without
        // saving leaves the provider and its key exactly as they were.
        accountsToDelete.append(profiles[index].secretAccount)
        profiles.remove(at: index)
        keyEntries[id] = nil
        catalogues[id] = nil
        storedKeys.remove(id)
        if selectedID == id { selectedID = profiles.first?.id }
    }

    private func removeSearch(_ id: UUID) {
        guard let index = searchProfiles.firstIndex(where: { $0.id == id }),
              searchProfiles.count > 1 else { return }
        accountsToDelete.append(searchProfiles[index].secretAccount)
        searchProfiles.remove(at: index)
        searchKeyEntries[id] = nil
        storedSearchKeys.remove(id)
        if selectedSearchID == id { selectedSearchID = searchProfiles.first?.id }
    }

    private func save() {
        var settings = preferences.providerSettings
        settings.modelProfiles = profiles
        settings.selectedModelID = selectedID ?? profiles.first?.id
        settings.searchProfiles = searchProfiles
        settings.selectedSearchID = selectedSearchID ?? searchProfiles.first?.id
        settings.pageReading = pageReading
        settings.readerEndpoint = readerEndpoint
        preferences.providerSettings = settings

        do {
            for account in accountsToDelete { try keychain.delete(account) }
            accountsToDelete = []
            // Blank means "leave the stored key alone" — see the type's documentation.
            // The check trims first, because `KeychainStore.set` trims too and *deletes*
            // on an empty result: a field holding one stray space from a sloppy paste
            // would otherwise pass `!isEmpty` and wipe a working key, reporting "Saved."
            for profile in profiles {
                let typed = keyEntries[profile.id] ?? ""
                guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                try keychain.set(typed, for: profile.secretAccount)
            }
            for profile in searchProfiles {
                let typed = searchKeyEntries[profile.id] ?? ""
                guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                try keychain.set(typed, for: profile.secretAccount)
            }
            if !readerKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychain.set(readerKeyEntry, for: .readerAPIKey)
            }
            keyEntries = [:]
            searchKeyEntries = [:]
            readerKeyEntry = ""
        } catch {
            status = error.localizedDescription
            statusIsProblem = true
            return
        }

        // Read the secret store directly rather than through the `@State` flags just
        // written: a SwiftUI state write is a store for the *next* update, and reading it
        // back on the same call stack is not a documented guarantee. Getting it wrong
        // would report "The web-search key is missing." on the very save that supplied it.
        storedKeys = Set(profiles.filter { keychain.hasValue(for: $0.secretAccount) }.map(\.id))
        storedSearchKeys = Set(searchProfiles
            .filter { keychain.hasValue(for: $0.secretAccount) }.map(\.id))
        // Re-read: `normalized()` may have filled in the default MCP endpoint, and the
        // form should show what was stored rather than what was typed.
        hasReaderKey = keychain.hasValue(for: .readerAPIKey)
        let saved = preferences.providerSettings
        searchProfiles = saved.searchProfiles
        readerEndpoint = saved.readerEndpoint

        // Report configuration problems now rather than at the first question, but do
        // not try to reach the providers: a connectivity check here would cost a
        // request and still not prove the key works for the model that was named.
        // Only the selected provider is checked, which is what `problems` validates —
        // a second one the user is halfway through configuring is not an error yet.
        let problems = saved.problems(hasModelKey: keychain.hasModelKey(for: saved),
                                      hasSearchKey: keychain.hasSearchKey(for: saved))
        statusIsProblem = !problems.isEmpty
        status = problems.isEmpty ? "Saved." : problems.joined(separator: " ")
    }
}
