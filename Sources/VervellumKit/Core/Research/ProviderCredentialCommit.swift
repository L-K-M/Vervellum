import Foundation

/// Commits provider destinations and the credentials that are allowed to reach them as
/// one disclosure-safe change.
///
/// Derived model and search profiles use copy-on-write secret accounts. A replacement
/// key is written to an unreferenced account first; only then is the profile made to
/// point at it. A destination changed without a replacement deliberately receives a
/// fresh, empty account, because carrying the old destination's key forward is the
/// failure this transaction exists to make structurally impossible.
///
/// The migrated first model and search profiles, and the reader, have fixed slots kept
/// for downgrade compatibility. They therefore use a deletion barrier: remove the old
/// value, persist the new endpoint, then write the new value. Any interruption can leave
/// that endpoint without a key, but can never bind it to the previous endpoint's key.
enum ProviderCredentialCommit {

    enum CredentialEdit: Equatable {
        /// A blank password field: keep a credential only when the destination is also
        /// unchanged. Destination changes still rotate to an empty account.
        case unchanged
        case replace(String)
        case clear
    }

    struct Edits: Equatable {
        var model: [UUID: CredentialEdit]
        var search: [UUID: CredentialEdit]
        var reader: CredentialEdit

        init(model: [UUID: CredentialEdit] = [:],
             search: [UUID: CredentialEdit] = [:],
             reader: CredentialEdit = .unchanged) {
            self.model = model
            self.search = search
            self.reader = reader
        }
    }

    struct Result: Equatable {
        let settings: ProviderSettings
        /// Superseded accounts that could not be removed. They are unreferenced and
        /// therefore cannot be sent, but the UI should say that cleanup is pending.
        let cleanupFailures: [SecretAccount]
    }

    enum CommitError: LocalizedError {
        case accountCollision
        case credentialAccountMismatch(SecretAccount)
        case sharedLegacyAccount(SecretAccount)
        case secretWriteAfterCommit(SecretAccount, Error)

