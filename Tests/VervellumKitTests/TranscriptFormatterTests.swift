import XCTest
#if canImport(VervellumKit)
@testable import VervellumKit
#else
@testable import Vervellum
#endif

/// One formatter feeds the macOS Copy button and the Linux command line, so these
/// assertions cover both.
final class TranscriptFormatterTests: XCTestCase {

    private func turn() -> ResearchTurn {
        var turn = ResearchTurn(question: "Why?")
        turn.answer = "Because of this [1], though not that [2]."
        turn.sources = [
            Source(number: 1, url: "https://one.example.com", title: "One", snippet: ""),
            Source(number: 2, url: "https://two.example.com", title: "Two", snippet: ""),
            Source(number: 3, url: "https://three.example.com", title: "Three", snippet: ""),
        ]
        turn.findings = [
            Finding(claim: "The first thing", verdict: .supported, reasoning: "Directly stated.",
                    sourceNumbers: [1]),
            Finding(claim: "The second thing", verdict: .insufficient, reasoning: "", sourceNumbers: []),
        ]
        turn.limitations = "Only summaries."
        turn.stage = .complete
        return turn
    }

    /// Copying prose whose `[3]` markers point at nothing would be worse than useless.
    func testCarriesTheCitedSources() {
        let text = TranscriptFormatter.plainText(turn())
        XCTAssertTrue(text.contains("[1] One — https://one.example.com"))
        XCTAssertTrue(text.contains("[2] Two — https://two.example.com"))
    }

    /// A dump of everything the search returned misrepresents what the answer rests on.
    func testOmitsUncitedSources() {
        XCTAssertFalse(TranscriptFormatter.plainText(turn()).contains("three.example.com"))
    }

    /// An answer without its verdicts is exactly the confident-sounding paragraph this
    /// app exists to replace.
    func testCarriesTheVerdicts() {
        let text = TranscriptFormatter.plainText(turn())
        XCTAssertTrue(text.contains("SUPPORTED [1]: The first thing"))
        XCTAssertTrue(text.contains("NOT ESTABLISHED: The second thing"))
        XCTAssertTrue(text.contains("Directly stated."))
    }

    func testCarriesLimitationsAndNotices() {
        var subject = turn()
        subject.notices = [.noEvidence]
        let text = TranscriptFormatter.plainText(subject)
        XCTAssertTrue(text.contains("Limitations: Only summaries."))
        XCTAssertTrue(text.contains("Note: " + TurnNotice.noEvidence.message))
    }

    /// Failure before prose still has a useful explanation, but no evidence to export.
    func testFailureBeforeAnAnswerReportsTheFailure() {
        var subject = ResearchTurn(question: "Why?")
        subject.failure = "The provider rejected the API key."
        subject.stage = .failed
        let text = TranscriptFormatter.plainText(subject)
        XCTAssertTrue(text.contains("Failed: The provider rejected the API key."))
        XCTAssertFalse(text.contains("Sources"))
    }

    func testIncludesSourcesCitedOnlyByFindings() {
        var subject = turn()
        subject.findings.append(Finding(claim: "Counterevidence", verdict: .contradicted,
                                        reasoning: "Another source disagrees.", sourceNumbers: [3, 1]))
        let text = TranscriptFormatter.plainText(subject)
        XCTAssertTrue(text.contains("[3] Three — https://three.example.com"))
        XCTAssertEqual(text.components(separatedBy: "[1] One —").count, 2)
        XCTAssertTrue(text.contains("[1] One — https://one.example.com\n"
                                    + "[2] Two — https://two.example.com\n"
                                    + "[3] Three — https://three.example.com"))
    }

    func testAssessmentFailureKeepsTheAnswerEvidenceAndCaveats() {
        var subject = turn()
        subject.stage = .failed
        subject.failure = "The assessment did not finish."
        subject.notices = [.invalidCitation]
        let text = TranscriptFormatter.plainText(subject)
        XCTAssertTrue(text.contains("Failed: The assessment did not finish."))
        XCTAssertTrue(text.contains(subject.answer))
        XCTAssertTrue(text.contains("[1] One — https://one.example.com"))
        XCTAssertTrue(text.contains("SUPPORTED [1]"))
        XCTAssertTrue(text.contains(subject.limitations))
        XCTAssertTrue(text.contains(TurnNotice.invalidCitation.message))
        XCTAssertTrue(text.contains("incomplete"))
    }

    func testEveryUnfinishedStageIsExplicit() {
        for stage: ResearchStage in [.queued, .planning, .searching, .answering, .assessing,
                                     .cancelled, .failed] {
            var subject = turn()
            subject.stage = stage
            let text = TranscriptFormatter.plainText(subject)
            XCTAssertTrue(text.contains(stage.label), stage.rawValue)
            XCTAssertTrue(text.contains("incomplete"), stage.rawValue)
            XCTAssertTrue(text.contains(subject.answer), stage.rawValue)
        }
    }

    func testACompleteAnswerHasNoIncompleteStatus() {
        XCTAssertFalse(TranscriptFormatter.plainText(turn()).contains("Status:"))
    }

    func testUnsourcedAndCancelledAnswersKeepTheirWarnings() {
        var subject = ResearchTurn(question: "Direct question")
        subject.answer = "Partial background answer."
        subject.stage = .cancelled
        subject.notices = [.noEvidence]
        let text = TranscriptFormatter.plainText(subject)
        XCTAssertTrue(text.contains("Cancelled"))
        XCTAssertTrue(text.contains(TurnNotice.noEvidence.message))
        XCTAssertTrue(text.contains(subject.answer))
        XCTAssertFalse(text.contains("\nSources\n"))
    }

    func testTheModelHelperMatchesTheFormatter() {
        XCTAssertEqual(turn().transcript, TranscriptFormatter.plainText(turn()))
    }
}
