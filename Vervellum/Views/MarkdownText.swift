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
///
/// The result is drawn by `AnswerTextView` rather than by a SwiftUI `Text`, because a
/// chip has to answer a hover and a `Text` cannot say what is under the pointer: it has
/// no per-run hit testing, and no way to attach a gesture to a run. That is the only
/// reason this is not four lines of SwiftUI — see `CitationText.native`, which is where
/// the attributes a `Text` would have understood become ones AppKit draws.
struct MarkdownText: View, Equatable {

    let markdown: String
    let sources: [Source]
    var scale: Double = 1.0
    /// The block's base font. Passed in rather than applied by the caller: this is drawn
    /// by an `NSTextView`, and a `.font()` modifier on a representable reaches the
    /// SwiftUI wrapper rather than the text inside it — a heading styled from outside
    /// would silently render at body size.
    var font: NSFont? = nil
    /// The block's base colour, for the same reason. A quote is dimmer than prose, and
    /// `.foregroundStyle` outside this view would not reach the glyphs either.
    ///
    /// Both defaults are written out rather than left to the implicit nil an optional
    /// `var` carries. There is no hand-written initialiser any more — the memberwise one
    /// is what every call site below reaches — and a memberwise initialiser's defaults
    /// are worth having in the source rather than inferred, since a caller omitting
    /// `font` is the ordinary case.
    var color: NSColor? = nil

    /// The parse happens here, and the hover lives one view down. That split is the
    /// whole shape of this type, and it is load-bearing in both directions.
    ///
    /// Not in a `body` that also owns the hover: `@State` invalidates the view that
    /// holds it, so a chip crossed by the pointer would re-run a full markdown parse and
    /// attribute build for a result that does not depend on the hover at all — on the
    /// hottest path in the panel.
    ///
    /// Not in `init` either, which was the first answer to that and is worse. SwiftUI
    /// constructs a fresh value for *every* child each time a parent's `body` runs,
    /// whether or not that child's inputs changed; only `body` is skipped for a value
    /// that compares equal to the last one. A parse in `init` therefore runs once per
    /// block per parent render — and the parent re-renders on every streamed chunk, so a
    /// long answer re-parsed every finished paragraph, bullet and heading for each token
    /// that arrived at the end of it.
    ///
    /// In `body`, with `hover` held by `HoveredAnswer` below, both are avoided: the
    /// stored properties above are the inputs SwiftUI compares, so a block whose text,
    /// scale, font and colour are unchanged is not re-parsed, and a hover invalidates
    /// only the child. A theme change still restyles — it re-renders the parent with a
    /// different colour, which is a changed input.
    ///
    /// `Equatable` is what makes that comparison a defined one rather than whatever the
    /// runtime infers from the stored properties' layout. Every one of them already is
    /// (`Source` conforms, and both AppKit classes are `NSObject`), so the conformance
    /// is synthesized and costs a `==` on five fields in place of a comparison nobody
    /// here specified.
    var body: some View {
        HoveredAnswer(attributed: CitationText.native(
                        markdown, sources: sources, scale: scale,
                        font: font ?? PanelTheme.NativeFont.body(scale),
                        color: color ?? PanelTheme.NativePalette.primaryText),
                      sources: sources)
    }
}

/// The drawn block and the popover over it, holding the only state either needs.
///
/// Separate from `MarkdownText` for the reason its `body` gives: this is the view a
/// hover invalidates, and it must not be the view that parses.
private struct HoveredAnswer: View {

    let attributed: NSAttributedString
    let sources: [Source]

    /// The chip the pointer is resting on, if any.
    ///
    /// Scoped to this block, which means the panel does not *enforce* that only one
    /// popover is open — two blocks each holding a stale hover could in principle both
    /// present. Nothing observed does that, because leaving a chip clears it and a
    /// replaced storage clears it too; if it ever happens, the fix is a shared owner
    /// that dismisses the previous popover before presenting the next, not another
    /// guard here.
    ///
    /// Written out for the reason `MarkdownText`'s optionals are: this type is built
    /// through its memberwise initialiser, and a private stored property with no default
    /// suppresses that initialiser entirely.
    @State private var hover: CitationHover? = nil

    /// Bumped by every hover callback, so the deferred half of a chip-to-chip handoff
    /// can tell whether it is still the latest word.
    ///
    /// The handoff below closes the popover and opens the next one a run loop later. A
    /// callback landing in that gap — the pointer leaving the answer altogether, or
    /// reaching a third chip — is the newer fact, and without this the older one lands
    /// on top of it: a popover over prose the pointer has left, or a card describing one
    /// citation under an arrow pinned to another. The second is the failure the handoff
    /// exists to prevent, so it must not be reintroduced by the fix for it.
    @State private var generation = 0

