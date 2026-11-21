import XCTest
#if canImport(VervellumKit)
@testable import VervellumKit
#else
@testable import Vervellum
#endif

/// A notice's tone is a scanning channel: a reader skimming the panel must be able to
/// tell a status change from a caveat from "this answer was never checked".
final class NoticeToneTests: XCTestCase {

    func testStatusChangesAreInformational() {
        for notice in [TurnNotice.answerRevised, .linkReadingOff, .modelFellBack,
                       .answerRegathered, .unknown] {
            XCTAssertEqual(notice.tone, .informational, notice.rawValue)
        }
    }

    func testEvidenceAndCheckCaveatsAreCautions() {
        for notice in [TurnNotice.contextTrimmed, .evidenceTrimmed, .invalidCitation,
                       .literalURL, .assessmentLinkDropped, .noEvidence,
                       .uncitedVerdictDropped, .unreadableVerdictDropped,
                       .revisionUnavailable, .noPagesRead, .pageTextTrimmed,
                       .linkNotRead, .imagesNotSent, .attachmentMissing,
                       .attachmentTrimmed] {
            XCTAssertEqual(notice.tone, .caution, notice.rawValue)
        }
    }

    /// The two notices that mean the reader cannot rely on the turn at all.
    func testUncheckedAndUnstoredAreCritical() {
        XCTAssertEqual(TurnNotice.assessmentUnavailable.tone, .critical)
        XCTAssertEqual(TurnNotice.attachmentNotStored.tone, .critical)
    }

    func testEveryToneNamesASymbol() {
        for tone in NoticeTone.allCases {
            XCTAssertFalse(tone.symbolName.isEmpty, tone.rawValue)
        }
    }
}
