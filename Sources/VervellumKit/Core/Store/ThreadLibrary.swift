import Foundation

/// Everything Vervellum keeps on disk between launches: past research threads.
///
/// Versioned from the first release. `version` is checked on load and a document
/// claiming a *newer* version is treated as read-only, because re-encoding it would
/// write fields this build lossily decoded back under the newer stamp — destroying
/// data a future build would have understood.
struct ThreadLibrary: Codable, Equatable {

    /// Version 2 adds tolerant notices. Future readers preflight this stamp; releases
    /// predating that protection cannot safely open this schema, even with a bump.
    static let currentVersion = 2
    /// How many threads are kept when the reader has expressed no preference.
    ///
    /// Old research is the least valuable thing on the disk and the file is read
    /// wholesale at launch, so the list is always bounded — the setting moves the bound,
    /// it does not remove it.
    static let defaultKeptThreads = 200

    /// What the setting may be set to.
    ///
    /// The floor is not zero: "keep nothing" is what turning history off means, and a
    /// zero here would be a second, quieter way to say it that also threw away the
    /// thread being written. The ceiling is where reading the file wholesale at launch
    /// starts to be felt.
    static let keptThreadsRange = 10...2000

    var version: Int = ThreadLibrary.currentVersion
    /// Newest first.
    var threads: [ResearchThread] = []

    /// Inserts or replaces `thread`, keeping the list newest-first and bounded.
    /// An empty thread is never stored: summoning the panel and dismissing it
    /// without asking anything should leave no trace.
    mutating func upsert(_ thread: ResearchThread,
                         keeping limit: Int = ThreadLibrary.defaultKeptThreads) {
        threads.removeAll { $0.id == thread.id }
        guard !thread.isEmpty else { return }
        threads.insert(thread, at: 0)
        prune(to: limit)
    }

    /// Drops the oldest threads past `limit`.
    ///
    /// Separate from `upsert` because lowering the setting has to take effect on threads
    /// that are already on disk. A bound that only applied to new writes would leave a
    /// reader who asked to keep fifty looking at two hundred until they had asked two
    /// hundred more questions.
    ///
    /// The limit is clamped rather than trusted: it arrives from a settings file that a
    /// crash, a sync or a hand edit can leave holding anything, and a zero there would
    /// silently erase the history.
    @discardableResult
    mutating func prune(to limit: Int) -> Int {
        let bounded = min(max(limit, Self.keptThreadsRange.lowerBound),
                          Self.keptThreadsRange.upperBound)
        guard threads.count > bounded else { return 0 }
        let dropped = threads.count - bounded
        threads.removeLast(dropped)
        return dropped
    }

    mutating func remove(id: UUID) {
        threads.removeAll { $0.id == id }
    }

    /// What a turn says when the app stopped before its answer did.
    static let interruptedMessage = "Vervellum quit before this answer finished."

    /// Marks every turn that was still running when the document was written as failed.
    ///
    /// Active turns are checkpointed, so the file may hold queued or answering work.
    /// After a crash, force-quit or restart, the turn would otherwise come back as running
    /// forever: a spinner nothing will ever stop, no way to retry, and a dead question
    /// sent to the model as history on the next follow-up. Whatever answer had arrived
    /// is kept.
    mutating func finishInterruptedTurns() {
        for threadIndex in threads.indices {
            for turnIndex in threads[threadIndex].turns.indices
            where !threads[threadIndex].turns[turnIndex].stage.isTerminal {
                threads[threadIndex].turns[turnIndex].stage = .failed
                threads[threadIndex].turns[turnIndex].failure = Self.interruptedMessage
                threads[threadIndex].turns[turnIndex].duration = nil
                let sourceCount = threads[threadIndex].turns[turnIndex].sources.count
                threads[threadIndex].turns[turnIndex].applyCitationValidation(sourceCount: sourceCount)
            }
        }
    }

    /// Threads whose questions or answers match `query`, newest first.
    ///
    /// Case-insensitive via `range(of:options:)` rather than lowercasing both sides:
    /// the search field re-runs this on every keystroke, and `lowercased()` on every
    /// answer in a full library allocates a copy of each — megabytes of transient
    /// strings per keystroke for a 200-thread library. `range` walks in place.
    func search(_ query: String) -> [ResearchThread] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return threads }
        return threads.filter { thread in
            thread.turns.contains { turn in
                turn.question.range(of: needle, options: .caseInsensitive) != nil
                    || turn.answer.range(of: needle, options: .caseInsensitive) != nil
            }
        }
    }
}
