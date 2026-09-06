import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class PlanParserTests: XCTestCase {

    func testParsesAWellFormedPlan() throws {
        // Written as typed locals rather than a nested literal: in an `Any` position a
        // heterogeneous or empty collection literal has no inferable type.
        let searches: [[String: Any]] = [
            ["purpose": "release notes", "arguments": ["search_query": "Swift 6 concurrency"]],
            ["purpose": "counter-evidence", "arguments": ["search_query": "Swift 6 opt out"]],
        ]
        let object: [String: Any] = [
            "reading": "Whether Swift 6 ships strict concurrency by default.",
            "searches": searches,
        ]
        let plan = try PlanParser.parse(object, maxSearches: 4)
        XCTAssertEqual(plan.searches.count, 2)
        XCTAssertEqual(plan.searches[0].purpose, "release notes")
        XCTAssertEqual(plan.searches[0].displayQuery, "Swift 6 concurrency")
    }

    /// An explicitly empty plan is a valid decision — "this needs no evidence" — and
    /// must not be confused with a malformed one.
    func testAnEmptySearchListIsValid() throws {
        let object: [String: Any] = ["reading": "Pure arithmetic.", "searches": [Any]()]
        let plan = try PlanParser.parse(object, maxSearches: 4)
        XCTAssertTrue(plan.searches.isEmpty)
        XCTAssertEqual(plan.reading, "Pure arithmetic.")
    }

    func testRejectsAMissingSearchList() {
        let object: [String: Any] = ["reading": "x"]
        XCTAssertThrowsError(try PlanParser.parse(object, maxSearches: 4))
    }

    /// Each planned search is a billed request; an over-long plan is refused rather
    /// than silently truncated.
    func testRejectsTooManySearches() {
        let searches: [[String: Any]] = (0..<9).map { ["arguments": ["search_query": "q\($0)"]] }
        let object: [String: Any] = ["searches": searches]
        XCTAssertThrowsError(try PlanParser.parse(object, maxSearches: 4))
    }

    /// Models routinely put the arguments at the top level instead of nesting them.
    /// Accepting that costs nothing and saves a retry.
    func testAcceptsTopLevelArguments() throws {
        let searches: [[String: Any]] = [["purpose": "p", "search_query": "top level"]]
        let plan = try PlanParser.parse(["searches": searches], maxSearches: 4)
        XCTAssertEqual(plan.searches.first?.displayQuery, "top level")
    }

    func testRejectsAnEntryWithNoArguments() {
        let searches: [[String: Any]] = [["purpose": "p"]]
        XCTAssertThrowsError(try PlanParser.parse(["searches": searches], maxSearches: 4))
    }
}

final class AssessmentParserTests: XCTestCase {

    private func finding(_ verdict: String, sources: [Any]) -> [String: Any] {
        ["claim": "A claim", "verdict": verdict, "reasoning": "Because.", "sources": sources]
    }

    func testParsesFindingsAndFollowups() throws {
        let object: [String: Any] = [
            "findings": [finding("supported", sources: [1, 2])],
            "limitations": "Only summaries were read.",
            "followups": ["What about 2025?", "  ", "And the EU?"],
        ]
        let assessment = try AssessmentParser.parse(object, sourceCount: 3)
        XCTAssertEqual(assessment.findings.count, 1)
        XCTAssertEqual(assessment.findings[0].verdict, .supported)
        XCTAssertEqual(assessment.findings[0].sourceNumbers, [1, 2])
        XCTAssertEqual(assessment.followups, ["What about 2025?", "And the EU?"])
    }

    /// The rule that separates a verdict from a vibe: an evidential verdict with no
    /// citation is the model's prior, so it is dropped and the user is told.
    func testDropsAnEvidentialVerdictWithNoSources() throws {
        let object: [String: Any] = ["findings": [finding("supported", sources: [Any]())]]
        let assessment = try AssessmentParser.parse(object, sourceCount: 3)
        XCTAssertTrue(assessment.findings.isEmpty)
        XCTAssertTrue(assessment.notices.contains(.uncitedVerdictDropped))
    }

    /// "We found nothing" is its own verdict and must survive without a citation.
    func testKeepsInsufficientAndOpinionWithoutSources() throws {
        let object: [String: Any] = [
            "findings": [finding("insufficient", sources: [Any]()), finding("opinion", sources: [Any]())],
        ]
        let assessment = try AssessmentParser.parse(object, sourceCount: 3)
        XCTAssertEqual(assessment.findings.count, 2)
        XCTAssertTrue(assessment.findings.allSatisfy { $0.sourceNumbers.isEmpty })
    }

    /// The requirement is that an evidential verdict must cite *something*, not that
    /// the others must not: naming the sources that failed to settle a claim is more
    /// useful than a bare "not established".
    func testKeepsCitationsOnANotEstablishedVerdict() throws {
        let object: [String: Any] = ["findings": [finding("insufficient", sources: [1, 2])]]
        let assessment = try AssessmentParser.parse(object, sourceCount: 3)
        XCTAssertEqual(assessment.findings.count, 1)
        XCTAssertEqual(assessment.findings.first?.verdict, .insufficient)
        XCTAssertEqual(assessment.findings.first?.sourceNumbers, [1, 2])
        XCTAssertTrue(assessment.notices.isEmpty)
    }

