import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class SnapshotCoalescerTests: XCTestCase {

    /// A scheduler that records work instead of running it, so tests decide when time
    /// "elapses" — and can assert what was *not* run.
    private final class ManualScheduler {
        var entries: [(delay: TimeInterval, generation: Int, work: () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            entries.append((delay, entries.count, work))
        }

        /// Runs the oldest entry, mirroring a serial queue's ordering.
        func runOldest() {
            guard !entries.isEmpty else { return }
            let entry = entries.removeFirst()
            entry.work()
        }

        var pendingCount: Int { entries.count }
    }

    private func turn(answer: String, stage: ResearchStage = .answering) -> ResearchTurn {
        var turn = ResearchTurn(question: "Q")
        turn.stage = stage
        turn.answer = answer
        return turn
    }

    // MARK: Structural changes

    func testTheFirstSnapshotPublishesImmediately() {
        var published: [String] = []
        let coalescer = SnapshotCoalescer(publish: { published.append($0.answer) })

        coalescer.receive(turn(answer: "a"))

        XCTAssertEqual(published, ["a"])
    }

    func testAStageChangePublishesImmediately() {
        var published: [ResearchStage] = []
        let coalescer = SnapshotCoalescer(publish: { published.append($0.stage) })

        coalescer.receive(turn(answer: "a", stage: .answering))
        coalescer.receive(turn(answer: "ab", stage: .assessing))

        XCTAssertEqual(published, [.answering, .assessing])
    }

    func testSourcesArrivingIsStructural() {
        var published: [Int] = []
        let coalescer = SnapshotCoalescer(publish: { published.append($0.sources.count) })

        coalescer.receive(turn(answer: "a"))
        var withSource = turn(answer: "ab")
        withSource.sources = [Source(number: 1, url: "https://example.com", title: "T", snippet: "S")]
        coalescer.receive(withSource)

        XCTAssertEqual(published, [0, 1])
    }

    // MARK: Answer growth

    func testAnswerGrowthCoalescesIntoTheNewestSnapshot() {
        let scheduler = ManualScheduler()
        var published: [String] = []
        let coalescer = SnapshotCoalescer(interval: 0.1, after: scheduler.schedule,
                                          publish: { published.append($0.answer) })

        coalescer.receive(turn(answer: "a"))            // first: immediate
        coalescer.receive(turn(answer: "ab"))           // growth: pending
        coalescer.receive(turn(answer: "abc"))          // growth: replaces pending

        XCTAssertEqual(published, ["a"])
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.runOldest()

        // Only the newest snapshot is published — the intermediate one never existed
        // as far as the UI is concerned.
        XCTAssertEqual(published, ["a", "abc"])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testAStructuralChangePublishesAndCancelsTheScheduledFlush() {
        let scheduler = ManualScheduler()
        var published: [String] = []
        let coalescer = SnapshotCoalescer(interval: 0.1, after: scheduler.schedule,
                                          publish: { published.append($0.answer) })

        coalescer.receive(turn(answer: "a"))
        coalescer.receive(turn(answer: "ab"))           // schedules a flush
        coalescer.receive(turn(answer: "abc", stage: .assessing))   // structural: immediate

        XCTAssertEqual(published, ["a", "abc"])

        scheduler.runOldest()                           // the stale flush must do nothing

        XCTAssertEqual(published, ["a", "abc"])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testFlushPublishesPendingWithoutWaiting() {
        let scheduler = ManualScheduler()
        var published: [String] = []
        let coalescer = SnapshotCoalescer(interval: 0.1, after: scheduler.schedule,
                                          publish: { published.append($0.answer) })

        coalescer.receive(turn(answer: "a"))
        coalescer.receive(turn(answer: "ab"))
        coalescer.flush()

        XCTAssertEqual(published, ["a", "ab"])

        scheduler.runOldest()                           // superseded flush: no-op

        XCTAssertEqual(published, ["a", "ab"])
    }

    func testDiscardPendingDropsTheWaitingSnapshot() {
        let scheduler = ManualScheduler()
        var published: [String] = []
        let coalescer = SnapshotCoalescer(interval: 0.1, after: scheduler.schedule,
                                          publish: { published.append($0.answer) })

        coalescer.receive(turn(answer: "a"))
        coalescer.receive(turn(answer: "ab"))
        coalescer.discardPending()                      // the caller is applying the final turn itself
        scheduler.runOldest()

        XCTAssertTrue(published == ["a"])
    }

    // MARK: Classification

    func testAnswerGrowthAloneIsNotStructural() {
        var before = turn(answer: "a")
        before.stage = .answering
        var after = turn(answer: "a longer answer")
        after.stage = .answering

        XCTAssertFalse(SnapshotCoalescer.isStructural(after, relativeTo: before))
    }

    func testNoticesAndFailureAreStructural() {
        var withNotice = turn(answer: "a")
        withNotice.notices = [.literalURL]
        XCTAssertTrue(SnapshotCoalescer.isStructural(withNotice, relativeTo: turn(answer: "a")))

        var failed = turn(answer: "a")
        failed.failure = "The provider connection failed or timed out. Please try again."
        XCTAssertTrue(SnapshotCoalescer.isStructural(failed, relativeTo: turn(answer: "a")))
    }
}
