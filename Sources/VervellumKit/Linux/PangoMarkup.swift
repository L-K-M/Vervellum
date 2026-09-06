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
        let validation = CitationValidator.validate(answer: text, sourceCount: sources.count)
        var citations: [String] = []
        var flattened = ""
        for span in validation.spans {
            switch span {
            case .text(let value):
                // A placeholder that arrives in the answer itself is dropped, so it
                // cannot be read back as a citation.
                flattened += value.replacingOccurrences(of: String(placeholder), with: "")
            case .citation(let indices, let raw):
                let cited = indices.compactMap { sources.indices.contains($0) ? sources[$0] : nil }
                if let first = cited.first {
                    let label = cited.map { String($0.number) }.joined(separator: ",")
                    citations.append("<a href=\"\(GTK.escape(first.url))\">"
                                     + "<span size=\"small\" font_family=\"monospace\">[\(label)]</span></a>")
                } else {
                    citations.append(GTK.escape(raw))
                }
                flattened.append(placeholder)
            }
        }

        var result = ""
        var pending = citations.makeIterator()
        for piece in emphasis(flattened).split(separator: placeholder, omittingEmptySubsequences: false) {
            result += piece
            if let citation = pending.next() { result += citation }
        }
        return result
    }

    /// Stands in for a citation while emphasis is parsed. A private-use character:
    /// no markdown marker, and nothing `g_markup_escape_text` touches.
    private static let placeholder: Character = "\u{E000}"

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
        return small(turn.stage.label + "…")
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
