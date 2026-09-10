#if os(Linux)
import Foundation

/// Renders a research turn as Pango markup for the GTK front end.
///
/// The macOS panel builds a SwiftUI view tree; GTK gets markup strings instead. That is
/// not a lesser choice — Pango markup gives bold, italic, monospace, colour, size and
/// clickable links in one attributed string, which is most of what an answer needs, and
/// it avoids managing a widget per span.
///
/// What matters is that the *structure* is shared: block parsing comes from
/// `MarkdownParser` and citation parsing from `CitationValidator`, exactly as on macOS.
/// Only the final serialisation differs, so a fix to either parser reaches both.
///
/// Everything that came from the model or the web is escaped. An unescaped `<` in a
/// search-result title makes `gtk_label_set_markup` reject the whole string, and the
/// paragraph renders as an error message.
enum PangoMarkup {

    /// Colours, as hex, mirroring the macOS palette's meaning rather than its exact
    /// values — GTK draws on a themed background, so these are chosen to read on both
    /// the light and dark Adwaita palettes.
    enum Colour {
        static let accent = "#c4630f"
        static let secondary = "#7a7a7a"
        static let supported = "#217a4a"
        static let contradicted = "#b32d2d"
        static let mixed = "#9a6a10"
        static let insufficient = "#5a6a80"
        static let opinion = "#6a54a8"

        static func verdict(_ verdict: Verdict) -> String {
            switch verdict {
            case .supported: return supported
            case .contradicted: return contradicted
            case .mixed: return mixed
            case .insufficient: return insufficient
            case .opinion: return opinion
            }
        }
    }

    /// A glyph per verdict, so meaning is never carried by colour alone — the same rule
    /// the macOS panel follows with SF Symbols.
    static func glyph(_ verdict: Verdict) -> String {
        switch verdict {
        case .supported: return "✓"
        case .contradicted: return "✗"
        case .mixed: return "≈"
        case .insufficient: return "?"
        case .opinion: return "❞"
        }
    }

    // MARK: Answer

    /// The answer's markdown as markup, with `[n]` citations turned into links.
    static func answer(_ markdown: String, sources: [Source]) -> String {
        MarkdownParser.parse(markdown).map { block in
            switch block.kind {
            case .paragraph:
                return inline(block.text, sources: sources)
            case .heading(let level):
                let size = level == 1 ? "large" : (level == 2 ? "medium" : "small")
                return "<span size=\"\(size)\" weight=\"bold\">"
                    + inline(block.text, sources: sources) + "</span>"
            case .bullet(let depth):
                return String(repeating: "    ", count: depth) + "• "
                    + inline(block.text, sources: sources)
            case .ordered(let number, let depth):
                return String(repeating: "    ", count: depth) + "\(number). "
                    + inline(block.text, sources: sources)
            case .quote:
                return "<span foreground=\"\(Colour.secondary)\">"
                    + inline(block.text, sources: sources) + "</span>"
            case .code:
                // Not run through `inline`: inside a code block, markdown emphasis
                // markers and bracketed numbers are literal text.
                return "<tt>" + GTK.escape(block.text) + "</tt>"
            case .table(let headers, let rows):
                return table(headers, rows: rows, sources: sources)
            case .rule:
                return "<span foreground=\"\(Colour.secondary)\">──────────</span>"
            }
        }.joined(separator: "\n\n")
    }

