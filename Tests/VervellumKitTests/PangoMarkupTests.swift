#if os(Linux)
import XCTest
@testable import VervellumKit

/// The inline renderer for the GTK front end. `GTK.escape` is a plain GLib call, so
/// these run without a display.
final class PangoMarkupTests: XCTestCase {

    private let sources = [
        Source(number: 1, url: "https://one.example.com", title: "One", snippet: ""),
        Source(number: 2, url: "https://two.example.com", title: "Two", snippet: ""),
    ]

    func testRendersACitationAsALink() {
        let markup = PangoMarkup.inline("As shown [1].", sources: sources)
        XCTAssertTrue(markup.contains("<a href=\"https://one.example.com\">"))
        XCTAssertTrue(markup.contains("[1]</span></a>."))
        XCTAssertTrue(markup.hasPrefix("As shown "))
    }

    /// `**Cost [2]:**` is the commonest shape a model writes. Parsing the text on
    /// either side of the citation separately left both asterisk pairs literal.
    func testEmphasisSpanningACitationStillRenders() {
        let markup = PangoMarkup.inline("The **Swift 6 toolchain [1]** is required.", sources: sources)
        XCTAssertFalse(markup.contains("**"), markup)
        XCTAssertTrue(markup.hasPrefix("The <b>Swift 6 toolchain <a href="), markup)
        XCTAssertTrue(markup.hasSuffix("</a></b> is required."), markup)
    }

    func testItalicAndCodeAcrossACitation() {
        let italic = PangoMarkup.inline("*see [1] and [2]* now", sources: sources)
        XCTAssertTrue(italic.hasPrefix("<i>see <a href="), italic)
        XCTAssertTrue(italic.contains("</a> and <a href="), italic)
        XCTAssertTrue(italic.hasSuffix("</a></i> now"), italic)
    }

    /// Markup characters in the prose are escaped, on both sides of a citation.
    func testEscapesTheProse() {
        let markup = PangoMarkup.inline("a < b [1] & c > d", sources: sources)
        XCTAssertTrue(markup.hasPrefix("a &lt; b <a href="), markup)
        XCTAssertTrue(markup.hasSuffix("</a> &amp; c &gt; d"), markup)
    }

    /// The placeholder is a private-use character; one that arrives in the answer
    /// must not become a citation.
    func testAPrivateUseCharacterInTheAnswerIsNotACitation() {
        let markup = PangoMarkup.inline("odd \u{E000} text [1]", sources: sources)
        XCTAssertEqual(markup.components(separatedBy: "<a href=").count - 1, 1)
        XCTAssertTrue(markup.hasPrefix("odd  text "), markup)
    }

    /// An out-of-range citation stays as the model wrote it, without a link.
    func testAnUnknownCitationStaysLiteral() {
        let markup = PangoMarkup.inline("**bold [7]** end", sources: sources)
        XCTAssertEqual(markup, "<b>bold [7]</b> end")
    }
}
#endif
