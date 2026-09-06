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

    /// A single enormous turn cannot be dropped below one — the current question must
    /// still be sent.
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
        XCTAssertEqual(answer, "X is true. Both agree. Not [9].")
        XCTAssertEqual(thread.first?["source_domains"] as? [String], ["a.example.com", "b.example.com"])
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

    func testEvidenceIsBudgetedAndReportsWhatWasDropped() {
        let snippet = String(repeating: "e", count: 600)
        let sources = (1...200).map {
            Source(number: $0, url: "https://e\($0).example.com/x", title: "T\($0)",
                   snippet: snippet, publishedAt: nil)
        }
        let (entries, dropped) = ResearchContext.evidence(from: sources)
        XCTAssertGreaterThan(dropped, 0)
        XCTAssertLessThanOrEqual(ResearchContext.measure(entries), ResearchContext.maxEvidenceCharacters)
        XCTAssertEqual(entries.count + dropped, sources.count)
    }

    func testEvidenceKeepsNumbersAndOmitsAnEmptyDate() {
        let sources = [Source(number: 3, url: "https://a.example.com", title: "T",
                              snippet: "S", publishedAt: "")]
        let (entries, _) = ResearchContext.evidence(from: sources)
        XCTAssertEqual(entries.first?["number"] as? Int, 3)
        XCTAssertNil(entries.first?["published"])
    }

    func testTodayStringIsISOFormatted() {
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let text = ResearchContext.todayString(date, calendar: calendar)
        XCTAssertEqual(text.count, 10)
        XCTAssertEqual(text.filter { $0 == "-" }.count, 2)
    }
}