    /// Inline markdown plus citations, as markup.
    ///
    /// Citations are resolved first, so a `[3]` becomes a link before emphasis is
    /// parsed and cannot be mistaken for markdown link syntax. Emphasis is then parsed
    /// over the *whole* run, with each citation standing in as one placeholder
    /// character. Parsing the text between citations piece by piece would leave a bold
    /// run that contains a citation — `**Cost [2]:**`, the commonest shape a model
    /// writes — with its opening marker in one piece and its closing marker in
    /// another, and both would be printed as literal asterisks.
    static func inline(_ text: String, sources: [Source]) -> String {
        let mask = CitationMask(text, sourceCount: sources.count)
        let citations = mask.sourceIndices.map { indices -> String in
            let cited = indices.map { sources[$0] }
            // A grouped marker links and describes its *first* source, the same rule the
            // macOS chip follows: a tooltip is a line about one page, not a list, and
            // `[3,7]` still shows both numbers and still has both rows in the source
            // list under the answer. What it must not become is a summary of two pages
            // in one line — least of all one line saying "page read" for a pair where
            // only one was.
            guard let first = cited.first else { return "" }
            let label = cited.map { String($0.number) }.joined(separator: ",")
            return "<a href=\"\(GTK.escape(first.url))\" title=\"\(GTK.escape(preview(of: first)))\">"
                + "<span size=\"small\" font_family=\"monospace\">[\(label)]</span></a>"
        }

        var result = ""
        var pending = citations.makeIterator()
        for piece in emphasis(mask.text).split(separator: CitationMask.placeholder, omittingEmptySubsequences: false) {
            result += piece
            if let citation = pending.next() { result += citation }
        }
        return result
    }

