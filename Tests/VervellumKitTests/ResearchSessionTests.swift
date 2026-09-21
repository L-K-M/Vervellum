import Foundation
import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// `ResearchSession` owns a thread's run state. These tests give it a `deliver` hop
/// that *queues* the runner's callbacks instead of running them, so the order in
/// which cancel, discard and a finishing run interleave is chosen by the test rather
/// than by the cooperative pool's scheduler. No run touches the network: the runner
/// is a `StubRunner` scripted to complete, fail, or hang until released.
final class ResearchSessionTests: XCTestCase {

    // MARK: Doubles

    /// A gate a stubbed run waits behind, so a test can hold a run in flight for as
    /// long as it needs to and then let it finish.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if open {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            open = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    /// A `ResearchRunning` whose run is a script, not a pipeline: it reports one
    /// mid-answer snapshot, waits behind its gate if it has one, and resolves to a
    /// completed or failed turn. `runCount` lets a test count starts — a queue that
    /// asked the same question twice would show up here.
    private final class StubRunner: ResearchRunning {
        let gate: Gate?
        let fails: Bool
        private(set) var runCount = 0

        init(gate: Gate? = nil, fails: Bool = false) {
            self.gate = gate
            self.fails = fails
        }

        func run(_ turn: ResearchTurn, mode: ResearchRunner.Mode,
                 history: [ResearchTurn],
                 onUpdate: @escaping (ResearchTurn) -> Void) async -> ResearchTurn {
            runCount += 1
            var streaming = turn
            streaming.stage = .answering
            streaming.answer = "partial"
            onUpdate(streaming)
            await gate?.wait()
            var finished = turn
            if fails {
                finished.stage = .failed
                finished.failure = "stub failure"
            } else {
                finished.stage = .complete
                finished.answer = "the answer"
            }
            return finished
        }
    }

    /// Wraps a `StubRunner` and records the history each run was handed.
    private final class RecordingRunner: ResearchRunning {
        let inner: StubRunner
        let record: ([ResearchTurn]) -> Void

        init(inner: StubRunner, record: @escaping ([ResearchTurn]) -> Void) {
            self.inner = inner
            self.record = record
        }

        func run(_ turn: ResearchTurn, mode: ResearchRunner.Mode,
                 history turns: [ResearchTurn],
                 onUpdate: @escaping (ResearchTurn) -> Void) async -> ResearchTurn {
            record(turns)
            return await inner.run(turn, mode: mode, history: turns, onUpdate: onUpdate)
        }
    }

    /// A `deliver` that enqueues callbacks rather than running them. The semaphore
    /// signals each enqueue, so a test can wait until the runner has reported and
    /// then deliver the callbacks by hand.
    private final class HopQueue {
        private var work: [() -> Void] = []
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)

        var deliver: (@escaping () -> Void) -> Void {
            { [self] block in
                self.lock.lock()
                self.work.append(block)
                self.lock.unlock()
                self.semaphore.signal()
            }
        }

