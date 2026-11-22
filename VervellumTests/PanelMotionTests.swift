import SwiftUI
import XCTest
@testable import Vervellum

/// The Reduce Motion contract, which lives in two functions that have to agree.
///
/// Worth pinning because the failure is silent and the setting is one nobody testing by
/// eye is likely to have switched on: an edit that answered with a real animation here
/// would put the container's height, the chevron's rotation and the rows' arrival back
/// in motion for the readers who asked for none, and every other test would stay green.
///
/// Only the animation half can be held still. `AnyTransition` is not `Equatable` and
/// carries nothing to inspect, so `disclosureTransition` has no assertion to make;
/// `Animation` is, and it is the half that actually decides whether anything moves —
/// with a nil animation the transition takes no time whichever shape it is.
final class PanelMotionTests: XCTestCase {

    func testReduceMotionDisablesTheDisclosureAnimationEntirely() {
        XCTAssertNil(PanelTheme.Motion.disclosureAnimation(true),
                     "nil is the whole of \"do it instantly\" — any animation is motion")
        XCTAssertEqual(PanelTheme.Motion.disclosureAnimation(false),
                       PanelTheme.Motion.disclosure,
                       "and without the setting it is the panel's ordinary disclosure")
    }

    /// The streaming caret must not blink under Reduce Motion. It sits in the middle
    /// of the panel for the whole gap between the last search and the first token, so
    /// an edit that animated it there would put motion in front of exactly the readers
    /// who asked for none — and no other test would notice.
    func testReduceMotionHoldsTheStreamingCaretSteady() {
        XCTAssertEqual(StreamingCaret.opacity(isBright: true, reduceMotion: true), 0.6)
        XCTAssertEqual(StreamingCaret.opacity(isBright: false, reduceMotion: true), 0.6,
                       "no tick changes the opacity: a blink is a blink at any phase")
        XCTAssertEqual(StreamingCaret.opacity(isBright: true, reduceMotion: false), 1)
        XCTAssertEqual(StreamingCaret.opacity(isBright: false, reduceMotion: false), 0.25,
                       "and without the setting the caret still blinks")
    }
}
