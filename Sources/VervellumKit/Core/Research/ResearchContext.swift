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

    /// Serialized UTF-8 context ceiling, not a tokenizer guarantee. The request
    /// boundary rejects fixed content that cannot fit after history is removed.
    static let maxCharacters = 110_000
    /// Ceiling on the evidence block alone, so a verbose search provider cannot
    /// crowd out the conversation.
    static let maxEvidenceCharacters = 70_000
    /// The evidence ceiling for a `deep` turn, which reads up to
    /// `PageReaderFactory.maxDeepPages` pages at 8,000 characters each. The quick-turn
    /// ceiling would drop later rounds' sources — the gap-closers the rounds exist to
    /// find — to make room for round one's pages, which is the one thing a deep turn
    /// must not do quietly. Still under `maxCharacters`, so history trims first.
    static let maxDeepEvidenceCharacters = 100_000
    /// Prior answers are summarised down to this length: the thread is there for
    /// pronoun resolution and follow-up context, not to be re-read in full.
    static let maxHistoricAnswerCharacters = 1_200

    private static let maxHistoricDomains = 8
    private static let maxHistoricFindings = 5
    /// How many attachment names one historic turn contributes. The intake caps a
    /// question at four, so this only binds a turn written by another build — but every
    /// other list here is bounded, and an unbounded one is the kind of thing that grows
    /// every later turn's context without anybody noticing.
    private static let maxHistoricAttachments = 8
    private static let jsonArrayBoundaryBytes = 2
    private static let jsonSeparatorBytes = 1

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
        let summaries = history
            .filter { $0.stage == .complete && !$0.question.isEmpty }
            .map(historyEntry)
        var entries = summaries.map { $0.payload }

        var payload: [String: Any] = extra
        payload["question"] = question
        payload["today"] = today
        payload["thread"] = [[String: Any]]()

        let fixedSize = measure(payload)
        // An explicit closure rather than `map(measure)`: passing an `(Any) -> Int`
        // function where `([String: Any]) -> Int` is expected relies on function
        // subtyping that type inference does not always resolve at a call site.
        let sizes = entries.map { measure($0) }
        var total = fixedSize + sizes.reduce(0, +) + max(0, entries.count - 1) * jsonSeparatorBytes
        var trimmed = summaries.contains { $0.trimmed }
        var firstKept = 0

        while total > maxCharacters, firstKept < entries.count {
            total -= sizes[firstKept]
            if entries.count - firstKept > 1 { total -= jsonSeparatorBytes }
            firstKept += 1
            trimmed = true
        }

        entries.removeFirst(firstKept)
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
    private static func historyEntry(_ turn: ResearchTurn) -> (payload: [String: Any], trimmed: Bool) {
        let answer = withoutCitationMarkers(turn.answer)
        var entry: [String: Any] = [
            "question": turn.question,
            "answer": shorten(answer, to: maxHistoricAnswerCharacters),
        ]
        let domains = Array(Set(turn.sources.map(\.domain))).sorted()
        if !domains.isEmpty { entry["source_domains"] = Array(domains.prefix(maxHistoricDomains)) }
        let unsettled = turn.findings
            .filter { $0.verdict == .insufficient || $0.verdict == .mixed || $0.verdict == .contradicted }
            .map { ["claim": withoutCitationMarkers($0.claim), "verdict": $0.verdict.rawValue] }
        if !unsettled.isEmpty { entry["unsettled"] = Array(unsettled.prefix(maxHistoricFindings)) }
        if !turn.notices.isEmpty { entry["notices"] = turn.notices.map(\.rawValue) }
        // Names only, and deliberately so. The picture itself was sent on the turn it was
        // attached to and is not sent again — see `Attachment` — but a later turn that
        // says "the second one" is otherwise talking about something the model has no
        // record of ever seeing. This is what lets it answer "you attached a screenshot
        // earlier; attach it again and I can look" instead of contradicting the user.
        if !turn.attachments.isEmpty {
            entry["attached"] = Array(turn.attachments.prefix(maxHistoricAttachments).map(\.name))
        }
        return (entry, answer.count > maxHistoricAnswerCharacters
                || domains.count > maxHistoricDomains || unsettled.count > maxHistoricFindings
                // Names drop off the end like everything else here, and a caller told the
                // entry is whole would have no way to know some went missing.
                || turn.attachments.count > maxHistoricAttachments)
    }

    /// The evidence block, trimmed to `limit` by dropping the lowest-ranked
    /// sources — search tools return results in relevance order, so the tail is the
    /// cheapest thing to lose. `limit` defaults to the quick-turn ceiling; a deep turn
    /// passes `maxDeepEvidenceCharacters` for the reason given on that constant.
    ///
    /// It drops a *suffix*, stopping at the first entry that does not fit rather than
    /// skipping it and carrying on. Skipping would leave gaps in the citation numbering
    /// the model is shown — 1, 2, 4 — and a gap is an invitation to cite the number that
    /// is missing.
    ///
    /// A page Vervellum read is added as `page_text` on top of an entry that already
    /// fits, and only when it fits too. That ordering is the point: **a source is never
    /// lost because its page was read**, and a page whose text did not fit is reported
    /// in `withheldPageText` so the caller can clear it from the source list. A source
    /// listed as read whose text the model never saw would be the one overstatement this
    /// app cannot afford.
    static func evidence(from sources: [Source], limit: Int = maxEvidenceCharacters)
        -> (entries: [[String: Any]], dropped: Int, withheldPageText: Set<Int>) {
        var entries: [[String: Any]] = []
        var withheld: Set<Int> = []
        var used = jsonArrayBoundaryBytes
        for source in sources {
            var entry: [String: Any] = [
                "number": source.number,
                "title": source.title,
                "url": source.url,
                "snippet": source.snippet,
            ]
            if let published = source.publishedAt, !published.isEmpty { entry["published"] = published }
            let separator = entries.isEmpty ? 0 : jsonSeparatorBytes
            let bare = measure(entry) + separator
            guard used + bare <= limit else { break }

            if source.wasRead, let text = source.fullText {
                var withText = entry
                withText["page_text"] = text
                let full = measure(withText) + separator
                if used + full <= limit {
                    entry = withText
                    used += full
                } else {
                    withheld.insert(source.number)
                    used += bare
                }
            } else {
                used += bare
            }
            entries.append(entry)
        }
        return (entries, sources.count - entries.count, withheld)
    }

    /// The answer with every `[n]` marker removed, and the space that carried it.
    ///
    /// Remove even formerly invalid numbers: a later source list could make them valid.
    /// Code remains literal. Int.max admits every syntactically recognized citation.
    static func withoutCitationMarkers(_ answer: String) -> String {
        let spans = CitationValidator.validate(answer: answer, sourceCount: Int.max).spans
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
