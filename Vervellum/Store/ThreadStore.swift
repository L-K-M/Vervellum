import Foundation
import Combine

/// The macOS front end's observable wrapper around the shared `ThreadArchive`.
///
/// The archive holds every persistence rule — atomic writes, the `.bak` rotation,
/// `0600` permissions, the read-only guard against a newer document, and the "history
/// off means the bytes are gone" behaviour — and is compiled into the Linux build too.
/// This class exists only because `ObservableObject` comes from Combine, which does not
/// exist on Linux.
final class ThreadStore: ObservableObject {

    /// Mirrors the archive's library so SwiftUI can observe it.
    @Published private(set) var library: ThreadLibrary

    private let archive: ThreadArchive
    /// The bytes behind the attachments the library's turns refer to. Owned here because
    /// this type is what knows when a thread stops existing, which is the only thing that
    /// can strand them.
    let attachmentStore: AttachmentStore
    /// Where those bytes are, for the one message that has to name it.
    private let attachmentsDirectory: URL
    /// Why the last erase left the attachment bytes in place, if it did. Kept beside the
    /// archive's own `eraseFailure` and reported through it, so Settings has one place
    /// to look and the user is never told "erased" over a directory of screenshots that
    /// are still there.
    private var attachmentEraseFailure: String?

    init(fileURL: URL = ThreadStore.defaultURL,
         fileManager: FileManager = .default,
         historyEnabled: Bool = true,
         keptThreads: Int = ThreadLibrary.defaultKeptThreads,
         debounce: TimeInterval = 1.0) {
        archive = ThreadArchive(fileURL: fileURL, fileManager: fileManager,
                                historyEnabled: historyEnabled, keptThreads: keptThreads,
                                debounce: debounce)
        // Through a local, so the wiring never reaches through a partly built `self`.
        let directory = AttachmentStore.directory(besideThreadFile: fileURL)
        attachmentsDirectory = directory
        attachmentStore = AttachmentStore(directory: directory, fileManager: fileManager)
        library = archive.library
        // At launch, once, because this is the moment a crash between a delete and its
        // save shows up as bytes nothing refers to. Everything else that can strand an
        // attachment — a delete, a prune, an erase — sweeps as it happens.
        //
        // On the archive's erase having *worked*, which is the same gate the setter and
        // `deleteAll` use and the one this call was missing. Launching with history off
        // empties the library in memory and erases the file (ThreadArchive.swift:151,
        // :161); when that erase fails the file survives with every thread in it, still
        // naming these bytes — and a sweep against an empty library would take all of
        // them. The reader fixes the permissions, turns history back on, and gets their
        // conversations back with every picture gone.
        if archive.eraseFailure == nil { sweepAttachments() }
        archive.onChange = { [weak self] in
            guard let self else { return }
            // The archive is driven from the main thread by this app, but the callback
            // is not contractually main-threaded — hop rather than assume.
            if Thread.isMainThread {
                self.library = self.archive.library
            } else {
                DispatchQueue.main.async { self.library = self.archive.library }
            }
        }
    }

    /// Where this app's attachment bytes go, under the default configuration.
    ///
    /// A default argument and nothing more. The live engine is handed *this* store's
    /// `attachmentStore` at the composition root, because "the directory the engine
    /// writes to" and "the directory this type sweeps" have to be the same directory and
    /// this is computed from `defaultURL` — so a store built over some other `fileURL`,
    /// as a test or a preview does, would sweep one folder while an engine holding the
    /// default swept another. One instance per directory is the only version of that
    /// which cannot drift.
    static var attachmentDirectory: URL {
        AttachmentStore.directory(besideThreadFile: defaultURL)
    }

