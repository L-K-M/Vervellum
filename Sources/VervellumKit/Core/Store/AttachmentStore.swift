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
/// over one library — they do not. `sweep(keeping:writtenBefore:)` is what closes that:
/// a file too young to have been in the snapshot is left for the next sweep. The cost of
/// being wrong in that direction is a stale file for an hour; the cost in the other
/// direction is a screenshot the user just attached, deleted while they were typing.
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
    /// reachable by another user whatever its own mode says. The file's `0600` is
    /// defence in depth and is applied after the atomic write, because `Data.write` has
    /// no way to take a mode; a failure to apply it does not fail the write, exactly as
    /// in `ThreadArchive`, because a volume that cannot chmod is a poor reason to lose
    /// the user's file. `AttachmentStoreTests` pins both modes so a regression is loud.
    func write(_ data: Data, for attachment: Attachment) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let destination = url(for: attachment.id)
        try data.write(to: destination, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: destination.path)
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
    @discardableResult
    func sweep(keeping live: Set<UUID>, writtenBefore grace: TimeInterval = 300) -> Int {
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
