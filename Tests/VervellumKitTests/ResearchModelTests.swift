import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class ResearchModelTests: XCTestCase {

    // MARK: Thread titles

    func testTitleUsesTheFirstQuestion() {
        var thread = ResearchThread()
        thread.turns = [ResearchTurn(question: "What is a tokamak?"),
                        ResearchTurn(question: "And a stellarator?")]
        XCTAssertEqual(thread.title, "What is a tokamak?")
    }

    func testTitleFallsBackWhenEmpty() {
        XCTAssertEqual(ResearchThread().title, "New thread")
    }

    func testTitleIsTruncatedOnAWordBoundary() {
        var thread = ResearchThread()
        thread.turns = [ResearchTurn(question: String(repeating: "alpha ", count: 40))]
        let title = thread.title
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, 61)
        XCTAssertFalse(title.contains("\n"))
    }

    func testTitleCollapsesNewlines() {
        var thread = ResearchThread()
        thread.turns = [ResearchTurn(question: "Line one\nLine two")]
        XCTAssertEqual(thread.title, "Line one Line two")
    }

    // MARK: Verdicts

    /// The asymmetry is the point: it forces the model into the honest buckets when
    /// it has no evidence.
    func testOnlyEvidentialVerdictsRequireSources() {
        XCTAssertTrue(Verdict.supported.requiresSources)
        XCTAssertTrue(Verdict.contradicted.requiresSources)
        XCTAssertTrue(Verdict.mixed.requiresSources)
        XCTAssertFalse(Verdict.insufficient.requiresSources)
        XCTAssertFalse(Verdict.opinion.requiresSources)
    }

    /// Meaning must never be carried by colour alone, so each verdict needs its own
    /// glyph and its own words.
    func testEveryVerdictHasADistinctGlyphAndLabel() {
        XCTAssertEqual(Set(Verdict.allCases.map(\.symbolName)).count, Verdict.allCases.count)
        XCTAssertEqual(Set(Verdict.allCases.map(\.label)).count, Verdict.allCases.count)
    }

    func testInsufficientDoesNotReadAsFalse() {
        XCTAssertEqual(Verdict.insufficient.label, "Not established")
    }

    // MARK: Sources

    func testDomainStripsTheSchemeAndWWW() {
        XCTAssertEqual(Source(number: 1, url: "https://www.example.com/a/b", title: "", snippet: "").domain,
                       "example.com")
        XCTAssertEqual(Source(number: 1, url: "https://sub.example.co.uk/a", title: "", snippet: "").domain,
                       "sub.example.co.uk")
    }

    func testDomainFallsBackToTheRawStringWhenUnparseable() {
        XCTAssertEqual(Source(number: 1, url: "nonsense", title: "", snippet: "").domain, "nonsense")
    }

    // MARK: Planned searches

    func testPlannedSearchRoundTripsItsArguments() throws {
        let search = try XCTUnwrap(PlannedSearch(purpose: "p",
                                                 arguments: ["search_query": "hello", "count": 5]))
        XCTAssertEqual(search.arguments["search_query"] as? String, "hello")
        XCTAssertEqual(search.arguments["count"] as? Int, 5)
        XCTAssertEqual(search.displayQuery, "hello")
    }

    /// Search tools name the query field inconsistently, so display must not depend
    /// on one spelling.
    func testDisplayQueryTriesTheCommonFieldNames() throws {
        for key in ["query", "q", "keyword", "text"] {
            let search = try XCTUnwrap(PlannedSearch(purpose: "p", arguments: [key: "the query"]))
            XCTAssertEqual(search.displayQuery, "the query", "failed for key \(key)")
        }
    }

    func testDisplayQueryFallsBackToTheLongestString() throws {
        let search = try XCTUnwrap(PlannedSearch(purpose: "p",
                                                 arguments: ["unknown_field": "a longer value", "x": "s"]))
        XCTAssertEqual(search.displayQuery, "a longer value")
    }

    // MARK: Persistence

    func testATurnSurvivesACodableRoundTrip() throws {
        var turn = ResearchTurn(question: "Q")
        turn.stage = .complete
        turn.answer = "An answer [1]."
        turn.sources = [Source(number: 1, url: "https://example.com", title: "T", snippet: "S")]
        turn.findings = [Finding(claim: "C", verdict: .mixed, reasoning: "R", sourceNumbers: [1])]
        turn.notices = [.contextTrimmed]
        turn.searches = [try XCTUnwrap(PlannedSearch(purpose: "p", arguments: ["q": "x"]))]
        turn.duration = 12.5

        var thread = ResearchThread()
        thread.turns = [turn]
        var library = ThreadLibrary()
        library.upsert(thread)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ThreadLibrary.self, from: encoder.encode(library))

        XCTAssertEqual(decoded.threads.first?.turns.first?.answer, "An answer [1].")
        XCTAssertEqual(decoded.threads.first?.turns.first?.findings.first?.verdict, .mixed)
        XCTAssertEqual(decoded.threads.first?.turns.first?.notices, [.contextTrimmed])
        XCTAssertEqual(decoded.threads.first?.turns.first?.searches.first?.displayQuery, "x")
    }

    /// Retry has to know how a turn was asked, and the document does not store it: a
    /// `/direct` turn and a turn the planner decided needed no search both carry the
    /// no-evidence notice, and only the second has a reading.
    func testDirectTurnsAreToldApartFromPlannerDecidedOnes() {
        var direct = ResearchTurn(question: "Q")
        direct.notices = [.noEvidence]
        XCTAssertTrue(direct.wasAskedDirectly)

        var plannerDecided = ResearchTurn(question: "Q")
        plannerDecided.reading = "Pure arithmetic; no evidence needed."
        plannerDecided.addNotice(.noEvidence)
        XCTAssertFalse(plannerDecided.wasAskedDirectly)

        XCTAssertFalse(ResearchTurn(question: "Q").wasAskedDirectly)
    }

    // MARK: Stages

    func testTerminalStages() {
        XCTAssertTrue(ResearchStage.complete.isTerminal)
        XCTAssertTrue(ResearchStage.failed.isTerminal)
        XCTAssertTrue(ResearchStage.cancelled.isTerminal)
        XCTAssertFalse(ResearchStage.planning.isTerminal)
        XCTAssertFalse(ResearchStage.searching.isTerminal)
        XCTAssertFalse(ResearchStage.answering.isTerminal)
        XCTAssertFalse(ResearchStage.assessing.isTerminal)
        XCTAssertFalse(ResearchStage.queued.isTerminal)
    }

    // MARK: Copying a turn

    /// Copying prose whose `[3]` markers point at nothing would be worse than useless.
    func testPlainTextCarriesTheCitedSources() {
        var turn = ResearchTurn(question: "Why?")
        turn.answer = "Because of this [1], though not that [2]."
        turn.sources = [
            Source(number: 1, url: "https://one.example.com", title: "One", snippet: ""),
            Source(number: 2, url: "https://two.example.com", title: "Two", snippet: ""),
            Source(number: 3, url: "https://three.example.com", title: "Three", snippet: ""),
        ]
        turn.limitations = "Only summaries."

        let text = turn.transcript
        XCTAssertTrue(text.contains("Why?"))
        XCTAssertTrue(text.contains("[1] One — https://one.example.com"))
        XCTAssertTrue(text.contains("[2] Two — https://two.example.com"))
        XCTAssertFalse(text.contains("three.example.com"), "an uncited source must not be listed")
        XCTAssertTrue(text.contains("Limitations: Only summaries."))
    }

    func testDurationFormatting() {
        XCTAssertEqual(Formatting.duration(4.2), "4.2s")
        XCTAssertEqual(Formatting.duration(95), "1:35")
        XCTAssertEqual(Formatting.duration(-1), "—")
    }
}

/// A stored document from a newer build must stay readable by an older one.
final class TurnNoticeDecodingTests: XCTestCase {

    func testAnUnknownNoticeDecodesRatherThanFailingTheDocument() throws {
        let data = Data(#"["contextTrimmed", "somethingFromTheFuture"]"#.utf8)
        let notices = try JSONDecoder().decode([TurnNotice].self, from: data)
        XCTAssertEqual(notices, [.contextTrimmed, .unknown])
        XCTAssertFalse(TurnNotice.unknown.message.isEmpty)
    }

    func testKnownNoticesRoundTrip() throws {
        let original: [TurnNotice] = [.noEvidence, .assessmentUnavailable, .unreadableVerdictDropped]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode([TurnNotice].self, from: data), original)
    }
}
