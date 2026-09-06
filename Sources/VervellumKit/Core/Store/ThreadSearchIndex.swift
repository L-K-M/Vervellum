import Foundation

/// A precomputed, lowercased haystack per thread, for interactive search.
///
/// `ThreadLibrary.search` lowercases every question and every answer on each call,
/// and the history view calls it on every keystroke — with a full library (200
/// threads of multi-KB answers) that is megabytes of lowercasing per keystroke.
/// The haystacks change only when the library does, so they are built once and
/// reused: searching this index is O(threads), not O(total answer bytes).
///
/// Pure and dependency-free, so it is fully unit-testable.
struct ThreadSearchIndex {

    private var haystacks: [UUID: String]

    init(library: ThreadLibrary) {
        var built: [UUID: String] = [:]
        built.reserveCapacity(library.threads.count)
        for thread in library.threads {
            var parts = [thread.title]
            for turn in thread.turns {
                parts.append(turn.question)
                parts.append(turn.answer)
            }
            built[thread.id] = parts.joined(separator: "\n").lowercased()
        }
        haystacks = built
    }

    /// Threads matching `query`, newest first — the same semantics and ordering as
    /// `ThreadLibrary.search`. A thread absent from the index (built before the
    /// thread existed) simply never matches, rather than matching stale text.
    func search(_ query: String, in library: ThreadLibrary) -> [ResearchThread] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return library.threads }
        return library.threads.filter { haystacks[$0.id]?.contains(needle) ?? false }
    }
}
