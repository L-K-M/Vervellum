import SwiftUI

/// Renders one markdown block, turning `[3]` citation markers into clickable,
/// monospaced links to the source they name.
///
/// Inline emphasis is handled by `AttributedString(markdown:)` rather than by hand.
/// Citations, though, cannot simply be substituted before or after that parse:
///
/// * Substituting *before* means the replacement text has to survive markdown
///   parsing intact, and `[3]` is markdown link syntax.
/// * Substituting *after* means finding `[3]` inside an already-parsed
///   `AttributedString`, where an emphasis run may have split it in two.
///
/// So each citation is replaced with the shared private-use placeholder
/// before parsing — one character, no markdown meaning, impossible to split — and
/// the placeholders are swapped for styled links afterwards, in order.
struct MarkdownText: View {

    let markdown: String
    let sources: [Source]
    var scale: Double = 1.0
    /// The block's base font. Passed in rather than applied by the caller: run-level
    /// attributes inside an `AttributedString` beat a `.font()` modifier on the
    /// enclosing `Text`, so a heading styled from outside would silently render at
    /// body size.
    var font: Font?

    var body: some View {
        Text(attributed)
            .font(font ?? PanelTheme.Font.body(scale))
            .textSelection(.enabled)
            .tint(PanelTheme.Palette.accent)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        CitationText.render(markdown, sources: sources, scale: scale)
    }
}

/// AppKit-side serialization, separate from the view so link attributes are testable.
enum CitationText {
    private static let placeholder = CitationMask.placeholder

    static func render(_ markdown: String, sources: [Source], scale: Double = 1) -> AttributedString {
        let (masked, citations) = Self.mask(markdown, sources: sources)
        var result = Self.parseInline(masked)
        // Markdown can consume text inside link destinations. Preserve every citation
        // position by falling back to literal text rather than shifting later chips.
        if result.characters.filter({ $0 == placeholder }).count != citations.count {
            result = AttributedString(masked)
        }
        // A link the model wrote is exactly what the citation rule forbids: evidence
        // is cited by number, and a URL in the prose is flagged, never followed. The
        // markdown parser turns `[text](url)` into a clickable run, so the attribute
        // is dropped and the text kept. The citation chips below are the only links.
        result.link = nil
        Self.substitute(citations, in: &result, scale: scale)
        return result
    }

    // MARK: Masking

    /// One citation marker's rendered form.
    private struct MaskedCitation {
        var label: String
        var url: URL?
    }

    /// Replaces every valid citation marker with a placeholder character, returning
    /// the masked text and the citations in the order they appeared.
    private static func mask(_ text: String, sources: [Source]) -> (String, [MaskedCitation]) {
        let mask = CitationMask(text, sourceCount: sources.count)
        let citations = mask.sourceIndices.map { indices -> MaskedCitation in
            let cited = indices.map { sources[$0] }
            // A grouped marker opens its first source; all remain in the source list.
            return MaskedCitation(label: cited.map { String($0.number) }.joined(separator: ","),
                                  url: cited.first.flatMap { URL(string: $0.url) })
        }
        return (mask.text, citations)
    }

    // MARK: Inline parsing

    private static func parseInline(_ text: String) -> AttributedString {
        // `.inlineOnlyPreservingWhitespace` keeps the block's own spacing and does not
        // try to interpret block structure — `MarkdownParser` already did that.
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        // A half-arrived construct mid-stream must never blank the paragraph.
        return AttributedString(text)
    }

    /// Replaces each placeholder character with its citation, in order.
    private static func substitute(_ citations: [MaskedCitation],
                                   in attributed: inout AttributedString,
                                   scale: Double) {
        for citation in citations {
            guard let range = attributed.range(of: String(placeholder)) else { return }
            var chip = AttributedString("[\(citation.label)]")
            chip.font = PanelTheme.Font.citation(scale)
            chip.foregroundColor = PanelTheme.Palette.accent
            if let url = citation.url { chip.link = url }
            attributed.replaceSubrange(range, with: chip)
        }
    }
}

