import Foundation
import Security

/// Stores Vervellum's API keys in the login keychain — as ONE generic-password item
/// holding a JSON dictionary of every account, not one item per account.
///
/// Keychain authorization is per *item*, and this app ships unsigned: a build an
/// item's ACL cannot recognise is prompted once per item it reads. One item per
/// provider therefore cost one prompt per configured provider on every turn, because
/// `SecretStore.modelKeys(for:)` reads them all up front. One item costs one prompt
/// however many providers exist — and because the decoded blob is cached
/// process-wide, at most once per launch.
///
/// Keys never touch `UserDefaults` or the settings file: those are readable by
/// anything running as the user and get swept into backups and screen shares. The
/// Keychain is the only local store macOS gives an unsandboxed app that is encrypted
/// at rest and access-controlled per application.
///
/// The pre-blob layout — one item per account — is still *written*, in step with
/// the blob, because it is the downgrade path: a build from before this change reads
/// only those items, the same way the `modelEndpoint`/`modelName` mirror keeps a
/// settings downgrade working. Reads touch them only to migrate an account the blob
/// does not hold yet, so they cost no prompts once the blob is populated.
///
/// No `kSecAttrAccessible` is set, and that is deliberate rather than an omission: on
/// macOS it applies only to the *data protection* keychain, which in turn derives its
/// access groups from entitlements authorized by a provisioning profile. Opting in
/// (`kSecUseDataProtectionKeychain`) without that provisioning makes every call fail
/// with `errSecMissingEntitlement`. Against the default file-based keychain the
/// attribute is silently ignored, so passing it would be documentation that lies.
/// Items are protected by the login keychain's own unlock state and ACL.
///
/// This is the macOS half of the shared `SecretStore` seam; the Linux build supplies
/// its own, weaker, implementation and says so.
final class KeychainStore: SecretStore {

    /// The keychain service name; one per app so two L-K-M apps never collide.
    let service: String

    var backendDescription: String { "your login Keychain" }

    init(service: String = AppIdentity.bundleIdentifier) {
        self.service = service
    }

    /// `kSecAttrAccount` of the one item every key lives inside. Not a
    /// `SecretAccount` — nothing outside this type may name it, and no account
    /// minted by `SecretAccount`'s statics or `derived(from:for:)` produces this
    /// string, so a blob lookup can never recurse into the legacy-item path.
    private static let blobAccount = "all-api-keys"

    /// The decoded blob per service, shared process-wide. Several instances are
    /// live at once (`AppDelegate`, `ProvidersView`, `PanelRootView`), and a
    /// per-instance cache would let Settings write a key that the engine's copy
    /// then reads as absent for the rest of the session.
    ///
    /// Single-process by assumption: a second copy of the app writing the item
    /// between this process's read and write is clobbered by the stale cached
    /// base. Acceptable for a menu-bar agent, but the assumption is stated so a
    /// future caller does not read this cache as generally coherent.
    private static let lock = NSLock()
    private static var blobs: [String: Blob] = [:]

