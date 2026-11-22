import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class DraftComparisonTests: XCTestCase {

    func testAssessmentTargetFollowsTheOperationThatSavedTheDraft() {
        var turn = ResearchTurn(question: "What changed?")
        XCTAssertEqual(DraftComparison.description(for: turn).heading, "Earlier draft")
        turn.notices = [.answerRegathered]
        XCTAssertEqual(DraftComparison.description(for: turn).heading, "Draft before additional research")
        XCTAssertEqual(DraftComparison.description(for: turn).hint,
                       "This draft predates the additional research. The findings assess the displayed answer.")
        for notices: [TurnNotice] in [[.answerRevised], [.answerRegathered, .answerRevised]] {
            turn.notices = notices
            XCTAssertEqual(DraftComparison.description(for: turn).heading, "Draft before correction")
            XCTAssertEqual(DraftComparison.description(for: turn).hint, "The findings assess this draft.")
        }
    }

    func testADifferentDraftIsOfferedForComparison() {
        XCTAssertTrue(DraftComparison.isOffered(draft: "First [1].", answer: "Second [1]."))
        XCTAssertFalse(DraftComparison.isOffered(draft: nil, answer: "Second [1]."))
        XCTAssertFalse(DraftComparison.isOffered(draft: "  ", answer: "Second [1]."))
        XCTAssertFalse(DraftComparison.isOffered(draft: "Same [1].\n", answer: "Same [1]."))
    }
}
