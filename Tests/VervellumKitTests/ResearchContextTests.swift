import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class ResearchContextTests: XCTestCase {

    private func turn(_ question: String, answer: String, stage: ResearchStage = .complete) -> ResearchTurn {
        var turn = ResearchTurn(question: question)
        turn.answer = answer
        turn.stage = stage
        return turn
    }

    func testIncludesCompletedTurnsOnly() {
        let history = [
            turn("Done", answer: "A"),
            turn("Failed", answer: "", stage: .failed),
            turn("Running", answer: "partial", stage: .answering),
        ]
        let assembled = ResearchContext.assemble(question: "Next?", history: history, today: "2026-09-05")
        let thread = assembled.payload["thread"] as? [[String: Any]] ?? []
        XCTAssertEqual(thread.count, 1)
        XCTAssertEqual(thread.first?["question"] as? String, "Done")
        XCTAssertFalse(assembled.trimmed)
    }

    /// A front end may keep informational turns in a thread — the Linux panel renders
    /// `/help` as a turn with no question — and those must never reach the model as
    /// conversation history.
    func testSkipsTurnsThatWereNeverAsked() {
        let history = [turn("Asked", answer: "A"), turn("", answer: "## Commands\n- /help")]
        let assembled = ResearchContext.assemble(question: "Next?", history: history, today: "2026-09-05")
        let thread = assembled.payload["thread"] as? [[String: Any]] ?? []
        XCTAssertEqual(thread.count, 1)
        XCTAssertEqual(thread.first?["question"] as? String, "Asked")
    }

    /// The single most important property of this type: when the budget is exceeded,
    /// whole turns are dropped from the *oldest* end and the caller is told, so a
    /// truncated prompt can never masquerade as a complete one.
    func testDropsOldestTurnsAndReportsIt() {
        // Each historic answer is shortened to `maxHistoricAnswerCharacters` before it
        // is measured, so it takes many turns rather than a few large ones to reach the
        // ceiling — which is exactly the case a real long-running thread hits.
        let big = String(repeating: "x", count: 4_000)
        let count = 200
        let history = (0..<count).map { turn("Q\($0)", answer: big) }
        let assembled = ResearchContext.assemble(question: "Now?", history: history, today: "2026-09-05")
        let thread = assembled.payload["thread"] as? [[String: Any]] ?? []
        XCTAssertTrue(assembled.trimmed)
        XCTAssertLessThan(thread.count, count)
        XCTAssertGreaterThan(thread.count, 0)
        // Whatever survived must be the most recent turns.
        XCTAssertEqual(thread.last?["question"] as? String, "Q\(count - 1)")
        XCTAssertLessThanOrEqual(ResearchContext.measure(assembled.payload), ResearchContext.maxCharacters)
    }

    func testHistoryBudgetIncludesJSONSeparators() {
        let history = [turn("First", answer: "A"), turn("Second", answer: "B")]
        let base = ResearchContext.assemble(question: "Q", history: history, today: "D")
        let padding = ResearchContext.maxCharacters - ResearchContext.measure(base.payload) + 1
        let context = ResearchContext.assemble(question: "Q" + String(repeating: "x", count: padding),
                                               history: history, today: "D")
        XCTAssertTrue(context.trimmed)
        XCTAssertLessThanOrEqual(ResearchContext.measure(context.payload), ResearchContext.maxCharacters)
    }

    /// Keep oversized questions intact; the request boundary rejects them locally.
    func testAlwaysReturnsAPayloadEvenWhenNothingFits() {
        let huge = String(repeating: "y", count: 400_000)
        let assembled = ResearchContext.assemble(question: huge, history: [], today: "2026-09-05")
        XCTAssertEqual(assembled.payload["question"] as? String, huge)
    }

    func testShortensHistoricAnswers() {
        let long = String(repeating: "z", count: 5_000)
        let assembled = ResearchContext.assemble(question: "Q", history: [turn("Old", answer: long)],
                                                 today: "2026-09-05")
        let thread = assembled.payload["thread"] as? [[String: Any]] ?? []
        let answer = thread.first?["answer"] as? String ?? ""
        XCTAssertLessThan(answer.count, long.count)
        XCTAssertTrue(answer.hasSuffix("[…]"))
        XCTAssertTrue(assembled.trimmed)
    }

    /// A `[2]` in last turn's answer indexed *last turn's* sources; passed on verbatim it
    /// invites the model to reuse it as a citation of this turn's source 2.
    func testStripsCitationMarkersFromHistoricAnswers() {
        var previous = turn("Old", answer: "X is true [1]. Both agree [1, 2]. Not [9].")
        previous.sources = [
            Source(number: 1, url: "https://a.example.com/", title: "A", snippet: ""),
            Source(number: 2, url: "https://b.example.com/", title: "B", snippet: ""),
        ]
        let assembled = ResearchContext.assemble(question: "And?", history: [previous], today: "2026-09-06")
        let thread = assembled.payload["thread"] as? [[String: Any]] ?? []
        let answer = thread.first?["answer"] as? String ?? ""
        XCTAssertEqual(answer, "X is true. Both agree. Not.")
        XCTAssertEqual(thread.first?["source_domains"] as? [String], ["a.example.com", "b.example.com"])
    }

    func testHistoryPreservesAssessmentFailureWithoutStaleReferences() {
        var previous = turn("Old", answer: "Unassessed [9]. Code `items[9]`.")
        previous.notices = [.assessmentUnavailable, .invalidCitation]
        previous.findings = [Finding(claim: "Unsettled [9]", verdict: .insufficient,
                                     reasoning: "", sourceNumbers: [])]
        let context = ResearchContext.assemble(question: "Summarize our findings", history: [previous], today: "D")
        let entry = (context.payload["thread"] as? [[String: Any]])?.first
        XCTAssertEqual(entry?["answer"] as? String, "Unassessed. Code `items[9]`.")
        XCTAssertEqual(entry?["notices"] as? [String], ["assessmentUnavailable", "invalidCitation"])
        let claims = entry?["unsettled"] as? [[String: String]]
        XCTAssertEqual(claims?.first?["claim"], "Unsettled")
    }

    func testCarriesUnsettledClaimsForward() {
        var previous = turn("Old", answer: "A")
        previous.findings = [
            Finding(claim: "Contested", verdict: .mixed, reasoning: "", sourceNumbers: [1]),
            Finding(claim: "Fine", verdict: .supported, reasoning: "", sourceNumbers: [1]),
        ]
        let assembled = ResearchContext.assemble(question: "Why?", history: [previous], today: "2026-09-05")
        let thread = assembled.payload["thread"] as? [[String: Any]] ?? []
        let unsettled = thread.first?["unsettled"] as? [[String: Any]] ?? []
        XCTAssertEqual(unsettled.count, 1)
        XCTAssertEqual(unsettled.first?["claim"] as? String, "Contested")
    }

    // MARK: Evidence budget

    /// The deep ceiling's whole point is that history can still trim to make room:
    /// a deep evidence budget at or above the context ceiling would make the
    /// evidence untrimmable and the turn unfixable. Pinned, because the constant's
    /// comment promises it and a number change would break it silently.
    func testTheDeepEvidenceCeilingStaysUnderTheContextCeiling() {
        XCTAssertLessThan(ResearchContext.maxDeepEvidenceCharacters,
                          ResearchContext.maxCharacters)
        XCTAssertGreaterThan(ResearchContext.maxDeepEvidenceCharacters,
                             ResearchContext.maxEvidenceCharacters)
    }

    /// The limit the runner actually gathers under must leave room for the fixed
    /// content and the streamed answer, not just for evidence.
    func testTheEvidenceLimitLeavesRoomForFixedContentAndTheAnswer() {
        // Even with nothing else in the payload, the answer reserve is charged: the
        // assessment carries the streamed answer on top of the evidence.
        XCTAssertEqual(
            ResearchContext.evidenceLimit(baseLimit: ResearchContext.maxDeepEvidenceCharacters,
                                          fixedContentBytes: 0),
            min(ResearchContext.maxDeepEvidenceCharacters,
                ResearchContext.maxCharacters - ResearchContext.answerContextReserve))
        let withAttachments = ResearchContext.evidenceLimit(
            baseLimit: ResearchContext.maxDeepEvidenceCharacters,
            fixedContentBytes: ResearchContext.maxAttachmentPayloadBytes)
        XCTAssertLessThan(withAttachments, ResearchContext.maxDeepEvidenceCharacters)
        // Fixed content plus the limit plus the answer reserve must fit the ceiling.
        XCTAssertLessThanOrEqual(
            ResearchContext.maxAttachmentPayloadBytes + withAttachments
                + ResearchContext.answerContextReserve,
            ResearchContext.maxCharacters)
        // Fixed content alone larger than the ceiling is not a negative limit.
        XCTAssertEqual(
            ResearchContext.evidenceLimit(baseLimit: ResearchContext.maxEvidenceCharacters,
                                          fixedContentBytes: ResearchContext.maxCharacters * 2),
            0)
    }

    /// Attachment text is capped per file in *characters*, so four files at that cap can
    /// be larger than the whole context ceiling (worse in UTF-8). The payload cap must
    /// trim the longest entries, mark the cut, and leave names and sent markers alone.
    func testCappingAttachmentTextFitsTheBudgetAndMarksTheCut() {
        let long = String(repeating: "研", count: Attachment.maxTextCharacters)
        let payload = (1...4).map { ["name": "file\($0).txt", "text": long] }
        XCTAssertGreaterThan(ResearchContext.measure(payload),
                             ResearchContext.maxCharacters,
                             "the premise: four max-size CJK files exceed the ceiling")

        let capped = ResearchContext.cappingAttachmentText(
            payload, to: ResearchContext.maxAttachmentPayloadBytes)
        XCTAssertTrue(capped.changed)
        XCTAssertLessThanOrEqual(ResearchContext.measure(capped.payload),
                               ResearchContext.maxAttachmentPayloadBytes)
        XCTAssertEqual(capped.payload.map { $0["name"] }, payload.map { $0["name"] })
        for entry in capped.payload {
            let text = entry["text"] ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.hasSuffix("[…]"),
                          "a cut file must say so: \(text.count) chars")
        }

        // A payload already under budget is untouched, including non-text entries.
        let small = [["name": "a.png", "sent": "yes"], ["name": "b.txt", "text": "short"]]
        let untouched = ResearchContext.cappingAttachmentText(
            small, to: ResearchContext.maxAttachmentPayloadBytes)
        XCTAssertFalse(untouched.changed)
        XCTAssertEqual(untouched.payload, small)
    }

    /// A budget below the payload's floor — every text entry at `[…]`, nothing left
    /// around it but names — cannot be met, and the trim loop used to spin on it
    /// forever: a floor entry was re-set to `[…]` with no size change, and the
    /// `keep < text.count` escape could never fire because `removeCharacters` is at
    /// least 1. Found by review; a test would have hung the suite rather than failed.
    /// The loop must terminate, hand back the floor payload, and still leave the
    /// entries that carry no text alone.
    func testCappingAttachmentTextTerminatesWhenNoFloorPayloadCanFit() {
        let payload = [
            ["name": "a.txt", "text": "attachment text that will not fit"],
            ["name": "b.png", "sent": "yes"],
            ["name": "c.txt", "text": "a second file, also cut"],
        ]
        // 0 and 10 bytes are both below what the floor payload measures, so no
        // amount of trimming can reach them.
        for budget in [0, 10] {
            let capped = ResearchContext.cappingAttachmentText(payload, to: budget)
            XCTAssertTrue(capped.changed, "budget \(budget): the files were cut")
            XCTAssertEqual(capped.payload.map { $0["name"] }, payload.map { $0["name"] },
                           "budget \(budget): names survive the floor")
            for entry in capped.payload where entry["text"] != nil {
                XCTAssertEqual(entry["text"], "[…]",
                               "budget \(budget): every text entry is at the floor")
            }
            XCTAssertEqual(capped.payload.first { $0["sent"] != nil }?["sent"], "yes",
                           "budget \(budget): non-text entries are never prose to cut")
            XCTAssertGreaterThan(ResearchContext.measure(capped.payload), budget,
                                 "budget \(budget): the floor genuinely cannot fit, which"
                                 + " is what makes this the impossible case")
        }
    }

    func testEvidenceIsBudgetedAndReportsWhatWasDropped() {
        let snippet = String(repeating: "e", count: 600)
        let sources = (1...200).map {
            Source(number: $0, url: "https://e\($0).example.com/x", title: "T\($0)",
                   snippet: snippet, publishedAt: nil)
        }
        let (entries, dropped, _) = ResearchContext.evidence(from: sources)
        XCTAssertGreaterThan(dropped, 0)
        XCTAssertLessThanOrEqual(ResearchContext.measure(entries), ResearchContext.maxEvidenceCharacters)
        XCTAssertEqual(entries.count + dropped, sources.count)
    }

    func testEvidenceBudgetIncludesArrayBrackets() {
        var source = Source(number: 1, url: "https://a.example", title: "A", snippet: "")
        let base = ResearchContext.evidence(from: [source]).entries
        let padding = ResearchContext.maxEvidenceCharacters - ResearchContext.measure(base) + 1
        source.snippet = String(repeating: "x", count: padding)
        let evidence = ResearchContext.evidence(from: [source])
        XCTAssertEqual(evidence.dropped, 1)
        XCTAssertLessThanOrEqual(ResearchContext.measure(evidence.entries), ResearchContext.maxEvidenceCharacters)
    }

    func testEvidenceKeepsNumbersAndOmitsAnEmptyDate() {
        let sources = [Source(number: 3, url: "https://a.example.com", title: "T",
                              snippet: "S", publishedAt: "")]
        let (entries, _, _) = ResearchContext.evidence(from: sources)
        XCTAssertEqual(entries.first?["number"] as? Int, 3)
        XCTAssertNil(entries.first?["published"])
    }

    // MARK: Page text

    /// A page Vervellum read reaches the model as `page_text`, beside the snippet rather
    /// than instead of it: the snippet is what the search engine said the page was for,
    /// and that framing is still worth having.
    func testAReadPageIsCarriedBesideItsSnippet() {
        var source = Source(number: 1, url: "https://a.example.com", title: "T", snippet: "S")
        source.fullText = "The page itself."
        let (entries, dropped, withheld) = ResearchContext.evidence(from: [source])
        XCTAssertEqual(dropped, 0)
        XCTAssertTrue(withheld.isEmpty)
        XCTAssertEqual(entries.first?["page_text"] as? String, "The page itself.")
        XCTAssertEqual(entries.first?["snippet"] as? String, "S")
    }

    func testAnUnreadSourceCarriesNoPageText() {
        let source = Source(number: 1, url: "https://a.example.com", title: "T", snippet: "S")
        let (entries, _, withheld) = ResearchContext.evidence(from: [source])
        XCTAssertNil(entries.first?["page_text"])
        XCTAssertTrue(withheld.isEmpty)
    }

    /// A source is never lost because its page was read: the page text is what gives
    /// way, and the source stays with its snippet.
    func testAPageTooLargeToFitIsWithheldWithoutLosingTheSource() {
        var first = Source(number: 1, url: "https://a.example.com", title: "A", snippet: "S")
        first.fullText = String(repeating: "p", count: ResearchContext.maxEvidenceCharacters)
        var second = Source(number: 2, url: "https://b.example.com", title: "B", snippet: "S")
        second.fullText = "Short enough."

        let (entries, dropped, withheld) = ResearchContext.evidence(from: [first, second])
        XCTAssertEqual(dropped, 0, "Both sources survive")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(withheld, [1])
        XCTAssertNil(entries.first?["page_text"], "The oversized page is the thing that gives way")
        XCTAssertEqual(entries.last?["page_text"] as? String, "Short enough.")
        XCTAssertLessThanOrEqual(ResearchContext.measure(entries),
                                 ResearchContext.maxEvidenceCharacters)
    }

    func testReadingAnEarlyPageCannotDisplaceLaterSourceMetadata() {
        var sources = (1...3).map {
            Source(number: $0, url: "https://e\($0).example", title: "Source", snippet: "Summary")
        }
        let metadata = ResearchContext.evidence(from: sources).entries
        let page = String(repeating: "p", count: 512)
        let limit = ResearchContext.measure(metadata) + page.utf8.count
        sources[0].fullText = page

        let result = ResearchContext.evidence(from: sources, limit: limit)
        XCTAssertEqual(result.entries.count, sources.count)
        XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(result.withheldPageText, [1])
        XCTAssertNil(result.entries.first?["page_text"])
        XCTAssertLessThanOrEqual(ResearchContext.measure(result.entries), limit)
    }

    func testTodayStringIsISOFormatted() {
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let text = ResearchContext.todayString(date, calendar: calendar)
        XCTAssertEqual(text.count, 10)
        XCTAssertEqual(text.filter { $0 == "-" }.count, 2)
    }

    func testMarkerStrippingHandlesWideRangesAndKeepsYears() {
        XCTAssertEqual(ResearchContext.withoutCitationMarkers("True [1-999999999]."), "True.")
        XCTAssertEqual(ResearchContext.withoutCitationMarkers("True [1000] [1-3]."), "True.")
        XCTAssertEqual(ResearchContext.withoutCitationMarkers("Restated in [2023] [2]."),
                       "Restated in [2023].")
    }
}
