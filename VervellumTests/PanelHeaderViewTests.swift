import XCTest
import CoreGraphics
@testable import Vervellum

final class PanelHeaderViewTests: XCTestCase {

    /// The drawn glyph frame every header button uses.
    private let glyphFrame = CGRect(x: 40, y: 6, width: 20, height: 18)

    /// The hit target the production padding produces for the glyph frame, computed
    /// from all four padding values so an asymmetric padding cannot pass unnoticed.
    private var hitFrame: CGRect {
        let pad = HeaderButton.hitPadding
        return CGRect(x: glyphFrame.minX - pad.leading,
                      y: glyphFrame.minY - pad.top,
                      width: glyphFrame.width + pad.leading + pad.trailing,
                      height: glyphFrame.height + pad.top + pad.bottom)
    }

    func testHitTargetContainsTheWholeGlyphFrame() {
        XCTAssertTrue(hitFrame.contains(glyphFrame))
    }

    func testHitTargetReachesAComfortableTargetSize() {
        XCTAssertGreaterThanOrEqual(hitFrame.width, 24)
        XCTAssertGreaterThanOrEqual(hitFrame.height, 24)
    }

    /// Buttons sit `PanelTheme.Space.small` apart in the header; the expansion is half
    /// that gap, so neighbouring hit areas meet but never overlap — one button must
    /// not swallow clicks meant for its neighbour.
    func testHitTargetDoesNotOverlapANeighbouringButton() {
        let gap = PanelTheme.Space.small
        let neighbour = CGRect(x: glyphFrame.maxX + gap, y: glyphFrame.minY,
                               width: glyphFrame.width, height: glyphFrame.height)
        XCTAssertLessThanOrEqual(hitFrame.maxX, neighbour.minX)
    }

    /// The expansion is symmetric, so the target is centred on the glyph rather than
    /// shifted toward one edge.
    func testHitTargetIsCentredOnTheGlyphFrame() {
        XCTAssertEqual(hitFrame.midX, glyphFrame.midX, accuracy: 0.01)
        XCTAssertEqual(hitFrame.midY, glyphFrame.midY, accuracy: 0.01)
    }

    /// The horizontal expansion is derived from the neighbour gap, so the no-overlap
    /// guarantee holds by construction even if the theme spacing changes.
    func testHorizontalExpansionIsHalfTheNeighbourGap() {
        XCTAssertEqual(HeaderButton.hitPadding.leading, PanelTheme.Space.small / 2)
        XCTAssertEqual(HeaderButton.hitPadding.trailing, PanelTheme.Space.small / 2)
        XCTAssertEqual(HeaderButton.inverseHitPadding.leading, -PanelTheme.Space.small / 2)
    }
}
