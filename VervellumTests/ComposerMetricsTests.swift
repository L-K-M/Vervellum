import XCTest
@testable import Vervellum

/// The composer's measured height, which is the one part of the text-size preference
/// that is arithmetic rather than a font a test cannot inspect.
///
/// It matters because the composer is an `NSTextView` laid out by hand: the panel asks
/// for a height, and a height computed at a fixed 13pt would clip the first line the
/// moment the reader turned the text up.
final class ComposerMetricsTests: XCTestCase {

    private let width: CGFloat = 320

    func testAnEmptyComposerIsOneScaledLineTall() {
        XCTAssertEqual(ComposerView.height(for: "", width: width, scale: 1.0),
                       ComposerView.minimumHeight(1.0), accuracy: 0.5)
        XCTAssertEqual(ComposerView.height(for: "", width: width, scale: 1.4),
                       ComposerView.minimumHeight(1.4), accuracy: 0.5)
    }

    /// The whole point: turning the text up makes the field taller, so the larger glyphs
    /// still fit the box that was measured for them.
    func testALargerTextSizeMakesTheFieldTaller() {
        let small = ComposerView.height(for: "A question", width: width, scale: 0.85)
        let normal = ComposerView.height(for: "A question", width: width, scale: 1.0)
        let large = ComposerView.height(for: "A question", width: width, scale: 1.4)
        XCTAssertLessThan(small, normal)
        XCTAssertLessThan(normal, large)
    }

    /// The ceiling scales too. A fixed maximum would show six lines at the smallest
    /// setting and three at the largest, which is the opposite of what turning the text
    /// up is for.
    func testTheCeilingScalesSoTheLineCountHolds() {
        let many = String(repeating: "wrap this line again and again ", count: 60)
        XCTAssertEqual(ComposerView.height(for: many, width: width, scale: 1.0),
                       ComposerView.maximumHeight(1.0), accuracy: 0.5)
        XCTAssertEqual(ComposerView.height(for: many, width: width, scale: 1.4),
                       ComposerView.maximumHeight(1.4), accuracy: 0.5)

        // "The line count holds" is proportionality, not merely growth: a ceiling that
        // inched up by half a point would satisfy a bare `>` while fitting fewer lines at
        // the larger size. Pinning the ratio of ceiling to floor says exactly what the
        // name promises — the box holds the same number of lines at every scale.
        for scale in [0.85, 1.0, 1.4] {
            XCTAssertEqual(ComposerView.maximumHeight(scale) / ComposerView.minimumHeight(scale),
                           ComposerView.maximumHeight(1.0) / ComposerView.minimumHeight(1.0),
                           accuracy: 0.001,
                           "the ceiling must scale with the floor, at scale \(scale)")
        }
    }

    /// The preference is clamped on read, so nothing odd should reach the metric. It is
    /// pinned here anyway because this end is where it would hurt: a NaN scale becomes a
    /// NaN frame height — layout warnings and a field nobody can see — and a zero becomes
    /// a composer of no height that cannot be typed into or fixed.
    func testAHostileScaleStillProducesUsableGeometry() {
        for scale in [0.0, -1.0, .nan, .infinity, 1000.0] {
            let height = ComposerView.height(for: "A question", width: width, scale: scale)
            XCTAssertFalse(height.isNaN, "at scale \(scale)")
            XCTAssertGreaterThan(height, 0, "at scale \(scale)")
            XCTAssertLessThanOrEqual(height, ComposerView.maximumHeight(3), "at scale \(scale)")
        }

        // Bounded is not enough: two scales that are both far out of range must collapse
        // to the *same* geometry, or the composer would quietly render at two different
        // sizes for two equally impossible inputs.
        XCTAssertEqual(ComposerView.height(for: "A question", width: width, scale: .infinity),
                       ComposerView.height(for: "A question", width: width, scale: 1000),
                       accuracy: 0.01, "everything above the range lands on one ceiling")
        XCTAssertEqual(ComposerView.height(for: "A question", width: width, scale: 0),
                       ComposerView.height(for: "A question", width: width, scale: -1),
                       accuracy: 0.01, "everything below it lands on one floor")
    }

