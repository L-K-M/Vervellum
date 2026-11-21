import XCTest
import AppKit
@testable import Vervellum

final class TurnViewThemeTests: XCTestCase {

    private let turn = ResearchTurn(question: "What is a tokamak?")

    private func makeView(palette: PanelPalette) -> TurnView {
        TurnView(turn: turn, showsProcessTrail: true, palette: palette,
                 onRetry: {}, onAskFollowup: { _ in })
    }

    /// A theme change is a global write (`PanelTheme.palette`), not an input any parent
    /// passes down — so `TurnView.==` must compare the palette it was rendered with, or
    /// every turn in an open thread keeps the old colours until its text changes.
    func testTurnViewIsNotEqualWhenThePaletteChanges() {
        let other = PanelPalette.presets.first { $0 != .ember }
        XCTAssertNotNil(other)
        guard let other else { return }
        XCTAssertTrue(makeView(palette: .ember) == makeView(palette: .ember))
        XCTAssertFalse(makeView(palette: .ember) == makeView(palette: other))
    }

    func testTurnViewStillSkipsWhenNothingChanged() {
        XCTAssertTrue(makeView(palette: .ember) == makeView(palette: .ember),
                      "the streaming fast path must not be broken by the palette input")
    }

    /// The chip attributes follow the accent; the refresh in `updateNSView` compares
    /// against these, so a changed accent must produce a different foreground.
    func testLinkAttributesFollowTheAccent() {
        let ember = AnswerTextView.linkAttributes(accent: PanelTheme.NativePalette.accent)
        let other = PanelPalette.presets.first { $0 != .ember }
        guard let other else { return }
        let previous = PanelTheme.palette
        PanelTheme.palette = other
        defer { PanelTheme.palette = previous }
        let rethemed = AnswerTextView.linkAttributes(accent: PanelTheme.NativePalette.accent)
        XCTAssertNotEqual(ember[.foregroundColor] as? NSColor,
                          rethemed[.foregroundColor] as? NSColor)
        XCTAssertNotNil(rethemed[.cursor])
    }
}
