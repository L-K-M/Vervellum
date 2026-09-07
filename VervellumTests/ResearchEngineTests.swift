import XCTest
@testable import Vervellum

final class ResearchEngineTests: XCTestCase {
    func testStopRejectsPendingProseAndLateCompletion() {
        let started = expectation(description: "Runner started")
        let completed = expectation(description: "Completion delivered")
        let runner = ManualRunner(onStart: { started.fulfill() })
        let scheduler = ManualScheduler()
        let engine = ResearchEngine(
            preferences: CorePreferences(store: MemorySettingsStore()),
            secrets: EphemeralSecretStore(), logSink: SilentLog(),
            makeRunner: { _, _ in runner }, deliver: scheduler.enqueue, after: scheduler.after)
        engine.ask("Question")
        wait(for: [started], timeout: 3)

        runner.emit("First")
        runner.emit("Latest [9]")
        scheduler.drain()
        XCTAssertEqual(scheduler.timers.count, 1, "Exercise an actual pending prose snapshot")
        XCTAssertEqual(engine.thread.turns.last?.answer, "First")

        engine.cancel()
        runner.emit("Stale")
        scheduler.drain()
        scheduler.expectDelivery { completed.fulfill() }
        runner.finish()
        wait(for: [completed], timeout: 3)
        scheduler.drain()
        scheduler.fireTimers()

        XCTAssertEqual(engine.thread.turns.last?.answer, "Latest [9]")
        XCTAssertEqual(engine.thread.turns.last?.stage, .cancelled)
        XCTAssertTrue(engine.thread.turns.last?.notices.contains(.invalidCitation) == true)
        XCTAssertFalse(engine.isRunning)
    }

    /// No sleeps or network: tests decide when runner callbacks and UI timers execute.
    private final class ManualScheduler {
        private let lock = NSLock()
        private var deliveries: [() -> Void] = []
        private var onDelivery: (() -> Void)?
        private(set) var timers: [() -> Void] = []

        func expectDelivery(_ callback: @escaping () -> Void) {
            lock.lock()
            onDelivery = callback
            lock.unlock()
        }

        func enqueue(_ work: @escaping () -> Void) {
            lock.lock()
            deliveries.append(work)
            let callback = onDelivery
            onDelivery = nil
            lock.unlock()
            callback?()
        }

        func after(_ delay: TimeInterval, _ work: @escaping () -> Void) { timers.append(work) }

        func drain() {
            while true {
                lock.lock()
                let next = deliveries.isEmpty ? nil : deliveries.removeFirst()
                lock.unlock()
                guard let next else { return }
                next()
            }
        }

        func fireTimers() {
            let pending = timers
            timers.removeAll()
            pending.forEach { $0() }
        }
    }

    private final class ManualRunner: ResearchRunning {
        private let lock = NSLock()
        private let onStart: () -> Void
        private var turn: ResearchTurn?
        private var update: ((ResearchTurn) -> Void)?
        private var completion: CheckedContinuation<ResearchTurn, Never>?

        init(onStart: @escaping () -> Void) { self.onStart = onStart }

        func run(_ turn: ResearchTurn, mode: ResearchRunner.Mode, history: [ResearchTurn],
                 onUpdate: @escaping (ResearchTurn) -> Void) async -> ResearchTurn {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.turn = turn
                update = onUpdate
                completion = continuation
                lock.unlock()
                onStart()
            }
        }

        func emit(_ answer: String) {
            lock.lock()
            var snapshot = turn!
            let callback = update!
            lock.unlock()
            snapshot.stage = .answering
            snapshot.answer = answer
            callback(snapshot)
        }

