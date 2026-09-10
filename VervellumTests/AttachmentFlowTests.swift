import XCTest
@testable import Vervellum

/// What happens to an attachment between the composer and the model: when its bytes are
/// written, who is handed them, and what makes them go away again.
final class AttachmentFlowTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vervellum-flow-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pendingImage(_ name: String = "shot.png") throws -> PendingAttachment {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 8)
        // The `Result`'s own error, not a bare nil. `try?` collapsed every rejection
        // into "unexpectedly found nil", so a fixture that stopped passing a future
        // validation rule would say only that it had stopped, and not why.
        return try PendingAttachment.make(from: bytes, name: name).get()
    }

    /// Builds an engine over a temporary attachment directory, and hands back the bytes
    /// seam the runner was built with so a test can ask what the turn would be sent.
    private func makeEngine(historyEnabled: Bool = true,
                            runner: CapturingRunner,
                            bytes: @escaping (@escaping (Attachment) -> Data?) -> Void)
        -> (ResearchEngine, AttachmentStore) {
        let preferences = CorePreferences(store: MemorySettingsStore())
        preferences.historyEnabled = historyEnabled
        let store = AttachmentStore(directory: directory)
        let engine = ResearchEngine(preferences: preferences,
                                    secrets: EphemeralSecretStore(),
                                    logSink: SilentLog(),
                                    attachmentStore: store,
                                    makeRunner: { _, _, seam in
                                        bytes(seam)
                                        return runner
                                    },
                                    deliver: { $0() },
                                    after: { _, _ in })
        return (engine, store)
    }

    /// A runner that fulfils one expectation on its first start and the other on its
    /// second, and hands back a way to ask how many there were.
    ///
    /// Locked, though the runs are sequenced: `onStart` is called from whatever thread
    /// each `Task` resumed on, and nothing here establishes that the second sees the
    /// first's write. A stale read fulfils the first expectation twice, leaves the second
    /// unfulfilled, and the test dies on a three-second timeout pointing nowhere near the
    /// cause.
    ///
    /// The count is returned because `else` was hiding a third run: XCTest tolerates an
    /// expectation fulfilled twice, so an engine that dequeued once too often looked
    /// exactly like one that dequeued correctly — in the two tests whose whole subject is
    /// the sequence.
    private func sequencedRunner(_ first: XCTestExpectation,
                                 _ second: XCTestExpectation)
        -> (runner: CapturingRunner, startCount: () -> Int) {
        let counter = NSLock()
        var starts = 0
        let runner = CapturingRunner(onStart: {
            counter.lock()
            starts += 1
            let run = starts
            counter.unlock()
            if run == 1 { first.fulfill() } else if run == 2 { second.fulfill() }
        })
        return (runner, {
            counter.lock()
            defer { counter.unlock() }
            return starts
        })
    }

    // MARK: Asking

    /// The turn records what was attached, and the bytes land beside the thread file at
    /// the moment the turn that refers to them exists — not before.
    func testAskingWithAnAttachmentRecordsItAndStoresItsBytes() throws {
        let started = expectation(description: "Run started")
        let runner = CapturingRunner(onStart: started.fulfill)
        // Unparked even if an assertion below throws — see `finish`.
        defer { runner.finish() }
        var seam: ((Attachment) -> Data?)?
        let (engine, store) = makeEngine(runner: runner, bytes: { seam = $0 })
        let pending = try pendingImage()

        engine.ask("What is this?", attachments: [pending])
        wait(for: [started], timeout: 3)

        let turn = try XCTUnwrap(engine.thread.turns.last)
        XCTAssertEqual(turn.attachments.map { $0.name }, ["shot.png"])
        XCTAssertEqual(store.data(for: pending.attachment), pending.data)
        // And the runner is handed the same bytes for the turn it is running.
        XCTAssertEqual(seam?(pending.attachment), pending.data)

    }

    /// "Keep history off" means the bytes are gone. A screenshot written to disk under a
    /// setting that promises nothing is kept would be the loudest way to break it — and
    /// the turn still runs with the picture, because what it is sent comes from memory.
    func testWithHistoryOffNothingIsWrittenButTheTurnStillSeesTheImage() throws {
        let started = expectation(description: "Run started")
        let runner = CapturingRunner(onStart: started.fulfill)
        // Unparked even if an assertion below throws — see `finish`.
        defer { runner.finish() }
        var seam: ((Attachment) -> Data?)?
        let (engine, store) = makeEngine(historyEnabled: false, runner: runner,
                                         bytes: { seam = $0 })
        let pending = try pendingImage()

        engine.ask("What is this?", attachments: [pending])
        wait(for: [started], timeout: 3)

        XCTAssertNil(store.data(for: pending.attachment), "history is off; nothing is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(seam?(pending.attachment), pending.data, "the turn still gets the image")
        XCTAssertEqual(engine.thread.turns.last?.attachments.count, 1,
                       "the transcript still says what was asked with")

    }

    /// A question that had to wait keeps what was attached to it, and a Stop hands the
    /// bytes back rather than dropping them.
    func testAQueuedQuestionKeepsItsAttachmentsAndAStopHandsThemBack() throws {
        let started = expectation(description: "First run started")
        let runner = CapturingRunner(onStart: started.fulfill)
        // Unparked even if an assertion below throws — see `finish`.
        defer { runner.finish() }
        var seam: ((Attachment) -> Data?)?
        let (engine, _) = makeEngine(runner: runner, bytes: { seam = $0 })
        let pending = try pendingImage("second.png")

        engine.ask("Running")
        wait(for: [started], timeout: 3)
        XCTAssertEqual(engine.ask("Waiting", attachments: [pending]),
                       ResearchEngine.AskOutcome.queued)
        XCTAssertEqual(engine.queue.first?.attachments.map { $0.id }, [pending.id])

        // The queue is handed back whole, so a Stop cannot lose the bytes of a pasted
        // screenshot — they exist nowhere else.
        //
        // Asserted straight after `cancel()` on purpose, and that is the contract, not
        // an assumption about timing: `stopRunningTurn` empties `queue` and calls
        // `onQueueReturned` on the next line, in the same call. There is no second
        // chance to deliver it — after the return the questions are held by nothing —
        // so a hand-back that arrived a run loop later would arrive after the composer
        // had already been redrawn empty. A `wait(for:)` here would pass either way and
        // would say the opposite about which of those is allowed.
        var returned: [ResearchEngine.QueuedQuestion] = []
        engine.onQueueReturned = { returned = $0 }
        engine.cancel()
        XCTAssertEqual(returned.flatMap { $0.attachments }, [pending])
        // The queue is *emptied*, not copied out of. `stopRunningTurn` takes it and
        // clears it in the same call, which is what makes the hand-back the only one
        // there will be — and it is what this line pins about Stop.
        XCTAssertTrue(engine.queue.isEmpty)
        // Kept only to say the engine took a way to read an attachment's bytes. It is
        // set as the first run starts, so it could not answer for anything Stop did;
        // the line above is the one that does.
        XCTAssertNotNil(seam, "the engine took a bytes seam when it was built")
    }

    /// And when the queue is *not* stopped, the waiting question is asked with its
    /// attachment when its turn comes.
    ///
    /// The dequeue is where bytes would most plausibly go missing: the question is
    /// rebuilt into a turn from the queue rather than from the composer, and until it
    /// runs its picture has never been written anywhere. So this follows it all the way
    /// through — the turn's record, the bytes on disk, and what the runner is handed.
    func testAQueuedQuestionIsAskedWithItsAttachmentWhenItsTurnComes() throws {
        let firstStarted = expectation(description: "First run started")
        let secondStarted = expectation(description: "Second run started")
        let (runner, startCount) = sequencedRunner(firstStarted, secondStarted)
        // Unparks the *second* run, which is still parked when the test ends.
        defer { runner.finish() }
        // Written inside `makeRunner`, on whatever thread the engine's task is on, and
        // read here on the test's. No lock, unlike `starts` above: every read below is
        // ordered after that write by a `wait(for:)` on an expectation `onStart` fulfils,
        // and `onStart` runs after the seam is handed over. A read on a path that is not
        // downstream of one of those waits would want the same treatment `starts` got.
        var seam: ((Attachment) -> Data?)?
        let (engine, store) = makeEngine(runner: runner, bytes: { seam = $0 })
        let pending = try pendingImage("second.png")

        engine.ask("Running")
        wait(for: [firstStarted], timeout: 3)
        XCTAssertEqual(engine.ask("Waiting", attachments: [pending]),
                       ResearchEngine.AskOutcome.queued)
        // Not stored yet: the bytes of a waiting question are in memory only, and the
        // turn that would refer to them does not exist.
        XCTAssertNil(store.data(for: pending.attachment))

        // Completing the first run is what pulls the next one — see `startNextQueued`,
        // which only dequeues after a turn that actually finished.
        runner.finish(stage: .complete)
        wait(for: [secondStarted], timeout: 3)

        let dequeued = try XCTUnwrap(engine.thread.turns.last)
        XCTAssertEqual(dequeued.question, "Waiting")
        XCTAssertEqual(dequeued.attachments.map { $0.name }, ["second.png"])
        XCTAssertEqual(store.data(for: pending.attachment), pending.data,
                       "the bytes are written when the turn that refers to them exists")
        XCTAssertEqual(seam?(pending.attachment), pending.data,
                       "and the run that was just started is handed them")
        XCTAssertTrue(engine.queue.isEmpty)
        XCTAssertEqual(startCount(), 2, "the queue held one question, so there were two runs")
    }

    /// The two rules crossed: a question that had to wait, under a setting that promises
    /// nothing is kept.
    ///
    /// The gate is read again at the dequeue, because that is where a queued question's
    /// bytes are written — the ask-time path never wrote them. A gate that guarded only
    /// the ask would leave this one intact: the history-off test never queues, and the
    /// queued test runs with history on, so a screenshot written under a setting that
    /// says nothing is kept would ship with the suite green.
    func testAQueuedQuestionUnderHistoryOffIsNeverWrittenEither() throws {
        let firstStarted = expectation(description: "First run started")
        let secondStarted = expectation(description: "Second run started")
        let (runner, startCount) = sequencedRunner(firstStarted, secondStarted)
        defer { runner.finish() }
        var seam: ((Attachment) -> Data?)?
        let (engine, store) = makeEngine(historyEnabled: false, runner: runner,
                                         bytes: { seam = $0 })
        let pending = try pendingImage("waited.png")

        engine.ask("Running")
        wait(for: [firstStarted], timeout: 3)
        XCTAssertEqual(engine.ask("Waiting", attachments: [pending]),
                       ResearchEngine.AskOutcome.queued)

        runner.finish(stage: .complete)
        wait(for: [secondStarted], timeout: 3)

        XCTAssertEqual(engine.thread.turns.last?.attachments.map { $0.name }, ["waited.png"])
        XCTAssertNil(store.data(for: pending.attachment),
                     "history is off, and the dequeue is a write like any other")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(seam?(pending.attachment), pending.data,
                       "and the run still gets the image, from memory")
        XCTAssertEqual(startCount(), 2, "the queue held one question, so there were two runs")
    }

    // MARK: Sweeping

    /// Deleting a thread takes its attachments with it, and leaves everything else alone.
    func testDeletingAThreadSweepsOnlyItsOwnAttachments() throws {
        let file = directory.appendingPathComponent("threads.json")
        let store = ThreadStore(fileURL: file, debounce: 0)
        let attachments = AttachmentStore(
            directory: AttachmentStore.directory(besideThreadFile: file))

        let kept = try pendingImage("kept.png"), dropped = try pendingImage("dropped.png")
        try attachments.write(kept.data, for: kept.attachment)
        try attachments.write(dropped.data, for: dropped.attachment)
        // Aged past the sweep's grace window, which exists to protect bytes written for a
        // question that has not been saved yet. Both of them, so what survives below
        // survives by being referenced rather than by being young — which is the whole
        // property this test is about.
        try age(kept.attachment, in: file)
        try age(dropped.attachment, in: file)

        var living = ResearchThread()
        living.turns = [turn(with: kept.attachment)]
        var doomed = ResearchThread()
        doomed.turns = [turn(with: dropped.attachment)]
        store.save(living)
        store.save(doomed)

        store.delete(id: doomed.id)

        XCTAssertNotNil(store.attachmentData(for: kept.attachment))
        XCTAssertNil(store.attachmentData(for: dropped.attachment))
    }

    /// Erasing the library erases the pictures. A conversation the user asked to be gone
    /// should not leave the screenshots behind.
    func testErasingEverythingTakesTheAttachmentsWithIt() throws {
        let file = directory.appendingPathComponent("threads.json")
        let store = ThreadStore(fileURL: file, debounce: 0)
        let pending = try pendingImage()
        var thread = ResearchThread()
        thread.turns = [turn(with: pending.attachment)]
        store.save(thread)
        try AttachmentStore(directory: AttachmentStore.directory(besideThreadFile: file))
            .write(pending.data, for: pending.attachment)

        store.deleteAll()
        XCTAssertNil(store.attachmentData(for: pending.attachment))
    }

    /// The other half of the grace window: a file nothing refers to *yet* survives.
    ///
    /// Both files in the tests above are aged past the window, so a sweep that dropped
    /// its grace check altogether would pass every one of them — while the screenshot
    /// written for a question whose turn has not been saved yet would be gone. That gap
    /// is the whole reason the window exists, and it is the answer this suite gives
    /// whenever a review round asks whether a running turn's bytes can be swept.
    func testAYoungAttachmentNothingRefersToYetSurvivesASweep() throws {
        let file = directory.appendingPathComponent("threads.json")
        let store = ThreadStore(fileURL: file, debounce: 0)
        let attachments = AttachmentStore(
            directory: AttachmentStore.directory(besideThreadFile: file))

        let fresh = try pendingImage("fresh.png")
        try attachments.write(fresh.data, for: fresh.attachment)
        let elsewhere = try pendingImage("elsewhere.png")
        try attachments.write(elsewhere.data, for: elsewhere.attachment)
        try age(elsewhere.attachment, in: file)

        // A delete is a sweep, and neither file is referenced by what survives it.
        var doomed = ResearchThread()
        doomed.turns = [turn(with: elsewhere.attachment)]
        store.save(doomed)
        store.delete(id: doomed.id)

        XCTAssertNil(store.attachmentData(for: elsewhere.attachment),
                     "unreferenced and old enough to collect")
        XCTAssertNotNil(store.attachmentData(for: fresh.attachment),
                        "unreferenced too, and written seconds ago")
    }

    /// A launch with history off erases the thread file — and when that erase fails, the
    /// file is still there with every thread in it, still naming these bytes. The
    /// library that launch emptied is not what may decide their fate.
    ///
    /// The same rule the history switch and `deleteAll` follow, on the one path that did
    /// not: a reader who fixes the permission and turns history back on would otherwise
    /// get their conversations back with every picture gone.
    func testALaunchThatCouldNotEraseKeepsTheImagesItStillNames() throws {
        let file = directory.appendingPathComponent("threads.json")
        let pending = try pendingImage("kept.png")
        let attachments = AttachmentStore(
            directory: AttachmentStore.directory(besideThreadFile: file))

        var thread = ResearchThread()
        thread.turns = [turn(with: pending.attachment)]
        let store = ThreadStore(fileURL: file, debounce: 0)
        store.save(thread)
        // Flushed, and held in a variable, because `debounce: 0` does not mean
        // synchronous: `scheduleSave` hops to the archive's queue and writes from an
        // `asyncAfter` that holds the archive weakly, so a store nothing keeps alive is
        // gone before its own write runs and the file never appears at all. `flush` is
        // `queue.sync` on that same serial queue, so it lands behind the hop and writes
        // the snapshot before returning. Without the file the launch erase below finds
        // nothing to fail at, records no failure, and the sweep this guards runs — the
        // test then passing for the wrong reason.
        //
        // The sweep tests above need neither: they assert on the library in memory,
        // which `save` updates before it returns.
        store.flush()
        try attachments.write(pending.data, for: pending.attachment)
        try age(pending.attachment, in: file)

        _ = ThreadStore(fileURL: file, fileManager: RefusesToDeleteTheThreadFile(),
                        historyEnabled: false, debounce: 0)

        // The premise, not only what follows from it. A launch that never attempted the
        // erase — no file on disk, nothing to fail at, no failure recorded — leaves the
        // bytes alone for a reason that has nothing to do with the guard this test is
        // about, and the assertion below stays green while testing nothing. That is not
        // hypothetical: it is exactly how this test passed and then failed while it was
        // being written, and the flush above is what fixed it. This says so out loud.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the launch erase was attempted and refused")
        XCTAssertNotNil(attachments.data(for: pending.attachment))
    }

    /// Refuses the thread file and nothing else, so the launch erase fails while the
    /// attachment directory stays perfectly writable — which is the shape of the real
    /// failure: a permission on one file, not a broken disk.
    private final class RefusesToDeleteTheThreadFile: FileManager {
        override func removeItem(at url: URL) throws {
            guard url.lastPathComponent.hasPrefix("threads.json") else {
                return try super.removeItem(at: url)
            }
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Back-dates an attachment's file so a sweep will consider it, rather than reaching
    /// into `AttachmentStore` for a test-only way to skip its grace window.
    ///
    /// A day, not an hour. The grace window is five minutes today, so an hour was
    /// enough — but it is a product number, and a change that widened it to protect a
    /// question left open overnight would leave these files looking young, the sweep
    /// correctly skipping them, and two tests failing for a reason that has nothing to
    /// do with the reference-tracking they exist to check. A day is past anything a
    /// grace window would plausibly become and costs the test nothing.
    private func age(_ attachment: Attachment, in threadFile: URL,
                     by seconds: TimeInterval = 60 * 60 * 24) throws {
        let path = AttachmentStore.directory(besideThreadFile: threadFile)
            .appendingPathComponent(attachment.id.uuidString).path
        // The modification date, because that is the one `AttachmentStore.sweep` reads
        // for its grace window. Back-dating a key it does not consult would leave these
        // files looking young, and the tests would then pass because the sweep skipped
        // them rather than because the library still named them.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: path)
    }

    private func turn(with attachment: Attachment) -> ResearchTurn {
        var turn = ResearchTurn(question: "Q", askedAt: Date())
        turn.stage = .complete
        turn.attachments = [attachment]
        return turn
    }

    /// A runner that parks until the test lets it finish. The engine's own tests own the
    /// elaborate one; this needs only "it started, and here is what it was given".
    private final class CapturingRunner: ResearchRunning {
        private let lock = NSLock()
        private let onStart: () -> Void
        private var turn: ResearchTurn?
        private var completion: CheckedContinuation<ResearchTurn, Never>?

        init(onStart: @escaping () -> Void) { self.onStart = onStart }

        func run(_ turn: ResearchTurn, mode: ResearchRunner.Mode, history: [ResearchTurn],
                 onUpdate: @escaping (ResearchTurn) -> Void) async -> ResearchTurn {
            await withCheckedContinuation { continuation in
                lock.lock()
                // One parked run at a time. A second would overwrite the first's
                // continuation and leak it, and XCTest would report the leak rather than
                // the overwrite — pointing at teardown instead of at whichever test let
                // two runs start. Nothing does that today; this is what says so.
                // `precondition`, not `assert`: this is compiled out under `-O`, and the
                // paragraph above is the reason it must not be. Its whole job is to name
                // the test that let two runs park, in place of the leaked-continuation
                // report XCTest gives at teardown — which is exactly the failure that is
                // hardest to read, and exactly the configuration where the guard would
                // otherwise be gone.
                precondition(completion == nil,
                             "a second run parked before finish() was called")
                self.turn = turn
                completion = continuation
                lock.unlock()
                onStart()
            }
        }

        /// Resumes the parked run, so no continuation is left suspended at teardown.
        ///
        /// Idempotent, which is what lets the tests `defer` it: the continuation is
        /// taken and cleared under the lock before it is resumed, so a second call
        /// resumes nothing. Worth relying on, because a `try` that throws mid-test
        /// otherwise leaves the run suspended and XCTest reports a leaked continuation
        /// *on top of* the real failure — a reliable way to debug the wrong thing.
        func finish(stage: ResearchStage = .complete) {
            lock.lock()
            let continuation = completion
            completion = nil
            var snapshot = turn ?? ResearchTurn(question: "", askedAt: Date())
            lock.unlock()
            snapshot.stage = stage
            continuation?.resume(returning: snapshot)
        }
    }
}
