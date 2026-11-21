import XCTest
import CoreGraphics
@testable import Vervellum

final class PanelHeaderViewTests: XCTestCase {

    /// The drawn glyph frame every header button uses.
    private let glyphFrame = CGRect(x: 40, y: 6, width: 20, height: 18)

    func testHitShapeContainsTheWholeGlyphFrame() {
        let hit = HeaderButton.hitShape(for: glyphFrame)
        XCTAssertTrue(hit.contains(glyphFrame))
    }

    func testHitShapeReachesAComfortableTargetSize() {
        let hit = HeaderButton.hitShape(for: glyphFrame)
        XCTAssertGreaterThanOrEqual(hit.width, 24)
        XCTAssertGreaterThanOrEqual(hit.height, 24)
    }

    /// Buttons sit `PanelTheme.Space.small` (6 pt) apart in the header, so the expansion
    /// may grow at most half that horizontally or neighbouring hit areas overlap and one
    /// button starts swallowing the next one's clicks.
    func testHitShapeDoesNotOverlapANeighbouringButton() {
        let gap = PanelTheme.Space.small
        let neighbour = CGRect(x: glyphFrame.maxX + gap, y: glyphFrame.minY,
                               width: glyphFrame.width, height: glyphFrame.height)
        let hit = HeaderButton.hitShape(for: glyphFrame)
        XCTAssertLessThanOrEqual(hit.maxX, neighbour.minX)
    }

    /// The expansion is symmetric, so the target is centred on the glyph rather than
    /// shifted toward one edge.
    func testHitShapeIsCentredOnTheGlyphFrame() {
        let hit = HeaderButton.hitShape(for: glyphFrame)
        XCTAssertEqual(hit.midX, glyphFrame.midX, accuracy: 0.01)
        XCTAssertEqual(hit.midY, glyphFrame.midY, accuracy: 0.01)
    }
}
