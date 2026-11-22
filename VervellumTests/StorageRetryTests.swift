import XCTest
@testable import Vervellum

/// Try Again finishes the erase that was asked for and takes nothing newer with it.
final class StorageRetryTests: XCTestCase {

    private final class RefusingFiles: FileManager {
        var refusesThreadFiles = false
        var refusesAttachments = false

        override func removeItem(at URL: URL) throws {
            if refusesThreadFiles, URL.lastPathComponent.hasPrefix("threads") {
                throw CocoaError(.fileWriteNoPermission)
            }
            if refusesAttachments, URL.lastPathComponent == "attachments"
                || URL.deletingLastPathComponent().lastPathComponent == "attachments" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try super.removeItem(at: URL)
        }
    }

    private var directory: URL!
    private var files: RefusingFiles!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vervellum-retry-\(UUID().uuidString)")
        files = RefusingFiles()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(historyEnabled: Bool = true) -> ThreadStore {
        ThreadStore(fileURL: directory.appendingPathComponent("threads.json"),
                    fileManager: files, historyEnabled: historyEnabled, debounce: 0)
    }

    private func image(_ name: String) throws -> PendingAttachment {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 8)
        return try PendingAttachment.make(from: bytes, name: name).get()
    }

    private func addThread(_ name: String, to store: ThreadStore) throws -> Attachment {
        let pending = try image(name)
        try store.attachmentStore.write(pending.data, for: pending.attachment)
        var turn = ResearchTurn(question: name)
        turn.stage = .complete
        turn.attachments = [pending.attachment]
        var thread = ResearchThread()
        thread.turns = [turn]
        store.save(thread)
        store.flush()
        return pending.attachment
    }

    func testRetryKeepsAttachmentsOfThreadsCreatedAfterAFailedErase() throws {
        let store = makeStore()
        let old = try addThread("old.png", to: store)
        files.refusesAttachments = true
        store.deleteAll()
        let new = try addThread("new.png", to: store)

        files.refusesAttachments = false
        store.retryStorage()

        XCTAssertTrue(store.attachmentStore.exists(new), "Try Again deleted a live thread's attachment")
        XCTAssertFalse(store.attachmentStore.exists(old), "the erase that was asked for must finish")
        XCTAssertNil(store.storageFailure)
    }

    /// A question's bytes are written before the first save that names them.
    func testRetryKeepsBytesWrittenAfterTheEraseThatNoThreadNamesYet() throws {
        let store = makeStore()
        _ = try addThread("old.png", to: store)
        files.refusesAttachments = true
        store.deleteAll()
        let sending = try image("sending.png")
        try store.attachmentStore.write(sending.data, for: sending.attachment)

        files.refusesAttachments = false
        store.retryStorage()

        XCTAssertTrue(store.attachmentStore.exists(sending.attachment))
    }

    func testRetryingAFailedThreadEraseFinishesTheAttachmentErase() throws {
        let store = makeStore()
        let old = try addThread("old.png", to: store)
        files.refusesThreadFiles = true
        store.deleteAll()
        XCTAssertTrue(store.attachmentStore.exists(old), "bytes the surviving file names must stay until it goes")

        files.refusesThreadFiles = false
        store.retryStorage()

        XCTAssertFalse(store.attachmentStore.exists(old), "the banner cleared with the picture left on disk")
        XCTAssertNil(store.storageFailure)
    }

    func testAnAttachmentEraseThatFailsOnRetryKeepsTheWarning() throws {
        let store = makeStore()
        let old = try addThread("old.png", to: store)
        files.refusesThreadFiles = true
        store.deleteAll()

        files.refusesThreadFiles = false
        files.refusesAttachments = true
        store.retryStorage()
        XCTAssertNotNil(store.storageFailure, "images are still on disk, so the warning must stand")

        files.refusesAttachments = false
        store.retryStorage()
        XCTAssertFalse(store.attachmentStore.exists(old))
        XCTAssertNil(store.storageFailure)
    }

    func testThreadsStartedDuringAFailedEraseAreSavedOnceItSucceeds() throws {
        let store = makeStore()
        _ = try addThread("old.png", to: store)
        files.refusesThreadFiles = true
        store.deleteAll()
        let new = try addThread("new.png", to: store)

        files.refusesThreadFiles = false
        store.retryStorage()
        store.flush()

        let reopened = makeStore()
        XCTAssertEqual(reopened.library.threads.map(\.title), ["new.png"], "the warning cleared over an unsaved thread")
        XCTAssertTrue(reopened.attachmentStore.exists(new))
    }

    /// Switching history back on retries a failed thread erase by itself.
    func testReenablingHistoryFinishesTheAttachmentErase() throws {
        let store = makeStore()
        let old = try addThread("old.png", to: store)
        files.refusesThreadFiles = true
        store.isHistoryEnabled = false

        files.refusesThreadFiles = false
        store.isHistoryEnabled = true

        XCTAssertFalse(store.attachmentStore.exists(old))
        XCTAssertNil(store.storageFailure)
    }

    func testRetryingALaunchTimeEraseFinishesTheAttachmentErase() throws {
        let old = try addThread("old.png", to: makeStore())
        files.refusesThreadFiles = true
        let store = makeStore(historyEnabled: false)

        files.refusesThreadFiles = false
        store.retryStorage()

        XCTAssertFalse(store.attachmentStore.exists(old))
        XCTAssertNil(store.storageFailure)
    }
}