    var body: some View {
        AnswerTextView(attributed: attributed, sources: sources) { next in
            // Chip to chip, the popover has to close and open again. SwiftUI reads
            // `attachmentAnchor` when it *presents*, and never again: assigning a new
            // hover while one is showing keeps `isPresented` true, so the card rerenders
            // with the new source under an arrow still pinned to the old chip. A preview
            // that points at one citation while describing another is the worst thing
            // this feature could do — it is precisely a claim about which source a
            // number names.
            //
            // Reachable even though adjacent markers are grouped into one chip: the
            // prose between two chips answers nil and would dismiss, but the pointer
            // moves in discrete `mouseMoved` events and a quick one crosses the gap
            // whole. So the nil is made here rather than waited for.
            generation &+= 1
            let asked = generation
            guard let next, let current = hover, next != current else {
                hover = next
                return
            }
            hover = nil
            DispatchQueue.main.async {
                guard asked == generation else { return }
                hover = next
            }
        }
            // The anchor is read as the popover opens, and `hover` is set in the same
            // state change that opens it — so the rect and the chip are always the same
            // chip. `.zero` is the value for a popover that is not being presented.
            .popover(isPresented: Binding(get: { hover != nil },
                                          set: { if !$0 { hover = nil } }),
                     attachmentAnchor: .rect(.rect(hover?.rect ?? .zero)),
                     arrowEdge: .top) {
                if let hover {
                    SourcePreview(source: hover.source)
                }
            }
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

    // MARK: AppKit

    /// The same text, as an `NSAttributedString` the answer's text view can draw.
    ///
    /// Built from `render`'s runs rather than by bridging it, because bridging loses
    /// almost everything that matters here: a SwiftUI `Font` and `Color` have no
    /// `NSAttributedString` counterpart at all, and `inlinePresentationIntent` — which is
    /// how `AttributedString(markdown:)` records bold and italic — survives as an
    /// attribute AppKit does not draw. So the structural attributes are read off the
    /// parse and turned into real fonts and colours here, once, where the mapping can be
    /// seen and tested.
    static func native(_ markdown: String,
                       sources: [Source],
                       scale: Double,
                       font: NSFont,
                       color: NSColor) -> NSAttributedString {
        let parsed = render(markdown, sources: sources, scale: scale)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            if let link = run.link {
                // A chip. `render` has already stripped every link the model wrote, so a
                // link attribute at this point is one this file put there.
                attributes[.link] = link
                attributes[.font] = PanelTheme.NativeFont.citation(scale)
                attributes[.foregroundColor] = PanelTheme.NativePalette.accent
            } else if let intent = run.inlinePresentationIntent {
                apply(intent, to: &attributes, base: font, scale: scale)
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    /// Markdown's inline intents as AppKit attributes.
    ///
    /// `code` replaces the face rather than adding a trait to it, which is why it is
    /// answered first: a monospaced run inside a bold sentence should be monospaced, and
    /// asking a monospaced family for a bold face after the fact would only sometimes
    /// find one. Everything else composes, so bold-italic works by being both.
    private static func apply(_ intent: InlinePresentationIntent,
                              to attributes: inout [NSAttributedString.Key: Any],
                              base: NSFont,
                              scale: Double) {
        var face = base
        if intent.contains(.code) {
            // Bold survives into code, which the trait path could not have promised and
            // this one can: `monospacedSystemFont` always resolves the weight asked of
            // it. `**`swift build`**` is ordinary markdown and the emphasis was being
            // dropped on the floor — italic is not offered, because a monospaced italic
            // is a face most families do not have and the slant would read as noise at
            // 11.5 points either way.
            face = PanelTheme.NativeFont.code(scale,
                                              weight: intent.contains(.stronglyEmphasized)
                                                  ? .bold : .regular)
        } else {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty { face = PanelTheme.NativeFont.adding(traits, to: base) }
        }
        attributes[.font] = face
        if intent.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
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
            // A grouped marker opens its first source, and hovering it previews that
            // same one: a popover is a card for one source, not a list. Every source a
            // grouped marker names is still in the list under the answer, which is
            // where the rest of them are read.
            return MaskedCitation(label: cited.map { String($0.number) }.joined(separator: ","),
                                  url: cited.first.flatMap { Self.openable($0.url) })
        }
        return (mask.text, citations)
    }

    /// A citation's address, but only when it is one a click may follow.
    ///
    /// `NSTextView` opens a `.link` run through `NSWorkspace`, which will launch *any*
    /// scheme a URL carries — `file:`, and whatever a third-party app has registered.
    /// A source address is harvested from the web, so it is not this panel's to trust:
    /// the GTK front end already refuses everything but http(s) in `GTK.openLink`, for
    /// the same reason and in the same words, and a chip that behaved differently on one
    /// platform would be the harder half to remember.
    ///
    /// A refused address still renders as a chip — the number, the face, the colour —
    /// and simply does not open. The source list under the answer is where its address
    /// is read either way.
    private static func openable(_ address: String) -> URL? {
        // A host as well as the scheme. `URL(string:)` will build `https:` — a scheme
        // and nothing else — and that passes a check that asks only what it starts
        // with. Nothing is opened by it, but this is the funnel that decides what a
        // click may reach, and a funnel that admits what it cannot describe is one
        // nobody can reason about later.
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
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
                         font: PanelTheme.NativeFont.heading(level, scale))
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
                MarkdownText(markdown: block.text, sources: sources, scale: scale,
                             color: PanelTheme.NativePalette.secondaryText)
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
                    .font(PanelTheme.Font.label(scale))
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
                                     scale: scale,
                                     font: PanelTheme.NativeFont.bodyEmphasis(scale))
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