        /// Waits for `count` runner callbacks to be enqueued.
        func expect(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
            for _ in 0..<count {
                XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success,
                               "timed out waiting for a runner callback",
                               file: file, line: line)
            }
        }

        /// Delivers everything enqueued so far.
        func drain() {
            lock.lock()
            let pending = work
            work.removeAll()
            lock.unlock()
            pending.forEach { $0() }
        }
    }

    /// A `SnapshotCoalescer` `after` that fires immediately. The coalescer's own
    /// pacing is covered by its tests; here the session is what matters, and a
    /// timer that ran on a real clock would only make these tests slow and flaky.
    private func immediateAfter(_: TimeInterval, _ work: @escaping () -> Void) {
        work()
    }

    private func makeSession(
        runner: StubRunner,
        deliver: @escaping (@escaping () -> Void) -> Void = { $0() }
    ) -> ResearchSession {
        ResearchSession(
            thread: ResearchThread(),
            preferences: CorePreferences(store: MemorySettingsStore()),
            secrets: EphemeralSecretStore(),
            logSink: SilentLog(),
            attachmentStore: AttachmentStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)),
            makeRunner: { _, _, _ in runner },
            deliver: deliver,
            after: immediateAfter)
    }

    // MARK: Tests

    func testACompletedRunSettlesTheSession() {
        let hops = HopQueue()
        let session = makeSession(runner: StubRunner(), deliver: hops.deliver)
        var changes = 0
        session.onChange = { _ in changes += 1 }

        XCTAssertEqual(session.ask("question"), .started)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(changes, 1)   // the appended turn

        // One snapshot, then the finishing delivery.
        hops.expect(2)
        hops.drain()

        XCTAssertEqual(session.thread.turns.count, 1)
        XCTAssertEqual(session.thread.turns.first?.stage, .complete)
        XCTAssertEqual(session.thread.turns.first?.answer, "the answer")
        XCTAssertFalse(session.isRunning)
    }

    func testAskWhileRunningQueues() {
        let gate = Gate()
        let runner = StubRunner(gate: gate)
        let session = makeSession(runner: runner)

        XCTAssertEqual(session.ask("first"), .started)
        XCTAssertEqual(session.ask("second"), .queued)
        XCTAssertEqual(session.queue.count, 1)
        XCTAssertEqual(session.queue.first?.question, "second")
        session.discard()
        // `Gate.wait` is not cancellation-aware: the cancelled task stays parked on
        // the gate unless it is released, which is also what proves a discarded
        // session ignores the finish that finally lands.
        gate.release()
    }

    func testTheFourthQuestionIsRefused() {
        let gate = Gate()
        let session = makeSession(runner: StubRunner(gate: gate))
        session.ask("first")
        for i in 1...ResearchSession.maxQueued {
            XCTAssertEqual(session.ask("queued \(i)"), .queued)
        }
        XCTAssertEqual(session.ask("one too many"), .queueFull)
        XCTAssertEqual(session.queue.count, ResearchSession.maxQueued)
        session.discard()
        gate.release()   // let the cancelled run finish rather than leak a parked task
    }

    func testACompletedRunStartsTheNextQueuedQuestion() {
        let hops = HopQueue()
        let runner = StubRunner()
        let session = makeSession(runner: runner, deliver: hops.deliver)

        session.ask("first")
        XCTAssertEqual(session.ask("second"), .queued)

        hops.expect(2)
        hops.drain()

        // The finish of "first" starts "second" inside the same drain, so a second
        // pair of callbacks is enqueued for it.
        hops.expect(2)
        hops.drain()

        XCTAssertEqual(runner.runCount, 2)
        XCTAssertEqual(session.queue.count, 0)
        XCTAssertEqual(session.thread.turns.map(\.question), ["first", "second"])
        XCTAssertTrue(session.thread.turns.allSatisfy { $0.stage == .complete })
        XCTAssertFalse(session.isRunning)
    }

    func testAFailedRunHandsTheQueueBack() {
        let hops = HopQueue()
        let session = makeSession(runner: StubRunner(fails: true), deliver: hops.deliver)
        var returned: [ResearchSession.QueuedQuestion] = []
        session.onQueueReturned = { _, questions in returned = questions }

        session.ask("first")
        session.ask("second")
        session.ask("third")

        hops.expect(2)
        hops.drain()

        XCTAssertEqual(session.thread.turns.first?.stage, .failed)
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(returned.map(\.question), ["second", "third"])
        XCTAssertFalse(session.isRunning)
    }

    func testCancelReturnsTheQueueAndMarksTheTurnCancelled() {
        let hops = HopQueue()
        let gate = Gate()
        let session = makeSession(runner: StubRunner(gate: gate), deliver: hops.deliver)
        var returned: [ResearchSession.QueuedQuestion] = []
        session.onQueueReturned = { _, questions in returned = questions }

        session.ask("first")
        session.ask("second")
        session.cancel()

        XCTAssertEqual(returned.map(\.question), ["second"])
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.thread.turns.first?.stage, .cancelled)

        // The cancelled run still reports back; its landing changes nothing.
        gate.release()
        hops.expect(2)
        hops.drain()
        XCTAssertEqual(session.thread.turns.first?.stage, .cancelled)
        XCTAssertFalse(session.isRunning)
    }

    func testDiscardStopsTheRunAndSealsIt() {
        let hops = HopQueue()
        let gate = Gate()
        let runner = StubRunner(gate: gate)
        let session = makeSession(runner: runner, deliver: hops.deliver)
        var changes = 0
        session.onChange = { _ in changes += 1 }
        var returned: [ResearchSession.QueuedQuestion] = []
        session.onQueueReturned = { _, questions in returned = questions }

        session.ask("first")
        session.ask("second")
        session.discard()

        XCTAssertTrue(session.isDiscarded)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertTrue(returned.isEmpty)   // a deleted thread's queue is not handed back

        // A discarded session takes no new questions…
        XCTAssertEqual(session.ask("later"), .ignored)
        // …and the finishing run's callbacks change nothing: the turn keeps the
        // `.queued` stage it was appended with, which is why a deleted thread cannot
        // be re-saved with its late answer attached.
        gate.release()
        hops.expect(2)
        hops.drain()
        XCTAssertEqual(session.thread.turns.first?.stage, .queued)
    }

    func testRetryAsksTheTurnsQuestionAgain() {
        let hops = HopQueue()
        let runner = StubRunner(fails: true)
        let session = makeSession(runner: runner, deliver: hops.deliver)

        session.ask("question")
        hops.expect(2)
        hops.drain()
        XCTAssertEqual(session.thread.turns.first?.stage, .failed)

        // Now a succeeding runner for the retry — `makeRunner` answers whatever the
        // session asks for, so the second attempt gets its own script.
        let retryRunner = StubRunner()
        let retried = ResearchSession(
            thread: session.thread,
            preferences: CorePreferences(store: MemorySettingsStore()),
            secrets: EphemeralSecretStore(),
            logSink: SilentLog(),
            attachmentStore: AttachmentStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)),
            makeRunner: { _, _, _ in retryRunner },
            deliver: hops.deliver,
            after: immediateAfter)
        retried.retry(session.thread.turns.first!.id)

        hops.expect(2)
        hops.drain()
        XCTAssertEqual(retryRunner.runCount, 1)
        XCTAssertEqual(retried.thread.turns.count, 1)
        XCTAssertEqual(retried.thread.turns.first?.stage, .complete)
    }

    func testLocalTurnsStayOutOfHistoryAndPersistence() {
        let hops = HopQueue()
        var seenHistory: [[String]] = []
        let runner = StubRunner()
        let session = ResearchSession(
            thread: ResearchThread(),
            preferences: CorePreferences(store: MemorySettingsStore()),
            secrets: EphemeralSecretStore(),
            logSink: SilentLog(),
            attachmentStore: AttachmentStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)),
            makeRunner: { _, _, _ in
                RecordingRunner(inner: runner, record: { seenHistory.append($0.map(\.question)) })
            },
            deliver: hops.deliver,
            after: immediateAfter)

        var turn = ResearchTurn(question: "")
        turn.answer = "help text"
        turn.stage = .complete
        session.appendLocalTurn(turn)

        XCTAssertEqual(session.thread.turns.count, 1)
        XCTAssertTrue(session.persistableThread.turns.isEmpty)

        session.ask("real question")
        hops.expect(2)
        hops.drain()
        XCTAssertEqual(seenHistory, [[]])   // the local turn was not sent as history
    }
}
