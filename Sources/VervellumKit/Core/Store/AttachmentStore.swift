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
/// **No locking, and that is a claim rather than an omission.** An attachment file is
/// written once, before any turn refers to it, and is never modified afterwards; the only
/// other operations are reads and a sweep that deletes files nothing refers to. There is
/// no mutation for two threads to race over. A store that allowed editing in place would
/// need a queue, the way `ThreadArchive` does.
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
    /// `0600` for the same reason the thread file is: a screenshot can be a screenshot of
    /// anything, and this is a directory in the user's own home rather than a cache
    /// anybody may read.
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
    func sweep(keeping live: Set<UUID>) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        var removed = 0
        for name in names {
            // A file whose name is not a UUID was not written here. Left alone rather
            // than deleted: this directory belongs to Vervellum, but deleting something
            // unrecognised is not a thing a sweep should decide on its own.
            guard let id = UUID(uuidString: name), !live.contains(id) else { continue }
            if (try? fileManager.removeItem(at: url(for: id))) != nil { removed += 1 }
        }
        return removed
    }

    /// Removes everything, for the "erase stored threads" path that already exists for
    /// the thread file itself. A library the user asked to be gone should not leave the
    /// pictures behind.
    func removeAll() {
        try? fileManager.removeItem(at: directory)
    }
}
