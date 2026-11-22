import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// A theme change must leave an open turn looking exactly like one built under the new
/// theme. Comparing the drawn result covers every child view, including the ones whose
/// own inputs a palette change does not touch.
@MainActor
final class TurnThemeRenderingTests: XCTestCase {

    private static let size = NSSize(width: 440, height: 1_400)

    private final class Theme: ObservableObject {
        @Published var palette: PanelPalette

        init(_ palette: PanelPalette) { self.palette = palette }
    }

    private struct OpenTurn: View {
        @ObservedObject var theme: Theme
        let turn: ResearchTurn

        var body: some View {
            TurnView(turn: turn, showsProcessTrail: true, palette: theme.palette,
                     onRetry: {}, onAskFollowup: { _ in },
                     attachmentData: { _ in nil })
                .equatable()
                .frame(width: TurnThemeRenderingTests.size.width,
                       height: TurnThemeRenderingTests.size.height, alignment: .top)
        }
    }

    func testAnAccentChangeRestylesTheWholeTurn() throws {
        var changed = PanelPalette.ember
        changed.accent = ThemeColor(0.05, 0.85, 0.95)
        try assertOpenTurnMatchesAFreshOne(changingTo: changed)
    }

    func testAFullThemeChangeRestylesTheWholeTurn() throws {
        var changed = PanelPalette.ember
        changed.accent = ThemeColor(0.05, 0.85, 0.95)
        changed.primaryText = ThemeColor(0.1, 0.9, 0.2)
        changed.secondaryText = ThemeColor(0.9, 0.2, 0.9)
        changed.cardFill = ThemeColor(0.1, 0.2, 0.9, 0.5)
        changed.chipFill = ThemeColor(0.9, 0.9, 0.1, 0.5)
        changed.hairline = ThemeColor(0.9, 0.1, 0.1, 0.8)
        changed.supported = ThemeColor(0.9, 0.5, 0.1)
        changed.contradicted = ThemeColor(0.2, 0.2, 0.9)
        changed.mixed = ThemeColor(0.1, 0.9, 0.7)
        changed.fontDesign = .serif
        changed.cornerScale = 0
        try assertOpenTurnMatchesAFreshOne(changingTo: changed)
    }

    private func assertOpenTurnMatchesAFreshOne(changingTo changed: PanelPalette,
                                                file: StaticString = #filePath,
                                                line: UInt = #line) throws {
        let previous = PanelTheme.palette
        defer { PanelTheme.palette = previous }
        let turn = Self.turn()

        PanelTheme.palette = .ember
        let theme = Theme(.ember)
        let open = host(OpenTurn(theme: theme, turn: turn))
        defer { open.close() }
        let before = try snapshot(open)
        PanelTheme.palette = changed
        theme.palette = changed
        settle()
        let restyled = try snapshot(open)

        let fresh = host(OpenTurn(theme: Theme(changed), turn: turn))
        defer { fresh.close() }
        let expected = try snapshot(fresh)

        XCTAssertFalse(differingRows(before, expected).isEmpty,
                       "the fixture must look different under the new theme", file: file, line: line)
        let stale = differingRows(restyled, expected)
        XCTAssertTrue(stale.isEmpty,
                      "stale rows from y=\(stale.first ?? 0) to y=\(stale.last ?? 0) (\(stale.count) rows)",
                      file: file, line: line)
    }

    private static func turn() -> ResearchTurn {
        var turn = ResearchTurn(question: "What changed in the theme?")
        turn.stage = .complete
        turn.model = "a-model"
        turn.answer = """
        # Heading

        Plain answer text with a citation [1].

        - A bullet [1]

        1. A numbered item

        > A quotation

        ```
        let code = true
        ```

        | Column | Other |
        | --- | --- |
        | Cell | Cell [1] |
        """
        turn.draftAnswer = "An earlier draft [1]."
        turn.reading = "Read the question."
        turn.sources = [Source(number: 1, url: "https://one.example/a", title: "One", snippet: "Summary")]
        turn.findings = [Finding(claim: "A claim", verdict: .supported, reasoning: "Because", sourceNumbers: [1]),
                         Finding(claim: "Another", verdict: .contradicted, reasoning: "Not so", sourceNumbers: [1])]
        turn.notices = [.answerRevised, .evidenceTrimmed, .assessmentUnavailable]
        turn.limitations = "A limitation."
        turn.followups = ["A follow-up?"]
        turn.failure = "A failure message."
        turn.attachments = [Attachment(kind: .text, name: "notes.txt", mediaType: "text/plain", byteCount: 12)]
        return turn
    }

    private func host(_ view: some View) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        settle()
        return window
    }

    private func snapshot(_ window: NSWindow) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    /// Rows with a channel off by more than antialiasing noise.
    private func differingRows(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [Int] {
        guard let left = a.bitmapData, let right = b.bitmapData,
              a.bytesPerRow == b.bytesPerRow, a.pixelsHigh == b.pixelsHigh else { return [0] }
        let tolerance = 8
        let width = a.pixelsWide * a.samplesPerPixel
        return (0..<a.pixelsHigh).filter { row in
            let start = row * a.bytesPerRow
            return (start..<start + width).contains { abs(Int(left[$0]) - Int(right[$0])) > tolerance }
        }
    }

    private func settle() {
        let settled = expectation(description: "Theme event loop settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }
}
