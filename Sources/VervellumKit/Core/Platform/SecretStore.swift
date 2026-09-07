import Foundation

/// Where API keys live.
///
/// Every platform has a different answer — the login Keychain on macOS, the Secret
/// Service on a Linux desktop, a mode-0600 file when there is no keyring at all — and
/// they are not equally strong. The protocol therefore carries `backendDescription`, so
/// Settings can tell the user *which* one is in use rather than implying they are
/// interchangeable.
protocol SecretStore: AnyObject {
    /// The stored secret, or nil when absent or unreadable.
    func value(for account: SecretAccount) -> String?
    /// Stores `secret`, replacing any existing value. An empty or whitespace-only
    /// secret deletes the item — "clear the field and save" is how a user removes a
    /// key, and leaving an empty item behind would make `hasValue(for:)` lie.
    func set(_ secret: String, for account: SecretAccount) throws
    func delete(_ account: SecretAccount) throws
    /// A short phrase naming the backend, for Settings. E.g. "your login Keychain".
    var backendDescription: String { get }
}

extension SecretStore {
    func hasValue(for account: SecretAccount) -> Bool { value(for: account) != nil }

    /// The selected model provider's key, or nil.
    ///
    /// Named once here because every caller has to ask the same slightly awkward
    /// question — "the key belonging to whichever provider is selected" — and a copy
    /// that reached for a fixed account instead would send one provider's key to
    /// another, or report a configured app as unconfigured.
    func modelKey(for settings: ProviderSettings) -> String? {
        settings.selectedModel.flatMap { value(for: $0.secretAccount) }
    }

    func hasModelKey(for settings: ProviderSettings) -> Bool { modelKey(for: settings) != nil }

    /// Every configured model provider's key, by profile id.
    ///
    /// Read in one pass at the start of a turn because the fallback chain may reach any
    /// of them, and a key looked up lazily at the moment of the switch would be read
    /// after the user had already had time to change it — a turn that sends one
    /// provider's old key and another's new one is not reproducible.
    ///
    /// Providers with no key are simply absent: a local llama.cpp or Ollama server
    /// takes none, and an absent entry sends no `Authorization` header at all.
    func modelKeys(for settings: ProviderSettings) -> [UUID: String] {
        var keys: [UUID: String] = [:]
        for profile in settings.modelProfiles {
            if let key = value(for: profile.secretAccount) { keys[profile.id] = key }
        }
        return keys
    }

    /// The selected search provider's key, or nil. Same reasoning as `modelKey(for:)`.
    func searchKey(for settings: ProviderSettings) -> String? {
        settings.selectedSearch.flatMap { value(for: $0.secretAccount) }
    }

    func hasSearchKey(for settings: ProviderSettings) -> Bool { searchKey(for: settings) != nil }
}

/// The secrets Vervellum stores, named rather than free strings so a typo cannot
/// silently create a second, empty slot that reads as "not configured".
///
/// A struct rather than an enum, because a key is no longer one of a fixed pair: a
/// user can configure several model providers, and each needs a slot of its own. New slots are minted by `SecretAccount.derived(from:for:)`,
/// which is the only way one is ever spelled out — a free `SecretAccount(rawValue:)`
/// would put the typo back.
///
/// **The two original raw values are load-bearing.** A Keychain item written by a
/// pre-profiles build lives at `model-api-key` / `search-api-key`, and the profile
/// migrated out of the old settings keeps exactly those accounts, so an existing user
/// upgrades without re-pasting a key.
struct SecretAccount: Hashable {
    let rawValue: String

    /// Deliberately not `public`-facing sugar: everything outside this file names an
    /// account through one of the statics or `derived(from:for:)`.
    init(rawValue: String) { self.rawValue = rawValue }

    /// The first model provider's key, and the account every pre-profiles build used.
    static let modelAPIKey = SecretAccount(rawValue: "model-api-key")
    /// The web-search key.
    static let searchAPIKey = SecretAccount(rawValue: "search-api-key")
    /// The page-reader service's key. A separate slot even when it holds the same z.ai
    /// Coding Plan credential as the search key: two services, two items, so revoking
    /// or rotating one does not silently break the other.
    static let readerAPIKey = SecretAccount(rawValue: "reader-api-key")

    /// A slot for a provider profile added after the first.
    ///
    /// The identifier is appended to the base account rather than replacing it, so a
    /// human reading a keyring still sees which kind of key an item holds.
    static func derived(from base: SecretAccount, for id: UUID) -> SecretAccount {
        SecretAccount(rawValue: base.rawValue + "." + id.uuidString)
    }
}

/// Holds secrets for the life of the process only. Used by tests, and by any run that
/// has no usable backend — losing the key on quit is better than writing it somewhere
/// the user was not told about.
final class EphemeralSecretStore: SecretStore {
    private var values: [SecretAccount: String] = [:]

    var backendDescription: String { "this session only (nothing is stored on disk)" }

    func value(for account: SecretAccount) -> String? { values[account] }

    func set(_ secret: String, for account: SecretAccount) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { values[account] = nil } else { values[account] = trimmed }
    }

    func delete(_ account: SecretAccount) throws { values[account] = nil }
}
