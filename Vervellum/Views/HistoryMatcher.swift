import Foundation

/// One worker per query. Streaming updates can replace the library before a
/// long search finishes. Reusing completed rows lets the next pass make progress.
actor HistoryMatcher {
    private let needle: String
    private var cache: [UUID: (thread: ResearchThread, matches: Bool)] = [:]

    init(needle: String) { self.needle = needle }

    func matches(in library: ThreadLibrary) throws -> Set<UUID> {
        var matches: Set<UUID> = []
        var live: Set<UUID> = []
        for thread in library.threads {
            try Task.checkCancellation()
            live.insert(thread.id)
            let found: Bool
            if let cached = cache[thread.id], cached.thread == thread {
                found = cached.matches
            } else {
                found = ThreadLibrary.matches(thread, needle: needle)
                cache[thread.id] = (thread, found)
            }
            if found { matches.insert(thread.id) }
        }
        cache = cache.filter { live.contains($0.key) }
        return matches
    }
}
