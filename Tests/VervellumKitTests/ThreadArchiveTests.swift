import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class ThreadLibraryTests: XCTestCase {

    private func thread(_ question: String) -> ResearchThread {
        var thread = ResearchThread()
        var turn = ResearchTurn(question: question)
        turn.answer = "An answer about \(question)."
        turn.stage = .complete
        thread.turns = [turn]
        return thread
    }

    func testUpsertPutsTheNewestFirst() {
        var library = ThreadLibrary()
        library.upsert(thread("first"), keeping: ThreadLibrary.defaultKeptThreads)
        library.upsert(thread("second"), keeping: ThreadLibrary.defaultKeptThreads)
        XCTAssertEqual(library.threads.map(\.title), ["second", "first"])
    }

    func testUpsertReplacesRatherThanDuplicates() {
        var library = ThreadLibrary()
        var subject = thread("original")
        library.upsert(subject, keeping: ThreadLibrary.defaultKeptThreads)
        subject.turns[0].question = "edited"
        library.upsert(subject, keeping: ThreadLibrary.defaultKeptThreads)
        XCTAssertEqual(library.threads.count, 1)
        XCTAssertEqual(library.threads.first?.title, "edited")
    }

    /// Summoning the panel and dismissing it without asking anything must leave no
    /// trace on disk.
    func testAnEmptyThreadIsNeverStored() {
        var library = ThreadLibrary()
        library.upsert(ResearchThread(), keeping: ThreadLibrary.defaultKeptThreads)
        XCTAssertTrue(library.threads.isEmpty)
    }

    func testTheListIsBounded() {
        var library = ThreadLibrary()
        let overfill = ThreadLibrary.defaultKeptThreads + 20
        for index in 0..<overfill {
            library.upsert(thread("q\(index)"), keeping: ThreadLibrary.defaultKeptThreads)
        }
        XCTAssertEqual(library.threads.count, ThreadLibrary.defaultKeptThreads)
        XCTAssertEqual(library.threads.first?.title, "q\(ThreadLibrary.defaultKeptThreads + 19)")
    }

    func testSearchMatchesQuestionsAndAnswers() {
        var library = ThreadLibrary()
        library.upsert(thread("photosynthesis"), keeping: ThreadLibrary.defaultKeptThreads)
        library.upsert(thread("tectonics"), keeping: ThreadLibrary.defaultKeptThreads)
        XCTAssertEqual(library.search("PHOTO").count, 1)
        XCTAssertEqual(library.search("an answer about").count, 2)
        XCTAssertEqual(library.search("nothing here").count, 0)
        XCTAssertEqual(library.search("   ").count, 2)
    }

    /// The floor lives in `prune(to:)`, not only in the preference that usually feeds
    /// it. A caller that reaches the library directly — a settings file read by another
    /// build, a future front end — must not be able to ask for zero and get an erased
    /// history, and must not be able to ask for a million and get a different answer
    /// than the ceiling gives.
    func testPruningClampsSoZeroCannotEraseAndTheCeilingHolds() {
        let floor = ThreadLibrary.keptThreadsRange.lowerBound
        let ceiling = ThreadLibrary.keptThreadsRange.upperBound
        var library = ThreadLibrary()
        library.threads = (0..<(floor + 5)).map { thread("q\($0)") }
        XCTAssertEqual(library.prune(to: 0), 5, "the floor applies, not the zero")
        XCTAssertEqual(library.threads.count, floor)

        // Above the ceiling with a library that is *over* it. The earlier version asked
        // for fifty thousand while holding ten threads, where a clamped request and an
        // unclamped one both drop nothing — so the half of this test the name is about
        // could not fail whether `prune` clamped or not.
        library.threads = (0..<(ceiling + 1)).map { thread("q\($0)") }
        XCTAssertEqual(library.prune(to: 50_000), 1, "a request above the ceiling is clamped to it")
        XCTAssertEqual(library.threads.count, ceiling)
    }
}

final class ThreadArchiveTests: XCTestCase {

