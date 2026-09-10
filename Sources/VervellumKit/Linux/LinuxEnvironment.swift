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
    /// The bytes behind the attachments the threads refer to, beside the thread file.
    let attachments: AttachmentStore

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

        let attachmentDirectory = AttachmentStore.directory(besideThreadFile: threadsFile)
        let attachmentStore = AttachmentStore(directory: attachmentDirectory)

        settingsStore = store
        preferences = corePreferences
        self.secrets = secrets
        archive = threadArchive
        attachments = attachmentStore

        // Once, at launch, and only here. A thread stops being referenced when the
        // archive prunes it or a crash interrupted a write, and neither says so out
        // loud; sweeping by reachability at the one moment the whole library is in hand
        // costs a directory listing and cannot delete anything a thread still names.
        //
        // The macOS store also sweeps on a delete, because that front end has a history
        // list to delete from. This one has "New" and nothing else: no thread is removed
        // while the window is open, so there is no second moment to sweep at. A prune
        // strands its bytes until the next launch, which is the direction this is
        // deliberately wrong in — see `AttachmentStore.sweep`.
        //
        // Never on a library that could not be read. A corrupt or half-written thread
        // file leaves an empty library behind, and sweeping against that would delete
        // every attachment while the file — and its `.bak` — still name them. Deleting
        // is the one thing here that cannot be undone.
        if corePreferences.historyEnabled, threadArchive.libraryIsTrustworthy {
            attachmentStore.sweep(keeping: Set(threadArchive.library.threads
                .flatMap { $0.turns }
                .flatMap { $0.attachments }
                .map { $0.id }))
        } else if corePreferences.historyEnabled {
            // The library could not be read, so nothing here can say what a thread still
            // names and the sweep above was skipped. Said out loud, because this front
            // end has no delete and therefore no second moment to sweep at: if the file
            // stays unreadable, this launch is every launch, and the bytes accumulate
            // with nothing anywhere reporting why.
            StandardErrorLog().write(.warning, "Could not read the thread library, so "
                + "nothing in \(attachmentDirectory.path) was removed: an attachment "
                + "cannot be shown to be unreferenced while the threads that would "
                + "name it are unreadable.")
        } else if !LinuxEnvironment.threadFileSurvives(threadsFile) {
            // History off means the stored conversation is gone — not merely unwritten.
            // `ThreadArchive.eraseEverything` removes the thread file *and* its `.bak`
            // when history is off, and this is the check that it actually did: with both
            // gone there is no record left that could still name these bytes.
            //
            // Checked rather than assumed, because "history is off" and "the thread file
            // is gone" are two facts written at two moments, and the second can fail on
            // its own. An erase refused by a read-only folder sets `eraseFailure` on an
            // archive that does not survive the process — so the *next* launch reads a
            // setting that says off, finds a thread file nobody erased, and would delete
            // every picture those threads still name. That is the same hazard the
            // `libraryIsTrustworthy` guard above exists for, arriving down the other
            // branch, and deleting is the one thing here that cannot be undone.
            //
            // A directory of screenshots beside an erased thread file is the part of
            // "off" that nobody thinks to check.
            //
            // Said out loud when it fails, on the same channel the archive uses for the
            // thread file: a start-up that leaves the pictures behind under a setting
            // that promises otherwise should not be silent about it.
            do {
                try attachmentStore.removeAll()
            } catch {
                // The error, not only the guess after it: EACCES, ENOSPC and EBUSY all
                // land here and want different answers, and the path is already in this
                // line — so naming the cause adds nothing the message did not disclose.
                //
                // "Whatever is left", not "the images are still there": `removeAll` is a
                // recursive remove, which can fail part-way with some of the directory
                // already gone. A log that promised survival would send whoever reads it
                // looking for pictures that are not there.
                StandardErrorLog().write(.warning, "Could not delete "
                    + "\(attachmentDirectory.path): \(ResearchError.safeLabel(for: error)). "
                    + "The folder may be read-only, or a "
                    + "file in it locked; whatever is still in it was left in place.")
            }
        } else {
            // History is off but the thread file outlived the erase that should have
            // taken it. The pictures stay: they are named by threads that still exist,
            // and the next erase — a toggle, or a `deleteAll` — takes both together.
            StandardErrorLog().write(.warning, "\(threadsFile.path) is still there with "
                + "history off, so nothing in \(attachmentDirectory.path) was removed: "
                + "a thread that survived an erase still names these images.")
        }

        // `historyEnabled` is read once when the archive is built, so without this the
        // archive would keep writing after the user turned history off — the setting
        // would appear to work and change nothing until the next launch.
        corePreferences.onChange = { [weak threadArchive, weak corePreferences] in
            guard let threadArchive, let corePreferences else { return }
            if threadArchive.isHistoryEnabled != corePreferences.historyEnabled {
                threadArchive.isHistoryEnabled = corePreferences.historyEnabled
            }
            // Read once at construction for the same reason, so a lowered limit has to
            // reach the archive without a relaunch.
            //
            // This prunes and writes at once, so lowering the limit here is final —
            // deliberately unlike the load-time trim, which is memory-only so a hand
            // edit stays recoverable. The two paths answer the same question differently
            // and neither should be "fixed" into the other, because they are reached by
            // different things. `onChange` fires from `CorePreferences`'s *setters*: it
            // means the running app just wrote the value. A hand edit to `settings.json`
            // never arrives here at all — `JSONFileSettingsStore` reads the file once at
            // construction and serves from memory afterwards, with nothing watching it —
            // so an edit made behind the app's back lands at the next launch, on the
            // recoverable path. An earlier version of this comment said the hand edit
            // reached this line, which made a permanent prune look like the wrong answer
            // to it.
            if threadArchive.keptThreads != corePreferences.keptThreads {
                threadArchive.keptThreads = corePreferences.keptThreads
            }
        }
    }

    /// Whether a thread file — or the backup that stands in for one — is still on disk.
    ///
    /// Both, because `ThreadArchive.eraseEverything` removes the pair and a `.bak` alone
    /// is still a record naming attachments: it is what a recovery reads. The name is
    /// derived the same way the archive derives it, which is the one coupling here; a
    /// mismatch would read as "erased" for a backup that is sitting right there.
    private static func threadFileSurvives(_ threadsFile: URL,
                                           fileManager: FileManager = .default) -> Bool {
        [threadsFile, threadsFile.appendingPathExtension("bak")]
            .contains { fileManager.fileExists(atPath: $0.path) }
    }

}
#endif
