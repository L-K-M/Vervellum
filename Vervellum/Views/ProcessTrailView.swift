import SwiftUI

/// The strip that shows what the research actually did.
///
/// This is the part a chat UI does not have, and the reason to trust the answer above
/// it. But process detail is also the fastest way to turn a panel into noise, so it
/// obeys one rule: **loud while it is happening, one quiet line once it is done.**
///
/// While a turn runs the stages are named as they complete, because a 40-second wait
/// with a spinner feels broken and the same wait with "searching the web · 3 of 4"
/// feels like work. Once the answer lands the whole thing collapses to a summary the
/// user can expand if they want to audit it.
struct ProcessTrailView: View {

    let turn: ResearchTurn
    @Binding var isExpanded: Bool

    private var isRunning: Bool { !turn.stage.isTerminal }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.small) {
            header
            if isExpanded || isRunning {
                detail
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            withAnimation(PanelTheme.Motion.disclosure) { isExpanded.toggle() }
        } label: {
            HStack(spacing: PanelTheme.Space.small) {
                stageGlyph
                Text(summaryLine)
                    .font(PanelTheme.Font.caption)
                    .foregroundStyle(PanelTheme.Palette.secondaryText)
                    .lineLimit(1)
                if isRunning {
                    // A ticking clock turns "is it stuck?" into information. A slow
                    // provider is common enough that the wait should be visible.
                    TimelineView(.periodic(from: turn.askedAt, by: 1)) { context in
                        Text(Formatting.duration(context.date.timeIntervalSince(turn.askedAt)))
                            .font(PanelTheme.Font.caption)
                            .monospacedDigit()
                            .foregroundStyle(PanelTheme.Palette.tertiaryText)
                    }
                }
                Spacer(minLength: 0)
                if !isRunning {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PanelTheme.Palette.tertiaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .accessibilityLabel(isExpanded ? "Hide research detail" : "Show research detail")
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
                .font(.system(size: 10, weight: .semibold))
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
                        .font(PanelTheme.Font.caption)
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
                                    .font(.system(size: 9))
                                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(search.displayQuery)
                                        .font(PanelTheme.Font.caption)
                                        .foregroundStyle(PanelTheme.Palette.primaryText)
                                    if !search.purpose.isEmpty {
                                        Text(search.purpose)
                                            .font(.system(size: 10))
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
                .font(PanelTheme.Font.label)
                .tracking(0.7)
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
            content()
        }
    }
}