    /// The width can produce garbage geometry as easily as the scale. Zero is not
    /// hypothetical: the composer is measured before any layout has happened, so the
    /// first frame runs on an estimate. One unbreakable word takes the other path — no
    /// soft-wrap opportunity at all.
    func testAHostileWidthOrAnUnbreakableWordStillProducesUsableGeometry() {
        let unbreakable = String(repeating: "x", count: 400)
        for candidate in [0.0, -1.0, 1.0, 320.0] as [CGFloat] {
            for text in ["A question", unbreakable] {
                let height = ComposerView.height(for: text, width: candidate, scale: 1.0)
                XCTAssertFalse(height.isNaN, "width \(candidate), \(text.count) characters")
                XCTAssertGreaterThanOrEqual(height, ComposerView.minimumHeight(1.0),
                                            "width \(candidate)")
                XCTAssertLessThanOrEqual(height, ComposerView.maximumHeight(1.0),
                                         "width \(candidate)")
            }
        }
    }

    /// Unscaled by default, so anything measuring the composer without an opinion gets
    /// exactly the geometry it got before the preference reached this far.
    func testTheDefaultScaleIsUnchangedGeometry() {
        XCTAssertEqual(ComposerView.height(for: "A question", width: width),
                       ComposerView.height(for: "A question", width: width, scale: 1.0),
                       accuracy: 0.01)
    }

    // MARK: A line break the user typed

    /// Shift-Return has to produce a line you can see. The newline always went in; the
    /// box measured for it did not grow, because `usedRect` counts only the fragments
    /// that hold glyphs and the line a final break opens holds none. The field kept its
    /// old height, the caret moved below it, and the scroll view followed the caret and
    /// took the question out of sight, which reads as the key having eaten it.
    func testATrailingNewlineOpensALineYouCanSee() {
        let one = ComposerView.height(for: "a question", width: width)
        let two = ComposerView.height(for: "a question\n", width: width)
        XCTAssertGreaterThan(two, one)
        // The same height as a line with something typed on it: an empty last line is
        // still a line, and is what the caret is sitting on.
        XCTAssertEqual(two, ComposerView.height(for: "a question\nb", width: width),
                       accuracy: 0.5)
    }

    /// Two presses open two lines. One extra line fragment covers the last empty line
    /// only, so a fix that added a fixed line to any newline-terminated text would be a
    /// line short here.
    func testEachTrailingNewlineOpensItsOwnLine() {
        let two = ComposerView.height(for: "a question\n", width: width)
        let three = ComposerView.height(for: "a question\n\n", width: width)
        XCTAssertGreaterThan(three, two)
        XCTAssertEqual(three, ComposerView.height(for: "a question\n\nb", width: width),
                       accuracy: 0.5)
    }

    /// A pasted question carries whatever line ending the app it came from uses, and the
    /// composer has to make the same room for each of them.
    func testAPastedLineEndingCountsLikeATypedOne() {
        let typed = ComposerView.height(for: "a question\n", width: width)
        for ending in ["\r", "\r\n"] {
            XCTAssertEqual(ComposerView.height(for: "a question" + ending, width: width),
                           typed, accuracy: 0.5, "ending \(ending.debugDescription)")
        }
    }

    /// The ceiling still wins. Holding Return must scroll inside the composer rather than
    /// grow it over the thread it belongs to.
    func testTheCeilingHoldsAgainstTrailingNewlines() {
        let held = "a question" + String(repeating: "\n", count: 40)
        XCTAssertEqual(ComposerView.height(for: held, width: width, scale: 1.0),
                       ComposerView.maximumHeight(1.0), accuracy: 0.5)
    }

    /// A question long enough to wrap is taller than one that is not, at every size —
    /// the growth behaviour the composer exists for must survive the scaling.
    func testItStillGrowsWithTheQuestion() {
        for scale in [0.85, 1.0, 1.4] {
            let one = ComposerView.height(for: "short", width: width, scale: scale)
            let several = ComposerView.height(
                for: String(repeating: "a somewhat longer question ", count: 6),
                width: width, scale: scale)
            XCTAssertGreaterThan(several, one, "at scale \(scale)")
        }
    }
}
