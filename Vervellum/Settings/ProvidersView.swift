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

    @State private var modelFallback = ProviderSettings.defaultModelFallback

    @State private var pageReading: PageReadingMode = .direct
    @State private var readerEndpoint = ""
    @State private var readerKeyEntry = ""
    @State private var hasReaderKey = false

    /// What each provider's model list is doing. Keyed by profile id because a card is
    /// fetched on its own — one provider being down must not blank another's list.
    @State private var catalogues: [UUID: CatalogueState] = [:]

    /// The live model-list fetch for each row, so a newer one can retire an older.
    ///
    /// `stillCurrent` alone was not enough: two fetches made with the *same* address and
    /// key both answered yes to it, so the one that finished last won even if it started
    /// first, and a slow failure could overwrite a fast success with "Could not list
    /// models". It was reachable, because clearing the catalogue on a key edit brings the
    /// refresh button back while the first fetch is still running.
    ///
    /// It is not reachable now, and that is what this holds: a new fetch cancels the one
    /// it replaces, and both guards test `Task.isCancelled` on the main actor with no
    /// suspension before the write, so a superseded task cannot land.
    @State private var modelFetches: [UUID: Task<Void, Never>] = [:]

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
                    + "configured side by side. A key is optional — a local model server usually "
                    + "needs none.") {

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

                // Shown only with somewhere to fall back to. A switch that cannot do
                // anything is a question the user has no way to answer.
                if profiles.count > 1 {
                    Toggle("Try the next provider if one fails", isOn: $modelFallback)
                        .help("The selected provider is tried first, then the rest in the "
                              + "order listed here.")
                    Text(fallbackExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                   note: "Optional — a local model server usually needs none.",
                   showsNote: false) {
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
                        // A bare indeterminate spinner reads as "busy" and nothing else,
                        // and there is one of these per provider card.
                        .accessibilityLabel("Listing models")
                }
                // Beside the spinner rather than replaced by it. The button already
                // cancels whatever is in flight before starting again, so leaving it up
                // costs nothing and buys the way out of a request that is going nowhere:
                // `sendCheapJSON` bounds the idle clock and the wall clock at thirty
                // seconds *each*, and they run one after the other, so a host that
                // accepts the connection and then says nothing can hold this row for the
                // better part of a minute. Hiding it also took the only labelled action
                // on the row away from VoiceOver for exactly that window.
                Button {
                    modelFetches[id]?.cancel()
                    // Read the row now, not when the task body runs. `profile` is a
                    // binding into the edited array: the body is enqueued and can run
                    // after other main-actor work, so `.wrappedValue` inside it would
                    // be whatever the field held *then* — or, if the row was deleted
                    // in between, a subscript into an index that is gone. It also
                    // makes `stillCurrent`'s comparison true to its own comment,
                    // which says the endpoint is the one the row asked with.
                    let asked = profile.wrappedValue
                    modelFetches[id] = Task { await loadModels(for: asked) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                // `.help` is a hint, not a label: without this the button reads as
                // "arrow clockwise", which says nothing about what it does.
                .accessibilityLabel("List this provider's models")
                .help("Ask this endpoint which models it serves")
                .disabled(ProviderSettings.modelListURL(from: profile.wrappedValue.endpoint) == nil)
                // A menu on the row rather than a second control under it. Both used to
                // be bound to `model`, so a loaded list drew the name twice — once in the
                // field, once in a pop-up below it — which is the same value asking to be
                // read as two settings. A menu has no selection of its own: it writes into
                // the field and leaves it the one place the model name lives. That also
                // retires the tag bookkeeping a `Picker` needed, where every value the
                // field could hold — empty, or typed and unlisted — had to be offered back
                // as a row or the menu drew blank.
                // `!models.isEmpty`, because a successful listing can be empty: a fresh
                // Ollama before its first pull, or LM Studio with nothing loaded, answer
                // `/models` with a well-formed empty list. Without this the row grows a
                // chevron that opens onto nothing — an affordance that cannot do
                // anything, offered exactly to the local-first setup this pane is for.
                // The old pop-up never had the problem because a `Picker` had to carry
                // the typed value as a row whatever the endpoint said.
                if case .loaded(let models) = catalogues[id], !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { name in
                            Button(name) { profile.model.wrappedValue = name }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .fixedSize()
                    .accessibilityLabel("Choose a listed model")
                    .help("\(models.count) models listed by this endpoint")
                }
            }

            // Only sentences stay under the row: something to read, not a control to
            // reach for.
            if case .failed(let reason) = catalogues[id] {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // An empty list is a real answer and needs saying. The spinner stops, the
            // menu does not appear, and without this the only difference between "asked
            // and told nothing" and "never asked" is a chevron nobody was watching for.
            if case .loaded(let models) = catalogues[id], models.isEmpty {
                Text("This endpoint listed no models. Type the name instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // A list belongs to the endpoint it came from. Editing the address makes it
        // stale, and a picker still offering the old host's models would be worse than
        // offering none.
        .onChange(of: profile.wrappedValue.endpoint) { _, _ in
            // Retired, not just ignored. `stillCurrent` already refuses to let the result
            // land, so this is about the request rather than the outcome: there is no
            // reason to keep asking an address the reader has moved off, with a key they
            // may have moved off too. Deleting a provider and reopening Settings both
            // cancel; these two were the ones that did not.
            modelFetches.removeValue(forKey: id)?.cancel()
            catalogues[id] = nil
        }
        // It belongs to the key just as much. Multi-tenant gateways filter `/models` by
        // entitlement, so a list fetched with the wrong key describes a different account
        // than the one the question will be asked with. Save clears the field too, which
        // discards a list that was in fact fetched with the key now stored — a click to
        // rebuild, and the same price this view already pays on every open.
        .onChange(of: keyEntries[id] ?? "") { _, _ in
            modelFetches.removeValue(forKey: id)?.cancel()
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
        // Cancellation is cooperative: a task cancelled before its first instruction still
        // runs its body. Without this, a fetch retired in that window would go on to write
        // `.loading`, fail, and decline to write anything else — leaving the row spinning
        // over a request nobody is waiting for. The refresh button now stays up beside the
        // spinner, so that state is recoverable rather than terminal; it is still wrong,
        // and this is what keeps it from happening rather than what rescues it.
        guard !Task.isCancelled else { return }
        catalogues[profile.id] = .loading
        let typed = (keyEntries[profile.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? keychain.value(for: profile.secretAccount) : typed
        let client = ModelCatalogClient(url: url, apiKey: key,
                                        trace: ResearchTrace(sink: SilentLog()))
        do {
            let models = try await client.fetch()
            guard !Task.isCancelled, stillCurrent(profile, entry: typed) else { return }
            catalogues[profile.id] = .loaded(models)
        } catch {
            guard !Task.isCancelled, stillCurrent(profile, entry: typed) else { return }
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
    /// Both comparisons rest on `ForEach($profiles)` handing out bindings that write
    /// straight into `profiles` as the user types. A draft binding that only landed on
    /// Save would leave the old endpoint here while a new one was on screen, and the
    /// stale result this guard exists to reject would pass it.
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
    /// `showsNote` is off for the rows that repeat. The reader and search keys appear
    /// once each, where a line under the field is guidance; the model cards appear once
    /// per provider, where the same sentence four times over is furniture. What it says
    /// is a fact about keys rather than about any one provider, so it belongs in the
    /// section's own footnote — and "a key is stored" is already what the field's
    /// placeholder says, one line above where this would print it again.
    private func keyRow(title: String,
                        entry: Binding<String>,
                        hasStored: Bool,
                        note: String,
                        showsNote: Bool = true,
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
                if showsNote {
                    Text(hasStored ? "A key is stored. \(note)" : note)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
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
        // list is one click away. A fetch still running is cancelled with them — which
        // reaches the ones this view still has a handle on, meaning a pane switch inside
        // a Settings window that stayed open. Close the window and the `@State` goes with
        // it, so on the next open there is nothing here to cancel and the old request
        // runs out its own budget writing into storage nobody reads. That costs one
        // request and cannot land anywhere, because it is a different view's dictionary;
        // it is not, as this said before, retired.
        for fetch in modelFetches.values { fetch.cancel() }
        modelFetches = [:]
        catalogues = [:]
        storedKeys = Set(profiles.filter { keychain.hasValue(for: $0.secretAccount) }.map(\.id))
        storedSearchKeys = Set(searchProfiles
            .filter { keychain.hasValue(for: $0.secretAccount) }.map(\.id))
        modelFallback = settings.modelFallback
        pageReading = settings.pageReading
        readerEndpoint = settings.readerEndpoint
        readerKeyEntry = ""
        hasReaderKey = keychain.hasValue(for: .readerAPIKey)
    }

    /// Names the order the chain will actually be tried in, from the live edits rather
    /// than from what was last saved — a user who has just reordered or reselected
    /// should be able to read the consequence before pressing Save.
    private var fallbackExplanation: String {
        guard modelFallback else {
            return "A failing provider fails the question. Nothing else is tried."
        }
        // The chain's own rule, not a second copy of it: a caption that drifted would
        // describe an order the runner does not walk.
        let order = ProviderSettings.chainOrder(profiles, selectedID: selectedID)
        guard !order.isEmpty else { return "" }
        return "Order: " + order.map(\.displayName).joined(separator: " → ")
            + ". The turn says which provider answered."
    }

    private func remove(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles.count > 1 else { return }
        // Recorded, not deleted: Save commits the removal, so closing Settings without
        // saving leaves the provider and its key exactly as they were.
        accountsToDelete.append(profiles[index].secretAccount)
        profiles.remove(at: index)
        keyEntries[id] = nil
        catalogues[id] = nil
        modelFetches.removeValue(forKey: id)?.cancel()
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
        settings.modelFallback = modelFallback
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
