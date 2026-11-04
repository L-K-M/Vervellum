import Foundation

/// Orders the three stores touched by the Providers pane so a failed credential write
/// cannot leave persisted settings pointing at a key that was never saved.
enum ProviderSettingsSaver {

    typealias SecretWrite = (account: SecretAccount, secret: String)

    enum CommitError: LocalizedError {
        case rollbackFailed

        var errorDescription: String? {
            "The settings were not saved, and an earlier credential change could not be "
                + "restored. Check the provider keys before trying again."
        }
    }

    private struct PreviousValue {
        var account: SecretAccount
        var secret: String?
    }

    /// Writes new credentials first, commits settings second, and only then removes
    /// credentials that the committed settings no longer reference. Failed cleanup is
    /// returned for a later retry because the settings commit itself is already complete.
    static func commit(settings: ProviderSettings,
                       writes: [SecretWrite],
                       deleting accounts: [SecretAccount],
                       secrets: SecretStore,
                       persist: (ProviderSettings) -> Void) throws -> [SecretAccount] {
        // A form can contain several credentials. If the second write fails, leaving
        // the first changed would pair an old endpoint with a new key even though the
        // settings commit never happened. Snapshot once per account and roll back every
        // successful write before returning the original failure.
        var previous: [PreviousValue] = []
        for write in writes where !previous.contains(where: { $0.account == write.account }) {
            previous.append(PreviousValue(account: write.account,
                                          secret: secrets.value(for: write.account)))
        }

        var applied: [SecretAccount] = []
        do {
            for write in writes {
                try secrets.set(write.secret, for: write.account)
                if !applied.contains(write.account) { applied.append(write.account) }
            }
        } catch let writeError {
            var rollbackFailed = false
            for account in applied.reversed() {
                guard let old = previous.first(where: { $0.account == account }) else { continue }
                do {
                    if let secret = old.secret {
                        try secrets.set(secret, for: account)
                    } else {
                        try secrets.delete(account)
                    }
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed { throw CommitError.rollbackFailed }
            throw writeError
        }

        persist(settings)

        var stillPending: [SecretAccount] = []
        for account in accounts {
            do {
                try secrets.delete(account)
            } catch {
                stillPending.append(account)
            }
        }
        return stillPending
    }
}
