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
         debounce: TimeInterval = 1.0) {
        archive = ThreadArchive(fileURL: fileURL, fileManager: fileManager,
                                historyEnabled: historyEnabled, debounce: debounce)
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
            objectWillChange.send()
            archive.isHistoryEnabled = newValue
        }
    }

    func save(_ thread: ResearchThread) { archive.save(thread) }
    func delete(id: UUID) { archive.delete(id: id) }
    func deleteAll() { archive.deleteAll() }
    func flush() { archive.flush() }
}
