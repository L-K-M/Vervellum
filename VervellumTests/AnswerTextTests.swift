import AppKit
import XCTest
@testable import Vervellum

/// The bridge from a parsed `AttributedString` to the string the answer's text view
/// actually draws.
///
/// Worth its own suite because the failure mode is silent. Bridging an `AttributedString`
/// to an `NSAttributedString` keeps the characters and drops almost everything that makes
/// them readable — a SwiftUI `Font` and `Color` have no AppKit counterpart, and
/// `inlinePresentationIntent` survives as an attribute nothing draws. An answer rendered
/// through a broken mapping is not blank or crashed; it is the right words in the wrong
/// face, in a colour that happens to be black in a dark panel.
final class AnswerTextTests: XCTestCase {

    private let sources = [
        Source(number: 1, url: "https://retrieved.example", title: "Retrieved", snippet: ""),
    ]
    private let base = NSFont.systemFont(ofSize: 13)
    private let colour = NSColor.labelColor

    private func native(_ markdown: String) -> NSAttributedString {
        CitationText.native(markdown, sources: sources, scale: 1, font: base, color: colour)
    }

    /// The attributes at the first character of `substring`.
    ///
    /// A missing substring fails rather than skips. It was a skip, which is wrong twice
    /// over: a parse that stopped producing the bold run would take
    /// `testEmphasisBecomesARealFontTrait` and its neighbour out of the suite, and a
    /// skipped test reads as green on every dashboard — so most of what this file is for
    /// could quietly disappear without anything turning red. Skips are for a machine that
    /// cannot run a test, not for the thing under test not happening.
    /// A substring that appears *twice* fails as well, for the same reason one that
    /// appears not at all does. `range(of:)` answers the first match and says nothing
    /// about the second, so a probe that became ambiguous — a copy edit to a sample
    /// sentence is all it takes — would silently start measuring a different character
    /// and go on passing. Every edge assertion in this file is a claim about one
    /// character's neighbours; a probe that does not name one character is not a claim.
    private func attributes(at substring: String,
                            in string: NSAttributedString) -> [NSAttributedString.Key: Any] {
        let text = string.string as NSString
        let range = text.range(of: substring)
        guard range.location != NSNotFound else {
            XCTFail("\(substring) is not in \(string.string)")
            // Empty rather than a trap: the assertions below then fail on their own
            // terms and name what they were looking for.
            return [:]
        }
        let after = NSRange(location: NSMaxRange(range),
                            length: text.length - NSMaxRange(range))
        guard text.range(of: substring, range: after).location == NSNotFound else {
            XCTFail("\(substring) appears more than once in \(string.string), so it "
                    + "names no particular character")
            return [:]
        }
        return string.attributes(at: range.location, effectiveRange: nil)
    }

    func testTheWholeAnswerSurvivesTheCrossing() {
        let string = native("Plain prose with **bold**, *italic* and `code` [1].")
        XCTAssertEqual(string.string, "Plain prose with bold, italic and code [1].")
    }

    /// The one run that has to be right: it is the hover target, and the hit test reads
    /// `.link` to find it.
    func testACitationChipIsALinkInTheAccentColourAndAMonospacedFace() throws {
        let string = native("Measured in arcseconds [1].")
        let chip = attributes(at: "[1]", in: string)

        XCTAssertEqual(chip[.link] as? URL, URL(string: "https://retrieved.example"))
        XCTAssertEqual(chip[.foregroundColor] as? NSColor, PanelTheme.NativePalette.accent)
        // Compared to the theme's own face rather than probed for monospacedness: this
        // is the one run whose look is a decision rather than a consequence, and the
        // decision lives in `PanelTheme.NativeFont`.
        XCTAssertEqual(chip[.font] as? NSFont, PanelTheme.NativeFont.citation(1))
        // And the run *stops* at the bracket. Every probe above is inside the chip, so a
        // link range that ran one character long would pass all of them — and the extra
        // character is a hover target: resting on the full stop after a citation would
        // open the popover for it.
        XCTAssertNil(attributes(at: ".", in: string)[.link])
        // And where it starts, which nothing asked. A run that began one character early
        // passes every probe above and puts a hover target — and a click — on the space
        // in front of the citation, which is the same off-by-one from the other side.
        XCTAssertNil(attributes(at: " [1]", in: string)[.link])
    }

