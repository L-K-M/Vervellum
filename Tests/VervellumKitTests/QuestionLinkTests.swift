import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// Links the user pastes into a question: finding them, naming them, and merging the
/// pages behind them with what the searches found.
///
/// The runner itself still needs a live model and a live search server to drive, so
/// what is pinned here is every decision the runner makes *about* those links that can
/// be made without one — which is all of the numbering, and numbering is what citations
/// rest on.
final class QuestionLinkTests: XCTestCase {

    // MARK: Finding the links

    func testReadsLinksInTheOrderTheyWereTyped() {
        let question = "Compare https://b.example.com/two with https://a.example.com/one please"
        XCTAssertEqual(SourceHarvester.links(inQuestion: question, limit: 3),
                       ["https://b.example.com/two", "https://a.example.com/one"])
    }

    /// The same address twice is one page. Reading it twice would spend two requests to
    /// put one page's text under two numbers, which reads as two sources agreeing.
    func testCollapsesARepeatedLink() {
        let question = "https://example.com/a — and again https://example.com/a"
        XCTAssertEqual(SourceHarvester.links(inQuestion: question, limit: 3),
                       ["https://example.com/a"])
        // Pinned, because the two numbers are compared against each other to decide
        // whether any link was left behind: a count of occurrences against a list of
        // pages would report a link dropped every time a question named one page twice.
        XCTAssertEqual(SourceHarvester.linkCount(inQuestion: question), 1,
                       "linkCount counts distinct pages, not occurrences")
    }

    /// The same page addressed two ways is still one page.
    ///
    /// This is what a real paste looks like: a browser hands over the fragment it was
    /// scrolled to, the trailing slash it displays, and the `utm_` tag by which the
    /// reader arrived. Compared byte for byte those are three pages, and the turn would
    /// read one document three times and number it three ways.
    func testCollapsesAddressesThatDifferOnlyInWhatABrowserAdded() {
        let question = "https://example.com/paper#results and https://example.com/paper/"
            + " and https://WWW.Example.com/paper?utm_source=news"
        XCTAssertEqual(SourceHarvester.links(inQuestion: question, limit: 3),
                       ["https://example.com/paper#results"],
                       "the first spelling is kept, because it is the one the user wrote")
        XCTAssertEqual(SourceHarvester.linkCount(inQuestion: question), 1)
    }

    /// The other half of that rule: only what cannot change which document is served is
    /// folded away. A different path — or a query item that is not attribution — is a
    /// different page, and collapsing two real pages loses evidence.
    func testKeepsAddressesThatCouldSelectADifferentDocument() {
        let question = "https://example.com/a https://example.com/A"
            + " https://example.com/a?page=2 https://example.com/a/b"
        XCTAssertEqual(SourceHarvester.linkCount(inQuestion: question), 4)
        // The name promises the addresses are kept, so assert the addresses. A bug that
        // dropped or reordered one while keeping the count consistent would otherwise
        // pass.
        XCTAssertEqual(SourceHarvester.links(inQuestion: question, limit: 4),
                       ["https://example.com/a", "https://example.com/A",
                        "https://example.com/a?page=2", "https://example.com/a/b"])
    }

    /// A path's parentheses are part of the address, and the pattern cannot include them.
    ///
    /// This is the single most-pasted URL shape after a news link, and without the repair
    /// it is cut mid-path and fetched as a page that does not exist.
    func testPutsBackAParenthesisThatBelongsToThePath() {
        XCTAssertEqual(
            SourceHarvester.links(inQuestion: "See https://en.wikipedia.org/wiki/Mercury_(planet).",
                                  limit: 3),
            ["https://en.wikipedia.org/wiki/Mercury_(planet)"])
        // Nested, closed one at a time.
        XCTAssertEqual(
            SourceHarvester.links(inQuestion: "https://example.com/a_(b_(c))", limit: 3),
            ["https://example.com/a_(b_(c))"])
    }

    /// The other side of that rule, and the reason it is scoped to a question rather than
    /// applied inside `bareURLs`: a parenthesis that closes prose is punctuation, and the
    /// match never opened one.
    func testDoesNotSwallowAParenthesisThatClosesTheSentence() {
        XCTAssertEqual(SourceHarvester.links(inQuestion: "(see https://example.com/a)", limit: 3),
                       ["https://example.com/a"])
        // Nor invents an ending the question does not carry.
        XCTAssertEqual(SourceHarvester.links(inQuestion: "https://example.com/a_(b and more",
                                             limit: 3),
                       ["https://example.com/a_(b"])
    }

    /// `http` is half of "http(s)" and every other scheme test is a negative one.
    func testPlainHTTPLinksAreHarvested() {
        XCTAssertEqual(SourceHarvester.links(inQuestion: "Read http://example.com/page", limit: 3),
                       ["http://example.com/page"])
    }

