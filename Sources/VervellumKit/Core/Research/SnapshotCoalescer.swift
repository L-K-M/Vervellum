import Foundation
import Dispatch

/// Rate-limits the snapshots a streaming research turn produces before they reach the
/// UI, without ever delaying the moments the user is waiting for.
///
/// A streamed answer arrives as dozens of snapshots a second, and each one republishes
/// the thread — re-running markdown parsing, citation validation and text layout for
/// the whole visible answer. Most of that work is thrown away a token later. The Linux
/// front end already coalesces these redraws to ~10 Hz (see `LinuxPanel.apply`); this
/// type gives the macOS engine the same behavior with the same rule:
///
/// * A **structural** change — a stage transition, sources or verdicts arriving, a
///   notice, a failure — publishes immediately. These are the moments a run visibly
///   progresses, and delaying them would make the panel feel sluggish in a way that
///   cannot be measured but is immediately obvious.
/// * Anything else (a streamed answer growing by a few characters) is *answer growth*:
///   the latest snapshot replaces any pending one and is published at most once per
///   `interval`. Answer growth is the one kind of change for which 100 ms of latency is
///   invisible, because the next chunk is already on its way.
///
/// Ordering guarantees: snapshots publish in the order received (a pending snapshot is
/// always superseded, never skipped past), a structural or explicit `flush()` publishes
/// before anything scheduled, and the final snapshot of a run should be handed to the
/// owner to apply directly after `discardPending()` so nothing scheduled can overwrite
/// the terminal state.
///
/// **Main-thread only.** Both front ends deliver runner callbacks onto their UI thread
/// before reaching this type; the lock-free state below relies on that.
final class SnapshotCoalescer {

    /// What separates a snapshot the UI must see at once from one that can wait a
    /// fraction of a second. Everything except the answer's growth is structural.
    ///
    /// Pure and static so it can be unit-tested apart from the scheduling.
    static func isStructural(_ new: ResearchTurn, relativeTo old: ResearchTurn) -> Bool {
        new.stage != old.stage
            || new.reading != old.reading
            || new.searches != old.searches
            || new.sources.count != old.sources.count
            || new.findings.count != old.findings.count
            || new.limitations != old.limitations
            || new.followups != old.followups
            || new.notices != old.notices
            || new.failure != old.failure
            || new.duration != old.duration
    }

    private let interval: TimeInterval
    private let now: () -> Date
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let publish: (ResearchTurn) -> Void

    private var pending: ResearchTurn?
    private var previous: ResearchTurn?
    private var flushScheduled = false
    private var lastPublish: Date?
    /// Bumped whenever pending state is resolved, so a flush already scheduled for a
    /// superseded snapshot can recognise itself as stale and do nothing.
    private var generation = 0

    /// - Parameters:
    ///   - interval: the maximum time an answer-growth snapshot may wait.
    ///   - now: clock, injectable for tests.
    ///   - after: schedules work after a delay on the caller's queue, injectable for
    ///     tests. Default is the main dispatch queue, which is the queue this type is
    ///     documented to live on.
    ///   - publish: receives the snapshots that may be shown.
    init(interval: TimeInterval = 0.1,
         now: @escaping () -> Date = { Date() },
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void =
             { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
         publish: @escaping (ResearchTurn) -> Void) {
        self.interval = interval
        self.now = now
        self.after = after
        self.publish = publish
    }

    // MARK: Receiving

    func receive(_ snapshot: ResearchTurn) {
        let structural = previous.map { Self.isStructural(snapshot, relativeTo: $0) } ?? true
        previous = snapshot

        guard !structural else {
            publishNow(snapshot)
            return
        }

        // Answer growth: the newest snapshot is always the whole truth, so an older
        // pending one is replaced rather than queued behind.
        pending = snapshot
        guard !flushScheduled else { return }

        // Schedule relative to the last publish, not to now: a structural snapshot
        // that just published resets the budget, so growth following it waits the full
        // interval rather than sneaking in immediately.
        let elapsed = lastPublish.map { now().timeIntervalSince($0) } ?? 0
        let delay = max(0, interval - elapsed)
        flushScheduled = true
        let scheduledGeneration = generation
        after(delay) { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.flushScheduled = false
            self.publishPending()
        }
    }

    /// Publishes any waiting snapshot immediately. Call when the UI must not wait —
    /// panel dismissal, termination, a screenshot.
    func flush() {
        publishPending()
    }

    /// Drops any waiting snapshot without publishing it. Call when a newer, complete
    /// snapshot is about to be applied by other means — the final turn of a run — so a
    /// stale scheduled flush cannot overwrite it.
    func discardPending() {
        generation += 1
        flushScheduled = false
        pending = nil
    }

    // MARK: Private

    private func publishNow(_ snapshot: ResearchTurn) {
        generation += 1
        flushScheduled = false
        pending = nil
        lastPublish = now()
        publish(snapshot)
    }

    private func publishPending() {
        guard let snapshot = pending else { return }
        publishNow(snapshot)
    }
}
