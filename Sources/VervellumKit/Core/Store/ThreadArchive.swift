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

    private(set) var library: ThreadLibrary
    // Late runner snapshots retain their IDs. Erasure must outlive those callbacks.
    private var forgottenThreadIDs: Set<UUID> = []

    /// True when the file on disk claims a newer document version than this build
    /// understands. In that case the archive never writes.
    let isReadOnly: Bool

    /// Why the last erase left the file in place, in words fit for the interface; nil
    /// once an erase succeeds. "History off means the bytes are gone" is a promise
    /// Settings makes, and when the file system breaks it the user has to be told
    /// rather than shown a toggle that says off.
    private(set) var eraseFailure: String?

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
    /// Whether the primary file is the "previous good copy" the `.bak` rotation
    /// promises: it decoded at launch, or this process has since written it. Set once
    /// in `init` and afterwards only on `queue`, where every write runs.
    private var primaryIsTrustworthy: Bool

    /// How many threads to keep. See `ThreadLibrary.prune(to:)`.
    ///
    /// Setting it prunes immediately rather than at the next write: a reader who has just
    /// asked to keep fifty expects to see fifty, not to wait for a hundred and fifty more
    /// questions to push the rest out.
    var keptThreads: Int {
        didSet {
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
        self.keptThreads = keptThreads

        // The file is read for its *version* even when history is off, and only adopted
        // when it is on. Skipping the read entirely would leave `isReadOnly` false, so a
        // user who launches with history disabled and then enables it would write an
        // empty document straight over a newer build's file — exactly the loss this
        // flag exists to prevent.
        let onDisk = Self.load(from: fileURL, fileManager: fileManager)
        isReadOnly = onDisk.newerVersion != nil
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
            _ = library.prune(to: keptThreads)
        }
    }

    // MARK: Mutation

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

    // MARK: Persistence

    private var backupURL: URL { fileURL.appendingPathExtension("bak") }

    private func scheduleSave() {
        guard isHistoryEnabled, !isReadOnly, eraseFailure == nil else { return }
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
        pendingSnapshot = nil
        writeNow(snapshot)
    }

    private func writeNow(_ snapshot: ThreadLibrary) {
        guard !isReadOnly else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)

            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            // Skip a write that would change nothing. `flush()` is called on every
            // dismissal and at termination, and without this each one rotates the
            // previous file into `.bak` — after two flushes the backup is a byte-perfect
            // copy of the live file and has stopped being a recovery copy at all.
            if currentContents() == data { return }

            // Rotate the previous good file, so a failure during the write still leaves
            // one recoverable copy — only now, when the contents really differ, and only
            // when the primary *is* a good file. After a launch that recovered from
            // `.bak`, the primary is the corrupt one; copying it over the backup before
            // the new write is known to have succeeded would, if that write then failed
            // for the same reason (a full disk, say), leave nothing readable at all.
            if primaryIsTrustworthy, fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.copyItem(at: fileURL, to: backupURL)
            }
            try data.write(to: fileURL, options: [.atomic])
            primaryIsTrustworthy = true
            // Research questions are personal. Keep the file owner-only rather than
            // inheriting the umask.
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            FileHandle.standardError.write(Data("vervellum warning: could not save threads\n".utf8))
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
    }

    private static func load(from url: URL, fileManager: FileManager) -> Loaded {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded = Loaded()
        let candidates = [url, url.appendingPathExtension("bak")].compactMap { candidate -> (URL, Data)? in
            guard let data = fileManager.contents(atPath: candidate.path) else { return nil }
            return (candidate, data)
        }
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
