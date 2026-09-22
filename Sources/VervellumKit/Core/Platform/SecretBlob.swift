import Foundation

/// The payload of the single keychain item every API key lives in on macOS: a JSON
/// object mapping `SecretAccount.rawValue` to the secret.
///
/// Keychain authorization is per *item*, and this app ships unsigned — a build the
/// item's ACL cannot recognise is prompted once per item it touches. One item per
/// provider therefore cost one prompt per configured provider on every turn, because
/// `SecretStore.modelKeys(for:)` reads them all up front. One item costs one prompt
/// however many providers exist. See `KeychainStore` for the item layout and the
/// migration; this file is only the codec, kept in Core so the shape is testable on
/// Linux.
///
/// The format is deliberately the same `[String: String]` JSONSerialization shape
/// `LinuxSecretStore`'s file tier already writes: one less encoding to reason about.
enum SecretBlob {

    /// The dictionary `data` decodes to, or nil when it is not a JSON object with
    /// string values. Nil means *unreadable*, which is not the same as empty: a
    /// caller that cannot tell a corrupt blob from an empty one would merge into it
    /// and write the result back, destroying every key it could not read.
    static func decode(_ data: Data) -> [String: String]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }

    /// Sorted keys, so the stored bytes are deterministic and two blobs holding the
    /// same keys diff clean.
    static func encode(_ secrets: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: secrets, options: [.sortedKeys])
    }
}
