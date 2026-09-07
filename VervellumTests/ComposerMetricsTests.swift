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
        XCTAssertGreaterThan(ComposerView.maximumHeight(1.4), ComposerView.maximumHeight(1.0))
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