    /// The key is built from the address as written. `%2F` decoded to "/" would turn one
    /// path segment into two, and `%2B` decoded to "+" is a different value — either
    /// folds two real documents onto one key, which loses evidence.
    func testTheKeyDoesNotDecodeWhatWouldChangeTheAddress() {
        XCTAssertNotEqual(SourceHarvester.canonicalKey(for: "https://example.com/a%2Fb"),
                          SourceHarvester.canonicalKey(for: "https://example.com/a/b"))
        XCTAssertNotEqual(SourceHarvester.canonicalKey(for: "https://example.com/q?a=%2B"),
                          SourceHarvester.canonicalKey(for: "https://example.com/q?a=+"))
    }

    /// The limit counts pages, not occurrences: the duplicate must not use up a slot
    /// that the second distinct link needs.
    func testTheLimitCountsDistinctPages() {
        let question = "https://a.example.com/1 https://a.example.com/1 https://b.example.com/2"
        XCTAssertEqual(SourceHarvester.links(inQuestion: question, limit: 2),
                       ["https://a.example.com/1", "https://b.example.com/2"])
    }

    func testKeepsOnlyTheFirstLinksPastTheLimit() {
        let question = "https://a.example.com https://b.example.com https://c.example.com"
        XCTAssertEqual(SourceHarvester.links(inQuestion: question, limit: 2),
                       ["https://a.example.com", "https://b.example.com"])
        XCTAssertEqual(SourceHarvester.linkCount(inQuestion: question), 3)
    }

    /// A question is prose, so a link at the end of a sentence carries a full stop that
    /// is punctuation and not path. Fetching "…/a." is a 404 for a page that exists.
    func testTrimsSentencePunctuationFromALink() {
        XCTAssertEqual(SourceHarvester.links(inQuestion: "See https://example.com/a.", limit: 3),
                       ["https://example.com/a"])
        // The two other ways a sentence ends around a link. "What is …/a?" is the most
        // natural phrasing there is, and a kept "?" 404s exactly as a kept "." would.
        XCTAssertEqual(SourceHarvester.links(inQuestion: "See https://example.com/a,", limit: 3),
                       ["https://example.com/a"])
        XCTAssertEqual(SourceHarvester.links(inQuestion: "What is https://example.com/a?",
                                             limit: 3),
                       ["https://example.com/a"])
        // And a real query is not punctuation: the "?" that opens one has to survive.
        XCTAssertEqual(SourceHarvester.links(inQuestion: "See https://example.com/s?q=x.",
                                             limit: 3),
                       ["https://example.com/s?q=x"])
    }

    /// Nothing but http(s) is a link Vervellum will fetch. A question that mentions a
    /// file path or an ftp address has not asked for a page to be read.
    func testIgnoresWhatIsNotAnHTTPLink() {
        let question = "Check file:///etc/passwd and ftp://example.com/x and just example.com"
        XCTAssertTrue(SourceHarvester.links(inQuestion: question, limit: 3).isEmpty)
        XCTAssertEqual(SourceHarvester.linkCount(inQuestion: question), 0)
    }

    func testAQuestionWithNoLinksAsksForNothing() {
        XCTAssertTrue(SourceHarvester.links(inQuestion: "How tall is Ben Nevis?", limit: 3).isEmpty)
    }

    /// A zero budget is asked for whenever the caller has already spent the turn's
    /// allowance, and must not be read as "no limit".
    func testAZeroLimitReadsNothing() {
        XCTAssertTrue(SourceHarvester.links(inQuestion: "https://example.com/a", limit: 0).isEmpty)
    }

    // MARK: Naming them

    func testNamesALinkedSourceAfterTheAddressTheUserTyped() {
        XCTAssertEqual(ResearchRunner.linkTitle(for: "https://www.example.com/docs/spec"),
                       "example.com/docs/spec")
        XCTAssertEqual(ResearchRunner.linkTitle(for: "https://example.com/"), "example.com")
        XCTAssertEqual(ResearchRunner.linkTitle(for: "https://example.com"), "example.com")
        // Host and path only, on purpose. A title is what the reader scans to recognise
        // where a claim came from, and a tracking parameter or a scroll position is noise
        // in that job — the source list still carries the address itself. The port goes
        // with them: two ports on one host is a case worth nothing against the noise the
        // rule removes on every other turn. Pinned so it stays a decision.
        XCTAssertEqual(ResearchRunner.linkTitle(for: "https://example.com/a?utm_source=news"),
                       "example.com/a")
        XCTAssertEqual(ResearchRunner.linkTitle(for: "https://example.com/a#results"),
                       "example.com/a")
        XCTAssertEqual(ResearchRunner.linkTitle(for: "https://example.com:8443/a"),
                       "example.com/a")
    }

    // MARK: Merging them with the search results

    /// The links are the turn's first sources. `ResearchContext.evidence` keeps a
    /// prefix, so this ordering is also what decides that a full evidence block drops a
    /// search hit before it drops the page the question pointed at.
    func testLinkedPagesAreNumberedFirstAndSearchHitsFollow() {
        let linked = [Source(number: 1, url: "https://linked.example.com/a",
                             title: "linked.example.com/a", snippet: "Pasted.")]
        let payload: [String: Any] = ["results": [
            ["title": "First hit", "url": "https://a.example.com/1", "snippet": "One."],
            ["title": "Second hit", "url": "https://b.example.com/2", "snippet": "Two."],
        ]]
        let combined = ResearchRunner.combined(linked: linked, results: [payload])
        XCTAssertEqual(combined.map(\.number), [1, 2, 3])
        XCTAssertEqual(combined.map(\.url), ["https://linked.example.com/a",
                                             "https://a.example.com/1",
                                             "https://b.example.com/2"])
    }

