import Foundation

/// The bytes behind the attachments a thread refers to.
///
/// A directory beside the thread file, one file per attachment, named by the
/// attachment's `id` and nothing else. Keeping the bytes out of `threads.json` is what
/// lets a thread remember a screenshot without paying for it twice over: the JSON is
/// rewritten whole on every save, and its contents are what get re-sent to the model as
/// history. `Attachment` explains that trade in full.
///
/// The file name is the `id` rather than anything the user typed. Nothing here needs to
/// know what a file was called — the name is display text on the record — and a store
/// that never builds a path out of user input cannot be talked into writing outside its
/// own directory.
///
/// **No locking, and here is exactly what that does and does not claim.** An attachment
/// file is written once, before any turn refers to it, and is never modified afterwards,
/// so no two writers can race over its contents and a reader can never see half a file.
///
/// The sweep *is* a mutation, though — it deletes — and it is the one operation that can
/// race a write. It deletes what the caller's snapshot of the library did not mention,
/// and bytes written after that snapshot was taken are, through no fault of their own,
/// not in it. Within one process the two happen on the same thread; across processes —
/// a `vervellum --ask` launched while the panel is mid-question, two copies of the app
/// over one library — they do not. `sweep(keeping:sparingFilesNewerThan:)` is what
/// closes that: a file young enough that the caller's snapshot could not have mentioned
/// it is left for the next sweep.
///
/// The window is measured from *now* rather than from when the snapshot was read, which
/// is exact only because every caller reads the library and sweeps in the same breath —
/// the two are microseconds apart, and the window is margin for the *other* process's
/// write, not for its own staleness. A caller that held a snapshot for minutes before
/// sweeping would need to be given the snapshot's time instead. The cost of being wrong
/// in this direction is a stale file until the next sweep; in the other, it is a
/// screenshot the user just attached, deleted while they were still typing.
///
/// A store that allowed editing in place would need a queue, the way `ThreadArchive`
/// does.
final class AttachmentStore {

    private let directory: URL
    private let fileManager: FileManager

    /// - Parameter directory: where the bytes go. Both front ends pass a sibling of the
    ///   thread file, so an attachment lives and dies with the library it belongs to.
    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Where the thread file's neighbours go, given the thread file itself.
    static func directory(besideThreadFile fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("attachments",
                                                                   isDirectory: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString)
    }

    // MARK: Reading and writing

