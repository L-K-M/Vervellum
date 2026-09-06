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
        library.upsert(thread("first"))
        library.upsert(thread("second"))
        XCTAssertEqual(library.threads.map(\.title), ["second", "first"])
    }

    func testUpsertReplacesRatherThanDuplicates() {
        var library = ThreadLibrary()
        var subject = thread("original")
        library.upsert(subject)
        subject.turns[0].question = "edited"
        library.upsert(subject)
        XCTAssertEqual(library.threads.count, 1)
        XCTAssertEqual(library.threads.first?.title, "edited")
    }

    /// Summoning the panel and dismissing it without asking anything must leave no
    /// trace on disk.
    func testAnEmptyThreadIsNeverStored() {
        var library = ThreadLibrary()
        library.upsert(ResearchThread())
        XCTAssertTrue(library.threads.isEmpty)
    }

    func testTheListIsBounded() {
        var library = ThreadLibrary()
        let overfill = ThreadLibrary.maxThreads + 20
        for index in 0..<overfill {
            library.upsert(thread("q\(index)"))
        }
        XCTAssertEqual(library.threads.count, ThreadLibrary.maxThreads)
        XCTAssertEqual(library.threads.first?.title, "q\(ThreadLibrary.maxThreads + 19)")
    }

    func testSearchMatchesQuestionsAndAnswers() {
        var library = ThreadLibrary()
        library.upsert(thread("photosynthesis"))
        library.upsert(thread("tectonics"))
        XCTAssertEqual(library.search("PHOTO").count, 1)
        XCTAssertEqual(library.search("an answer about").count, 2)
        XCTAssertEqual(library.search("nothing here").count, 0)
        XCTAssertEqual(library.search("   ").count, 2)
    }
}

final class ThreadArchiveTests: XCTestCase {

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
        // `UInt` in swift-corelibs-foundation, and this test runs on both. A closure
        // rather than `map(Int.init)`: newer toolchains (Swift 6.2, current Xcode)
        // find the bare initializer reference ambiguous, and CI turning red on a
        // toolchain bump is exactly what this line is supposed to survive.
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

    func testDeleteAllRemovesTheFile() {
        let store = ThreadArchive(fileURL: fileURL, debounce: 0)
        store.save(thread("gone"))
        store.flush()
        store.deleteAll()
        XCTAssertTrue(store.library.threads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
