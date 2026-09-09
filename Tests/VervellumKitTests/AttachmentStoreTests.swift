import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The bytes behind an attachment, which live beside the thread file rather than in it.
final class AttachmentStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vervellum-attachments-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ id: UUID = UUID()) -> Attachment {
        Attachment(id: id, kind: .image, name: "shot.png", mediaType: "image/png", byteCount: 3)
    }

    func testBytesSurviveARoundTripAndTheDirectoryIsMadeOnDemand() throws {
        let store = AttachmentStore(directory: directory)
        let attachment = record()
        XCTAssertFalse(store.exists(attachment))

        try store.write(Data([1, 2, 3]), for: attachment)
        XCTAssertTrue(store.exists(attachment))
        XCTAssertEqual(store.data(for: attachment), Data([1, 2, 3]))
    }

    /// Missing bytes are an ordinary outcome, not a failure: a library copied between
    /// machines without its attachments folder leaves records pointing at nothing, and
    /// the turn's job is to carry on without the picture.
    func testMissingBytesReadAsNilRatherThanThrowing() {
        let store = AttachmentStore(directory: directory)
        XCTAssertNil(store.data(for: record()))
        XCTAssertFalse(store.exists(record()))
    }

    /// The sweep is by reachability. It is handed what is still referenced, never what
    /// was removed, so a delete that raced a save cannot take a live attachment with it.
    func testSweepingKeepsWhatIsStillReferenced() throws {
        let store = AttachmentStore(directory: directory)
        let live = record(), dead = record()
        try store.write(Data([1]), for: live)
        try store.write(Data([2]), for: dead)

        XCTAssertEqual(store.sweep(keeping: [live.id], sparingFilesNewerThan: 0), 1)
        XCTAssertTrue(store.exists(live))
        XCTAssertFalse(store.exists(dead))

        // And it is idempotent: nothing is left to remove the second time.
        XCTAssertEqual(store.sweep(keeping: [live.id], sparingFilesNewerThan: 0), 0)
    }

    /// A file this store did not write is left alone. The directory belongs to Vervellum,
    /// but deleting something unrecognised is not a call a sweep should make by itself.
    func testSweepingLeavesFilesItDidNotWrite() throws {
        let store = AttachmentStore(directory: directory)
        try store.write(Data([1]), for: record())
        let stranger = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: stranger)

        XCTAssertEqual(store.sweep(keeping: [], sparingFilesNewerThan: 0), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    /// Sweeping a directory that was never created is a no-op rather than a crash — the
    /// state every library starts in, and one a sweep must not quietly leave.
    func testSweepingAnAbsentDirectoryDoesNothing() {
        XCTAssertEqual(AttachmentStore(directory: directory).sweep(keeping: []), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "sweeping an absent directory created it")
    }

    /// Re-attaching under an id that already has bytes replaces them. The path a retaken
    /// screenshot follows, and the one where a write that appended — or refused — would
    /// send the model something other than what the panel is showing.
    func testWritingAgainForTheSameIdReplacesTheBytes() throws {
        let store = AttachmentStore(directory: directory)
        let attachment = record()
        try store.write(Data([1, 2, 3]), for: attachment)
        try store.write(Data([9]), for: attachment)

        XCTAssertEqual(store.data(for: attachment), Data([9]))
        // And nothing is left over from the first write: the staged copy is moved into
        // place, never left beside it.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [attachment.id.uuidString])
    }

    func testErasingRemovesEverything() throws {
        let store = AttachmentStore(directory: directory)
        let attachment = record()
        try store.write(Data([1]), for: attachment)

        try store.removeAll()
        XCTAssertFalse(store.exists(attachment))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Erasing a library that never had an attachment is not a failure — there is
    /// nothing to remove — so the ordinary case does not make the caller handle an error.
    func testErasingWhatWasNeverCreatedSucceeds() {
        XCTAssertNoThrow(try AttachmentStore(directory: directory).removeAll())
    }

    /// The bytes are `0600` inside a `0700` directory, and the docs say so. Pinned here
    /// so a regression widens who can read a screenshot loudly rather than silently.
    func testWrittenBytesAndTheirDirectoryArePrivateToTheirOwner() throws {
        let store = AttachmentStore(directory: directory)
        let attachment = record()
        try store.write(Data([1, 2, 3]), for: attachment)

        let manager = FileManager.default
        let file = try manager.attributesOfItem(
            atPath: directory.appendingPathComponent(attachment.id.uuidString).path)
        XCTAssertEqual(file[.posixPermissions] as? NSNumber, 0o600)
        let folder = try manager.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(folder[.posixPermissions] as? NSNumber, 0o700)
    }

    /// The one way a sweep could destroy something: bytes written for a question that
    /// has not been saved yet, so its id cannot be in the set the sweep is given. Another
    /// process reading the library a moment earlier would see them as unreachable. Too
    /// young to sweep means kept.
    func testAJustWrittenFileSurvivesASweepThatCannotKnowAboutItYet() throws {
        let store = AttachmentStore(directory: directory)
        let attachment = record()
        try store.write(Data([1]), for: attachment)

        XCTAssertEqual(store.sweep(keeping: []), 0, "a file written moments ago was swept")
        XCTAssertTrue(store.exists(attachment))

        // And it is not immortal: the same sweep with no grace window removes it.
        XCTAssertEqual(store.sweep(keeping: [], sparingFilesNewerThan: 0), 1)
        XCTAssertFalse(store.exists(attachment))
    }

    /// The bytes sit next to the thread file, so an attachment lives and dies with the
    /// library it belongs to rather than in a cache somewhere else.
    func testTheDirectorySitsBesideTheThreadFile() {
        let threads = URL(fileURLWithPath: "/tmp/vervellum/threads.json")
        XCTAssertEqual(AttachmentStore.directory(besideThreadFile: threads).path,
                       "/tmp/vervellum/attachments")
    }

    /// An erase is not the end of the store. The next write recreates the directory,
    /// which is what lets a panel keep taking screenshots after "erase stored threads" —
    /// a transition a user can reach twice in one session.
    func testTheStoreKeepsWorkingAfterAnErase() throws {
        let store = AttachmentStore(directory: directory)
        try store.write(Data([1]), for: record())
        try store.removeAll()

        let fresh = record()
        try store.write(Data([2]), for: fresh)
        XCTAssertEqual(store.data(for: fresh), Data([2]))
    }
}
