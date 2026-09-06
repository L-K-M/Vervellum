import Foundation

/// Everything Vervellum keeps on disk between launches: past research threads.
///
/// Versioned from the first release. `version` is checked on load and a document
/// claiming a *newer* version is treated as read-only, because re-encoding it would
/// write fields this build lossily decoded back under the newer stamp — destroying
/// data a future build would have understood.
struct ThreadLibrary: Codable, Equatable {

    /// Bump this whenever the document gains a field or an enum case an older build
    /// could not decode. The stamp is the first thing an older build reads; a document
    /// that fails to decode *without* a newer stamp is taken for corruption instead.
    static let currentVersion = 1
    /// How many threads are kept. Old research is the least valuable thing on the
    /// disk and the file is read wholesale at launch, so the list is bounded.
    static let maxThreads = 200

    var version: Int = ThreadLibrary.currentVersion
    /// Newest first.
    var threads: [ResearchThread] = []

    /// Inserts or replaces `thread`, keeping the list newest-first and bounded.
    /// An empty thread is never stored: summoning the panel and dismissing it
    /// without asking anything should leave no trace.
    mutating func upsert(_ thread: ResearchThread) {
        threads.removeAll { $0.id == thread.id }
        guard !thread.isEmpty else { return }
        threads.insert(thread, at: 0)
        if threads.count > Self.maxThreads {
            threads.removeLast(threads.count - Self.maxThreads)
        }
    }

    mutating func remove(id: UUID) {
        threads.removeAll { $0.id == id }
    }

    /// What a turn says when the app stopped before its answer did.
    static let interruptedMessage = "Vervellum quit before this answer finished."

    /// Marks every turn that was still running when the document was written as failed.
    ///
    /// A turn is saved when it is asked and again when it finishes; between the two the
    /// file holds it as queued or answering. If the app crashed, was force-quit or the
    /// machine restarted in that window, the turn would otherwise come back as running
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
            }
        }
    }

    /// Threads whose title or any question matches `query`, newest first.
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
