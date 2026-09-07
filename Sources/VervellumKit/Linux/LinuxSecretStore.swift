#if os(Linux)
import Foundation

/// Stores API keys on Linux, using the best backend actually available.
///
/// There is no single equivalent of the macOS Keychain, and the obvious candidate
/// fails in ways that are common rather than exotic: the Secret Service needs a running
/// keyring daemon and an *unlocked* collection, which a machine set up for automatic
/// login, a headless session, or a fresh container does not have. An app that refused
/// to start in those cases would be broken for a large minority of users.
///
/// So this is a ladder, tried in order, and the tier in use is reported to the user
/// rather than glossed over:
///
/// 1. **The Secret Service**, through `secret-tool`. Encrypted at rest and unlocked
///    with the login password — the closest thing to the Keychain.
/// 2. **An environment variable** (`VERVELLUM_MODEL_KEY`, `VERVELLUM_SEARCH_KEY`).
///    Read-only, and the right answer for a scripted or containerised setup.
/// 3. **A mode-0600 file** in the config directory, labelled in the interface as
///    unencrypted. Weaker than the other two, and the app says so.
///
/// `secret-tool` is invoked rather than linking libsecret because the CLI is a stable,
/// tiny contract and the alternative is variadic C interop for a feature that must
/// degrade gracefully anyway. Its cost is that it cannot distinguish "no such key" from
/// "the keyring is broken" — the man page documents only "0 on success, non-zero
/// otherwise" — so any failure is treated as "not stored" and the ladder moves on.
final class LinuxSecretStore: SecretStore {

    private enum Backend {
        case secretService
        case file
    }

    private let service: String
    private let fileURL: URL

    /// What the last successful write actually used. There is no reliable way to *probe*
    /// the Secret Service — `secret-tool lookup` reports "not found" and "the keyring is
    /// broken" with the same non-zero exit — so the ladder is walked for real on each
    /// operation and the outcome is recorded rather than predicted.
    private var lastWriteBackend: Backend?

    init(service: String = AppIdentity.bundleIdentifier, fileURL: URL = LinuxPaths.secretsFile) {
        self.service = service
        self.fileURL = fileURL
    }

    var backendDescription: String {
        switch lastWriteBackend {
        case .secretService: return "your login keyring"
        case .file: return "an unencrypted file in ~/.config/vervellum (no keyring was available)"
        case nil:
            return Self.secretToolPath == nil
                ? "an unencrypted file in ~/.config/vervellum (install libsecret-tools for a keyring)"
                : "your login keyring, or an unencrypted file if none is running"
        }
    }

    // MARK: SecretStore

    func value(for account: SecretAccount) -> String? {
        // The environment always wins: someone who exported a key meant it to be used,
        // and it is the documented way to run without a keyring.
        if let name = Self.environmentKey(account),
           let fromEnvironment = ProcessInfo.processInfo.environment[name],
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        // The ladder, walked for real. `secret-tool lookup` cannot distinguish "no such
        // key" from "no keyring", so a failure simply moves to the next tier.
        if let stored = Self.run(Self.secretToolPath, ["lookup", "service", service,
                                                      "account", account.rawValue])?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return stored
        }
        return fileValues()[account.rawValue]?.nonEmpty
    }

    func set(_ secret: String, for account: SecretAccount) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try delete(account); return }

        // Written on stdin, not as an argument: an argument is visible in `ps` to every
        // process on the machine. `secret-tool store` reads to EOF, which is also why
        // the value must not be echoed with a trailing newline — that newline would
        // become part of the stored secret, and every request would then carry a
        // malformed header.
        if Self.run(Self.secretToolPath,
                    ["store", "--label", "Vervellum \(account.rawValue)",
                     "service", service, "account", account.rawValue],
                    input: trimmed) != nil {
            lastWriteBackend = .secretService
            // Remove any earlier file copy, so the weaker tier does not keep a stale key
            // that would silently win nothing but still sit on disk.
            var values = fileValues()
            if values.removeValue(forKey: account.rawValue) != nil { try? writeFile(values) }
            return
        }

        var values = fileValues()
        values[account.rawValue] = trimmed
        try writeFile(values)
        lastWriteBackend = .file
    }

    /// Clears the key from *every* tier. A delete that left a copy behind in the
    /// weaker one would be the worst possible outcome: the user believes the key is
    /// gone and it is still on disk.
    func delete(_ account: SecretAccount) throws {
        _ = Self.run(Self.secretToolPath, ["clear", "service", service,
                                           "account", account.rawValue])
        var values = fileValues()
        if values.removeValue(forKey: account.rawValue) != nil { try writeFile(values) }
    }

    // MARK: File backend

    private func fileValues() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }

    private func writeFile(_ values: [String: String]) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])

        // Written to a temporary file created 0600 and then moved into place, rather
        // than with `Data.write(options: .atomic)`. An atomic write creates its own
        // temporary file under the process umask and renames it over the destination,
        // which *discards* whatever permissions the destination had — so pre-creating
        // the file 0600 and then writing atomically would leave the secret
        // world-readable on a default umask.
        let temporary = directory.appendingPathComponent(".secrets-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: nil,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw ResearchError("Vervellum could not create a file to store the key in.")
        }
        do {
            try data.write(to: temporary)
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: secret-tool

    /// The environment variable a key may be supplied in, for the two documented
    /// accounts.
    ///
    /// Only those three have one. A provider profile added in the macOS interface gets
    /// a derived account with a UUID in it (`SecretAccount.derived(from:for:)`), and an
    /// environment variable named after a UUID would be undocumentable — those profiles
    /// use the keyring or the file tier. Returning nil rather than synthesising a name
    /// keeps `value(for:)` from reading an unrelated variable that happens to collide.
    private static func environmentKey(_ account: SecretAccount) -> String? {
        switch account.rawValue {
        case SecretAccount.modelAPIKey.rawValue: return "VERVELLUM_MODEL_KEY"
        case SecretAccount.searchAPIKey.rawValue: return "VERVELLUM_SEARCH_KEY"
        default: return nil
        }
    }

    private static let secretToolPath: String? = {
        ["/usr/bin/secret-tool", "/bin/secret-tool", "/usr/local/bin/secret-tool"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs a command, returning its standard output, or nil if it could not run or
    /// exited non-zero.
    private static func run(_ path: String?, _ arguments: [String], input: String? = nil) -> String? {
        guard let path else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        // The null device, not a Pipe. An undrained pipe fills at 64 KB and the child
        // blocks writing to it forever, which would hang `waitUntilExit` — and this
        // output is never shown or logged anyway, because a provider's own error text
        // must not escape.
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }

        do {
            try process.run()
        } catch {
            return nil
        }
        if let input {
            // The throwing form: a child that exited before reading makes the write fail
            // with EPIPE, and `FileHandle.write(_:)` raises an Objective-C exception for
            // that, which Swift cannot catch — it terminates the process.
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Read before waiting: the reverse order deadlocks if the child writes more than
        // the pipe buffer holds.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension String {
    /// The string, or nil when it is empty. Keeps "stored but blank" from reading as
    /// "configured".
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
