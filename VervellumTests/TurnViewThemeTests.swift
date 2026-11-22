import XCTest
import AppKit
@testable import Vervellum

final class TurnViewThemeTests: XCTestCase {

    private let turn = ResearchTurn(question: "What is a tokamak?")

    private func makeView(palette: PanelPalette) -> TurnView {
        TurnView(turn: turn, showsProcessTrail: true, palette: palette,
                 onRetry: {}, onAskFollowup: { _ in },
                 attachmentData: { _ in nil })
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
    /// the current accent, so the comparison can only fire on a theme change if two
    /// presets actually produce different accents. Pin that property here; if it ever
    /// fails, the fix belongs in the palette presets (store distinct literal colours),
    /// not in the comparison.
    func testAccentChangesAcrossPresets() {
        let previous = PanelTheme.palette
        defer { PanelTheme.palette = previous }
        PanelTheme.palette = .ember
        let emberAccent = PanelTheme.NativePalette.accent
        guard let other = PanelPalette.presets.first(where: { $0 != .ember }) else {
            XCTFail("this test needs at least two palette presets")
            return
        }
        PanelTheme.palette = other
        XCTAssertNotEqual(emberAccent, PanelTheme.NativePalette.accent,
                          "two presets share an accent; updateNSView would never rewrite link attributes when switching to it")
    }
}