    /// A search that surfaces the page the user already linked must not give it a second
    /// number: two entries for one page is a source list claiming evidence it does not
    /// have. `EvidenceExtractor` cannot catch this itself — it never sees the linked
    /// sources, which did not come from a search result.
    func testASearchHitForALinkedPageIsNotNumberedTwice() {
        let shared = "https://example.com/paper"
        let linked = [Source(number: 1, url: shared, title: "example.com/paper", snippet: "Pasted.")]
        let payload: [String: Any] = ["results": [
            ["title": "The paper", "url": shared, "snippet": "Found by searching."],
            ["title": "Something else", "url": "https://other.example.com/x", "snippet": "Else."],
        ]]
        let combined = ResearchRunner.combined(linked: linked, results: [payload])
        XCTAssertEqual(combined.map(\.url), [shared, "https://other.example.com/x"])
        // Renumbered after the duplicate was dropped. A list numbered 1, 3 shows the
        // model a gap, and a gap is an invitation to cite the number that is missing.
        XCTAssertEqual(combined.map(\.number), [1, 2])
    }

    /// The linked page keeps the text that was read for it; merging must not rebuild it
    /// from the search hit that happens to point at the same URL.
    func testAMergedLinkedPageKeepsItsPageText() {
        let shared = "https://example.com/paper"
        var link = Source(number: 1, url: shared, title: "example.com/paper", snippet: "Excerpt.")
        link.fullText = "The whole page."
        let payload: [String: Any] = ["results": [["title": "The paper", "url": shared]]]
        let combined = ResearchRunner.combined(linked: [link], results: [payload])
        XCTAssertEqual(combined.count, 1)
        XCTAssertTrue(combined[0].wasRead)
        XCTAssertEqual(combined[0].fullText, "The whole page.")
    }

    /// With no links the turn must number its sources exactly as it did before this
    /// feature existed — every thread already on disk was written that way.
    func testWithoutLinksTheNumberingIsUnchanged() {
        let payload: [String: Any] = ["results": [
            ["title": "First", "url": "https://a.example.com/1", "snippet": "One."],
            ["title": "Second", "url": "https://b.example.com/2", "snippet": "Two."],
        ]]
        // Compared field by field: `Source` is Equatable over its `id` too, and these are
        // two independently built lists, so each entry carries a fresh UUID.
        let combined = ResearchRunner.combined(linked: [], results: [payload])
        let direct = EvidenceExtractor.sources(from: [payload])
        XCTAssertEqual(combined.map(\.number), direct.map(\.number))
        XCTAssertEqual(combined.map(\.url), direct.map(\.url))
        XCTAssertEqual(combined.map(\.title), direct.map(\.title))
    }

    func testLinkedPagesAloneAreTheWholeSourceList() {
        let linked = [Source(number: 1, url: "https://example.com/a",
                             title: "example.com/a", snippet: "Pasted.")]
        // Whole-value equality, which includes `Source.id`. Safe only because `combined`
        // hands the linked sources straight back when nothing was found; a version that
        // rebuilt them would carry fresh UUIDs and fail here despite being correct.
        XCTAssertEqual(ResearchRunner.combined(linked: linked, results: []), linked)
    }

    // MARK: The planner is told, and only when there is something to tell

    func testThePlanPromptDescribesLinkedPagesOnlyWhenThereAreSome() {
        let without = ResearchPrompts.plan(maxSearches: 4, today: "2026-09-08")
        XCTAssertFalse(without.contains("linked_pages"),
                       "a prompt naming a key the payload does not carry invites the model "
                       + "to explain its absence")

        let with = ResearchPrompts.plan(maxSearches: 4, today: "2026-09-08", hasLinkedPages: true)
        XCTAssertTrue(with.contains("linked_pages"))
        // The whole point of reading first: plan for what is still missing, not for the
        // page that is already on the table.
        XCTAssertTrue(with.contains("already been read"))
        // The empty-plan escape has to admit the "just read this for me" case, or a
        // question answered entirely by its link still burns a search — and it must not
        // offer that escape to a question that linked nothing.
        XCTAssertTrue(with.contains("the linked pages settle on their own"))
        XCTAssertFalse(without.contains("linked pages settle"))
        // One list, one "or", in both spellings. Appending the linked case to a list
        // that already ended in "or …" put two in the same sentence, which reads as two
        // separate decisions rather than one list of cases.
        XCTAssertTrue(with.contains("pure preference, a request to transform text the "
                                    + "user supplied, or a question the linked pages "
                                    + "settle on their own"), with)
        XCTAssertTrue(without.contains("pure preference, or a request to transform text "
                                       + "the user supplied"), without)
    }
}