    /// Stores the bytes for `attachment`.
    ///
    /// `0700` on the directory and `0600` on the file, for the same reason the thread
    /// file is `0600`: a screenshot can be a screenshot of anything, and this is a
    /// directory in the user's own home rather than a cache anybody may read.
    ///
    /// The directory's mode is the one that has to hold, and it is set as the directory
    /// is created rather than fixed afterwards — nothing inside a `0700` directory is
    /// reachable by another user whatever its own mode says.
    ///
    /// The file's `0600` is applied *before* it is reachable under its own name, which
    /// is why the bytes go to a temporary name first: `Data.write` takes no mode, so a
    /// chmod after the write would leave the file at the umask's default — usually
    /// `0644` — at its final path for as long as the two calls take. Inside a `0700`
    /// directory nobody could open it in that window, but a directory that pre-dates
    /// this feature, or one a sync tool recreated, is not one this code created. Doing
    /// it in this order means the promise does not rest on the directory being right.
    ///
    /// The chmod itself is still best-effort, exactly as in `ThreadArchive`: a volume
    /// that cannot chmod is a poor reason to lose the user's file.
    /// `AttachmentStoreTests` pins both modes so a regression is loud.
    func write(_ data: Data, for attachment: Attachment) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        // And again, unconditionally, because `createDirectory` applies its attributes
        // only when it *creates* the directory. A directory an older build or a sync tool
        // left behind keeps whatever mode it was made with — and the staging order above
        // only protects the bytes if the parent is closed. Without this the argument in
        // the paragraph above holds for exactly the directories that never needed it.
        try? fileManager.setAttributes([.posixPermissions: 0o700],
                                       ofItemAtPath: directory.path)
        // A UUID name, so a crash between the write and the move leaves something the
        // sweep already understands: unreferenced, and removed once it is old enough.
        let staged = url(for: UUID())
        try data.write(to: staged, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: staged.path)
        let destination = url(for: attachment.id)
        let displaced = url(for: UUID())
        do {
            // Moved aside rather than removed, because `moveItem` refuses an occupied
            // destination and a *removal* is the one step here that cannot be taken
            // back. If the move that follows then fails — a locked file, a transient
            // error — the previous bytes are gone while the turn that names them is
            // still on screen. A rename keeps them until the new ones are in place, and
            // the catch puts them back. What a crash strands is a copy under a UUID name
            // nothing refers to, which is precisely what the sweep is for.
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: displaced)
            }
            try fileManager.moveItem(at: staged, to: destination)
            try? fileManager.removeItem(at: displaced)
        } catch {
            // Never leave the staged copy behind on a failure: it is bytes of the user's
            // file under a name no turn will ever mention. The displaced copy is the
            // opposite — bytes a turn *does* name — so it goes back where it was.
            try? fileManager.removeItem(at: staged)
            if !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: displaced, to: destination)
            }
            throw error
        }
    }

    /// The bytes for `attachment`, or nil when they are gone.
    ///
    /// Nil is an ordinary outcome rather than a failure: a library copied between
    /// machines without its attachments directory, or a file removed by hand, leaves
    /// records pointing at nothing. The caller's job is to carry on without the picture,
    /// not to fail the turn — which is why this returns an optional rather than throwing.
    func data(for attachment: Attachment) -> Data? {
        fileManager.contents(atPath: url(for: attachment.id).path)
    }

    /// True when the bytes are still there. For a panel that would rather show a missing
    /// attachment as missing than as a broken image.
    func exists(_ attachment: Attachment) -> Bool {
        fileManager.fileExists(atPath: url(for: attachment.id).path)
    }

    // MARK: Sweeping

    /// Deletes every stored file that no surviving attachment refers to.
    ///
    /// Called after the library is saved, with the ids still in it. Sweeping by
    /// *reachability* rather than deleting alongside each removed thread is deliberate:
    /// a delete that raced a save, or a crash between the two, would otherwise leave
    /// bytes on disk that nothing will ever look at again and nothing will ever remove.
    /// Getting the set wrong in the safe direction costs a stale file until the next
    /// sweep; getting it wrong in the other direction would delete a live attachment, so
    /// the caller passes what it *kept*, never what it dropped.
    ///
    /// The window assumes bytes are written at *send* time, which is what both front
    /// ends do: `ResearchEngine.start` and `LinuxPanel.ask` write inside the same
    /// function that appends the turn and saves the library, milliseconds apart. Five
    /// minutes is margin against a slow disk, not against a reader who is still typing —
    /// a front end that ever wrote at attach time would need a window longer than a
    /// compose, and should raise this rather than hope.
    @discardableResult
    func sweep(keeping live: Set<UUID>, sparingFilesNewerThan grace: TimeInterval = 300) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        let cutoff = Date().addingTimeInterval(-grace)
        var removed = 0
        for name in names {
            // A file whose name is not a UUID was not written here. Left alone rather
            // than deleted: this directory belongs to Vervellum, but deleting something
            // unrecognised is not a thing a sweep should decide on its own.
            guard let id = UUID(uuidString: name), !live.contains(id) else { continue }
            let file = url(for: id)
            // A file younger than the grace window may belong to a question asked in
            // another process since `live` was read — the panel writes the bytes before
            // the turn that names them reaches the file this sweep is derived from. Left
            // for the next sweep, which is the direction it is safe to be wrong in.
            if let written = modified(file), written > cutoff { continue }
            if (try? fileManager.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// When a file was last written, or nil when that cannot be read — in which case the
    /// sweep treats it as old, because a file whose age is unknowable would otherwise be
    /// immortal.
    private func modified(_ file: URL) -> Date? {
        try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    }

    /// Removes everything, for the "erase stored threads" path that already exists for
    /// the thread file itself. A library the user asked to be gone should not leave the
    /// pictures behind.
    ///
    /// Throwing rather than silent, because this one is user-initiated: a panel that
    /// says "erased" over a directory of screenshots that are still there would be a
    /// privacy promise broken quietly. A directory that was never created counts as
    /// erased — there is nothing to remove — so the ordinary case does not throw.
    func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }
}
