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
        XCTAssertNotNil(other, "this test needs at least two palette presets")
        guard let other else { return }
        let previous = PanelTheme.palette
        PanelTheme.palette = other
        defer { PanelTheme.palette = previous }
        let rethemed = AnswerTextView.linkAttributes(accent: PanelTheme.NativePalette.accent)
        XCTAssertNotEqual(ember[.foregroundColor] as? NSColor,
                          rethemed[.foregroundColor] as? NSColor)
        XCTAssertNotNil(rethemed[.cursor])
    }

    /// `updateNSView` skips the attribute rewrite only when the stored foreground equals
    /// the current accent, so a colour rebuilt on each read would rewrite attributes on
    /// every streamed chunk. Pin that one theme's accent is a stable value across reads;
    /// if this ever fails, the fix belongs in the palette presets (store literal
    /// colours), not in the comparison.
    func testAccentIsStableAcrossReadsForOneTheme() {
        XCTAssertEqual(PanelTheme.NativePalette.accent,
                       PanelTheme.NativePalette.accent)
    }
}
