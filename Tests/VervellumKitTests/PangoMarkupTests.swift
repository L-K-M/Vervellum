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

    func testTablesKeepLongCellsAndActionableCitations() {
        let cell = String(repeating: "evidence ", count: 20) + "[2]"
        let markdown = "| Claim | Detail |\n| --- | --- |\n| <tag> | \(cell) |"
        let markup = PangoMarkup.answer(markdown, sources: sources)
        XCTAssertTrue(markup.contains(String(repeating: "evidence ", count: 20)))
        XCTAssertTrue(markup.contains("&lt;tag&gt;"))
        XCTAssertTrue(markup.contains("<a href=\"https://two.example.com\" title="))
        // No ellipsis anywhere: a table cell is never truncated. That holds only while
        // the fixture sources stay under the tooltip's own caps, which are the one other
        // thing here that can produce one — so the coupling is checked rather than
        // written down. Without the loop, lengthening a fixture title later fails this
        // test on a bare `…` with nothing to say which of the two truncations made it.
        XCTAssertFalse(markup.contains("…"))
        for source in sources {
            XCTAssertFalse(PangoMarkup.preview(of: source).contains("…"),
                           "the fixture for \(source.url) now trips the tooltip cap, so "
                            + "the assertion above is no longer about table cells")
        }
    }

    func testRendersACitationAsALink() {
        let markup = PangoMarkup.inline("As shown [1].", sources: sources)
        XCTAssertTrue(markup.contains("<a href=\"https://one.example.com\" title="))
        XCTAssertTrue(markup.contains("[1]</span></a>."))
        XCTAssertTrue(markup.hasPrefix("As shown "))
    }

    /// Hovering a citation says what it cites, which on GTK is one attribute rather than
    /// a hit test: `title` on an `<a>` is the link tooltip a `GtkLabel` already draws.
    func testACitationCarriesItsSourceAsATooltip() {
        // `wasRead` is derived from the page text, so a source that was read is one that
        // carries some.
        let read = Source(number: 1, url: "https://one.example.com", title: "One & Only",
                          snippet: "", publishedAt: "2026-01-05", fullText: "The page.")
        let markup = PangoMarkup.inline("As shown [1].", sources: [read])

        XCTAssertTrue(markup.contains("title=\"[1] One &amp; Only · one.example.com "
                                      + "· 2026-01-05 · page read\""),
                      markup)
    }

    /// A headline with a quotation mark in it would terminate the `title` attribute
    /// early and corrupt every byte of markup after it — the whole paragraph would
    /// render as escaped text. `g_markup_escape_text` handles it (`&quot;`, and `&apos;`
    /// for the single quote), which is why the attribute is safe; this pins that rather
    /// than trusting it, because the failure is silent until a source is titled the way
    /// newspapers title things.
    func testAQuotedTitleCannotEscapeTheTooltipAttribute() {
        let quoted = Source(number: 1, url: "https://one.example.com",
                            title: "The \"Best\" Widgets of 2026", snippet: "")
        let markup = PangoMarkup.inline("As shown [1].", sources: [quoted])

        XCTAssertFalse(markup.contains("\"Best\""), markup)
        XCTAssertTrue(markup.contains("&quot;Best&quot;"), markup)
        // And the attribute still closes where it should: one `title="` and, after it,
        // the tag's own `>` rather than a stray one from the title.
        XCTAssertTrue(markup.contains("&quot;Best&quot; Widgets of 2026 · one.example.com"
                                      + " · search summary\">"),
                      markup)
    }

    /// And the apostrophe, the other character that could close the attribute early.
    ///
    /// Pinned rather than described: `g_markup_escape_text` spells it `&apos;`, a round
    /// of review read it as `&#39;`, and nothing on this side of the call can be read to
    /// settle which a build produced. The entity itself is not the point — that the
    /// character cannot survive raw is — but an assertion that names it is the only kind
    /// that would notice GLib changing its mind.
    func testAnApostropheInATitleIsEscapedToo() {
        let quoted = Source(number: 1, url: "https://one.example.com",
                            title: "It's Widgets", snippet: "")
        let markup = PangoMarkup.inline("As shown [1].", sources: [quoted])

        XCTAssertFalse(markup.contains("It's"), markup)
        XCTAssertTrue(markup.contains("It&apos;s"), markup)
    }

    /// And the angle brackets, which would inject a tag rather than merely close the
    /// attribute early. Pinned in a *title* for the same reason the quote is: the prose
    /// path already has a test, and this is the newer surface.
    func testAngleBracketsInATitleAreEscapedToo() {
        let tagged = Source(number: 1, url: "https://one.example.com",
                            title: "Cheap <b>Widgets", snippet: "")
        let markup = PangoMarkup.inline("As shown [1].", sources: [tagged])

        XCTAssertFalse(markup.contains("<b>"), markup)
        XCTAssertTrue(markup.contains("&lt;b&gt;"), markup)
    }

    /// A domain too long for the tooltip keeps the end that names the site.
    ///
    /// Cut from the other end, every host under a long shared prefix reads the same and
    /// none of them names a site the reader can place — which is the ambiguity the caps
    /// were added to prevent, reintroduced by the cap itself.
    func testALongDomainIsCutFromTheFrontSoTheSiteSurvives() {
        let long = Source(number: 1,
                          url: "https://cdn.assets.internal.widgets.example.com/notes",
                          title: "Notes", snippet: "")
        let preview = PangoMarkup.preview(of: long)

        XCTAssertTrue(preview.contains("widgets.example.com"), preview)
        XCTAssertFalse(preview.contains("cdn.assets"), preview)
        XCTAssertTrue(preview.contains("…"), preview)
    }

    /// A citation to a page nobody read is worth less than one to a page that was, and
    /// the number in the prose cannot say which — so the tooltip does, either way.
    func testTheTooltipAlwaysSaysWhetherThePageWasRead() {
        let summary = PangoMarkup.preview(of: Source(number: 1, url: "https://one.example.com",
                                                     title: "One", snippet: ""))
        XCTAssertTrue(summary.hasSuffix("search summary"), summary)
        XCTAssertFalse(summary.contains("·  ·"), "an absent date must not leave a gap: \(summary)")

        // The other half, which this test's name promised and only the exact-string
        // assertion above happened to cover: loosen that one and nothing would have
        // been left saying what a page that *was* read looks like.
        let read = PangoMarkup.preview(of: Source(number: 2, url: "https://two.example.com",
                                                  title: "Two", snippet: "",
                                                  fullText: "The page."))
        XCTAssertTrue(read.hasSuffix("page read"), read)
        XCTAssertFalse(read.contains("search summary"), read)
    }

    /// A page's own `<title>` is unbounded, and a headline written for a search engine
    /// runs long enough to push everything after it off the end of a one-line tooltip —
    /// including the read-versus-summary fact, which is the one worth hovering for.
    func testALongTitleCannotSwallowTheTooltip() {
        let shouty = Source(number: 1, url: "https://one.example.com",
                            title: String(repeating: "Widget", count: 40), snippet: "")
        let preview = PangoMarkup.preview(of: shouty)

        XCTAssertTrue(preview.hasSuffix("· one.example.com · search summary"), preview)
        XCTAssertTrue(preview.contains("…"), preview)
        XCTAssertLessThan(preview.count, 120, preview)
    }

    /// The cap counts what the reader will be shown, not what the page's markup held.
    ///
    /// The two halves of one bug. A `<title>` is usually a line break and the
    /// indentation around it, so a title that reads short can be long in characters:
    /// counted raw, the cap fires on padding — cutting a title nobody would call long
    /// and stamping an ellipsis on it for text that was never going to be drawn. The
    /// second case is the same fact taken to its end: indented far enough, the whole cap
    /// lands inside the whitespace and the tooltip is an ellipsis and nothing else.
    func testTheTooltipCapCountsVisibleCharacters() {
        let indented = Source(number: 1, url: "https://one.example.com",
                              title: "\n" + String(repeating: " ", count: 100) + "Widgets\n",
                              snippet: "")
        XCTAssertEqual(PangoMarkup.preview(of: indented),
                       "[1] Widgets · one.example.com · search summary")

        // And a title that really is too long is still cut, with the ellipsis earned.
        let long = Source(number: 1, url: "https://one.example.com",
                          title: String(repeating: "W", count: 65), snippet: "")
        XCTAssertEqual(PangoMarkup.preview(of: long),
                       "[1] " + String(repeating: "W", count: 64)
                        + "… · one.example.com · search summary")
    }

    /// The cap holds for every field that comes off the network, not only the title.
    ///
    /// A cap on one field is a cap on nothing: the domain and the date are whatever the
    /// search backend returned, and either could be long enough to push the
    /// read-versus-summary fact — the one worth hovering for — off the end of the line
    /// the title cap was written to protect.
    func testNoSingleFieldCanSwallowTheTooltip() {
        let shouty = Source(number: 1,
                            url: "https://" + String(repeating: "long", count: 30) + ".example",
                            title: "Widgets", snippet: "",
                            publishedAt: String(repeating: "x", count: 200))
        let preview = PangoMarkup.preview(of: shouty)

        XCTAssertTrue(preview.hasSuffix("· search summary"), preview)
        XCTAssertLessThan(preview.count, 160, preview)

        // And the longest field a backend returns is not in the tooltip at all. A
        // snippet is a paragraph; a tooltip is a line, and GTK will not wrap it well.
        // Documented above `preview`, and pinned here, because the way that decision
        // gets undone is somebody adding the snippet to the list of "facts worth
        // showing" without noticing which of them is measured in sentences.
        let wordy = Source(number: 1, url: "https://one.example.com", title: "Widgets",
                           snippet: String(repeating: "snippet ", count: 40))
        let wordyPreview = PangoMarkup.preview(of: wordy)
        XCTAssertFalse(wordyPreview.contains("snippet"), wordyPreview)
        XCTAssertLessThan(wordyPreview.count, 120, wordyPreview)
    }

    /// A tooltip is one line, and neither of the two fields that come off the network
    /// can be trusted to be one: a title carries whatever was between the page's own
    /// `<title>` tags, and a date field is sometimes present but blank.
    func testATooltipIsOneLineWhateverTheSourceCarries() {
        let ragged = Source(number: 1, url: "https://one.example.com",
                            title: "\n  Widgets\n  and Gadgets  ", snippet: "",
                            publishedAt: "   ")
        XCTAssertEqual(PangoMarkup.preview(of: ragged),
                       "[1] Widgets and Gadgets · one.example.com · search summary")
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
