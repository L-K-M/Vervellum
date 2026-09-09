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

        XCTAssertEqual(store.sweep(keeping: [live.id]), 1)
        XCTAssertTrue(store.exists(live))
        XCTAssertFalse(store.exists(dead))

        // And it is idempotent: nothing is left to remove the second time.
        XCTAssertEqual(store.sweep(keeping: [live.id]), 0)
    }

    /// A file this store did not write is left alone. The directory belongs to Vervellum,
    /// but deleting something unrecognised is not a call a sweep should make by itself.
    func testSweepingLeavesFilesItDidNotWrite() throws {
        let store = AttachmentStore(directory: directory)
        try store.write(Data([1]), for: record())
        let stranger = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: stranger)

        XCTAssertEqual(store.sweep(keeping: []), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    /// Sweeping a directory that was never created is a no-op rather than a crash — the
    /// state every library starts in.
    func testSweepingAnAbsentDirectoryDoesNothing() {
        XCTAssertEqual(AttachmentStore(directory: directory).sweep(keeping: []), 0)
    }

    func testErasingRemovesEverything() throws {
        let store = AttachmentStore(directory: directory)
        let attachment = record()
        try store.write(Data([1]), for: attachment)

        store.removeAll()
        XCTAssertFalse(store.exists(attachment))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// The bytes sit next to the thread file, so an attachment lives and dies with the
    /// library it belongs to rather than in a cache somewhere else.
    func testTheDirectorySitsBesideTheThreadFile() {
        let threads = URL(fileURLWithPath: "/tmp/vervellum/threads.json")
        XCTAssertEqual(AttachmentStore.directory(besideThreadFile: threads).path,
                       "/tmp/vervellum/attachments")
    }
}