        /// Ends the run in `stage`. Defaults to `.failed`, which is what the stop test
        /// wants and what a queued follow-up must *not* be started by.
        func finish(stage: ResearchStage = .failed) {
            lock.lock()
            var snapshot = turn!
            let continuation = completion!
            completion = nil
            lock.unlock()
            snapshot.stage = stage
            continuation.resume(returning: snapshot)
        }
    }

    /// Fulfils a list of expectations in order, once per run started.
    ///
    /// A plain captured counter would be mutated from the cooperative pool while the
    /// test thread reads it; this keeps the hand-off behind a lock and lets a test wait
    /// for the first start before arranging the second.
    private final class StartCounter {
        private let lock = NSLock()
        private var pending: [XCTestExpectation]

        init(_ pending: [XCTestExpectation]) { self.pending = pending }

        func record() {
            lock.lock()
            let next = pending.isEmpty ? nil : pending.removeFirst()
            lock.unlock()
            next?.fulfill()
        }
    }

    private func makeEngine(runner: ResearchRunning,
                            scheduler: ManualScheduler) -> ResearchEngine {
        ResearchEngine(preferences: CorePreferences(store: MemorySettingsStore()),
                       secrets: EphemeralSecretStore(), logSink: SilentLog(),
                       makeRunner: { _, _ in runner },
                       deliver: scheduler.enqueue, after: scheduler.after)
    }

    // MARK: Asking during a run

    /// The composer stays live during a run, so a question asked then has to go
    /// somewhere. It waits, and starts on its own when the thread frees up.
    func testAQuestionAskedDuringARunIsQueuedAndRunWhenTheFirstCompletes() {
        let first = expectation(description: "First run started")
        let second = expectation(description: "Second run started")
        let runner = ManualRunner(onStart: StartCounter([first, second]).record)
        let scheduler = ManualScheduler()
        let engine = makeEngine(runner: runner, scheduler: scheduler)

        engine.ask("First question")
        wait(for: [first], timeout: 3)

        XCTAssertEqual(engine.ask("Second question"), .queued)
        XCTAssertEqual(engine.queue.map(\.question), ["Second question"])
        XCTAssertEqual(engine.thread.turns.count, 1, "Nothing is appended until it runs")

        // The runner resumes its continuation on this thread, but the task that awaits it
        // resumes on the cooperative pool and only *then* hands the completion to the
        // scheduler. Draining before that has happened finds an empty queue and the
        // completion is never applied — so wait for the delivery to arrive first, the
        // same handshake `testStopRejectsPendingProseAndLateCompletion` uses.
        let delivered = expectation(description: "Completion delivered")
        scheduler.expectDelivery { delivered.fulfill() }
        runner.finish(stage: .complete)
        wait(for: [delivered], timeout: 3)
        scheduler.drain()
        wait(for: [second], timeout: 3)
        scheduler.drain()

        XCTAssertTrue(engine.queue.isEmpty)
        XCTAssertEqual(engine.thread.turns.map(\.question), ["First question", "Second question"])
        XCTAssertTrue(engine.isRunning)
    }

    /// A queue with no visible end is a way to spend a provider's quota by accident, so
    /// it is bounded — and a refused question keeps its text rather than vanishing.
    func testAFullQueueRefusesInsteadOfSwallowingTheQuestion() {
        let first = expectation(description: "Run started")
        let runner = ManualRunner(onStart: StartCounter([first]).record)
        let scheduler = ManualScheduler()
        let engine = makeEngine(runner: runner, scheduler: scheduler)

        engine.ask("Running")
        wait(for: [first], timeout: 3)

        for index in 1...ResearchEngine.maxQueued {
            XCTAssertEqual(engine.ask("Waiting \(index)"), .queued)
        }
        XCTAssertEqual(engine.ask("Overflow"), .queueFull)
        XCTAssertEqual(engine.queue.count, ResearchEngine.maxQueued)
        XCTAssertFalse(engine.queue.contains { $0.question == "Overflow" })

        engine.removeQueued(engine.queue[0].id)
        XCTAssertEqual(engine.queue.map(\.question), ["Waiting 2", "Waiting 3"])
    }

    /// Stop means stop everything that was asked for — and typed text is the one thing
    /// the user cannot get back, so the queue is handed over rather than dropped.
    func testStopCancelsTheQueueAndHandsItBack() {
        let first = expectation(description: "Run started")
        let runner = ManualRunner(onStart: StartCounter([first]).record)
        let scheduler = ManualScheduler()
        let engine = makeEngine(runner: runner, scheduler: scheduler)
        var returned: [String] = []
        engine.onQueueReturned = { returned = $0 }

        engine.ask("Running")
        wait(for: [first], timeout: 3)
        engine.ask("Second")
        engine.ask("Third")
        XCTAssertEqual(engine.queue.count, 2)

        engine.cancel()
        XCTAssertEqual(returned, ["Second", "Third"])
        XCTAssertTrue(engine.queue.isEmpty)

        // Resume the abandoned run so the harness's continuation is not left suspended.
        runner.finish()
        scheduler.drain()
        XCTAssertEqual(engine.thread.turns.count, 1)
    }

    /// A failed turn usually means a provider, a key or a quota — conditions the next
    /// question would meet unchanged. Running the queue anyway would collect the same
    /// error once per question and bill for each.
    func testAFailedTurnHandsTheQueueBackInsteadOfAskingItAgain() {
        let first = expectation(description: "Run started")
        let runner = ManualRunner(onStart: StartCounter([first]).record)
        let scheduler = ManualScheduler()
        let engine = makeEngine(runner: runner, scheduler: scheduler)
        var returned: [String] = []
        engine.onQueueReturned = { returned = $0 }

        engine.ask("Running")
        wait(for: [first], timeout: 3)
        engine.ask("Second")

        let delivered = expectation(description: "Completion delivered")
        scheduler.expectDelivery { delivered.fulfill() }
        runner.finish(stage: .failed)
        wait(for: [delivered], timeout: 3)
        scheduler.drain()

        XCTAssertEqual(returned, ["Second"])
        XCTAssertTrue(engine.queue.isEmpty)
        XCTAssertEqual(engine.thread.turns.count, 1, "The queued question was not started")
        XCTAssertFalse(engine.isRunning)
    }

    /// A new thread puts the conversation away. Its follow-ups go with it rather than
    /// reappearing in the composer over a thread they were not about.
    func testANewThreadDropsTheQueueWithoutHandingItBack() {
        let first = expectation(description: "Run started")
        let runner = ManualRunner(onStart: StartCounter([first]).record)
        let scheduler = ManualScheduler()
        let engine = makeEngine(runner: runner, scheduler: scheduler)
        var returned: [String] = []
        engine.onQueueReturned = { returned = $0 }

        engine.ask("Running")
        wait(for: [first], timeout: 3)
        engine.ask("Second")

        engine.startNewThread()
        XCTAssertTrue(engine.queue.isEmpty)
        XCTAssertTrue(returned.isEmpty)

        runner.finish()
        scheduler.drain()
    }
}