    /// Prose is the base font and colour the block was given, which is how a heading and
    /// a quote get to look different without a modifier the text view cannot see.
    func testProseKeepsTheFontAndColourTheBlockWasGiven() throws {
        let string = native("Measured in arcseconds [1].")
        let prose = attributes(at: "Measured", in: string)

        XCTAssertEqual(prose[.font] as? NSFont, base)
        XCTAssertEqual(prose[.foregroundColor] as? NSColor, colour)
        XCTAssertNil(prose[.link])
    }

    /// Emphasis has to become a *face*. `inlinePresentationIntent` is what the markdown
    /// parser records and what nothing in AppKit draws, so a run that carried the intent
    /// through unchanged would render as plain text and look like markdown that failed
    /// to parse.
    func testEmphasisBecomesARealFontTrait() throws {
        let string = native("A **strong** and an *emphasised* word.")

        let bold = try XCTUnwrap(attributes(at: "strong", in: string)[.font] as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let italic = try XCTUnwrap(attributes(at: "emphasised", in: string)[.font] as? NSFont)
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))

        // A face has to *stop*. Probing only the emphasised runs cannot tell a correct
        // mapping from one that starts a trait at the right character and carries it to
        // the end of the block — which is what a run boundary read off by one produces,
        // and it renders as a paragraph that is bold from the first strong word on.
        let before = try XCTUnwrap(attributes(at: "A ", in: string)[.font] as? NSFont)
        XCTAssertFalse(before.fontDescriptor.symbolicTraits.contains(.bold))
        let between = try XCTUnwrap(attributes(at: " and", in: string)[.font] as? NSFont)
        XCTAssertFalse(between.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(between.fontDescriptor.symbolicTraits.contains(.italic))
        // Bold's right edge is what the probe above catches. Italic has two edges of its
        // own, and a run that began one character early or ended one late would leave
        // every assertion so far standing.
        let beforeItalic = try XCTUnwrap(attributes(at: " emphasised", in: string)[.font] as? NSFont)
        XCTAssertFalse(beforeItalic.fontDescriptor.symbolicTraits.contains(.italic))
        let afterItalic = try XCTUnwrap(attributes(at: " word", in: string)[.font] as? NSFont)
        XCTAssertFalse(afterItalic.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testBoldItalicIsBoth() throws {
        let string = native("A ***loud*** word.")
        let font = try XCTUnwrap(attributes(at: "loud", in: string)[.font] as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic))

        // And both stop, as `testEmphasisBecomesARealFontTrait` insists for one trait at
        // a time. This is the one face case where the sample is its own, so nothing else
        // in the file holds its edges: a `***` mapping that ran to the end of the block
        // would satisfy every assertion above.
        let before = try XCTUnwrap(attributes(at: "A ", in: string)[.font] as? NSFont)
        XCTAssertFalse(before.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(before.fontDescriptor.symbolicTraits.contains(.italic))
        let after = try XCTUnwrap(attributes(at: " word", in: string)[.font] as? NSFont)
        XCTAssertFalse(after.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(after.fontDescriptor.symbolicTraits.contains(.italic))
    }

    /// Code replaces the face rather than adding to it: asking a monospaced family for a
    /// bold face after the fact only sometimes finds one, and the alignment is the point.
    func testInlineCodeIsMonospacedEvenInsideEmphasis() throws {
        let string = native("Run **`swift build`** now.")
        // Monospaced *and* still bold. The emphasis used to be dropped: the code branch
        // answered first and never read the intent again, so a bolded snippet — which is
        // how a model writes a command it wants you to notice — rendered as plain code.
        XCTAssertEqual(attributes(at: "swift build", in: string)[.font] as? NSFont,
                       PanelTheme.NativeFont.code(1, weight: .bold))
        // And the face stops. " now." is outside both the code and the bold, so a run
        // bound off by one — or a code attribute that leaked forward through the closing
        // `**` — turns the rest of the paragraph monospaced with nothing to catch it.
        // Positively, not by elimination: the prose after the run is *the block's own
        // font*, which the suite pins elsewhere, so this catches every wrong face here —
        // an italic that leaked, a size that drifted — rather than the two this used to
        // name.
        XCTAssertEqual(attributes(at: " now", in: string)[.font] as? NSFont, base)
    }

    /// The rule `render` enforces has to survive the crossing: a link the model wrote is
    /// dropped there, and if it reappeared here it would be a clickable URL in the prose
    /// — and, worse, a hover target the source list has no row for.
    func testALinkTheModelWroteIsNotALinkHere() {
        let string = native("See [this](https://evil.example) and [1].")
        var links: [URL] = []
        string.enumerateAttribute(.link, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links, [URL(string: "https://retrieved.example")!])
    }

    /// Everything above asks at scale 1, where a mapping that dropped the scale entirely
    /// and built every face at 1× would pass the whole file — and the reader who set the
    /// panel's text larger is exactly the one who would notice and have nothing to point
    /// at. One assertion at another scale is what closes that.
    func testTheTextScaleReachesTheFacesOnTheOtherSide() throws {
        let string = CitationText.native("Measured in arcseconds [1], with `code`.",
                                         sources: sources, scale: 2,
                                         font: PanelTheme.NativeFont.body(2), color: colour)
        XCTAssertEqual(attributes(at: "[1]", in: string)[.font] as? NSFont,
                       PanelTheme.NativeFont.citation(2))
        XCTAssertEqual(attributes(at: "code", in: string)[.font] as? NSFont,
                       PanelTheme.NativeFont.code(2))
        // And the prose keeps the face it was handed rather than a scaled-again one:
        // the block's font is the caller's answer to the scale, not this file's.
        XCTAssertEqual(attributes(at: "Measured", in: string)[.font] as? NSFont,
                       PanelTheme.NativeFont.body(2))
    }

    /// Two independently built faces of the same theme compare equal.
    ///
    /// Not a test about fonts: it is the premise `MarkdownText`'s `Equatable` skip rests
    /// on. Every block is handed a freshly constructed `NSFont` and `NSColor` on each
    /// parent render, and the whole reason the parse moved from `init` into `body` is
    /// that SwiftUI can then skip a block whose inputs are unchanged. If either class
    /// ever compared by identity instead of by value, nothing would break, nothing would
    /// look wrong, and every block would silently re-parse on every streamed chunk —
    /// which is the cost the move was made to remove. The fix then is memoising the
    /// faces, not weakening the conformance, so this fails loudly first.
    func testTheThemesFacesAndColoursCompareByValue() {
        XCTAssertEqual(PanelTheme.NativeFont.body(1), PanelTheme.NativeFont.body(1))
        XCTAssertEqual(PanelTheme.NativeFont.heading(1, 1), PanelTheme.NativeFont.heading(1, 1))
        XCTAssertEqual(PanelTheme.NativeFont.code(1, weight: .bold),
                       PanelTheme.NativeFont.code(1, weight: .bold))
        XCTAssertEqual(PanelTheme.NativeFont.citation(1), PanelTheme.NativeFont.citation(1))
        XCTAssertEqual(PanelTheme.NativePalette.primaryText, PanelTheme.NativePalette.primaryText)
        XCTAssertEqual(PanelTheme.NativePalette.accent, PanelTheme.NativePalette.accent)
        // And a face that differs really does differ, so the assertions above are not
        // all passing for the reason that every NSFont compares equal to every other.
        XCTAssertNotEqual(PanelTheme.NativeFont.body(1), PanelTheme.NativeFont.body(2))
    }
}
