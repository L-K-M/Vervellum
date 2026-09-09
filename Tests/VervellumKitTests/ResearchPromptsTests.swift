import XCTest
#if canImport(VervellumKit)
@testable import VervellumKit
#else
@testable import Vervellum
#endif

/// The prompts are the product; these pin the properties each one defends so a
/// rewording cannot quietly drop one.
final class ResearchPromptsTests: XCTestCase {

    func testEveryPromptCarriesTheTrustPreamble() {
        for prompt in [ResearchPrompts.plan(maxSearches: 4, today: "2026-09-06"),
                       ResearchPrompts.answer, ResearchPrompts.assess, ResearchPrompts.direct] {
            XCTAssertTrue(prompt.hasPrefix(ResearchPrompts.trust))
        }
    }

    /// "Between 1 and N" contradicted the empty-array instruction two paragraphs later.
    func testThePlanAllowsNoSearches() {
        let plan = ResearchPrompts.plan(maxSearches: 4, today: "2026-09-06")
        XCTAssertTrue(plan.contains("up to 4 searches"))
        XCTAssertFalse(plan.contains("between 1 and"))
        XCTAssertTrue(plan.contains("empty \"searches\" array"))
        XCTAssertTrue(plan.contains("Today is 2026-09-06"))
    }

    /// The question arrives as a JSON field under an English system prompt, which
    /// pulls toward English harder than a chat message would.
    func testTheAnswerIsWrittenInTheQuestionsLanguage() {
        XCTAssertTrue(ResearchPrompts.answer.contains("language of the question"))
        XCTAssertTrue(ResearchPrompts.direct.contains("language of the question"))
    }

    /// Evidence carries a published date and the payload carries today; the prompts
    /// have to say what to do with them or a 2023 blog beats a 2026 release page.
    func testDatesAreWeighed() {
        XCTAssertTrue(ResearchPrompts.answer.contains("\"published\""))
        XCTAssertTrue(ResearchPrompts.answer.contains("most recent source"))
        XCTAssertTrue(ResearchPrompts.assess.contains("undated sources"))
    }

    /// The assessment is a fresh call: nothing in it "just wrote" anything.
    func testTheAssessmentAddressesAFreshModel() {
        XCTAssertFalse(ResearchPrompts.assess.contains("you just wrote"))
        XCTAssertTrue(ResearchPrompts.assess.contains("\"reading\""))
        XCTAssertTrue(ResearchPrompts.assess.contains("\"thread\""))
    }

    func testTheCitationRuleStillForbidsURLs() {
        XCTAssertTrue(ResearchPrompts.answer.contains("may not write a URL"))
    }

    /// An attachment has no citation number and cannot get one, so the prompts that
    /// enforce numbering have to say what to do with it. Without this clause a model
    /// told "every statement resting on a source must carry that source's number" either
    /// invents a number for the picture or declines to mention it.
    func testTheAnswerAndDirectPromptsSayWhatToDoWithAnAttachment() {
        for (label, prompt) in [("answer", ResearchPrompts.answer),
                                ("direct", ResearchPrompts.direct)] {
            XCTAssertTrue(prompt.contains(ResearchPrompts.attachments),
                          "the \(label) prompt is missing the attachment clause")
        }
        // And it does not reopen the citation rule it sits next to.
        XCTAssertTrue(ResearchPrompts.attachments.contains("no citation number"))
        XCTAssertFalse(ResearchPrompts.attachments.contains("http"))
    }

    /// Conditional, because a standing sentence about attachments on a turn with none is
    /// a standing invitation to plan searches about a file nobody sent.
    func testThePlanMentionsAttachmentsOnlyWhenThereAreSome() {
        let without = ResearchPrompts.plan(maxSearches: 4, today: "2026-09-06")
        XCTAssertFalse(without.lowercased().contains("attach"))

        let with = ResearchPrompts.plan(maxSearches: 4, today: "2026-09-06",
                                        hasAttachments: true)
        XCTAssertTrue(with.contains("attached something to this question"))
    }
}
