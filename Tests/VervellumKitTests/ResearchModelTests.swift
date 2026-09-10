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

    // MARK: Thread library search

    func testSearchMatchesQuestionsAndAnswersCaseInsensitively() {
        var turn = ResearchTurn(question: "What is a tokamak?")
        turn.answer = "A toroidal magnetic confinement device."
        var thread = ResearchThread()
        thread.turns = [turn]
        var library = ThreadLibrary()
        library.threads = [thread]

        XCTAssertEqual(library.search("TOKAMAK").count, 1)
        XCTAssertEqual(library.search("tokamak").count, 1)
        XCTAssertEqual(library.search("TOROIDAL").count, 1)
        XCTAssertFalse(library.search("stellarator").contains(thread))
    }

    func testSearchBlankQueryReturnsEverythingTrimmedIsBlank() {
        var library = ThreadLibrary()
        library.threads = [ResearchThread()]
        XCTAssertEqual(library.search("").count, 1)
        XCTAssertEqual(library.search("   ").count, 1)
    }

    func testSearchKeepsNewestFirstOrder() {
        var older = ResearchThread()
        older.turns = [ResearchTurn(question: "About rust language")]
        var newer = ResearchThread()
        newer.turns = [ResearchTurn(question: "About rust the fungus")]
        var library = ThreadLibrary()
        library.threads = [newer, older]

        XCTAssertEqual(library.search("rust").map(\.id), [newer.id, older.id])
    }

    // MARK: Search progress

    /// A document written before `searchesCompleted` existed must still load: the
    /// counter is 0 ("nothing reported yet"), not a decode failure that would drop the
    /// user's whole library to the empty state. The fixture is the exact shape the
    /// previous build's encoder wrote — every old key present, only the new one absent.
    func testDecodesATurnWrittenBeforeSearchProgressExisted() throws {
        let json = """
        {"id": "1B4E2C5A-0000-0000-0000-000000000001",
         "question": "Q",
         "askedAt": "2026-01-01T00:00:00Z",
         "stage": "complete",
         "reading": "",
         "searches": [],
         "sources": [],
         "answer": "A",
         "findings": [],
         "limitations": "",
         "followups": [],
         "notices": [],
         "duration": 3,
         "model": "m"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let turn = try decoder.decode(ResearchTurn.self, from: Data(json.utf8))
        XCTAssertEqual(turn.searchesCompleted, 0)
        XCTAssertEqual(turn.answer, "A")
    }

    func testSearchProgressRoundTripsThroughCodable() throws {
        var turn = ResearchTurn(question: "Q")
        turn.searches = [PlannedSearch(purpose: "a", argumentsJSON: "{\"q\":\"a\"}"),
                         PlannedSearch(purpose: "b", argumentsJSON: "{\"q\":\"b\"}")]
        turn.searchesCompleted = 1

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ResearchTurn.self, from: encoder.encode(turn))
        XCTAssertEqual(decoded.searchesCompleted, 1)
    }

    func testRunningProgressCountsSearchesAttempted() {
        var turn = ResearchTurn(question: "Q")
        turn.stage = .searching
        turn.searches = [PlannedSearch(purpose: "a", argumentsJSON: "{\"q\":\"a\"}"),
                         PlannedSearch(purpose: "b", argumentsJSON: "{\"q\":\"b\"}"),
                         PlannedSearch(purpose: "c", argumentsJSON: "{\"q\":\"c\"}")]

        turn.searchesCompleted = 2
        XCTAssertEqual(turn.runningProgressLabel, "Searching the web · 2 of 3")

        // Nothing has finished yet: the first search is in flight, not zero of them done.
        turn.searchesCompleted = 0
        XCTAssertEqual(turn.runningProgressLabel, "Searching the web · 1 of 3")

        // A count past the end (a turn re-run mid-stage, a corrupted document) clamps
        // rather than reading "4 of 3".
        turn.searchesCompleted = 9
        XCTAssertEqual(turn.runningProgressLabel, "Searching the web · 3 of 3")
    }

    /// The read the panel could not previously report at all: a question's links are
    /// fetched *before* the plan exists, so the stage is still `.planning` and the panel
    /// used to say "Planning searches" for as long as three fetches take.
    func testAPreplanLinkReadSaysSoDespiteTheStage() {
        var turn = ResearchTurn(question: "Summarise https://example.com/a")
        turn.stage = .planning
        turn.pagesAttempted = 3
        turn.pagesInFlight = 3
        XCTAssertEqual(turn.runningProgressLabel, "Reading 3 pages")

        // And the moment the read returns it is the planning call the reader waits on,
        // which is what the stage already says.
        turn.pagesInFlight = 0
        XCTAssertEqual(turn.runningProgressLabel, ResearchStage.planning.label)
    }

    /// The count is a fact about *now*, not a tally left behind. Pages that *were* read
    /// — the two behind a pasted link, finished before the plan existed — leave
    /// `pagesAttempted` at 2 for the rest of the turn, and that must not displace the
    /// search progress, or a question beginning with a link would read "Reading 2 pages"
    /// for the whole search stage.
    ///
    /// A read genuinely in flight is the opposite case and outranks the searches
    /// deliberately: it is what the turn is waiting on, and reporting a search count
    /// while nothing is being searched is the confusion this field exists to end. The
    /// two are different facts, which is exactly why the label stopped inferring one
    /// from the other.
    func testSearchProgressOutranksPagesAlreadyReadButNotOnesInFlight() {
        var turn = ResearchTurn(question: "Summarise https://example.com/a")
        turn.stage = .searching
        turn.pagesAttempted = 2
        turn.searches = [PlannedSearch(purpose: "a", argumentsJSON: "{\"q\":\"a\"}"),
                         PlannedSearch(purpose: "b", argumentsJSON: "{\"q\":\"b\"}")]

        turn.searchesCompleted = 1
        XCTAssertEqual(turn.runningProgressLabel, "Searching the web · 1 of 2")

        // Still the searches once they are all in, because nothing is being fetched:
        // those two pages were read before the plan and are long since done.
        turn.searchesCompleted = 2
        XCTAssertEqual(turn.runningProgressLabel, "Searching the web · 2 of 2")

        // The second read — the pages behind the search results — says so itself.
        turn.pagesInFlight = 2
        XCTAssertEqual(turn.runningProgressLabel, "Reading 2 pages")

        turn.pagesInFlight = 1
        XCTAssertEqual(turn.runningProgressLabel, "Reading 1 page")
    }

    /// The state a link-question actually spends time in, and the one place the two
    /// facts are genuinely both true: the pre-plan fetch is still outstanding while the
    /// searches are only part done. In flight wins here too — it is what the turn is
    /// waiting on — and the precedence is pinned rather than left to the two tests that
    /// only ever ask it once the searches are finished.
    func testAnInFlightReadOutranksSearchesThatAreNotFinished() {
        var turn = ResearchTurn(question: "Summarise https://example.com/a")
        turn.stage = .searching
        turn.searches = [PlannedSearch(purpose: "a", argumentsJSON: "{\"q\":\"a\"}"),
                         PlannedSearch(purpose: "b", argumentsJSON: "{\"q\":\"b\"}")]
        turn.searchesCompleted = 1
        turn.pagesAttempted = 1
        turn.pagesInFlight = 1
        XCTAssertEqual(turn.runningProgressLabel, "Reading 1 page")

        // And the moment it lands, the searches are what is left to wait for.
        turn.pagesInFlight = 0
        XCTAssertEqual(turn.runningProgressLabel, "Searching the web · 1 of 2")
    }

    /// The reason the field counts rather than flags. A turn that read one pasted link
    /// and is now fetching the two pages behind its search results has attempted three,
    /// and is reading two. The label reports what is outstanding, which is the only
    /// number that describes what the user is waiting for.
    func testTheLabelCountsWhatIsInFlightNotWhatWasAttempted() {
        var turn = ResearchTurn(question: "Summarise https://example.com/a")
        turn.stage = .searching
        turn.searches = [PlannedSearch(purpose: "a", argumentsJSON: "{\"q\":\"a\"}")]
        turn.searchesCompleted = 1
        turn.pagesAttempted = 3
        turn.pagesInFlight = 2
        XCTAssertEqual(turn.runningProgressLabel, "Reading 2 pages")
    }

    /// The turn this feature created: a question answered by its own links, whose plan
    /// asked for no searches at all. There is no search progress to report, so the label
    /// must never read "Searching the web · 0 of 0" — a count of nothing presented as
    /// progress — whether or not a read is in flight.
    func testALinkOnlyTurnNeverReportsASearchCountOfNothing() {
        var turn = ResearchTurn(question: "Summarise https://example.com/a")
        turn.stage = .searching
        turn.searches = []
        turn.pagesAttempted = 3
        turn.pagesInFlight = 3
        XCTAssertEqual(turn.runningProgressLabel, "Reading 3 pages")

        turn.pagesInFlight = 0
        XCTAssertEqual(turn.runningProgressLabel, ResearchStage.searching.label)
    }

    /// The gap between the two branches: every search is in, and no page was attempted.
    /// The count is still the honest report there — nothing is being read — so it stays
    /// rather than falling through to the bare stage label.
    func testCompletedSearchesWithNoPagesStillReportTheCount() {
        var turn = ResearchTurn(question: "Q")
        turn.stage = .searching
        turn.searches = [PlannedSearch(purpose: "a", argumentsJSON: "{\"q\":\"a\"}")]
        turn.searchesCompleted = 1
        turn.pagesAttempted = 0
        XCTAssertEqual(turn.runningProgressLabel, "Searching the web · 1 of 1")
    }

    /// A count the runner never zeroed — a crash mid-read, a document from a build that
    /// did — must not leave a finished turn claiming to be fetching something.
    func testAFinishedTurnNeverClaimsToBeReading() {
        var turn = ResearchTurn(question: "Q")
        turn.pagesAttempted = 2
        turn.pagesInFlight = 2

        for stage in [ResearchStage.complete, .failed, .cancelled] {
            turn.stage = stage
            XCTAssertEqual(turn.runningProgressLabel, stage.label, "\(stage)")
        }
    }

    /// The field is new, so a thread written before it has to decode without it — and a
    /// thread saved *during* a read, which is the shape a crash mid-fetch leaves behind,
    /// must not come back claiming a request is still outstanding. A document is a record
    /// of a turn; nothing in one can be evidence about the network right now.
    func testAStoredTurnNeverDecodesAsReading() throws {
        func turn(withPagesInFlight field: String) throws -> ResearchTurn {
            let json = """
                {"id":"\(UUID().uuidString)","question":"Q","askedAt":"2026-09-08T12:00:00Z",
                 "stage":"searching","reading":"","searches":[],"sources":[],"answer":"",
                 \(field)"findings":[],"limitations":"","followups":[],"notices":[],"model":""}
                """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ResearchTurn.self, from: Data(json.utf8))
        }

        XCTAssertEqual(try turn(withPagesInFlight: "").pagesInFlight, 0)
        XCTAssertEqual(try turn(withPagesInFlight: "\"pagesInFlight\":3,").pagesInFlight, 0)
        // And the label written from that document says nothing about reading.
        XCTAssertEqual(try turn(withPagesInFlight: "\"pagesInFlight\":3,").runningProgressLabel,
                       ResearchStage.searching.label)

        // The other half of the same invariant, which the decoder cannot enforce alone:
        // the field is never written either. A key that reached a document would be a
        // count waiting for someone to make the decoder believe it.
        var reading = ResearchTurn(question: "Q")
        reading.pagesInFlight = 3
        let encoded = try JSONEncoder().encode(reading)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("pagesInFlight"))
    }

    /// A partial search count must not resurface once the turn has moved past searching.
    /// The label is gated on the stage, not on the counters, and a turn that began with a
    /// pasted link spends most of its life past that stage.
    func testSearchCountsDoNotResurfaceOnceTheTurnMovesOn() {
        var turn = ResearchTurn(question: "Summarise https://example.com/a")
        turn.searches = [PlannedSearch(purpose: "a", argumentsJSON: "{\"q\":\"a\"}"),
                         PlannedSearch(purpose: "b", argumentsJSON: "{\"q\":\"b\"}")]
        turn.searchesCompleted = 1
        turn.pagesAttempted = 2

        turn.stage = .answering
        XCTAssertEqual(turn.runningProgressLabel, ResearchStage.answering.label)
        turn.stage = .assessing
        XCTAssertEqual(turn.runningProgressLabel, ResearchStage.assessing.label)
    }

    func testRunningProgressFallsBackToTheStageLabel() {
        var turn = ResearchTurn(question: "Q")
        turn.stage = .planning
        XCTAssertEqual(turn.runningProgressLabel, ResearchStage.planning.label)

        // No planned searches to count: the bare label, not "0 of 0".
        turn.stage = .searching
        XCTAssertEqual(turn.runningProgressLabel, "Searching the web")
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
        // The revision keeps the draft so the findings above stay readable. A field that
        // went missing from the document would leave the table annotating prose that no
        // longer makes the claims — the exact thing keeping it prevents.
        turn.draftAnswer = "An answer that was wrong [1]."
        turn.searches = [try XCTUnwrap(PlannedSearch(purpose: "p", arguments: ["q": "x"]))]
        turn.duration = 12.5

        var thread = ResearchThread()
        thread.turns = [turn]
        var library = ThreadLibrary()
        library.upsert(thread, keeping: ThreadLibrary.defaultKeptThreads)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ThreadLibrary.self, from: encoder.encode(library))

        XCTAssertEqual(decoded.threads.first?.turns.first?.answer, "An answer [1].")
        XCTAssertEqual(decoded.threads.first?.turns.first?.draftAnswer,
                       "An answer that was wrong [1].")
        XCTAssertEqual(decoded.threads.first?.turns.first?.findings.first?.verdict, .mixed)
        XCTAssertEqual(decoded.threads.first?.turns.first?.notices, [.contextTrimmed])
        XCTAssertEqual(decoded.threads.first?.turns.first?.searches.first?.displayQuery, "x")
    }

    /// The upgrade path, which the round trip above cannot see: it writes the field and
    /// reads it back, so it would pass just as happily if a document *without* the field
    /// were undecodable. Every thread saved before the revision stage existed is such a
    /// document, and a `keyNotFound` here would take the whole library with it on the
    /// first launch after the update.
    func testATurnSavedBeforeTheRevisionStageStillLoads() throws {
        var turn = ResearchTurn(question: "Q")
        turn.stage = .complete
        turn.answer = "An answer [1]."
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try encoder.encode(turn)) as? [String: Any])
        // The document as an older build wrote it: no such key at all, rather than null.
        object.removeValue(forKey: "draftAnswer")
        // And a key no build writes, put there on purpose. `isRevising` is transient —
        // it has no `CodingKeys` case — so asserting it decodes false out of a document
        // this test encoded proves nothing: the encoder never wrote it either way. A
        // document that *does* carry it is the only thing that can tell "never written"
        // apart from "written and read back", and the second would strand a turn saved
        // mid-revision on "Revising…" for the rest of its life.
        object["isRevising"] = true

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ResearchTurn.self, from: try JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(decoded.answer, "An answer [1].")
        XCTAssertNil(decoded.draftAnswer)
        XCTAssertFalse(decoded.isRevising, "a persisted flag would outlive its request")
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

    /// A turn can move down the chain more than once, and the runner posts the notice on
    /// each switch. One row is what the reader should see: "a provider failed, so the
    /// next one answered" is a fact about the turn, not a tally. `addNotice` is what
    /// keeps that true, and nothing else does — the runner posts blindly.
    func testANoticePostedTwiceIsShownOnce() {
        var turn = ResearchTurn(question: "Q")
        turn.addNotice(.modelFellBack)
        turn.addNotice(.modelFellBack)
        XCTAssertEqual(turn.notices, [.modelFellBack])
        // And a different notice still gets its own row, so the guard above is a
        // deduplication rather than a first-one-wins.
        turn.addNotice(.noEvidence)
        XCTAssertEqual(turn.notices, [.modelFellBack, .noEvidence])
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