    func testWritesStampTheExpandedNoticeSchema() throws {
        try Data(#"{"version":1,"threads":[]}"#.utf8).write(to: fileURL)
        let archive = ThreadArchive(fileURL: fileURL)
        archive.save(thread("Updated"))
        archive.flush()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ThreadLibrary.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(document.version, 2, "New notice cases need an explicit schema stamp")
    }

    func testRecoveredCheckpointsValidateTheirRetainedProse() {
        var turn = ResearchTurn(question: "Interrupted")
        turn.stage = .answering
        turn.answer = "Unverified [9] https://example.com"
        var thread = ResearchThread()
        thread.turns = [turn]
        var library = ThreadLibrary()
        library.upsert(thread, keeping: ThreadLibrary.defaultKeptThreads)
        library.finishInterruptedTurns()
        let recovered = library.threads.first?.turns.first
        XCTAssertEqual(recovered?.stage, .failed)
        XCTAssertTrue(recovered?.notices.contains(.invalidCitation) == true)
        XCTAssertTrue(recovered?.notices.contains(.literalURL) == true)
    }

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VervellumArchiveTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("threads.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func thread(_ question: String) -> ResearchThread {
        var thread = ResearchThread()
        thread.turns = [ResearchTurn(question: question)]
        return thread
    }

    func testSavesAndReloads() {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("remembered"))
        store.flush()

        let reloaded = ThreadArchive(fileURL: fileURL, debounce: 0)
        XCTAssertEqual(reloaded.library.threads.first?.title, "remembered")
    }

