import Foundation

/// Assembles the JSON context sent to the model, and enforces the size budget.
///
/// The budget matters more than it looks. Every provider has a context limit, and
/// the failure when you exceed it is not an error — it is a silently truncated
/// prompt and a confidently wrong answer. So Vervellum decides what to drop itself,
/// drops whole turns rather than cutting one mid-sentence, and **tells the user**
/// with a `contextTrimmed` notice. Silent truncation is the thing this type exists
/// to prevent.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum ResearchContext {

    /// Character ceiling on the assembled context. Chosen to sit inside a 32k-token
    /// model with room for the answer; a larger model just means fewer turns get
    /// dropped, never a different result.
    static let maxCharacters = 110_000
    /// Ceiling on the evidence block alone, so a verbose search provider cannot
    /// crowd out the conversation.
    static let maxEvidenceCharacters = 70_000
    /// Prior answers are summarised down to this length: the thread is there for
    /// pronoun resolution and follow-up context, not to be re-read in full.
    static let maxHistoricAnswerCharacters = 1_200

    /// The conversation context plus a flag saying whether anything was dropped.
    struct Assembled {
        var payload: [String: Any]
        var trimmed: Bool
    }

    /// Builds the context for the planning and answering calls.
    ///
    /// `history` is oldest-first. Turns are dropped from the *oldest* end, because
    /// the most recent exchange is what a follow-up question refers to.
    static func assemble(question: String,
                         history: [ResearchTurn],
                         today: String,
                         extra: [String: Any] = [:]) -> Assembled {
        // Each entry is encoded and measured once, then dropped from the front until
        // the total fits. Re-encoding the whole payload after every drop would be
        // quadratic, and a long-running thread is exactly where that would be felt.
        // Completed turns only, and only ones that were actually asked. A front end may
        // keep informational turns in a thread — the Linux panel renders `/help` as a
        // turn with an empty question — and sending those would feed the model its own
        // help text as conversation history.
        var entries = history
            .filter { $0.stage == .complete && !$0.question.isEmpty }
            .map(historyEntry)

        var payload: [String: Any] = extra
        payload["question"] = question
        payload["today"] = today
        payload["thread"] = [[String: Any]]()

        let fixedSize = measure(payload)
        // An explicit closure rather than `map(measure)`: passing an `(Any) -> Int`
        // function where `([String: Any]) -> Int` is expected relies on function
        // subtyping that type inference does not always resolve at a call site.
        var sizes = entries.map { measure($0) }
        var total = fixedSize + sizes.reduce(0, +)
        var trimmed = false

        while total > maxCharacters, !entries.isEmpty {
            total -= sizes.removeFirst()
            entries.removeFirst()
            trimmed = true
        }

        payload["thread"] = entries
        return Assembled(payload: payload, trimmed: trimmed)
    }

    /// One prior turn as the model sees it: the question, a shortened answer, and
    /// the domains that backed it. Verdicts are included because a follow-up like
    /// "why is that uncertain?" is unanswerable without them.
    ///
    /// The answer goes in with its citation markers removed. A `[2]` in last turn's
    /// answer indexed *last turn's* source list; shown to the model verbatim, it is an
    /// invitation to restate the claim with the same marker, which `CitationValidator`
    /// would accept as a citation of *this* turn's source 2 — a wrong attribution
    /// wearing a clean badge, which is exactly what citing by number is meant to make
    /// impossible. The domains that backed the earlier answer travel separately.
    private static func historyEntry(_ turn: ResearchTurn) -> [String: Any] {
        var entry: [String: Any] = [
            "question": turn.question,
            "answer": shorten(withoutCitationMarkers(turn.answer, sourceCount: turn.sources.count),
                              to: maxHistoricAnswerCharacters),
        ]
        let domains = Array(Set(turn.sources.map(\.domain))).sorted().prefix(8)
        if !domains.isEmpty { entry["source_domains"] = Array(domains) }
        let unsettled = turn.findings
            .filter { $0.verdict == .insufficient || $0.verdict == .mixed || $0.verdict == .contradicted }
            .map { ["claim": $0.claim, "verdict": $0.verdict.rawValue] }
        if !unsettled.isEmpty { entry["unsettled"] = Array(unsettled.prefix(5)) }
        return entry
    }

    /// The evidence block, trimmed to `maxEvidenceCharacters` by dropping the
    /// lowest-ranked sources — search tools return results in relevance order, so
    /// the tail is the cheapest thing to lose.
    ///
    /// It drops a *suffix*, stopping at the first entry that does not fit rather than
    /// skipping it and carrying on. Skipping would leave gaps in the citation numbering
    /// the model is shown — 1, 2, 4 — and a gap is an invitation to cite the number that
    /// is missing.
    static func evidence(from sources: [Source]) -> (entries: [[String: Any]], dropped: Int) {
        var entries: [[String: Any]] = []
        var used = 0
        for source in sources {
            var entry: [String: Any] = [
                "number": source.number,
                "title": source.title,
                "url": source.url,
                "snippet": source.snippet,
            ]
            if let published = source.publishedAt, !published.isEmpty { entry["published"] = published }
            let size = measure(entry)
            guard used + size <= maxEvidenceCharacters else { break }
            used += size
            entries.append(entry)
        }
        return (entries, sources.count - entries.count)
    }

    /// The answer with every `[n]` marker removed, and the space that carried it.
    ///
    /// `sourceCount` is the *earlier* turn's, so only markers that were real citations
    /// then are stripped; a bracketed number the validator would not have read as a
    /// citation (inside code, or out of range) is left as the text it was.
    static func withoutCitationMarkers(_ answer: String, sourceCount: Int) -> String {
        let spans = CitationValidator.validate(answer: answer, sourceCount: sourceCount).spans
        var result = ""
        for span in spans {
            switch span {
            case .text(let text):
                result += text
            case .citation:
                // Drop the space before the marker too, so "true [1]." reads "true.".
                while result.last == " " { result.removeLast() }
            }
        }
        return result
    }

    /// Serialized size of a payload, which is what the provider actually charges
    /// against its context — not the Swift string lengths.
    ///
    /// `isValidJSONObject` already accepts a top-level array, so it is the whole guard.
    /// An `|| value is [Any]` escape hatch would only ever admit an array that
    /// `isValidJSONObject` had just *rejected* — one holding a `Date` or a `UUID`, say —
    /// and hand it to a serializer that raises an Objective-C exception rather than
    /// throwing a catchable Swift error.
    static func measure(_ value: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return 0 }
        return data.count
    }

    /// Truncates on a paragraph boundary where possible, so a shortened answer still
    /// reads as prose rather than stopping mid-clause.
    static func shorten(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        if let breakPoint = cut.range(of: "\n\n", options: .backwards),
           cut.distance(from: cut.startIndex, to: breakPoint.lowerBound) > limit / 2 {
            return String(cut[..<breakPoint.lowerBound]) + "\n\n[…]"
        }
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + " […]"
        }
        return cut + " […]"
    }

    /// `today` in the form the prompts expect.
    static func todayString(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        // Setting the calendar does not set the time zone, and a formatter left on
        // the system zone would print yesterday's date for anyone west of UTC in the
        // evening — which the prompts then use to bias searches by recency.
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
