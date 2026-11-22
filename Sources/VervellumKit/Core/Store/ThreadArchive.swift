import Foundation
import Dispatch

/// Loads and saves the thread library as JSON, on every platform.
///
/// Writes are **atomic** and **debounced**, keeping one `.bak` of the previous good
/// file: the front ends save a thread whenever it changes — when a question is asked,
/// when its turn finishes, and on dismissal — so writing straight through would hammer
/// the disk, and writing non-atomically would leave a truncated file if the app were
/// killed mid-write.
///
/// The debounce runs on a **private serial queue**, not the main queue. That is not an
/// optimisation — `DispatchQueue.main` is only drained on Linux if something calls
/// `dispatchMain()`, and a GTK application runs a GLib main loop instead, so a
/// main-queue timer would simply never fire there. Using an owned queue also keeps the
/// file write off whichever thread is streaming the answer.
///
/// The whole archive is a no-op when history is disabled, and `eraseEverything()`
/// removes the file rather than writing an empty one — "off" has to mean the bytes are
/// gone, not that they are hidden.
final class ThreadArchive {

    /// Invoked after any change to `library`, so a platform can republish it.
    var onChange: (() -> Void)?

    /// Invoked when `saveFailure` or `backupFailure` changes, so a front end that
    /// shows them can republish. Hops to the main queue; `writeNow` runs on the
    /// archive's private queue.
    var onFailureChanged: (() -> Void)?

    private(set) var library: ThreadLibrary
    // Late runner snapshots retain their IDs. Erasure must outlive those callbacks.
    private var forgottenThreadIDs: Set<UUID> = []

    /// True when the file on disk claims a newer document version than this build
    /// understands. In that case the archive never writes.
    let isReadOnly: Bool

    /// Whether `library` is a true picture of what is stored — either the file decoded,
    /// or there was no file to decode.
    ///
    /// False means a document exists and could not be read: a corrupt file, a partial
    /// write, or one this build must not touch. It matters to anything that *deletes*
    /// what the library does not mention. `AttachmentStore`'s sweep is exactly that, and
    /// an empty library from a failed read would tell it to delete every attachment
    /// while a repairable thread file — and its `.bak` — still name them.
    ///
    /// Two states look as though they should need a clause here and do not. A *read-only*
    /// document — one stamped with a version this build does not know — never arrives
    /// trustworthy, because `load` returns on the version stamp before it decodes
    /// anything: the library is nil beside a file that existed, which is the false case
    /// already. And with history *off*, `library` is deliberately empty while the file
    /// may still be on disk — but the erase in `init` is what makes the disk agree, and a
    /// sweep that then finds nothing live is that erase reaching the bytes rather than a
    /// flag vouching for a picture it does not have. Gating this on `historyEnabled`
    /// would undo it: the sweep is the only thing that clears attachment bytes when the
    /// app launches with history already off.
    ///
    /// Set in `init` and afterwards only on `queue`, where `eraseEverything` marks it
    /// true again once the unreadable document is really gone: the emptied library is
    /// then a true picture of what is stored, which is nothing. That is the confinement
    /// `primaryIsTrustworthy` already uses, and it is what lets a "history off, then on
    /// again" cycle save again rather than refuse for the rest of the session.
    private(set) var libraryIsTrustworthy: Bool

    /// Why the stored document could not be read, in words fit for the interface; nil
    /// when there was nothing to read, when it read fine, or when the document is merely
    /// *read-only* (a newer version stamp, which `isReadOnly` already covers).
    ///
    /// Without this, a corrupt or unreadable file reads as an empty library, nothing
    /// anywhere says so, and the first save silently replaces the bytes — the user's
    /// only copy of conversations a repair could have recovered. Settings shows this
    /// beside the erase failure, and no write is attempted while it stands.
    ///
    /// A warning that outlives its condition tells a lie, so `eraseEverything` clears
    /// it beside `libraryIsTrustworthy` once the file it describes is gone.
    private(set) var readFailure: String?

    /// Why the last erase left the file in place, in words fit for the interface; nil
    /// once an erase succeeds. "History off means the bytes are gone" is a promise
    /// Settings makes, and when the file system breaks it the user has to be told
    /// rather than shown a toggle that says off.
    private(set) var eraseFailure: String?

