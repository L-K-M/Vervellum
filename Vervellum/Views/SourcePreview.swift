import AppKit
import SwiftUI

/// What a citation cites, shown where the citation is.
///
/// The same facts as a row in the source list, and deliberately the same order: number,
/// title, domain and date, then what the model actually saw of it. A reader who has
/// learned to read those rows should not have to learn a second layout to read this.
///
/// The last line is the one that matters most and is the easiest to leave out. A
/// citation to a source that was only ever a search summary is worth less than one to a
/// page that was read, and the number in the prose cannot say which — so the preview
/// does, every time, rather than only when there is a snippet to show.
///
/// Nothing in here is clickable, on purpose. A hover popover closes when the pointer
/// leaves the thing it is attached to, and the pointer has to leave the chip to reach
/// this — so a link in here would be one the reader could see and could not press,
/// which is worse than none. The chip itself is the affordance: `AnswerTextView` leaves
/// `NSTextView`'s own link handling in place, so clicking `[21]` opens the page exactly
/// as it did before this popover existed. Making the preview reachable would mean a
/// grace period on the exit and hit-testing the popover's own frame — worth doing if
/// there is ever something in here worth pressing, and not before.
struct SourcePreview: View {

    @Environment(\.panelTextScale) private var textScale

    let source: Source

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: PanelTheme.Space.small) {
                Text("[\(source.number)]")
                    .font(PanelTheme.Font.citation(textScale))
                    .foregroundStyle(PanelTheme.Palette.accent)
                Text(source.title)
                    .font(PanelTheme.Font.at(PanelTheme.Metrics.previewTitle, textScale,
                                             weight: .medium))
                    .foregroundStyle(PanelTheme.Palette.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: PanelTheme.Space.tight) {
                Text(source.domain)
                if let published = source.publishedAt, !published.isEmpty {
                    Text("·")
                    Text(published)
                }
            }
            // One line, whatever the domain. The width is fixed so the card stays out
            // of the paragraph being read, and a domain long enough to wrap would buy
            // its second line out of exactly that.
            .lineLimit(1)
            .truncationMode(.middle)
            .font(PanelTheme.Font.at(PanelTheme.Metrics.previewMeta, textScale))
            .foregroundStyle(PanelTheme.Palette.tertiaryText)

            if !source.snippet.isEmpty {
                Text(source.snippet)
                    .font(PanelTheme.Font.at(PanelTheme.Metrics.previewSnippet, textScale))
                    .foregroundStyle(PanelTheme.Palette.secondaryText)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

            Label(source.wasRead
                  ? "The answer had this page's own text"
                  : "Search summary — not the full page",
                  systemImage: source.wasRead ? "doc.text" : "text.magnifyingglass")
                .font(PanelTheme.Font.at(PanelTheme.Metrics.previewFootnote, textScale))
                .foregroundStyle(source.wasRead
                                 ? PanelTheme.Palette.verdict(.supported)
                                 : PanelTheme.Palette.tertiaryText)
        }
        // One element, not five. Ungrouped, VoiceOver stops at the number, the title,
        // the domain, the snippet and the read-or-summary line as five unrelated
        // fragments — and the whole of what this card is for is that they are one
        // answer to "what does [21] cite". Combining costs nothing here: the read state
        // is already in words rather than only in colour.
        .accessibilityElement(children: .combine)
        .padding(PanelTheme.Space.medium)
        // Wide enough for a title and a sentence of snippet, narrow enough not to cover
        // the paragraph the reader is in the middle of.
        .frame(width: 300, alignment: .leading)
    }
}
