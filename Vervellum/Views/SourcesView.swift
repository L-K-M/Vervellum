import SwiftUI
import AppKit

/// The source list under a turn.
///
/// Sources are split into *cited* and *found but unused*, and the split is shown
/// rather than hidden. A source the model looked at and did not use is evidence about
/// the answer: four cited out of eighteen found means the model was selective, and the
/// user should be able to see the fourteen it passed over.
///
/// The list itself is closed until asked for. "8 of 24 cited" is the fact most readers
/// want from it, and eight rows of URLs between the answer and the next question buries
/// the thing they came for. The count stays on screen; the rows are one click away.
struct SourcesView: View {

    @Environment(\.panelTextScale) private var textScale

    let sources: [Source]
    let citedNumbers: Set<Int>
    @Binding var isExpanded: Bool
    @Binding var showsAll: Bool

    private var cited: [Source] { sources.filter { citedNumbers.contains($0.number) } }
    private var uncited: [Source] { sources.filter { !citedNumbers.contains($0.number) } }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.small) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
                    ForEach(cited) { source in
                        SourceRow(source: source, isCited: true)
                    }
                    if showsAll {
                        ForEach(uncited) { source in
                            SourceRow(source: source, isCited: false)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                uncitedToggle
            }
        }
    }

    /// The label, which is also the way in. A whole-width hit area rather than a
    /// chevron to aim at: the row is one line of small text, and the reader's target
    /// should be the sentence they are reading.
    private var header: some View {
        Button {
            withAnimation(PanelTheme.Motion.disclosure) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: PanelTheme.Space.small) {
                SectionLabel(text: "Sources", trailing: countText)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(PanelTheme.Font.at(9, textScale, weight: .semibold))
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide the sources" : "Show the sources")
        // The count, spoken. An explicit label on a button replaces the one SwiftUI
        // would have built from its children, so naming the gesture silently took
        // "8 of 24 cited" away from the readers who cannot see it — and now that the
        // rows are closed by default, there is nothing left for them to count.
        // `countText` is nil only for a turn with no sources at all, which is a
        // section that does not appear.
        .accessibilityValue(countText ?? "")
    }

    @ViewBuilder
    private var uncitedToggle: some View {
        if !uncited.isEmpty {
            Button {
                withAnimation(PanelTheme.Motion.disclosure) { showsAll.toggle() }
            } label: {
                Text(showsAll
                     ? "Hide the \(uncited.count) uncited"
                     : "Show \(uncited.count) found but not cited")
                    .font(PanelTheme.Font.caption(textScale))
                    .foregroundStyle(PanelTheme.Palette.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var countText: String? {
        guard !sources.isEmpty else { return nil }
        return "\(cited.count) of \(sources.count) cited"
    }
}

/// One source: number, title, domain, date, and what the model actually saw of it.
///
/// The single most misleading thing a research tool can do is present a citation as
/// though the page had been read. So each row says which it was — the page, or a search
/// engine's summary of it — and the label is driven by `Source.wasRead`, which the
/// runner clears when a page was fetched but its text did not fit the model's context.
/// The row therefore describes the evidence the answer had, never the request that was
/// made on its behalf.
struct SourceRow: View {
    @Environment(\.panelTextScale) private var textScale

    let source: Source
    var isCited: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            guard let url = URL(string: source.url) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .top, spacing: PanelTheme.Space.small) {
                Text("\(source.number)")
                    .font(PanelTheme.Font.citation(textScale))
                    .foregroundStyle(isCited ? PanelTheme.Palette.accent : PanelTheme.Palette.tertiaryText)
                    .frame(width: 18, alignment: .trailing)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(PanelTheme.Font.at(12, textScale, weight: .medium))
                        .foregroundStyle(isCited
                                         ? PanelTheme.Palette.primaryText
                                         : PanelTheme.Palette.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: PanelTheme.Space.tight) {
                        Text(source.domain)
                            .font(PanelTheme.Font.at(10.5, textScale))
                            .foregroundStyle(PanelTheme.Palette.tertiaryText)
                        if let published = source.publishedAt, !published.isEmpty {
                            Text("·").foregroundStyle(PanelTheme.Palette.tertiaryText)
                            Text(published)
                                .font(PanelTheme.Font.at(10.5, textScale))
                                .foregroundStyle(PanelTheme.Palette.tertiaryText)
                        }
                        if source.wasRead {
                            // Shown on the row rather than only on hover: it changes what
                            // a citation to this source is worth, which is not a detail.
                            Text("·").foregroundStyle(PanelTheme.Palette.tertiaryText)
                            Label("page read", systemImage: "doc.text")
                                .font(PanelTheme.Font.at(10, textScale))
                                .foregroundStyle(PanelTheme.Palette.verdict(.supported))
                        }
                    }
                    if isHovering, !source.snippet.isEmpty {
                        Text(source.snippet)
                            .font(PanelTheme.Font.at(10.5, textScale))
                            .foregroundStyle(PanelTheme.Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                        Text(source.wasRead
                             ? "Search summary. The answer also had this page's own text."
                             : "Search summary — not the full page")
                            .font(PanelTheme.Font.at(9.5, textScale))
                            .foregroundStyle(PanelTheme.Palette.tertiaryText)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.square")
                    .font(PanelTheme.Font.at(9, textScale))
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                    .opacity(isHovering ? 1 : 0)
                    .padding(.top, 2)
            }
            .padding(.vertical, PanelTheme.Space.tight)
            .padding(.horizontal, PanelTheme.Space.small)
            .background(isHovering ? PanelTheme.Palette.chipFill : .clear,
                        in: RoundedRectangle(cornerRadius: PanelTheme.Radius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(PanelTheme.Motion.disclosure) { isHovering = hovering }
        }
        .help(source.url)
        .accessibilityLabel("Source \(source.number), \(source.title), \(source.domain)"
                            + (source.wasRead ? ", page read" : ", search summary only"))
    }
}