    /// Why the last write could not be completed, in words fit for the interface;
    /// nil after a successful write. A failed write keeps its snapshot pending, so
    /// `retrySave()` is a real retry rather than a no-op.
    private(set) var saveFailure: String?

    /// Why the backup copy could not be replaced, or the file could not be made
    /// owner-readable, in words fit for the interface; nil after a fully protected
    /// write. Reported separately from `saveFailure`: the threads themselves may
    /// have been written, and the missing half is the recovery copy or the privacy
    /// promise.
    private(set) var backupFailure: String?

    /// When false, nothing is written and nothing is remembered.
    var isHistoryEnabled: Bool {
        didSet {
            guard oldValue != isHistoryEnabled else { return }
            // Turning history *on* stores nothing yet: writing here would create a file
            // holding an empty library before the user has any threads. The next
            // `save(_:)` writes it.
            guard !isHistoryEnabled else {
                // Enabling history is not proof that a failed deletion succeeded.
                if eraseFailure != nil { recordingFailure { try eraseEverything() } }
                onChange?()
                return
            }
            // Forget in memory as well as on disk. Erasing only the file would leave
            // every thread loaded, so switching history back on would write them all out
            // again — the user's "delete this" would have been a no-op.
            forgottenThreadIDs.formUnion(library.threads.map(\.id))
            library.threads.removeAll()
            recordingFailure { try eraseEverything() }
            onChange?()
        }
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleIdentifier).threads")
    // Queue-confined snapshots let continuous streams checkpoint without races.
    private var pendingSave: DispatchWorkItem?
    private var pendingSnapshot: ThreadLibrary?
    /// A backup staging copy left behind when a rotation failed, holding the
    /// primary as it was before the write. Queue-confined with the other write
    /// state; `finishPendingBackupRotation` completes it on a retry.
    private var pendingBackupStaging: URL?
    /// Whether the primary file is the "previous good copy" the `.bak` rotation
    /// promises: it decoded at launch, or this process has since written it. Set once
    /// in `init` and afterwards only on `queue`, where every write runs.
    private var primaryIsTrustworthy: Bool

    /// How many threads to keep. See `ThreadLibrary.prune(to:)`.
    ///
    /// Setting it prunes immediately rather than at the next write: a reader who has just
    /// asked to keep fifty expects to see fifty, not to wait for a hundred and fifty more
    /// questions to push the rest out.
    ///
    /// Clamped on every assignment, not only in `init`. `prune(to:)` clamps the number
    /// it is handed, so an out-of-range value never cost a thread — but the property went
    /// on reporting it, and a limit that says 3 while the archive enforces 10 is honest
    /// about nothing. The same door `PanelPalette.cornerScale` was left standing open by:
    /// clamping the initializer and trusting the property afterwards.
    var keptThreads: Int {
        didSet {
            // Before the `oldValue` comparison, so assigning 3 to an archive already at
            // the floor settles back to 10 and then does nothing, rather than pruning to
            // 10 a second time. Assigning inside `didSet` does not re-enter it.
            let clamped = ThreadLibrary.clampedKeptThreads(keptThreads)
            if clamped != keptThreads { keptThreads = clamped }
            guard keptThreads != oldValue, isHistoryEnabled, !isReadOnly else { return }
            guard library.prune(to: keptThreads) > 0 else { return }
            onChange?()
            scheduleSave()
        }
    }

    init(fileURL: URL,
         fileManager: FileManager = .default,
         historyEnabled: Bool = true,
         keptThreads: Int = ThreadLibrary.defaultKeptThreads,
         debounce: TimeInterval = 1.0) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.debounce = debounce
        self.isHistoryEnabled = historyEnabled
        // Clamped here *as well as* in the setter, because `didSet` never fires for an
        // initial assignment. Nothing else in the observer would be right here either:
        // it reads `isReadOnly` and `library`, neither of which is assigned until
        // further down.
        //
        // Clamped, not replaced. `CorePreferences.keptThreads` reads a non-positive
        // number as a damaged file and answers with the default; this layer has no idea
        // where its argument came from, so it treats one as a number out of range. The
        // production callers hand it the already-normalised preference, so the two rules
        // never disagree in practice — a caller that builds an archive from raw input
        // has to normalise first if it wants the damage rule.
        self.keptThreads = ThreadLibrary.clampedKeptThreads(keptThreads)

