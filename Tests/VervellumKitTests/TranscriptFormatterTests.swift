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
            Source(number: 4, url: "https://four.example.com", title: "Four", snippet: ""),
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

    /// A turn that failed before any answer arrived has nothing worth printing, and
    /// saying why is the only useful thing left.
    func testAFailedTurnWithNoAnswerReportsOnlyTheFailure() {
        var subject = turn()
        subject.answer = ""
        subject.failure = "The provider rejected the API key."
        subject.stage = .failed
        let text = TranscriptFormatter.plainText(subject)
        XCTAssertTrue(text.contains("Failed: The provider rejected the API key."))
        XCTAssertFalse(text.contains("Sources"))
    }

    /// A failure after the answer streamed — the reply was cut off, the app quit before
    /// the checks ran — must not throw away an answer that is on screen and was paid
    /// for. The command line prints nothing but this transcript.
    func testAFailureAfterTheAnswerKeepsTheAnswer() throws {
        var subject = turn()
        subject.failure = "The model's reply was cut off by its output limit."
        subject.stage = .failed
        let text = TranscriptFormatter.plainText(subject)
        let answer = try XCTUnwrap(text.range(of: "Because of this [1]"))
        let failure = try XCTUnwrap(text.range(of: "Failed: The model's reply was cut off"))
        XCTAssertTrue(answer.lowerBound < failure.lowerBound, "the failure should trail the answer")
        XCTAssertTrue(text.contains("[1] One — https://one.example.com"))
    }

    /// A stopped run's partial answer must not read as a finished one.
    func testAStoppedTurnSaysSo() throws {
        var subject = turn()
        subject.answer = "Because of this [1], though"
        subject.findings = []
        subject.stage = .cancelled
        let text = TranscriptFormatter.plainText(subject)
        let notice = try XCTUnwrap(text.range(of: "Stopped before the answer finished"))
        let answer = try XCTUnwrap(text.range(of: "Because of this [1], though"))
        XCTAssertTrue(notice.lowerBound < answer.lowerBound)
        XCTAssertTrue(text.contains("[1] One — https://one.example.com"))
    }

    /// The assessor sees the whole evidence block and routinely grades a claim against
    /// a source the prose never cited; that `[3]` needs a `[3]` below it too.
    func testCarriesSourcesOnlyAVerdictCites() {
        var subject = turn()
        subject.findings[0].sourceNumbers = [3]
        let text = TranscriptFormatter.plainText(subject)
        XCTAssertTrue(text.contains("SUPPORTED [3]: The first thing"))
        XCTAssertTrue(text.contains("[3] Three — https://three.example.com"))
        XCTAssertFalse(text.contains("four.example.com"))
    }

    func testTheModelHelperMatchesTheFormatter() {
        XCTAssertEqual(turn().transcript, TranscriptFormatter.plainText(turn()))
    }
}