/// Renders a whole answer: block structure from `MarkdownParser`, inline content and
/// citations from `MarkdownText`.
struct MarkdownBody: View {

    let markdown: String
    let sources: [Source]
    var scale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.medium) {
            ForEach(MarkdownParser.parse(markdown)) { block in
                row(for: block)
            }
        }
    }

    @ViewBuilder
    private func row(for block: MarkdownParser.Block) -> some View {
        switch block.kind {
        case .paragraph:
            MarkdownText(markdown: block.text, sources: sources, scale: scale)

        case .heading(let level):
            MarkdownText(markdown: block.text, sources: sources, scale: scale,
                         font: PanelTheme.Font.heading(level, scale))
                .padding(.top, level == 1 ? PanelTheme.Space.small : PanelTheme.Space.hair)

        case .bullet(let depth):
            listRow(marker: "•", depth: depth, text: block.text, monospacedMarker: false)

        case .ordered(let number, let depth):
            listRow(marker: "\(number).", depth: depth, text: block.text, monospacedMarker: true)

        case .quote:
            HStack(alignment: .top, spacing: PanelTheme.Space.medium) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(PanelTheme.Palette.accent.opacity(0.55))
                    .frame(width: 2)
                MarkdownText(markdown: block.text, sources: sources, scale: scale)
                    .foregroundStyle(PanelTheme.Palette.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language):
            CodeBlock(code: block.text, language: language, scale: scale)

        case .table(let headers, let rows):
            TableBlock(headers: headers, rows: rows, sources: sources, scale: scale)

        case .rule:
            Divider().overlay(PanelTheme.Palette.hairline)
        }
    }

    private func listRow(marker: String, depth: Int, text: String, monospacedMarker: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelTheme.Space.small) {
            Text(marker)
                .font(monospacedMarker ? PanelTheme.Font.code(scale) : PanelTheme.Font.body(scale))
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
                // A fixed width keeps every item's text on the same left edge, which
                // a proportional marker ("1." vs "10.") would otherwise ragged out.
                .frame(width: 16, alignment: .trailing)
            MarkdownText(markdown: text, sources: sources, scale: scale)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A fenced code block: horizontally scrollable rather than wrapped, because
/// wrapping code in a 460-point panel makes it unreadable.
struct CodeBlock: View {
    let code: String
    let language: String
    var scale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language.uppercased())
                    .font(PanelTheme.Font.label)
                    .tracking(0.6)
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                    .padding(.horizontal, PanelTheme.Space.medium)
                    .padding(.top, PanelTheme.Space.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(PanelTheme.Font.code(scale))
                    .textSelection(.enabled)
                    .padding(PanelTheme.Space.medium)
            }
        }
        .background(PanelTheme.Palette.cardFill, in:
            RoundedRectangle(cornerRadius: PanelTheme.Radius.card, style: .continuous))
    }
}

/// A pipe table, rendered as a real grid.
///
/// Cells go through `MarkdownText`, so emphasis and `[n]` citations work inside a
/// table exactly as they do in prose. The grid sits in a horizontal ScrollView for
/// the same reason code does: squashing a wide table into a 460-point panel makes
/// it unreadable, and a table the model produced is usually worth its width.
struct TableBlock: View {
    let headers: [String]
    let rows: [[String]]
    let sources: [Source]
    var scale: Double = 1.0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading,
                 horizontalSpacing: PanelTheme.Space.large,
                 verticalSpacing: PanelTheme.Space.small) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { column in
                        MarkdownText(markdown: headers[column], sources: sources,
                                     scale: scale, font: PanelTheme.Font.bodyEmphasis(scale))
                    }
                }
                // A direct child of Grid (not wrapped in GridRow) spans all columns.
                Divider().overlay(PanelTheme.Palette.hairline)
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            MarkdownText(markdown: rows[row][column], sources: sources,
                                         scale: scale)
                        }
                    }
                }
            }
            .padding(PanelTheme.Space.medium)
        }
        .background(PanelTheme.Palette.cardFill, in:
            RoundedRectangle(cornerRadius: PanelTheme.Radius.card, style: .continuous))
    }
}