        // The file is read for its *version* even when history is off, and only adopted
        // when it is on. Skipping the read entirely would leave `isReadOnly` false, so a
        // user who launches with history disabled and then enables it would write an
        // empty document straight over a newer build's file — exactly the loss this
        // flag exists to prevent.
        let onDisk = Self.load(from: fileURL, fileManager: fileManager)
        isReadOnly = onDisk.newerVersion != nil
        libraryIsTrustworthy = onDisk.library != nil || !onDisk.fileExisted
        // A file that exists and is neither readable nor a newer version is the case
        // `libraryIsTrustworthy == false` was built for, minus the read-only branch,
        // which has its own explanation. Said here because the alternative is worse than
        // silence: the archive looks empty, and the next save would overwrite the only
        // copy with that emptiness.
        readFailure = !isReadOnly && !libraryIsTrustworthy
            ? "Could not read \(fileURL.lastPathComponent) in "
                + "\(fileURL.deletingLastPathComponent().path). The file may be corrupt "
                + "or unreadable; nothing new will be written to it until it can be read."
            : nil
        library = historyEnabled ? (onDisk.library ?? ThreadLibrary()) : ThreadLibrary()
        primaryIsTrustworthy = onDisk.primaryDecoded
        if let newer = onDisk.newerVersion {
            // Built as one string first: `.utf8` binds tighter than `+`, so applying it
            // to the last literal of a concatenation is a type error, not a byte view.
            let warning = "vervellum warning: threads file is version \(newer) "
                + "but this build understands \(ThreadLibrary.currentVersion) — history is "
                + "read-only so the newer file isn't downgraded.\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
        if !historyEnabled, !isReadOnly {
            recordingFailure { try eraseEverything() }
        }
        // A file written when the limit was higher — or by a build that had no setting —
        // is trimmed on the way in, so the list the reader sees already obeys what they
        // asked for. Never when the document is read-only: re-encoding a newer version
        // is exactly what that flag forbids.
        //
        // In memory only: the trimmed file lands with the next real write instead. This
        // is the one destructive path with no user gesture behind it — the limit comes
        // from `settings.json`, which a sync tool or a hand edit can lower without anyone
        // asking — and writing at once would make a stray edit unrecoverable before the
        // reader had done anything. Leaving the file alone means raising the limit and
        // relaunching gets everything back. Every real write prunes anyway, so the file
        // still converges; it just does so behind an action somebody took.
        if historyEnabled, !isReadOnly {
            let dropped = library.prune(to: keptThreads)
            if dropped > 0 {
                // Said out loud, because this is the one trim nobody asked for. Every
                // other one follows a picker the reader just moved; this one follows a
                // number that changed in a file while the app was closed, and the threads
                // are gone from the list before anything is on screen. "Where did my
                // threads go" is unanswerable without it — and the answer matters while
                // it is still recoverable, which is until the next save.
                let warning = "vervellum warning: \(dropped) thread(s) are not shown, "
                    + "because the stored limit is \(keptThreads). They are still in the "
                    + "file until something is saved — raise the limit and relaunch to "
                    + "get them back.\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
        }
    }

    // MARK: Mutation

    /// The write that makes a launch-time trim permanent, if one happened: the trimmed
    /// list is what gets encoded, and the reader's gesture was "ask a question" rather
    /// than "delete two thousand threads". What stands between them and that is the
    /// backup `writePending` rotates before every write — the untrimmed file survives as
    /// `.bak` until the *second* save of the session. That is thin, and it is the reason
    /// the load-time trim is memory-only rather than one more thing that also writes.
    func save(_ thread: ResearchThread) {
        guard isHistoryEnabled, !forgottenThreadIDs.contains(thread.id) else { return }
        library.upsert(thread, keeping: keptThreads)
        onChange?()
        scheduleSave()
    }

    func delete(id: UUID) {
        forgottenThreadIDs.insert(id)
        library.remove(id: id)
        onChange?()
        scheduleSave()
    }

    func deleteAll() {
        forgottenThreadIDs.formUnion(library.threads.map(\.id))
        library.threads.removeAll()
        recordingFailure { try eraseEverything() }
        onChange?()
    }

    /// The bytes currently on disk, or nil when there is no file. Used to skip a write
    /// that would change nothing.
    private func currentContents() -> Data? { fileManager.contents(atPath: fileURL.path) }

    /// Removes the stored file and its backup outright.
    ///
    /// The deletion runs *on the write queue*. Deleting off-queue would race a debounced
    /// write that is already running, and the file the user just erased would reappear a
    /// fraction of a second later.
    private func eraseEverything() throws {
        var failure: Error?
        queue.sync {
            pendingSave?.cancel()
            pendingSave = nil
            pendingSnapshot = nil
            for url in [fileURL, backupURL] where fileManager.fileExists(atPath: url.path) {
                do { try fileManager.removeItem(at: url) } catch { failure = error }
            }
            if failure == nil {
                // The document a read failure described no longer exists, so the
                // refusal it caused has to end with it. Every caller empties the
                // library before this runs, so it is again a true picture of what is
                // stored — nothing — and the next save may proceed. Left standing,
                // `readFailure` would keep reporting a file that is gone and
                // `libraryIsTrustworthy` would keep refusing every write, which is
                // how toggling history off and back on used to persist nothing until
                // relaunch. Mutated here, on `queue`, beside `primaryIsTrustworthy`:
                // `writeNow` reads the flag on this same queue, so confining the
                // write to it is what keeps the flag race-free.
                readFailure = nil
                libraryIsTrustworthy = true
            }
        }
        // Reported, not swallowed. "History off means the bytes are gone" is a promise
        // the interface makes; if the file is still there the user has to be told.
        if let failure { throw failure }
    }

    /// Runs an erase and keeps its outcome in `eraseFailure`, so a front end that
    /// cannot throw through a toggle binding still has something to show.
    private func recordingFailure(_ erase: () throws -> Void) {
        do {
            try erase()
            eraseFailure = nil
        } catch {
            // Vervellum's own words, not the file manager's: the message is shown in
            // Settings, and the path is the one thing the user needs to go and fix.
            eraseFailure = "Could not delete \(fileURL.lastPathComponent) in "
                + "\(fileURL.deletingLastPathComponent().path). The file may be locked "
                + "or the folder read-only; nothing new will be written to it."
            FileHandle.standardError.write(Data("vervellum warning: \(eraseFailure ?? "")\n".utf8))
        }
    }

    /// Writes any pending change before returning. Called at termination and on
    /// dismissal, where a lost second of work would be a lost answer.
    ///
    /// `queue.sync` rather than a direct call: a debounced write may already be running
    /// on the queue, and two overlapping `.bak` rotations would leave the backup in an
    /// undefined state. Serialising through the same queue makes the ordering explicit.
    func flush() {
        queue.sync {
            pendingSave?.cancel()
            writePending()
        }
    }

    /// Re-attempts the erase that recorded `eraseFailure`.
    ///
    /// The Settings warning offers this because a refusal that has since been fixed
    /// — a permission grant, an unlocked file — should not stay a permanent write
    /// block. A success clears the failure beside the file.
    func retryErase() {
        guard eraseFailure != nil else { return }
        let failureBefore = eraseFailure
        recordingFailure { try eraseEverything() }
        // Only republish on an actual change, matching `recordFailures`. A retry
        // that fails again for the same reason leaves the same warning standing.
        if eraseFailure != failureBefore {
            DispatchQueue.main.async { self.onFailureChanged?() }
        }
    }

    /// Re-attempts a failed write or backup rotation.
    ///
    /// A failed write keeps its snapshot pending, so this rewrites the exact
    /// document that failed. A backup-only failure re-runs the rotation against
    /// the current primary, because the next ordinary write may be a long way off
    /// and the recovery copy is worth having now. A staging copy left by the
    /// failed rotation is finished first: it holds the pre-write primary, which is
    /// the recovery copy the backup exists to be.
    func retrySave() {
        queue.sync {
            if pendingSnapshot != nil {
                pendingSave?.cancel()
                pendingSave = nil
                writePending()
            } else if backupFailure != nil {
                let directory = fileURL.deletingLastPathComponent()
                var backup: String?
                if finishPendingBackupRotation() || rotateBackup() {
                    // A rotation completed through the staging copy never
                    // re-attempts the primary's chmod. Retry it here so a
                    // failed owner-only permission is not cleared while the
                    // saved file may still be readable by others.
                    do {
                        try fileManager.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: fileURL.path)
                    } catch {
                        backup = Self.permissionFailureMessage(
                            in: directory, file: fileURL.lastPathComponent)
                    }
                } else {
                    backup = Self.backupFailureMessage(in: directory,
                                                       file: fileURL.lastPathComponent)
                }
                recordFailures(save: nil, backup: backup)
            }
        }
    }