    func testKeepsAPreviousCopyAsABackup() {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("one"))
        store.flush()
        store.save(thread("two"))
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("bak").path))
    }

    /// A truncated write must not lose the whole history.
    func testRecoversFromTheBackupWhenThePrimaryIsCorrupt() throws {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("recoverable"))
        store.flush()
        store.save(thread("second"))
        store.flush()
        try "{ not json".write(to: fileURL, atomically: true, encoding: .utf8)

        let reloaded = ThreadArchive(fileURL: fileURL, debounce: 0)
        XCTAssertFalse(reloaded.library.threads.isEmpty)
        // A backup standing in is still the whole of what this launch will honour: the
        // save it is behind by is lost either way, so bytes only that save named are
        // orphaned, not in use, and the sweep may run.
        XCTAssertTrue(reloaded.libraryIsTrustworthy)
    }

    /// The launch sweep deletes every attachment the library does not name, so it may
    /// only run when the library that came back is the whole truth. A first launch has
    /// nothing to protect and passes that test; a document that would not decode fails it.
    func testAnAbsentLibraryIsTrustworthyAndAnUndecodableOneIsNot() throws {
        XCTAssertTrue(ThreadArchive(fileURL: fileURL, debounce: 0).libraryIsTrustworthy)

        try "{ not json".write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(ThreadArchive(fileURL: fileURL, debounce: 0).libraryIsTrustworthy)
    }

    /// Unreadable is not absent, and only the second is safe. A document whose bytes
    /// never arrive — a permissions change, an I/O error, a directory standing where the
    /// file should be — leaves the archive holding an empty library exactly as a first
    /// launch does. Reading that as "nothing was ever stored" is what would let the
    /// launch sweep delete the attachments the unread document still names.
    func testALibraryThatIsThereButCannotBeReadIsNotTrustworthy() throws {
        // Anything left at the path first: a file from an earlier test would make this
        // throw before its own assertions ran, and the error would name the wrong thing.
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        let archive = ThreadArchive(fileURL: fileURL, debounce: 0)
        XCTAssertTrue(archive.library.threads.isEmpty)
        XCTAssertFalse(archive.libraryIsTrustworthy)
    }

    /// "Off" has to mean the bytes are gone, not that they are hidden.
    func testTurningHistoryOffErasesTheFile() {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("secret"))
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.isHistoryEnabled = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testLaunchingWithHistoryOffErasesExistingFiles() {
        let previous = ThreadArchive(fileURL: fileURL, debounce: 0)
        previous.save(thread("one"))
        previous.flush()
        previous.save(thread("two"))
        previous.flush()

        let disabled = ThreadArchive(fileURL: fileURL, historyEnabled: false)
        XCTAssertTrue(disabled.library.threads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("bak").path))
    }

    func testContinuousSnapshotsDoNotStarveCheckpoints() throws {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0.05)
        var active = thread("streaming")
        let end = Date().addingTimeInterval(0.5)
        while Date() < end {
            active.turns[0].answer += "x"
            store.save(active)
            Thread.sleep(forTimeInterval: 0.005)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        store.flush()
        let reloaded = ThreadArchive(fileURL: fileURL)
        XCTAssertEqual(reloaded.library.threads.first?.turns.first?.answer, active.turns[0].answer)
    }

    func testNothingIsWrittenWhileHistoryIsOff() {
        let store = ThreadArchive(fileURL: fileURL, historyEnabled: false, debounce: 0)
        store.save(thread("not stored"))
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.library.threads.isEmpty)
    }

    /// Research questions are personal; the file must not inherit a permissive umask.
    func testTheFileIsOwnerReadableOnly() throws {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("private"))
        store.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        // Three-way cast: Foundation boxes this as `NSNumber` on Darwin but as a plain
        // `UInt` in swift-corelibs-foundation, and this test runs on both.
        let raw = attributes[.posixPermissions]
        let permissions = (raw as? NSNumber)?.intValue ?? (raw as? UInt).map { Int($0) } ?? (raw as? Int) ?? -1
        XCTAssertNotEqual(permissions, -1, "could not read the file's permissions")
        XCTAssertEqual(permissions & 0o077, 0)
    }

    /// A file from a newer build must never be rewritten by an older one: the
    /// re-encode would stamp lossily-decoded content with the newer version.
    func testANewerDocumentIsTreatedAsReadOnly() throws {
        let future = #"{"version": 99, "threads": []}"#
        try future.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        XCTAssertTrue(store.isReadOnly)
        store.save(thread("should not persist"))
        store.flush()

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("99"))
        XCTAssertFalse(onDisk.contains("should not persist"))
    }

    func testDeletedThreadsCannotBeResurrectedByLateSnapshots() {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        let active = thread("active")
        store.save(active)
        store.delete(id: active.id)
        store.save(active)
        store.flush()
        XCTAssertTrue(store.library.threads.isEmpty)

        let next = thread("next")
        store.save(next)
        store.deleteAll()
        store.save(next)
        store.flush()
        XCTAssertTrue(store.library.threads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testReenablingHistoryDoesNotRestoreErasedActiveThreads() {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        let active = thread("active")
        store.save(active)
        store.isHistoryEnabled = false
        store.isHistoryEnabled = true
        store.save(active)
        store.flush()
        XCTAssertTrue(store.library.threads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDeleteAllRemovesTheFile() {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("gone"))
        store.flush()
        store.deleteAll()
        XCTAssertTrue(store.library.threads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(store.eraseFailure)
    }

    /// The realistic newer document is one this build cannot decode at all — a newer
    /// build added an enum case or a field. That must read as "newer", not as
    /// "corrupt": a corrupt file is recovered from the backup and then written over.
    func testANewerDocumentThisBuildCannotDecodeIsStillReadOnly() throws {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("from before"))
        store.flush()
        store.save(thread("also from before"))
        store.flush()
        let backupURL = fileURL.appendingPathExtension("bak")
        let backupBefore = try Data(contentsOf: backupURL)

        let future = "{\"version\": \(ThreadLibrary.currentVersion + 1), \"threads\": [{\"stage\": \"teleporting\"}]}"
        try future.write(to: fileURL, atomically: true, encoding: .utf8)

        let reloaded = ThreadArchive(fileURL: fileURL, debounce: 0)
        XCTAssertTrue(reloaded.isReadOnly)
        // Nor is the backup shown in its place: an older snapshot presented as the
        // history would only raise the question of where the newest threads went.
        XCTAssertTrue(reloaded.library.threads.isEmpty)
        reloaded.save(thread("should not persist"))
        reloaded.flush()

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), future)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupBefore)
    }

    /// A newer backup is just as untouchable: the first write would create a primary
    /// and the second would rotate it over the backup.
    func testANewerBackupIsAlsoReadOnly() throws {
        let future = #"{"version": 3, "threads": []}"#
        try future.write(to: fileURL.appendingPathExtension("bak"), atomically: true, encoding: .utf8)
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        XCTAssertTrue(store.isReadOnly)
    }

    func testANewerBackupProtectsAnOtherwiseReadablePrimary() throws {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("older primary"))
        store.flush()
        let future = "{\"version\": \(ThreadLibrary.currentVersion + 1), \"threads\": []}"
        let backupURL = fileURL.appendingPathExtension("bak")
        try future.write(to: backupURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: fileURL)

        let reloaded = ThreadArchive(fileURL: fileURL, debounce: 0)
        XCTAssertTrue(reloaded.isReadOnly)
        reloaded.save(thread("must not replace the backup"))
        reloaded.flush()
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), future)
    }

    func testFailedErasureBlocksFurtherWrites() throws {
        let store = ThreadArchive(fileURL: fileURL, fileManager: StubbornFileManager(), debounce: 0)
        store.save(thread("before"))
        store.flush()
        let before = try Data(contentsOf: fileURL)
        store.deleteAll()
        store.save(thread("after"))
        store.flush()

        XCTAssertNotNil(store.eraseFailure)
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testResolvedErasureAllowsOnlyNewHistory() {
        let manager = StubbornFileManager()
        let store = ThreadArchive(fileURL: fileURL, fileManager: manager, debounce: 0)
        store.save(thread("old"))
        store.flush()
        store.isHistoryEnabled = false
        XCTAssertNotNil(store.eraseFailure)

        manager.removal = .allowed
        store.isHistoryEnabled = true
        XCTAssertNil(store.eraseFailure)
        store.save(thread("new"))
        store.flush()
        XCTAssertEqual(ThreadArchive(fileURL: fileURL).library.threads.map(\.title), ["new"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("bak").path))
    }

    func testReenablingHistoryCannotClearAnUnresolvedEraseFailure() throws {
        let store = ThreadArchive(fileURL: fileURL, fileManager: StubbornFileManager(), debounce: 0)
        store.save(thread("before"))
        store.flush()
        let before = try Data(contentsOf: fileURL)
        store.isHistoryEnabled = false
        store.isHistoryEnabled = true
        store.save(thread("after"))
        store.flush()
        XCTAssertNotNil(store.eraseFailure)
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    /// A turn saved mid-run — the app crashed or was killed before it finished — must
    /// not come back as running forever.
    func testAnInterruptedTurnComesBackFailedWithItsPartialAnswer() {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        var interrupted = ResearchThread()
        var turn = ResearchTurn(question: "still going")
        turn.stage = .answering
        turn.answer = "Half of an"
        interrupted.turns = [turn]
        store.save(interrupted)
        store.flush()

        let reloaded = ThreadArchive(fileURL: fileURL, debounce: 0)
        let loaded = reloaded.library.threads.first?.turns.first
        XCTAssertEqual(loaded?.stage, .failed)
        XCTAssertEqual(loaded?.failure, ThreadLibrary.interruptedMessage)
        XCTAssertEqual(loaded?.answer, "Half of an")
        XCTAssertNil(loaded?.duration)
    }

    /// After recovering from the backup, the corrupt primary must not be rotated over
    /// the only good copy before the new write is known to have succeeded.
    func testRecoveringFromTheBackupKeepsTheBackupIntact() throws {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("one"))
        store.flush()
        store.save(thread("two"))
        store.flush()
        try "{ not json".write(to: fileURL, atomically: true, encoding: .utf8)
        let backupURL = fileURL.appendingPathExtension("bak")
        let goodBackup = try Data(contentsOf: backupURL)

        let recovered = ThreadArchive(fileURL: fileURL, debounce: 0)
        XCTAssertEqual(recovered.library.threads.map(\.title), ["one"])
        recovered.save(thread("three"))
        recovered.flush()
        XCTAssertEqual(try Data(contentsOf: backupURL), goodBackup, "the corrupt primary replaced the backup")

        // The primary this process wrote is a good file again, so the next write
        // rotates it as usual.
        recovered.save(thread("four"))
        recovered.flush()
        let rotated = ThreadArchive(fileURL: backupURL, debounce: 0)
        XCTAssertEqual(rotated.library.threads.map(\.title), ["three", "one"])
    }

    /// A file manager that cannot delete, standing in for a locked file or a folder
    /// that lost its write permission.
    private final class StubbornFileManager: FileManager {
        enum Removal { case allowed, denied }
        var removal = Removal.denied

        override func removeItem(at URL: URL) throws {
            guard removal == .allowed else { throw CocoaError(.fileWriteNoPermission) }
            try super.removeItem(at: URL)
        }
    }

    /// "History off means the bytes are gone" is a promise; when the file system
    /// breaks it, the archive has to say so rather than let the toggle claim success.
    func testAFailedEraseIsReportedNotSwallowed() {
        let store = ThreadArchive(fileURL: fileURL, fileManager: StubbornFileManager(), debounce: 0)
        store.save(thread("stuck"))
        store.flush()

        store.deleteAll()
        XCTAssertTrue(store.library.threads.isEmpty)
        XCTAssertNotNil(store.eraseFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.save(thread("stuck again"))
        store.flush()
        store.isHistoryEnabled = false
        XCTAssertNotNil(store.eraseFailure)
        // The toggle cannot prove deletion succeeded; keep the warning and write block.
        store.isHistoryEnabled = true
        XCTAssertNotNil(store.eraseFailure)
    }

    // MARK: Retention

    /// The setting moves the bound; it never removes it.
    func testKeepsOnlyTheNewestUpToTheLimit() {
        var library = ThreadLibrary()
        for index in 0..<40 { library.upsert(thread("q\(index)"), keeping: 25) }
        XCTAssertEqual(library.threads.count, 25)
        XCTAssertEqual(library.threads.first?.title, "q39", "newest first")
        XCTAssertEqual(library.threads.last?.title, "q15", "the oldest fifteen are gone")
    }

    /// A limit that only applied to new writes would leave a reader who asked to keep
    /// twenty-five looking at two hundred until they had asked two hundred more questions.
    func testLoweringTheLimitPrunesWhatIsAlreadyThere() {
        var library = ThreadLibrary()
        let ceiling = ThreadLibrary.keptThreadsRange.upperBound
        XCTAssertGreaterThanOrEqual(ceiling, 60,
                                    "sixty threads have to fit under the ceiling, or this "
                                    + "test fails about the range rather than about pruning")
        for index in 0..<60 { library.upsert(thread("q\(index)"), keeping: ceiling) }
        XCTAssertEqual(library.threads.count, 60)
        XCTAssertEqual(library.prune(to: 20), 40)
        XCTAssertEqual(library.threads.count, 20)
        XCTAssertEqual(library.threads.first?.title, "q59")
    }

    func testPruningToAHigherLimitDropsNothing() {
        var library = ThreadLibrary()
        let ceiling = ThreadLibrary.keptThreadsRange.upperBound
        for index in 0..<5 { library.upsert(thread("q\(index)"), keeping: ceiling) }
        XCTAssertEqual(library.prune(to: ceiling), 0)
        XCTAssertEqual(library.threads.count, 5)
    }

    /// The limit arrives from a settings file a crash, a sync or a hand edit can leave
    /// holding anything. A zero there must not be able to erase the history — "keep
    /// nothing" is what turning history off means, and it says so out loud.
    func testAnAbsurdLimitIsClampedRatherThanObeyed() {
        var library = ThreadLibrary()
        let ceiling = ThreadLibrary.keptThreadsRange.upperBound
        for index in 0..<40 { library.upsert(thread("q\(index)"), keeping: ceiling) }
        // The dropped count as well as what is left. Every sibling test asserts what
        // `prune` reports, because that number is its contract — it is what a caller
        // would surface as "removed N" — and this was the one clamping path where a
        // return of the pre-clamp delta, or of nothing at all, went unnoticed.
        XCTAssertEqual(library.prune(to: 0), 40 - ThreadLibrary.keptThreadsRange.lowerBound,
                       "the reported count is the clamped delta, not the raw one")
        XCTAssertEqual(library.threads.count, ThreadLibrary.keptThreadsRange.lowerBound)

        var negative = ThreadLibrary()
        for index in 0..<40 { negative.upsert(thread("q\(index)"), keeping: -5) }
        XCTAssertEqual(negative.threads.count, ThreadLibrary.keptThreadsRange.lowerBound)
    }

    /// Setting it prunes at once: a reader who has just asked to keep twenty-five expects
    /// to see twenty-five.
    func testTheArchivePrunesWhenTheLimitIsLowered() throws {
        // The ceiling rather than the default, so forty threads are guaranteed to fit
        // whatever the shipped default becomes — a smaller default would prune inside
        // the loop and fail this test about a constant it is not testing.
        let archive = ThreadArchive(fileURL: fileURL,
                                    keptThreads: ThreadLibrary.keptThreadsRange.upperBound,
                                    debounce: 0)
        for index in 0..<40 { archive.save(thread("q\(index)")) }
        XCTAssertEqual(archive.library.threads.count, 40)

        archive.keptThreads = 15
        XCTAssertEqual(archive.library.threads.count, 15)
        XCTAssertEqual(archive.library.threads.first?.title, "q39")

        // And on disk, which is the half that makes it a deletion rather than a filter.
        // The pane says the drop is permanent; a prune that only shrank the list in
        // memory would put all forty back at the next launch.
        archive.flush()
        XCTAssertEqual(ThreadArchive(fileURL: fileURL, debounce: 0).library.threads.count, 15)
    }

    /// The path production uses most: an archive built with a low limit, whose `save`
    /// prunes through `upsert(keeping:)`. Without this, `save` forgetting to forward the
    /// limit would go unnoticed.
    func testSavingRespectsTheConfiguredLimit() {
        let archive = ThreadArchive(fileURL: fileURL, keptThreads: 25, debounce: 0)
        for index in 0..<40 { archive.save(thread("q\(index)")) }
        XCTAssertEqual(archive.library.threads.count, 25)
        XCTAssertEqual(archive.library.threads.first?.title, "q39")
    }

    /// Turning history off empties the library in memory as well as on disk, so turning
    /// it back on adopts nothing — there is no oversized list left to prune.
    func testReEnablingHistoryStartsEmptyRatherThanReadoptingAFile() {
        let archive = ThreadArchive(fileURL: fileURL, keptThreads: 15, debounce: 0)
        for index in 0..<40 { archive.save(thread("q\(index)")) }
        archive.isHistoryEnabled = false
        XCTAssertTrue(archive.library.threads.isEmpty)
        // On disk too — the claim this test's name and comment are actually about, and
        // the one it used not to check. No `flush` first: `eraseEverything` runs
        // `queue.sync` and cancels whatever was pending, so the bytes are gone by the
        // time the setter returns.
        // The bytes directly, then the round trip. `ThreadArchive.init` takes
        // `historyEnabled` as an argument and reads no settings of its own, so a fresh
        // one really would adopt a surviving file and the round trip is not vacuous —
        // but it proves "nothing was adopted", and what this test's name claims is
        // "nothing is there". Only the first assertion says that.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "history off must delete the file, not merely stop reading it")
        XCTAssertTrue(ThreadArchive(fileURL: fileURL, debounce: 0).library.threads.isEmpty,
                      "history off must erase the file, not only clear memory")
        archive.isHistoryEnabled = true
        XCTAssertTrue(archive.library.threads.isEmpty)
    }

    /// A file written when the limit was higher — or by a build that had no setting — is
    /// trimmed on the way in, so the list already obeys what was asked for.
    func testAnExistingFileIsTrimmedOnLoad() throws {
        let writer = ThreadArchive(fileURL: fileURL,
                                   keptThreads: ThreadLibrary.keptThreadsRange.upperBound,
                                   debounce: 0)
        for index in 0..<40 { writer.save(thread("q\(index)")) }
        writer.flush()

        let reopened = ThreadArchive(fileURL: fileURL, keptThreads: 12, debounce: 0)
        XCTAssertEqual(reopened.library.threads.count, 12)
        XCTAssertEqual(reopened.library.threads.first?.title, "q39")
    }

    /// ...but only in memory. The limit is read from `settings.json`, which a sync tool
    /// or a hand edit can lower with nobody asking, so writing the trim at load would
    /// destroy history before the reader had taken a single action. Raising the limit
    /// and relaunching must bring it all back.
    func testTheLoadTimeTrimDoesNotTouchTheFile() throws {
        let writer = ThreadArchive(fileURL: fileURL,
                                   keptThreads: ThreadLibrary.keptThreadsRange.upperBound,
                                   debounce: 0)
        for index in 0..<40 { writer.save(thread("q\(index)")) }
        writer.flush()

        let narrowed = ThreadArchive(fileURL: fileURL, keptThreads: 12, debounce: 0)
        XCTAssertEqual(narrowed.library.threads.count, 12)

        // Same file, limit restored: nothing was actually dropped from disk.
        let restored = ThreadArchive(fileURL: fileURL,
                                     keptThreads: ThreadLibrary.keptThreadsRange.upperBound,
                                     debounce: 0)
        XCTAssertEqual(restored.library.threads.count, 40,
                       "the load-time trim must be recoverable by raising the limit")
    }

    /// Changing the limit with history off must change nothing, and must still be
    /// remembered for whenever history comes back on.
    ///
    /// What this pins is that end-to-end behaviour, not the `isHistoryEnabled` guard in
    /// isolation — and the difference is worth stating rather than implying. In both
    /// states that guard covers, history off and a read-only document, the library is
    /// already empty: `load` returns before decoding any threads once it sees a newer
    /// version stamp, and history off adopts none and erases the file. So `prune(to:)`
    /// reports nothing dropped and the *second* guard would exit too. Removing the
    /// first guard today would not fail this test. It is still worth having both,
    /// because "the library happens to be empty in these states" is a property of code
    /// elsewhere, and this test is what would catch a refactor that made history-off
    /// retain its threads in memory.
    func testLoweringTheLimitWhileHistoryIsOffChangesNothing() throws {
        let writer = ThreadArchive(fileURL: fileURL,
                                   keptThreads: ThreadLibrary.keptThreadsRange.upperBound,
                                   debounce: 0)
        for index in 0..<30 { writer.save(thread("q\(index)")) }
        writer.flush()

        let archive = ThreadArchive(fileURL: fileURL, historyEnabled: false,
                                    keptThreads: ThreadLibrary.keptThreadsRange.upperBound,
                                    debounce: 0)
        XCTAssertTrue(archive.library.threads.isEmpty, "history off adopts nothing")
        archive.keptThreads = 10
        XCTAssertEqual(archive.keptThreads, 10, "the value is remembered, just not applied")
        XCTAssertTrue(archive.library.threads.isEmpty)
    }

    /// The initializer clamped and the property did not, so `archive.keptThreads = 3`
    /// read back as 3 while `prune(to:)` quietly enforced 10 — a limit the archive was
    /// not applying, reported by the one thing a caller can ask. No thread was ever lost
    /// to it, which is why nothing noticed.
    func testALimitAssignedAfterConstructionIsClampedToo() {
        // The ceiling rather than the default, so forty threads are guaranteed to fit
        // whatever the shipped default becomes — a smaller default would prune inside
        // the loop and fail this test about a constant it is not testing.
        let archive = ThreadArchive(fileURL: fileURL,
                                    keptThreads: ThreadLibrary.keptThreadsRange.upperBound,
                                    debounce: 0)
        for index in 0..<40 { archive.save(thread("q\(index)")) }

        archive.keptThreads = 3
        XCTAssertEqual(archive.keptThreads, ThreadLibrary.keptThreadsRange.lowerBound,
                       "the floor, not the number it was handed")
        XCTAssertEqual(archive.library.threads.count,
                       ThreadLibrary.keptThreadsRange.lowerBound,
                       "and the prune obeyed the same floor")

        archive.keptThreads = 99_999
        XCTAssertEqual(archive.keptThreads, ThreadLibrary.keptThreadsRange.upperBound,
                       "the ceiling, not the number it was handed")
        // Raising cannot restore what pruning dropped, so the count stays where the
        // floor left it. Asserted rather than assumed: a clamp that had been applied by
        // re-entering the observer would have pruned again on the way past.
        XCTAssertEqual(archive.library.threads.count,
                       ThreadLibrary.keptThreadsRange.lowerBound)
    }
}
