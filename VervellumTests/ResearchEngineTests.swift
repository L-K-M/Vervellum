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

        func finish() {
            lock.lock()
            var snapshot = turn!
            let continuation = completion!
            completion = nil
            lock.unlock()
            snapshot.stage = .failed
            continuation.resume(returning: snapshot)
        }
    }
}
