import SwiftUI

/// The strip that shows what the research actually did.
///
/// This is the part a chat UI does not have, and the reason to trust the answer above
/// it. But process detail is also the fastest way to turn a panel into noise, so it
/// obeys one rule: **loud while it is happening, one quiet line once it is done.**
///
/// While a turn runs the stage is named as it changes, because a 40-second wait with a
/// spinner feels broken and the same wait with "searching the web · 3 of 4" feels like
/// work. That live line is the whole of it: the queries behind it are a dozen rows of
/// text that push the answer off the screen at exactly the moment it arrives, so they
/// wait behind a disclosure like everything else. One line running, one line done, and
/// the detail one click away in both.
///
/// The disclosure was previously forced open for the duration of a run, which meant it
/// also shut itself the moment the answer landed. It no longer does either, and the
/// consequence is deliberate: a reader who opens the queries mid-run still has them
/// open afterwards. Closing what somebody opened, because a background task they were
/// not watching finished, is the panel deciding it knows better — and the one click it
/// saves is the same click they just spent.
struct ProcessTrailView: View {

    @Environment(\.panelTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let turn: ResearchTurn
    @Binding var isExpanded: Bool

    private var isRunning: Bool { !turn.stage.isTerminal }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.small) {
            header
            if isExpanded {
                detail
                    .transition(PanelTheme.Motion.disclosureTransition(reduceMotion))
            }
        }
        .padding(.vertical, PanelTheme.Space.small)
        .padding(.horizontal, PanelTheme.Space.medium)
        .background(PanelTheme.Palette.cardFill,
                    in: RoundedRectangle(cornerRadius: PanelTheme.Radius.card, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        Button {
            withAnimation(PanelTheme.Motion.disclosureAnimation(reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: PanelTheme.Space.small) {
                stageGlyph
                Text(summaryLine)
                    .font(PanelTheme.Font.caption(textScale))
                    .foregroundStyle(PanelTheme.Palette.secondaryText)
                    .lineLimit(1)
                if isRunning {
                    // A ticking clock turns "is it stuck?" into information. A slow
                    // provider is common enough that the wait should be visible.
                    TimelineView(.periodic(from: turn.askedAt, by: 1)) { context in
                        Text(Formatting.duration(context.date.timeIntervalSince(turn.askedAt)))
                            .font(PanelTheme.Font.caption(textScale))
                            .monospacedDigit()
                            .foregroundStyle(PanelTheme.Palette.tertiaryText)
                    }
                }
                Spacer(minLength: 0)
                // Shown while it runs too. The queries arrive early and are the most
                // interesting thing on screen for the few seconds before an answer
                // exists — but only to a reader who went looking, which is what the
                // chevron is for.
                // Turned rather than swapped, for the reason `SourcesView` gives: two
                // symbols are an identity change and will not animate.
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .font(PanelTheme.Font.at(9, textScale, weight: .semibold))
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide research detail" : "Show research detail")
        // The same swallowed-label bug `SourcesView` has, and here it costs more. An
        // explicit label replaces the one SwiftUI composes from the button's children, so
        // the live line goes with it — and since the detail now starts closed, that line
        // is the *only* place a running turn says what it is doing. A reader using
        // VoiceOver heard "Show research detail" for the whole forty seconds. "Loud while
        // it is happening" has to mean out loud.
        .accessibilityValue(summaryLine)
    }

    @ViewBuilder
    private var stageGlyph: some View {
        if isRunning {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
        } else {
            Image(systemName: terminalSymbol)
                .font(PanelTheme.Font.at(10, textScale, weight: .semibold))
                .foregroundStyle(terminalColor)
                .frame(width: 12)
        }
    }

    private var terminalSymbol: String {
        switch turn.stage {
        case .complete: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "stop.circle"
        default: return "circle"
        }
    }

    private var terminalColor: Color {
        switch turn.stage {
        case .complete: return PanelTheme.Palette.tertiaryText
        case .failed: return PanelTheme.Palette.verdict(.contradicted)
        default: return PanelTheme.Palette.tertiaryText
        }
    }

    /// The one line that stands in for the whole trail once a turn is done.
    private var summaryLine: String {
        guard !isRunning else { return runningLine }
        var parts: [String] = []
        if turn.searches.isEmpty {
            parts.append("no search")
        } else {
            parts.append("\(turn.searches.count) search\(turn.searches.count == 1 ? "" : "es")")
        }
        if !turn.sources.isEmpty {
            parts.append("\(turn.sources.count) source\(turn.sources.count == 1 ? "" : "s")")
        }
        // Only when a page was actually read. "0 pages read" on every turn with the
        // setting off would be a line about a feature rather than about this answer.
        if turn.pagesRead > 0 {
            parts.append("\(turn.pagesRead) page\(turn.pagesRead == 1 ? "" : "s") read")
        }
        if !turn.findings.isEmpty {
            parts.append("\(turn.findings.count) claim\(turn.findings.count == 1 ? "" : "s") checked")
        }
        if let duration = turn.duration { parts.append(Formatting.duration(duration)) }
        return parts.joined(separator: " · ")
    }

    /// The live line while a turn runs. Search progress comes from the turn itself —
    /// see `ResearchTurn.runningProgressLabel` — so both platforms show the same ticks.
    private var runningLine: String {
        turn.runningProgressLabel
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.small) {
            if !turn.reading.isEmpty {
                labelled("Reading") {
                    Text(turn.reading)
                        .font(PanelTheme.Font.caption(textScale))
                        .foregroundStyle(PanelTheme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !turn.searches.isEmpty {
                labelled("Queries") {
                    VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
                        ForEach(turn.searches) { search in
                            HStack(alignment: .firstTextBaseline, spacing: PanelTheme.Space.small) {
                                Image(systemName: "magnifyingglass")
                                    .font(PanelTheme.Font.at(9, textScale))
                                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(search.displayQuery)
                                        .font(PanelTheme.Font.caption(textScale))
                                        .foregroundStyle(PanelTheme.Palette.primaryText)
                                    if !search.purpose.isEmpty {
                                        Text(search.purpose)
                                            .font(PanelTheme.Font.at(10, textScale))
                                            .foregroundStyle(PanelTheme.Palette.tertiaryText)
                                    }
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.hair) {
            Text(title.uppercased())
                .font(PanelTheme.Font.label(textScale))
                .tracking(0.7)
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
            content()
        }
    }
}