        var settingsWereCommitted: Bool {
            if case .secretWriteAfterCommit = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .accountCollision:
                return "Could not allocate a fresh Keychain account. Nothing was saved."
            case .credentialAccountMismatch:
                return "A provider refers to a Keychain account reserved for another provider type. Nothing was saved."
            case .sharedLegacyAccount:
                return "Two providers share a Keychain account. Separate them before saving."
            case .secretWriteAfterCommit(_, let error):
                return "The provider settings were saved, but a replacement key was not: "
                    + error.localizedDescription
            }
        }
    }

    /// Performs the transaction. `persist` must return only after the settings are
    /// durable across a process restart; fixed-account replacements are written after
    /// that boundary and nowhere else.
    static func commit(original: ProviderSettings,
                       edited: ProviderSettings,
                       edits: Edits,
                       secrets: SecretStore,
                       makeAccount: (SecretAccount) -> SecretAccount = freshAccount,
                       pendingCleanup: [SecretAccount] = [],
                       persistPendingCleanup: ([SecretAccount]) throws -> Void = { _ in },
                       recordPendingCleanup: ([SecretAccount]) -> Void = { _ in },
                       persist: (ProviderSettings) throws -> Void) throws -> Result {
        let before = original.normalized()
        var committed = edited.normalized()
        var occupied = Set(before.modelProfiles.map(\.secretAccount)
            + before.searchProfiles.map(\.secretAccount)
            + committed.modelProfiles.map(\.secretAccount)
            + committed.searchProfiles.map(\.secretAccount)
            + pendingCleanup
            + [.readerAPIKey])
        var stagedWrites: [(SecretAccount, String)] = []
        var stagedEmptyAccounts: [SecretAccount] = []
        var barriers: [SecretAccount: CredentialEdit] = [:]

        for index in committed.modelProfiles.indices {
            let proposed = committed.modelProfiles[index]
            let prior = before.modelProfiles.first { $0.id == proposed.id }
            let edit = edits.model[proposed.id] ?? .unchanged
            let destinationChanged = prior.map {
                modelDestination($0.endpoint) != modelDestination(proposed.endpoint)
            } ?? true
            if let prior { committed.modelProfiles[index].keyAccount = prior.keyAccount }
            if prior == nil || destinationChanged || edit != .unchanged {
                if let prior, prior.secretAccount == .modelAPIKey {
                    guard barriers[.modelAPIKey] == nil else {
                        throw CommitError.sharedLegacyAccount(.modelAPIKey)
                    }
                    barriers[.modelAPIKey] = edit
                } else {
                    let account = try mint(from: .modelAPIKey, occupied: &occupied,
                                           secrets: secrets,
                                           makeAccount: makeAccount)
                    committed.modelProfiles[index].keyAccount = account.rawValue
                    if let replacement = edit.replacement {
                        stagedWrites.append((account, replacement))
                    } else {
                        stagedEmptyAccounts.append(account)
                    }
                }
            }
        }

        for index in committed.searchProfiles.indices {
            let proposed = committed.searchProfiles[index]
            let prior = before.searchProfiles.first { $0.id == proposed.id }
            let edit = edits.search[proposed.id] ?? .unchanged
            let destinationChanged = prior.map {
                searchDestination($0) != searchDestination(proposed)
            } ?? true
            if let prior { committed.searchProfiles[index].keyAccount = prior.keyAccount }
            if prior == nil || destinationChanged || edit != .unchanged {
                if let prior, prior.secretAccount == .searchAPIKey {
                    guard barriers[.searchAPIKey] == nil else {
                        throw CommitError.sharedLegacyAccount(.searchAPIKey)
                    }
                    barriers[.searchAPIKey] = edit
                } else {
                    let account = try mint(from: .searchAPIKey, occupied: &occupied,
                                           secrets: secrets,
                                           makeAccount: makeAccount)
                    committed.searchProfiles[index].keyAccount = account.rawValue
                    if let replacement = edit.replacement {
                        stagedWrites.append((account, replacement))
                    } else {
                        stagedEmptyAccounts.append(account)
                    }
                }
            }
        }

        // Existing IDs deliberately regain their stored account pointers above, so the
        // ownership check belongs after that restoration rather than on the editable
        // form's untrusted copies.
        try validateCredentialAccounts(in: committed)

        let readerChanged = readerDestination(before.readerEndpoint)
            != readerDestination(committed.readerEndpoint)
            || edits.reader != .unchanged
        if readerChanged { barriers[.readerAPIKey] = edits.reader }

        let beforeReferences = Set(before.modelProfiles.map(\.secretAccount)
            + before.searchProfiles.map(\.secretAccount))
        let committedReferenceList = committed.modelProfiles.map(\.secretAccount)
            + committed.searchProfiles.map(\.secretAccount)
        let committedReferences = Set(committedReferenceList + [.readerAPIKey])
        // A fixed slot can outlive its profile when an older build persisted removal
        // before a Keychain deletion failed. Delete every unowned slot before the scalar
        // mirror falls back to a selected derived-account provider; checking only the
        // prior profile list would preserve exactly that unsafe legacy state.
        for fixed in [SecretAccount.modelAPIKey, .searchAPIKey]
            where !committedReferences.contains(fixed) {
            barriers[fixed] = .clear
        }
        // One account answers to one destination: two profiles pointing at the same
        // Keychain item would send its secret to two different services — the binding
        // this transaction exists to prevent. The fixed slots are the ordinary case
        // (each has exactly one scalar downgrade mirror), but a derived name shared
        // through a hand-edited file is the same exposure, so every committed
        // reference is counted rather than just the legacy pair. Rejecting here, after
        // the per-profile loop has restored stored pointers, is also the only ordering
        // that catches duplicates this save does not touch at all.
        var referenceCounts: [SecretAccount: Int] = [:]
        for account in committedReferenceList {
            referenceCounts[account, default: 0] += 1
        }
        if let shared = referenceCounts
            .filter({ $0.value > 1 })
            .keys.sorted(by: { $0.rawValue < $1.rawValue })
            .first {
            throw CommitError.sharedLegacyAccount(shared)
        }

        let superseded = beforeReferences
            .subtracting(committedReferences)
            .subtracting(barriers.keys)
        let cleanupCandidates = Set(pendingCleanup)
            .union(superseded)
            .subtracting(committedReferences)
            .subtracting(barriers.keys)
            .sorted { $0.rawValue < $1.rawValue }
        // Written durably before the first Keychain mutation. If the process dies after
        // staging a fresh secret but before settings reference it, a later launch can
        // still find and remove the orphan. Live references are subtracted on retry, so
        // journalling accounts that go on to commit is safe.
        let preparedCleanup = Set(cleanupCandidates)
            .union(stagedWrites.map(\.0))
            .union(stagedEmptyAccounts)
            .sorted { $0.rawValue < $1.rawValue }
        var stagedAccounts: [SecretAccount] = []
        do {
            try persistPendingCleanup(preparedCleanup)
            for account in stagedEmptyAccounts {
                // `value(for:)` deliberately reports unreadable as absent. An explicit
                // delete is therefore the only safe proof that a fresh empty slot cannot
                // reveal an orphaned credential after the Keychain becomes readable.
                try secrets.delete(account)
            }
            for (account, replacement) in stagedWrites {
                // Include the in-progress account in rollback: a two-item Keychain write
                // may have updated its authoritative blob before its downgrade mirror
                // reported failure.
                stagedAccounts.append(account)
                try secrets.set(replacement, for: account)
            }
            for account in barriers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                try secrets.delete(account)
            }
            try persist(committed)
        } catch {
            discard(stagedAccounts, from: secrets)
            // Keep the candidate superset. A persistence barrier can report failure
            // after bytes reached disk; the next retry subtracts every live reference,
            // so retaining extra candidates is safe while dropping one can leak an
            // unreferenced Keychain item forever.
            recordPendingCleanup(preparedCleanup)
            throw error
        }

        var postCommitError: (SecretAccount, Error)?
        for account in barriers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let replacement = barriers[account]?.replacement {
                do {
                    try secrets.set(replacement, for: account)
                } catch {
                    // Settings are already committed. Do not roll them back to the old
                    // endpoint: its key was deleted first, and a retry may safely add
                    // the replacement to the new endpoint.
                    if postCommitError == nil { postCommitError = (account, error) }
                }
            }
        }

        var cleanupFailures: [SecretAccount] = []
        for account in cleanupCandidates {
            do {
                try secrets.delete(account)
            } catch {
                cleanupFailures.append(account)
            }
        }
        recordPendingCleanup(cleanupFailures)

        if let (account, error) = postCommitError {
            throw CommitError.secretWriteAfterCommit(account, error)
        }
        return Result(settings: committed, cleanupFailures: cleanupFailures)
    }

    private static func freshAccount(from base: SecretAccount) -> SecretAccount {
        SecretAccount.derived(from: base, for: UUID())
    }

    private static func mint(from base: SecretAccount,
                             occupied: inout Set<SecretAccount>,
                             secrets: SecretStore,
                             makeAccount: (SecretAccount) -> SecretAccount) throws -> SecretAccount {
        let account = makeAccount(base)
        // `occupied` includes the persisted cleanup journal. The store lookup also
        // covers an orphan left by a crash before that journal could be written.
        guard !occupied.contains(account), !secrets.hasValue(for: account) else {
            throw CommitError.accountCollision
        }
        occupied.insert(account)
        return account
    }

    private static func discard(_ accounts: [SecretAccount], from secrets: SecretStore) {
        for account in accounts {
            try? secrets.delete(account)
        }
    }

    // MARK: Account ownership

    private enum AccountNamespace {
        case model
        case search
        case reader
        case unknown
    }

    /// Recognised account names are load-bearing even though profile JSON is lenient.
    /// A transaction must never preserve a model that names a search slot (or the
    /// inverse), because its next request would send the other service's credential.
    private static func validateCredentialAccounts(in settings: ProviderSettings) throws {
        for profile in settings.modelProfiles {
            let namespace = accountNamespace(profile.secretAccount)
            guard namespace != .search, namespace != .reader else {
                throw CommitError.credentialAccountMismatch(profile.secretAccount)
            }
        }
        for profile in settings.searchProfiles {
            let namespace = accountNamespace(profile.secretAccount)
            guard namespace != .model, namespace != .reader else {
                throw CommitError.credentialAccountMismatch(profile.secretAccount)
            }
        }
    }

    private static func accountNamespace(_ account: SecretAccount) -> AccountNamespace {
        let raw = account.rawValue
        if raw == SecretAccount.modelAPIKey.rawValue
            || raw.hasPrefix(SecretAccount.modelAPIKey.rawValue + ".") { return .model }
        if raw == SecretAccount.searchAPIKey.rawValue
            || raw.hasPrefix(SecretAccount.searchAPIKey.rawValue + ".") { return .search }
        if raw == SecretAccount.readerAPIKey.rawValue
            || raw.hasPrefix(SecretAccount.readerAPIKey.rawValue + ".") { return .reader }
        return .unknown
    }

    // MARK: Destinations

    private enum Destination: Equatable {
        case model(String)
        case mcp(String)
        case searxng(String)
        case command(String)
        case reader(String)
        case invalid(String, String)
    }

    /// Discovery can run with unsaved fields. Only the currently saved profile can
    /// authorize a stored credential for that request, under the same destination
    /// comparison that Save uses when deciding whether to rotate an account.
    static func catalogKey(for draft: ModelProfile, saved: ProviderSettings,
                           edit: CredentialEdit, secrets: SecretStore) -> String? {
        switch edit {
        case .clear: return nil
        case .replace: return edit.replacement
        case .unchanged:
            guard let owner = saved.modelProfiles.first(where: { $0.id == draft.id }),
                  case let .model(destination) = modelDestination(draft.endpoint),
                  modelDestination(owner.endpoint) == .model(destination) else { return nil }
            return secrets.value(for: owner.secretAccount)
        }
    }

    private static func modelDestination(_ raw: String) -> Destination {
        guard let url = ProviderSettings.chatCompletionsURL(from: raw) else {
            return .invalid("model", trimmed(raw))
        }
        return .model(canonical(url))
    }

    private static func searchDestination(_ profile: SearchProfile) -> Destination {
        switch profile.kind {
        case .mcp:
            guard let url = ProviderSettings.validatedEndpointURL(profile.endpoint) else {
                return .invalid("mcp", trimmed(profile.endpoint))
            }
            return .mcp(canonical(url))
        case .searxng:
            guard let url = ProviderSettings.searxngSearchURL(from: profile.endpoint) else {
                return .invalid("searxng", trimmed(profile.endpoint))
            }
            return .searxng(canonical(url))
        case .kagiCLI:
            return .command(trimmed(profile.endpoint))
        case .unsupported(let raw):
            // A kind this build cannot run is still a destination of its own: keyed by
            // its stored spelling, so switching it to a supported kind counts as a
            // destination change and rotates the account rather than carrying the key.
            return .invalid("unsupported:" + raw, trimmed(profile.endpoint))
        }
    }

    private static func readerDestination(_ raw: String) -> Destination {
        guard let url = ProviderSettings.validatedEndpointURL(raw) else {
            return .invalid("reader", trimmed(raw))
        }
        return .reader(canonical(url))
    }

    private static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        // Fragments never reach a server and therefore cannot distinguish credential
        // destinations. Queries do reach it and remain part of the identity.
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension ProviderCredentialCommit.CredentialEdit {
    var replacement: String? {
        switch self {
        case .unchanged, .clear:
            return nil
        case .replace(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
