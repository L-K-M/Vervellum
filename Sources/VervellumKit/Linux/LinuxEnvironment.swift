#if os(Linux)
import Foundation

/// Assembles the platform pieces the shared core needs on Linux: where settings live,
/// where secrets live, where threads live.
///
/// The macOS app does the same assembly in its `AppDelegate` with `UserDefaults`, the
/// Keychain and Application Support. Everything above this line — the pipeline, the
/// prompts, the parsers, the archive — is identical between them; this is the whole of
/// the difference.
final class LinuxEnvironment {

    /// Shared by the panel and the command line, so both see the same settings and the
    /// same thread history within one process.
    static let shared = LinuxEnvironment()

    let settingsStore: SettingsStore
    let preferences: CorePreferences
    let secrets: SecretStore
    let archive: ThreadArchive

    init(settingsFile: URL = LinuxPaths.settingsFile,
         threadsFile: URL = LinuxPaths.threadsFile,
         secrets: SecretStore = LinuxSecretStore()) {
        // Built through locals so the wiring below never has to reach through a
        // partially initialised `self`.
        let store = JSONFileSettingsStore(url: settingsFile)
        let corePreferences = CorePreferences(store: store)
        let threadArchive = ThreadArchive(fileURL: threadsFile,
                                          historyEnabled: corePreferences.historyEnabled,
                                          keptThreads: corePreferences.keptThreads)

        settingsStore = store
        preferences = corePreferences
        self.secrets = secrets
        archive = threadArchive

        // `historyEnabled` is read once when the archive is built, so without this the
        // archive would keep writing after the user turned history off — the setting
        // would appear to work and change nothing until the next launch.
        corePreferences.onChange = { [weak threadArchive, weak corePreferences] in
            guard let threadArchive, let corePreferences else { return }
            if threadArchive.isHistoryEnabled != corePreferences.historyEnabled {
                threadArchive.isHistoryEnabled = corePreferences.historyEnabled
            }
            // Read once at construction for the same reason, and hand-edited in
            // `settings.json` on this platform — so a lowered limit has to reach the
            // archive without a relaunch.
            // Deliberately unlike the load-time trim, which is memory-only so a hand
            // edit stays recoverable: this prunes and writes at once, so lowering the
            // limit here is final. That is the right trade for a setting the reader just
            // changed — one that did nothing until relaunch would be worse — but the two
            // paths answer the same question differently, so neither should be "fixed"
            // into the other.
            if threadArchive.keptThreads != corePreferences.keptThreads {
                threadArchive.keptThreads = corePreferences.keptThreads
            }
        }
    }
}
#endif