    func testStripsOutOfRangeSourceNumbersAndFlagsThem() throws {
        let object: [String: Any] = ["findings": [finding("mixed", sources: [1, 99])]]
        let assessment = try AssessmentParser.parse(object, sourceCount: 2)
        XCTAssertEqual(assessment.findings.first?.sourceNumbers, [1])
        XCTAssertTrue(assessment.notices.contains(.invalidCitation))
    }

    /// Providers differ on whether a JSON integer survives their serialisation.
    func testAcceptsSourceNumbersAsStringsOrDoubles() throws {
        let object: [String: Any] = ["findings": [finding("supported", sources: ["1", 2.0])]]
        let assessment = try AssessmentParser.parse(object, sourceCount: 3)
        XCTAssertEqual(assessment.findings.first?.sourceNumbers, [1, 2])
    }

    func testSkipsUnparseableFindingsWithoutFailingTheTurn() throws {
        let entries: [[String: Any]] = [
            ["claim": "", "verdict": "supported", "sources": [1]],
            ["claim": "Real", "verdict": "not-a-verdict", "sources": [1]],
            finding("supported", sources: [1]),
        ]
        let assessment = try AssessmentParser.parse(["findings": entries], sourceCount: 2)
        XCTAssertEqual(assessment.findings.count, 1)
    }

    func testCapsFindingsAndFollowups() throws {
        let object: [String: Any] = [
            "findings": Array(repeating: finding("supported", sources: [1]), count: 30),
            "followups": ["a", "b", "c", "d", "e"],
        ]
        let assessment = try AssessmentParser.parse(object, sourceCount: 2)
        XCTAssertEqual(assessment.findings.count, AssessmentParser.maxFindings)
        XCTAssertEqual(assessment.followups.count, AssessmentParser.maxFollowups)
    }

    func testRejectsAMissingFindingsKey() {
        let object: [String: Any] = ["limitations": "x"]
        XCTAssertThrowsError(try AssessmentParser.parse(object, sourceCount: 2))
    }
}

/// The shapes a model actually writes, read the way the prompt meant them.
final class LenientAssessmentFieldTests: XCTestCase {

    func testReadsSourceNumbersInEveryShape() {
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: [1, 3]), [1, 3])
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: "1, 3"), [1, 3])
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: "[1]"), [1])
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: "1 and 3"), [1, 3])
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: 2), [2])
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: 2.0), [2])
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: ["[1]", "2-3"]), [1, 2, 3])
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: nil), [])
    }

    /// A model's JSON can say `1e308`; that must be a dropped number, not a trap.
    func testRefusesNumbersThatDoNotFitOrCannotBeCitations() {
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: 1e308), [])
        XCTAssertEqual(AssessmentParser.sourceNumbers(from: "see 1234"), [])
    }

    /// The bug this guards against: a *supported* verdict that cited "1, 2" as a string
    /// was dropped with "A verdict that cited no source was discarded" — blaming the
    /// model for a citation it made.
    func testAStringOfSourcesKeepsAnEvidentialVerdict() throws {
        let entries: [[String: Any]] = [["claim": "X", "verdict": "supported", "sources": "1, 2"]]
        let assessment = try AssessmentParser.parse(["findings": entries], sourceCount: 2)
        XCTAssertEqual(assessment.findings.first?.sourceNumbers, [1, 2])
        XCTAssertFalse(assessment.notices.contains(.uncitedVerdictDropped))
    }

    func testReadsVerdictSynonymsAndPadding() {
        XCTAssertEqual(AssessmentParser.verdict(from: " Supported "), .supported)
        XCTAssertEqual(AssessmentParser.verdict(from: "Not established"), .insufficient)
        XCTAssertEqual(AssessmentParser.verdict(from: "not_established"), .insufficient)
        XCTAssertEqual(AssessmentParser.verdict(from: "refuted"), .contradicted)
        XCTAssertEqual(AssessmentParser.verdict(from: "Partially supported"), .mixed)
        XCTAssertEqual(AssessmentParser.verdict(from: "subjective"), .opinion)
        XCTAssertNil(AssessmentParser.verdict(from: 3))
    }

    /// "unsupported" means "no evidence" to some models and "false" to others. Mapping
    /// it either way would collapse *not established* into *false* for half of them.
    func testTheAmbiguousWordIsNotGuessed() {
        XCTAssertNil(AssessmentParser.verdict(from: "unsupported"))
    }

    func testAnUnreadableVerdictIsReportedRatherThanDroppedSilently() throws {
        let entries: [[String: Any]] = [["claim": "X", "verdict": "unsupported", "sources": [1]]]
        let assessment = try AssessmentParser.parse(["findings": entries], sourceCount: 2)
        XCTAssertTrue(assessment.findings.isEmpty)
        XCTAssertTrue(assessment.notices.contains(.unreadableVerdictDropped))
    }
}
