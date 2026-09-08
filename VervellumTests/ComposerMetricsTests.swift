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