    /// `~/Library/Application Support/Vervellum/threads.json`.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vervellum", isDirectory: true)
            .appendingPathComponent("threads.json")
    }

    // MARK: Forwarding

    var isReadOnly: Bool { archive.isReadOnly }
    /// Why the last erase left something in place, if it did. Read after `library`
    /// republishes, which every erase triggers.
    ///
    /// The thread file's failure first: it is the larger part of what the user asked to
    /// be gone, and a folder of pictures beside a file that would not delete is the
    /// smaller half of the same problem.
    ///
    /// Both of them, when both failed. `??` reported the thread file and said nothing
    /// about the folder of screenshots that was also still there — and broken permissions
    /// on the container above them is one cause that fails both at once. A reader who
    /// fixes the file and sees the warning clear would never learn the images survived.
    var eraseFailure: String? {
        let failures = [archive.eraseFailure, attachmentEraseFailure].compactMap { $0 }
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    var isHistoryEnabled: Bool {
        get { archive.isHistoryEnabled }
        set {
            // Guarded for the reason `keptThreads` below is: `AppDelegate` forwards this
            // on *every* preference change, and most of them are a width drag or a text
            // size step. The archive's own observer already ignores a repeat, so this is
            // about not redrawing the thread list for a setting that never moved.
            guard archive.isHistoryEnabled != newValue else { return }
            objectWillChange.send()
            archive.isHistoryEnabled = newValue
            // The thread file first, and the bytes only if it actually went. Turning
            // history off erases the thread file, so the bytes beside it go too — "off"
            // has always meant the stored conversation is gone, and a directory of
            // screenshots left behind would be the part of it nobody thought to check.
            //
            // But an erase that *failed* leaves those threads on disk still naming these
            // bytes, and taking the pictures anyway would answer a refusal with the one
            // loss the refusal was reporting had not happened. In this order every way
            // this can end badly ends in bytes nothing refers to, which the launch sweep
            // collects; the other order ended in threads that survived pointing at
            // nothing, which nothing heals. A crash between the two lines lands the same
            // way round.
            //
            // The ordering costs the failure no visibility. The announcement above
            // covers every mutation made synchronously after it, because the read
            // happens once this call has returned.
            //
            // And it rests on one thing worth naming, because the archive takes a
            // `debounce` and a reader is right to wonder: **`ThreadArchive` erases
            // synchronously**. It is the *save* that is debounced there; the erase goes
            // through the same write queue with `queue.sync` — cancelling any pending
            // save on the way — and records the outcome before returning. So the line
            // above has already set, or cleared, `eraseFailure` by the time the line
            // below reads it. If that ever stops being true this gate reads the
            // *previous* operation's nil and takes the pictures out of threads that
            // survived the failure, so the erase would have to move into whatever
            // completion the archive grew instead.
            if !newValue, archive.eraseFailure == nil { eraseAttachments() }
        }
    }

    /// How many past threads are kept. Setting it prunes at once — see
    /// `ThreadArchive.keptThreads`.
    var keptThreads: Int {
        get { archive.keptThreads }
        set {
            // `AppDelegate` assigns this on *every* preference change, because the archive
            // reads the limit when it is built. Most of those changes are a width drag or
            // a text-size step, and announcing one as a thread change would redraw the
            // thread list and its counter for a setting that never moved.
            guard archive.keptThreads != newValue else { return }
            objectWillChange.send()
            // No re-read of `library` after this. The archive's own observer calls
            // `onChange` when the prune drops something, and this type's handler is what
            // assigns `library` — synchronously, because the assignment above happens on
            // the main thread and the handler only hops when it is not. A defensive
            // re-read here would be a second path doing the first one's job.
            archive.keptThreads = newValue
            // A lower limit drops threads, and their attachments go with them.
            sweepAttachments()
        }
    }

    func save(_ thread: ResearchThread) { archive.save(thread) }

    func delete(id: UUID) {
        archive.delete(id: id)
        sweepAttachments()
    }

    func deleteAll() {
        // Everything, rather than a sweep: a sweep keeps what is still referenced, and
        // after this nothing is. A library the user asked to be gone should not leave
        // the pictures behind.
        archive.deleteAll()
        // And the thread file first, for the reason `isHistoryEnabled` gives: a delete
        // that could not remove the threads leaves them naming these bytes, so taking
        // the bytes would destroy pictures out of conversations the user still has.
        // On the same synchronous-erase invariant recorded there.
        guard archive.eraseFailure == nil else { return }
        objectWillChange.send()
        eraseAttachments()
    }

    func flush() { archive.flush() }

    // MARK: Attachments

    /// The bytes for one of a turn's attachments, for a panel that wants to show it
    /// again. Nil when they are gone, which a reopened thread has to be able to survive.
    func attachmentData(for attachment: Attachment) -> Data? {
        attachmentStore.data(for: attachment)
    }

    /// Erases the attachment bytes, keeping the outcome for `eraseFailure`.
    ///
    /// Vervellum's own words rather than the file manager's, exactly as `ThreadArchive`
    /// does it: the message is shown in Settings, and the folder is the one thing the
    /// user needs in order to go and fix it.
    private func eraseAttachments() {
        do {
            try attachmentStore.removeAll()
            attachmentEraseFailure = nil
        } catch {
            attachmentEraseFailure = "Could not delete \(attachmentsDirectory.path). The "
                + "folder may be read-only, or a file in it locked; the images in it are "
                + "still there."
        }
    }

    /// Deletes the bytes of every attachment no thread in the library refers to any more.
    ///
    /// Called where something can *stop* being referenced — a delete, a prune, an erase,
    /// and once at launch — rather than on every save. A save happens for each streamed
    /// chunk of an answer, and a directory listing per chunk would buy nothing: no chunk
    /// has ever dropped an attachment.
    ///
    /// Two different things are safe here for two different reasons, and the comment
    /// used to name only one of them. The *run* is safe because a running turn is sent
    /// the bytes it was given rather than the bytes on disk — see `ResearchEngine.start`.
    /// The *record* is safe because `sweep` spares files younger than its grace window:
    /// bytes are written when the turn is created, and the first save that puts that turn
    /// in the library rides the first streamed chunk, so there is a gap in which they are
    /// on disk and referred to by nothing this can see. Without the grace window a delete
    /// landing in that gap would take them, and the transcript would keep a turn naming a
    /// file whose bytes are gone.
    private func sweepAttachments() {
        // Never on a library that could not be read. A corrupt or half-written thread
        // file leaves an empty library behind, and sweeping against that would delete
        // every attachment while the file — and its `.bak` — still name them. Deleting
        // is the one thing here that cannot be undone.
        guard archive.libraryIsTrustworthy else { return }
        // `archive.library`, not the published mirror beside it. `onChange` hops to the
        // main thread when it is not on it, so the copy this object publishes can be one
        // delivery behind the archive that a delete has already changed — and a sweep
        // reading it would find a deleted thread's attachments still referenced and keep
        // them until the next launch. The error direction is safe, which is exactly why
        // it would never be noticed.
        let live = Set(archive.library.threads
            .flatMap(\.turns)
            .flatMap(\.attachments)
            .map(\.id))
        attachmentStore.sweep(keeping: live)
    }
}
