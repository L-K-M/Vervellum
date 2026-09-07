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

    @State private var searchEndpoint = ""
    @State private var searchKeyEntry = ""
    @State private var hasSearchKey = false
    @State private var status: String?
    @State private var statusIsProblem = false

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
                footnote: "Vervellum searches through a Model Context Protocol server. The default "
                    + "is z.ai's hosted web-search endpoint, which needs a Coding Plan key.") {
                LabeledContent("Endpoint") {
                    TextField(ProviderSettings.defaultSearchEndpoint, text: $searchEndpoint)
                        .textFieldStyle(.roundedBorder)
                }
                keyRow(title: "Search key",
                       entry: $searchKeyEntry,
                       hasStored: hasSearchKey,
                       note: "Required. Research cannot run without it.") {
                    try? keychain.delete(.searchAPIKey)
                    hasSearchKey = keychain.hasValue(for: .searchAPIKey)
                    statusIsProblem = false
                    status = "Key removed."
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
                TextField("model-name", text: profile.model)
                    .textFieldStyle(.roundedBorder)
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
        searchEndpoint = settings.searchEndpoint
        keyEntries = [:]
        accountsToDelete = []
        storedKeys = Set(profiles.filter { keychain.hasValue(for: $0.secretAccount) }.map(\.id))
        hasSearchKey = keychain.hasValue(for: .searchAPIKey)
    }

    private func remove(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles.count > 1 else { return }
        // Recorded, not deleted: Save commits the removal, so closing Settings without
        // saving leaves the provider and its key exactly as they were.
        accountsToDelete.append(profiles[index].secretAccount)
        profiles.remove(at: index)
        keyEntries[id] = nil
        storedKeys.remove(id)
        if selectedID == id { selectedID = profiles.first?.id }
    }

    private func save() {
        var settings = preferences.providerSettings
        settings.modelProfiles = profiles
        settings.selectedModelID = selectedID ?? profiles.first?.id
        settings.searchEndpoint = searchEndpoint
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
            keyEntries = [:]
            if !searchKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychain.set(searchKeyEntry, for: .searchAPIKey)
            }
            searchKeyEntry = ""
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
        let searchKeyPresent = keychain.hasValue(for: .searchAPIKey)
        hasSearchKey = searchKeyPresent
        let saved = preferences.providerSettings

        // Report configuration problems now rather than at the first question, but do
        // not try to reach the providers: a connectivity check here would cost a
        // request and still not prove the key works for the model that was named.
        // Only the selected provider is checked, which is what `problems` validates —
        // a second one the user is halfway through configuring is not an error yet.
        let problems = saved.problems(hasModelKey: keychain.hasModelKey(for: saved),
                                      hasSearchKey: searchKeyPresent)
        statusIsProblem = !problems.isEmpty
        status = problems.isEmpty ? "Saved." : problems.joined(separator: " ")
    }
}