    /// Publishes a pair of failure strings. Both nil clears a previous warning, so
    /// a successful retry cannot leave a stale one beside the file.
    private func recordFailures(save: String?, backup: String?) {
        // Every successful write passes through here; a main-queue hop on each one
        // would put a block on the queue ten times a second during a stream.
        guard saveFailure != save || backupFailure != backup else { return }
        saveFailure = save
        backupFailure = backup
        DispatchQueue.main.async { self.onFailureChanged?() }
    }

    /// The write/backup failure strings, safe to read from any thread.
    ///
    /// The stored properties are confined to `queue`, because `writeNow` runs
    /// there during debounced streaming saves. A reader on the main thread —
    /// SwiftUI evaluating `ThreadStore.storageFailure`, or a retry button — goes
    /// through here rather than racing the write. Never call this from code
    /// already on `queue`: `queue.sync` would deadlock.
    func storageFailures() -> (save: String?, backup: String?) {
        queue.sync { (saveFailure, backupFailure) }
    }

    private static func saveFailureMessage(in directory: URL, file: String) -> String {
        "Could not save \(file) in \(directory.path). The file may be locked or the "
        + "folder read-only; nothing was written. Earlier threads are unchanged."
    }

    private static func backupFailureMessage(in directory: URL, file: String) -> String {
        "Could not keep a backup copy of \(file) in \(directory.path). The threads "
        + "file itself was saved, but the previous copy was not replaced."
    }