    /// What hovering a citation says about the source it names.
    ///
    /// Pango's `title` on an `<a>` is GTK's own link tooltip, so this costs one attribute
    /// rather than a hit test — the macOS panel has to draw its prose through an
    /// `NSTextView` to answer the same gesture, because a SwiftUI `Text` has no per-run
    /// hit testing at all.
    ///
    /// Three facts, in the order the source list gives them, and the third is the one
    /// that matters: a citation to a page that was read is worth more than one to a
    /// search summary, and the number in the prose cannot say which. Deliberately not the
    /// snippet — a tooltip is a line, not a card, and GTK will not wrap it well.
    static func preview(of source: Source) -> String {
        // The title, flattened and *then* capped. A page's own `<title>` is unbounded and
        // a headline written for a search engine runs to a few hundred characters, which
        // would push the three facts after it — and the read-versus-summary one most of
        // all — off the end of a one-line tooltip. Sixty-four is enough to tell two
        // sources apart.
        //
        // Flattened first because the cap has to count what the reader will see. A
        // `<title>` is usually a line break and the indentation around it, as the `.map`
        // below says — so counting the raw string measures the whitespace, and a title
        // that fits comfortably gets cut mid-word and stamped with an ellipsis for
        // padding nobody was going to be shown. Deeply indented, it could be cut to
        // nothing but the ellipsis.
        //
        // And the two fields after it are capped too, at a shorter length. The title is
        // the one that runs long by design, but a domain and a date are whatever the
        // search backend put in them — the `.map` below already treats the date as
        // possibly a bare space — and either could be returned long enough to push the
        // read-versus-summary fact off the end, which is the whole failure the title cap
        // was written to stop. A cap on one field only holds while the others behave.
        // Led by the number, because a grouped marker links its first source only: the
        // label reads `[3,7]` and everything after this describes 3, so a reader hovering
        // it could otherwise attribute "page read" to 7 — the misattribution the
        // read-versus-summary fact exists to prevent. The macOS card has always opened
        // with the number for the same reason; this is the GTK half of that.
        let capped = clipped(source.title, to: maxTooltipTitle)
        var parts = ["[\(source.number)] \(capped)", clippedHost(source.domain)]
        if let published = source.publishedAt {
            parts.append(clipped(published, to: maxTooltipField))
        }
        parts.append(source.wasRead ? "page read" : "search summary")
        return parts
            // Every part is flattened before it is judged empty, because a title is
            // whatever a page's own `<title>` held — a line break and the indentation
            // around it, most often — and a date is whatever the search backend put in
            // the field, which is sometimes a space. Unflattened, the first would break
            // a one-line tooltip across two, and the second would pass the emptiness
            // test below and leave a bare `·  ·` in the middle of the line.
            .map(flattened)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// `text` flattened to one line and cut to `limit` visible characters.
    ///
    /// Flattened first, so the cut counts what the reader will be shown rather than the
    /// whitespace a page's own `<title>` wraps itself in.
    private static func clipped(_ text: String, to limit: Int) -> String {
        let flat = flattened(text)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// A host cut to the same length, but from the front.
    ///
    /// A domain identifies itself by its tail. Cut from the other end,
    /// `cdn.assets.internal.widgets.example.com` becomes
    /// `cdn.assets.internal.widgets.exam…`, which names no site the reader can place and
    /// reads identically to every sibling under the same long prefix — while the part
    /// that would have told them apart, and told them whose page this is, is the part
    /// thrown away. The whole reason the tooltip carries a domain at all is to answer
    /// "whose page is `[21]`", so the answer is the end of it.
    private static func clippedHost(_ domain: String) -> String {
        let flat = flattened(domain)
        return flat.count > maxTooltipField
            ? "…" + String(flat.suffix(maxTooltipField)) : flat
    }

    /// One line's worth of whatever a page or a search backend put in a field.
    ///
    /// Idempotent, which is what lets the title go through it twice — once before the
    /// cap, so the cap counts visible characters, and once with everything else.
    private static func flattened(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// How much of a source's title a tooltip will carry.
    private static let maxTooltipTitle = 64

    /// And of a domain or a date, which are shorter by nature and longer only when
    /// something upstream has gone wrong.
    private static let maxTooltipField = 32

    /// The inline markdown Pango can express: bold, italic and code.
    ///
    /// Deliberately small. Pango markup is not markdown, and a half-implemented
    /// converter that mangles an unmatched marker is worse than one that leaves it
    /// visible — which is the streaming case, where every answer is briefly malformed.
    static func emphasis(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)

        while let marker = nextMarker(in: rest) {
            result += GTK.escape(String(rest[rest.startIndex..<marker.start]))
            result += marker.open + GTK.escape(String(marker.content)) + marker.close
            rest = rest[marker.end...]
        }
        result += GTK.escape(String(rest))
        return result
    }

    private struct Marker {
        var start: Substring.Index
        var end: Substring.Index
        var content: Substring
        var open: String
        var close: String
    }

    /// The earliest complete `**bold**`, `*italic*` or `` `code` `` run.
    ///
    /// Only *complete* pairs match, so a marker whose partner has not streamed in yet
    /// stays literal and settles into place when it arrives.
    private static func nextMarker(in text: Substring) -> Marker? {
        let candidates: [(String, String, String)] = [
            ("**", "<b>", "</b>"),
            ("`", "<tt>", "</tt>"),
            ("*", "<i>", "</i>"),
        ]
        var best: Marker?
        for (delimiter, open, close) in candidates {
            guard let openRange = text.range(of: delimiter) else { continue }
            let afterOpen = openRange.upperBound
            guard afterOpen < text.endIndex,
                  let closeRange = text.range(of: delimiter, range: afterOpen..<text.endIndex),
                  closeRange.lowerBound > afterOpen
            else { continue }
            let marker = Marker(start: openRange.lowerBound,
                                end: closeRange.upperBound,
                                content: text[afterOpen..<closeRange.lowerBound],
                                open: open, close: close)
            if best == nil || marker.start < best!.start { best = marker }
        }
        return best
    }

    // MARK: Tables

    /// Labeled rows wrap without truncating evidence or disabling cell citations.
    private static func table(_ headers: [String], rows: [[String]], sources: [Source]) -> String {
        guard !rows.isEmpty else {
            return headers.map { inline($0, sources: sources) }.joined(separator: " · ")
        }
        return rows.map { row in
            headers.indices.map { column in
                let value = row.indices.contains(column) ? row[column] : ""
                return "<b>" + inline(headers[column], sources: sources) + ":</b> "
                    + inline(value, sources: sources)
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Turn sections

    static func question(_ text: String) -> String {
        "<span weight=\"bold\">" + GTK.escape(text) + "</span>"
    }

    static func trail(_ turn: ResearchTurn) -> String {
        guard !turn.stage.isTerminal else {
            var parts: [String] = []
            // A stopped run must say so: a truncated paragraph over an ordinary-looking
            // summary line reads as the model simply stopping there, and nobody would
            // know its claims were never checked.
            if turn.stage == .cancelled { parts.append("Stopped") }
            parts.append(turn.searches.isEmpty
                         ? "no search"
                         : "\(turn.searches.count) search\(turn.searches.count == 1 ? "" : "es")")
            if !turn.sources.isEmpty {
                parts.append("\(turn.sources.count) source\(turn.sources.count == 1 ? "" : "s")")
            }
            if !turn.findings.isEmpty {
                parts.append("\(turn.findings.count) claim\(turn.findings.count == 1 ? "" : "s") checked")
            }
            if let duration = turn.duration { parts.append(Formatting.duration(duration)) }
            var line = small(parts.joined(separator: " · "))
            // When nothing was searched, the planner's reading is the explanation of
            // why — and, on this platform, the only place it is shown.
            if turn.searches.isEmpty, !turn.reading.isEmpty {
                line += "\n" + small(GTK.escape(turn.reading))
            }
            return line
        }
        return small(turn.runningProgressLabel + "…")
    }

    static func notices(_ notices: [TurnNotice]) -> String? {
        guard !notices.isEmpty else { return nil }
        return notices
            .map { "<span foreground=\"\(Colour.mixed)\">⚠ " + GTK.escape($0.message) + "</span>" }
            .joined(separator: "\n")
    }

    static func findings(_ findings: [Finding]) -> String? {
        guard !findings.isEmpty else { return nil }
        let rows = findings.map { finding -> String in
            let colour = Colour.verdict(finding.verdict)
            var row = "<span foreground=\"\(colour)\" weight=\"bold\">"
                + "\(glyph(finding.verdict)) \(GTK.escape(finding.verdict.label.uppercased()))</span>"
            if !finding.sourceNumbers.isEmpty {
                let numbers = finding.sourceNumbers.map(String.init).joined(separator: ",")
                row += " <span size=\"small\" font_family=\"monospace\" foreground=\"\(Colour.accent)\">"
                    + "[\(numbers)]</span>"
            }
            row += "\n" + GTK.escape(finding.claim)
            if !finding.reasoning.isEmpty { row += "\n" + small(GTK.escape(finding.reasoning)) }
            return row
        }
        return sectionLabel("Claims") + "\n" + rows.joined(separator: "\n\n")
    }

    static func limitations(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        return sectionLabel("Limitations") + "\n" + small(GTK.escape(text))
    }

    static func sources(_ sources: [Source], cited: Set<Int>) -> String? {
        guard !sources.isEmpty else { return nil }
        let rows = sources.map { source -> String in
            let isCited = cited.contains(source.number)
            let number = "<span font_family=\"monospace\" foreground=\""
                + (isCited ? Colour.accent : Colour.secondary) + "\">[\(source.number)]</span>"
            let title = "<a href=\"\(GTK.escape(source.url))\">" + GTK.escape(source.title) + "</a>"
            return "\(number) \(title)\n" + small(GTK.escape(source.domain))
        }
        let heading = sectionLabel("Sources — \(cited.count) of \(sources.count) cited")
        return heading + "\n" + rows.joined(separator: "\n")
    }

    static func followups(_ followups: [String]) -> String? {
        guard !followups.isEmpty else { return nil }
        let rows = followups.map { "↳ " + GTK.escape($0) }.joined(separator: "\n")
        return sectionLabel("Next") + "\n<span foreground=\"\(Colour.accent)\">\(rows)</span>"
    }

    static func failure(_ message: String) -> String {
        "<span foreground=\"\(Colour.contradicted)\">⚠ " + GTK.escape(message) + "</span>"
    }

    // MARK: Helpers

    private static func sectionLabel(_ text: String) -> String {
        "<span size=\"x-small\" weight=\"bold\" foreground=\"\(Colour.secondary)\">"
            + GTK.escape(text.uppercased()) + "</span>"
    }

    private static func small(_ markup: String) -> String {
        "<span size=\"small\" foreground=\"\(Colour.secondary)\">\(markup)</span>"
    }
}
#endif
