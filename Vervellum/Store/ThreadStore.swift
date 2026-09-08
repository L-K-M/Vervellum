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

    init(fileURL: URL = ThreadStore.defaultURL,
         fileManager: FileManager = .default,
         historyEnabled: Bool = true,
         keptThreads: Int = ThreadLibrary.defaultKeptThreads,
         debounce: TimeInterval = 1.0) {
        archive = ThreadArchive(fileURL: fileURL, fileManager: fileManager,
                                historyEnabled: historyEnabled, keptThreads: keptThreads,
                                debounce: debounce)
        library = archive.library
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

    /// `~/Library/Application Support/Vervellum/threads.json`.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vervellum", isDirectory: true)
            .appendingPathComponent("threads.json")
    }

    // MARK: Forwarding

    var isReadOnly: Bool { archive.isReadOnly }
    /// Why the last erase left the file in place, if it did. Read after `library`
    /// republishes, which every erase triggers.
    var eraseFailure: String? { archive.eraseFailure }

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
        }
    }

    func save(_ thread: ResearchThread) { archive.save(thread) }
    func delete(id: UUID) { archive.delete(id: id) }
    func deleteAll() { archive.deleteAll() }
    func flush() { archive.flush() }
}