    private enum Blob {
        /// The item was read (or there was none): every account the blob holds.
        case loaded([String: String])
        /// The read failed for a reason other than absence. Cached rather than
        /// retried: every retry can re-prompt, and a denied dialog would otherwise
        /// return on each key lookup for the life of the process. A blob in this
        /// state must never be written over — see `mutateBlob`.
        case unreadable(OSStatus)
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        /// An account named after the blob item — only possible through a
        /// hand-edited settings file, since `SecretAccount`'s minting never
        /// produces it. Named so the failure is self-explaining and greppable
        /// rather than another generic `errSecParam`.
        case reservedBlobAccount

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error \(status)\(detail.map { ": \($0)" } ?? "")."
            case .reservedBlobAccount:
                return "An API-key account name collides with Vervellum's keychain item; correct the entry in settings."
            }
        }
    }

    // MARK: Read

    /// The stored secret for `account`, or nil when absent.
    ///
    /// A read failure other than "not found" is reported as nil rather than thrown:
    /// callers treat a missing key as "not configured yet", and a keychain that is
    /// momentarily unavailable should read the same way rather than crashing a
    /// research run. The status is logged so it is still diagnosable.
    func value(for account: SecretAccount) -> String? {
        // A `keyAccount` decodes from the settings file, which is not validated —
        // if one ever named the blob item itself, the legacy fallback below would
        // query the blob as a *per-account* item and hand back every key's JSON as
        // this account's secret, and `set`/`delete` would overwrite or remove the
        // whole blob. Reject the collision rather than trust the minting rules —
        // and log it, because it fires exactly when someone is already debugging
        // why a configured provider reads as unconfigured.
        guard account.rawValue != Self.blobAccount else {
            NSLog("Vervellum: settings named an account after the keychain blob item; treating it as unset")
            return nil
        }
        guard case .loaded(let secrets) = loadBlob() else { return nil }
        if let value = secrets[account.rawValue], !value.isEmpty { return value }

        // The blob does not hold this account — a key written by a pre-blob build,
        // or one this build has not migrated yet. Fall back to the per-account item
        // and fold what it holds into the blob, so the next read never looks twice.
        // The item itself is left in place: it is the downgrade path. A miss costs
        // one `errSecItemNotFound` and no prompt — only a *found* item's ACL can
        // ask a question.
        guard let legacy = legacyValue(for: account) else { return nil }
        try? mutateBlob { $0[account.rawValue] = legacy }
        return legacy
    }

    // MARK: Write

    /// Stores `secret` for `account`, replacing any existing value. An empty or
    /// whitespace-only secret deletes it instead — "clear the field and save" is
    /// how a user removes a key, and leaving an empty entry behind would make
    /// `hasValue(for:)` lie.
    func set(_ secret: String, for account: SecretAccount) throws {
        guard account.rawValue != Self.blobAccount else {
            throw KeychainError.reservedBlobAccount
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try delete(account); return }
        try mutateBlob { $0[account.rawValue] = trimmed }
        // Best-effort and after the blob: the blob is authoritative, the item
        // exists so a downgraded build still finds the key.
        try? setLegacy(trimmed, for: account)
    }

    /// Removes the stored secret. Succeeds when nothing was stored.
    func delete(_ account: SecretAccount) throws {
        guard account.rawValue != Self.blobAccount else {
            throw KeychainError.reservedBlobAccount
        }
        // The legacy item first, and its failure is fatal rather than swallowed:
        // removing only the blob entry would leave a copy that the next blob-miss
        // read migrates straight back — a deleted key resurrecting itself. Throwing
        // here keeps the blob entry, which is the honest "delete failed" state.
        try deleteLegacy(account)
        try mutateBlob { $0.removeValue(forKey: account.rawValue) }
    }

    // MARK: The blob

    private var blobQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.blobAccount,
        ]
    }

    /// The cached blob, reading and decoding the item on first use.
    private func loadBlob() -> Blob {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return lockedBlob()
    }

    /// Must be called with `Self.lock` held.
    private func lockedBlob() -> Blob {
        if let blob = Self.blobs[service] { return blob }
        let blob = readBlob()
        // A locked keychain fails with errSecInteractionNotAllowed and shows no
        // dialog, so caching that result suppresses no prompt — it would only keep
        // every key unreadable until relaunch after the user unlocks. Retry it;
        // denials and cancellations still cache, which is what the cache is for.
        if case .unreadable(errSecInteractionNotAllowed) = blob { return blob }
        Self.blobs[service] = blob
        return blob
    }

    private func readBlob() -> Blob {
        var query = blobQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secrets = SecretBlob.decode(data) else {
                NSLog("Vervellum: keychain blob item found but failed to decode")
                return .unreadable(errSecDecode)
            }
            return .loaded(secrets)
        case errSecItemNotFound:
            return .loaded([:])
        default:
            NSLog("Vervellum: keychain blob read failed with status \(status)")
            return .unreadable(status)
        }
    }

    /// Applies `mutate` to the blob and writes it back, updating the shared cache.
    ///
    /// Throws rather than write a partial dictionary over a blob it could not read:
    /// an unreadable blob overwritten with just the new account would destroy every
    /// other key in it.
    private func mutateBlob(_ mutate: (inout [String: String]) -> Void) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        switch lockedBlob() {
        case .unreadable(let status):
            throw KeychainError.unexpectedStatus(status)
        case .loaded(var secrets):
            mutate(&secrets)
            try persistBlob(secrets)
            Self.blobs[service] = .loaded(secrets)
        }
    }

    private func persistBlob(_ secrets: [String: String]) throws {
        try upsert(query: blobQuery,
                   value: SecretBlob.encode(secrets),
                   label: "Vervellum — API keys")
    }

    // MARK: The per-account items (downgrade path)

    private func legacyQuery(account: SecretAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    /// The per-account item a pre-blob build wrote, or nil.
    private func legacyValue(for account: SecretAccount) -> String? {
        var query = legacyQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                NSLog("Vervellum: keychain read for '\(account.rawValue)' failed with status \(status)")
            }
            return nil
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string.isEmpty ? nil : string
    }

    /// Writes the per-account item. `Data(secret.utf8)` rather than
    /// `data(using:)` — UTF-8 encoding cannot fail, so there is nothing to guard.
    private func setLegacy(_ secret: String, for account: SecretAccount) throws {
        try upsert(query: legacyQuery(account: account),
                   value: Data(secret.utf8),
                   label: "Vervellum — \(account.rawValue)")
    }

    private func deleteLegacy(_ account: SecretAccount) throws {
        let status = SecItemDelete(legacyQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Update-then-insert rather than insert-then-update: an add against an
    /// existing item fails with `errSecDuplicateItem`, so insert-first would take
    /// the error path on every ordinary key change. It also beats
    /// delete-then-insert, which has a window where the keys are simply gone.
    /// `attributesToUpdate` carries only the change; the query identifies the item
    /// and must not contain `kSecValueData`. The label goes in the update too, so
    /// an item written before the label existed still gains it.
    private func upsert(query: [String: Any], value: Data, label: String) throws {
        let update: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrLabel as String: label,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = value
        insert[kSecAttrLabel as String] = label
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Another writer inserted between the update miss and this add; the
            // item exists now, so a plain update finishes the write.
            let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(retryStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }
}