    private static func permissionFailureMessage(in directory: URL, file: String) -> String {
        "Could not make \(file) owner-readable only in \(directory.path). The file was "
        + "saved, but it may be readable by others."
    }

    // MARK: Persistence

    private var backupURL: URL { fileURL.appendingPathExtension("bak") }

    private func scheduleSave() {
        // An unreadable document is not an empty one. Writing the in-memory library over
        // it would destroy the bytes a repaired permission or a backup tool could still
        // recover, and the reader was never told anything was wrong. Refuse, and leave
        // `readFailure` as the reason. `eraseFailure` and `isReadOnly` are separate
        // blockers for separate situations.
        guard isHistoryEnabled, !isReadOnly, eraseFailure == nil,
              libraryIsTrustworthy else { return }
        var document = library
        document.version = ThreadLibrary.currentVersion
        let snapshot = document
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSnapshot = snapshot
            // Keep the first deadline: resetting it on every token never saves.
            guard self.pendingSave == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.writePending() }
            self.pendingSave = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }

    private func writePending() {
        pendingSave = nil
        guard let snapshot = pendingSnapshot else { return }
        // `pendingSnapshot` stays until `writeNow` succeeds, so a failed write can
        // be retried with the same document rather than being silently dropped.
        writeNow(snapshot)
    }

    private func writeNow(_ snapshot: ThreadLibrary) {
        // Belt and braces around `scheduleSave`'s gate: `flush()` reaches `writePending`
        // directly, so the same refusal belongs at the one place every write passes.
        guard !isReadOnly, libraryIsTrustworthy else { return }
        let directory = fileURL.deletingLastPathComponent()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)

            // Fence off Foundation's atomic temporary files before any bytes are written.
            let privateDirectory: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: privateDirectory)
            try fileManager.setAttributes(privateDirectory, ofItemAtPath: directory.path)
            // Skip a write that would change nothing. `flush()` is called on every
            // dismissal and at termination, and without this each one rotates the
            // previous file into `.bak` — after two flushes the backup is a byte-perfect
            // copy of the live file and has stopped being a recovery copy at all.
            if currentContents() == data {
                pendingSnapshot = nil
                // The intended bytes are already there, so a failed *write* is
                // resolved — but a failed backup is not: no rotation happened, and
                // the recovery copy is still the stale one.
                recordFailures(save: nil, backup: backupFailure)
                return
            }

            // Rotate the previous good file, so a failure during the write still leaves
            // one recoverable copy — only now, when the contents really differ, and only
            // when the primary *is* a good file. After a launch that recovered from
            // `.bak`, the primary is the corrupt one; copying it over the backup before
            // the new write is known to have succeeded would, if that write then failed
            // for the same reason (a full disk, say), leave nothing readable at all.
            var attemptBackupFailure: String?
            if primaryIsTrustworthy, fileManager.fileExists(atPath: fileURL.path) {
                if !rotateBackup() {
                    attemptBackupFailure = Self.backupFailureMessage(
                        in: directory, file: fileURL.lastPathComponent)
                }
            }
            do {
                try data.write(to: fileURL, options: [.atomic])
                primaryIsTrustworthy = true
                // Consumed only now that the bytes are on disk. A failure leaves the
                // snapshot pending so `retrySave()` can rewrite the same document.
                pendingSnapshot = nil
            } catch {
                recordFailures(save: Self.saveFailureMessage(in: directory,
                                                             file: fileURL.lastPathComponent),
                               // This attempt's rotation result.
                               backup: attemptBackupFailure)
                FileHandle.standardError.write(Data("vervellum warning: could not save threads\n".utf8))
                return
            }
            // Research questions are personal. Keep the file owner-only rather than
            // inheriting the umask. A failure here does not undo the write, but it
            // does leave the file readable by others, which is worth saying.
            //
            // Run regardless of the rotation result: a failed backup must not also
            // silently drop the owner-only promise for the file that did get
            // written. Both failures are kept, because they send the reader to two
            // different places.
            do {
                try fileManager.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: fileURL.path)
            } catch {
                attemptBackupFailure = [attemptBackupFailure,
                                        Self.permissionFailureMessage(
                                            in: directory, file: fileURL.lastPathComponent)]
                    .compactMap { $0 }.joined(separator: " ")
            }
            recordFailures(save: nil, backup: attemptBackupFailure)
        } catch {
            // Reachable only before a rotation is attempted (encoding, directory
            // creation), so this deliberately reads the *property*: a previously
            // recorded backup failure still stands when this write never got that far.
            recordFailures(save: Self.saveFailureMessage(in: directory,
                                                         file: fileURL.lastPathComponent),
                           backup: backupFailure)
            FileHandle.standardError.write(Data("vervellum warning: could not save threads\n".utf8))
        }
    }

    /// Copies the current primary over the backup, replacing it only once the new
    /// copy exists.
    ///
    /// The old order — remove `.bak`, then copy the primary into its place — threw
    /// away the only recovery copy whenever the copy failed: a full disk, a locked
    /// file, a permission change. Copying to a staging name first means the previous
    /// backup survives until the replacement is actually there.
    @discardableResult
    private func rotateBackup() -> Bool {
        guard primaryIsTrustworthy, fileManager.fileExists(atPath: fileURL.path) else {
            return true
        }
        let staging = backupURL.appendingPathExtension("tmp")
        // A staging copy inherited from a failed rotation holds the pre-write
        // primary — the recovery copy this rotation exists to make. Finish that
        // rotation rather than staging a new copy over it. Returning false keeps
        // the failure reported and the staging copy alive for the next attempt.
        if pendingBackupStaging == staging {
            return finishPendingBackupRotation()
        }
        do {
            try? fileManager.removeItem(at: staging)
            // Tighten the primary before staging, so the copy that becomes the
            // backup inherits owner-only mode rather than the umask default. On
            // a fresh archive's first save the primary has not been chmod'd yet,
            // and the backup is the copy most likely to outlive it.
            // Correctness, not cleanup: a copy that inherits the umask must
            // not become the recovery copy. Failing here leaves the old backup
            // in place (it is removed only after this) and reports the problem.
            try fileManager.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: fileURL.path)
            try fileManager.copyItem(at: fileURL, to: staging)
            // Remove the old backup only once the new copy exists, so a
            // failure here leaves the previous recovery copy untouched. The
            // remove-and-move is deliberately not `replaceItemAt`: that API
            // cannot be overridden portably in the shared test target, and the
            // staging copy is what makes the failure recoverable.
            try? fileManager.removeItem(at: backupURL)
            try fileManager.moveItem(at: staging, to: backupURL)
            pendingBackupStaging = nil
            return true
        } catch {
            // Keep the staging copy: it is the pre-write primary, and finishing the
            // rotation later is what turns a failed backup into a recovery copy.
            pendingBackupStaging = fileManager.fileExists(atPath: staging.path) ? staging : nil
            return false
        }
    }

    /// Completes a rotation whose staging copy survived, if there is one.
    @discardableResult
    private func finishPendingBackupRotation() -> Bool {
        guard let staging = pendingBackupStaging,
              fileManager.fileExists(atPath: staging.path) else {
            pendingBackupStaging = nil
            return false
        }
        do {
            // The inherited staging copy predates the write path's chmod; give
            // it the same owner-only mode before it becomes the backup.
            try fileManager.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: staging.path)
            try? fileManager.removeItem(at: backupURL)
            try fileManager.moveItem(at: staging, to: backupURL)
            pendingBackupStaging = nil
            return true
        } catch {
            return false
        }
    }

    /// Just the stamp, decoded before anything else: it is the one field every version
    /// of the document shares.
    private struct VersionStamp: Decodable { let version: Int }

    private struct Loaded {
        var library: ThreadLibrary?
        /// The version claimed by a file this build must not touch.
        var newerVersion: Int?
        /// Whether the primary file decoded, as opposed to the backup standing in for it.
        var primaryDecoded = false
        /// Whether a document is *there*, readable or not. Distinguishes "no library
        /// yet" from "a library that would not decode", which look the same afterwards.
        ///
        /// Presence, deliberately, rather than "bytes came back": a file whose contents
        /// cannot be read at all — a permissions change, an I/O error, a directory where
        /// the file should be — leaves `candidates` empty exactly as an absent file
        /// does, and calling that "nothing stored" is what would let a sweep delete
        /// every attachment the unreadable file still names.
        var fileExisted = false
    }

    private static func load(from url: URL, fileManager: FileManager) -> Loaded {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded = Loaded()
        // One expression for the backup's name, read by both the loader and the presence
        // test below. Written twice they agreed today and would have disagreed silently
        // the day one of them moved — and a `.bak` the presence test could not see would
        // report an unreadable library as "nothing stored", which is the one answer that
        // lets a sweep delete what it still names.
        let backup = url.appendingPathExtension("bak")
        let candidates = [url, backup].compactMap { candidate -> (URL, Data)? in
            guard let data = fileManager.contents(atPath: candidate.path) else { return nil }
            return (candidate, data)
        }
        loaded.fileExisted = fileManager.fileExists(atPath: url.path)
            || fileManager.fileExists(atPath: backup.path)
        // Inspect both stamps before adopting either file; rotation can erase a newer backup.
        for (_, data) in candidates {
            if let stamp = try? decoder.decode(VersionStamp.self, from: data),
               stamp.version > ThreadLibrary.currentVersion {
                loaded.newerVersion = stamp.version
                return loaded
            }
        }
        for (candidate, data) in candidates {
            guard var library = try? decoder.decode(ThreadLibrary.self, from: data) else { continue }
            library.finishInterruptedTurns()
            if candidate == url {
                loaded.primaryDecoded = true
            } else {
                FileHandle.standardError.write(Data(
                    "vervellum warning: threads file was unreadable; recovered the .bak copy.\n".utf8))
            }
            loaded.library = library
            break
        }
        return loaded
    }
}
