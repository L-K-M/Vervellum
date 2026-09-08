import SwiftUI
import AppKit

/// One question and its research, rendered top to bottom in the order a reader needs
/// it: what was asked, what was done, the answer, what the answer rests on, what it
/// could not settle, and where to go next.
///
/// `Equatable`, and rendered through `.equatable()`, because otherwise a thread of any
/// length freezes the panel while an answer streams. SwiftUI decides whether to re-run
/// a view's body by comparing its stored properties, and two of these are closures.
/// A closure is a fresh heap box every time the enclosing body runs, so no `TurnView`
/// was ever equal to its predecessor — and since a streamed snapshot republishes the
/// engine ten times a second, *every* turn in the thread re-laid itself out ten times a
/// second, whether or not anything in it had changed. Each of those turns re-created
/// the AppKit text views behind `.textSelection(.enabled)` on every one of its
/// paragraphs, which is where a process sample of the frozen app spent its time.
///
/// Comparing the two values the render actually depends on collapses that to the one
/// turn that changed. The callbacks are deliberately left out of the comparison: they
/// capture the engine (a reference that outlives the render) and this row's turn id
/// (which never changes for the life of the row), so a skipped update cannot leave a
/// stale one behind.
struct TurnView: View, Equatable {

    static func == (lhs: TurnView, rhs: TurnView) -> Bool {
        lhs.turn == rhs.turn && lhs.showsProcessTrail == rhs.showsProcessTrail
    }

    @Environment(\.panelTextScale) private var textScale

    let turn: ResearchTurn
    let showsProcessTrail: Bool
    var onRetry: () -> Void
    var onAskFollowup: (String) -> Void

    @State private var trailExpanded = false
    @State private var showsAllSources = false

    private var validation: CitationValidator.Result {
        CitationValidator.validate(answer: turn.answer, sourceCount: turn.sources.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.medium) {
            question

            // Shown while running, and afterwards whenever there is something to audit:
            // the searches, a failure, or — for a turn the planner decided needed no
            // search at all — the reading that says why.
            if showsProcessTrail && (!turn.stage.isTerminal || !turn.searches.isEmpty
                                     || !turn.reading.isEmpty || turn.stage == .failed) {
                ProcessTrailView(turn: turn, isExpanded: $trailExpanded)
            }

            if !turn.notices.isEmpty {
                NoticesView(notices: turn.notices)
            }

            if let failure = turn.failure {
                FailureView(message: failure, onRetry: onRetry)
            }

            if !turn.answer.isEmpty {
                MarkdownBody(markdown: turn.answer, sources: turn.sources, scale: textScale)
                    .padding(.vertical, PanelTheme.Space.hair)
                answerFooter
            } else if turn.stage == .answering {
                // The gap between "searching finished" and the first token is the one
                // moment with nothing to show. A caret keeps it alive.
                StreamingCaret()
            }

            if !turn.findings.isEmpty {
                FindingsView(findings: turn.findings, sources: turn.sources) { source in
                    if let url = URL(string: source.url) { NSWorkspace.shared.open(url) }
                }
            } else if turn.stage == .assessing {
                Label("Checking the answer's claims…", systemImage: "checkmark.seal")
                    .font(PanelTheme.Font.caption(textScale))
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
            }

            if !turn.limitations.isEmpty {
                LimitationsView(text: turn.limitations)
            }

            if !turn.sources.isEmpty {
                SourcesView(sources: turn.sources,
                            citedNumbers: Set(turn.citedSources(using: validation).map(\.number)),
                            showsAll: $showsAllSources)
            }

            if !turn.followups.isEmpty {
                FollowupsView(followups: turn.followups, onSelect: onAskFollowup)
            }
        }
    }

    // MARK: Pieces

    private var question: some View {
        HStack(alignment: .top, spacing: PanelTheme.Space.small) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(PanelTheme.Palette.accent)
                .frame(width: 2)
            Text(turn.question)
                .font(PanelTheme.Font.question(textScale))
                .foregroundStyle(PanelTheme.Palette.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, PanelTheme.Space.hair)
    }

    private var answerFooter: some View {
        HStack(spacing: PanelTheme.Space.medium) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.transcript, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(PanelTheme.Font.caption(textScale))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PanelTheme.Palette.tertiaryText)
            .help("Copy the answer with its sources")

            // Retry is not only for failures: a completed answer is worth re-running
            // after a settings change, or when the sources felt thin. `retry` on a
            // non-last turn re-asks at the end of the thread, where it belongs.
            if turn.stage == .complete {
                Button(action: onRetry) {
                    Label("Ask again", systemImage: "arrow.clockwise")
                        .font(PanelTheme.Font.caption(textScale))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
                .help("Research this question again")
            }

            if !turn.model.isEmpty {
                Text(turn.model)
                    .font(PanelTheme.Font.at(10, textScale))
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

}

/// A blinking caret for the moment between the last search and the first token.
struct StreamingCaret: View {
    @State private var isBright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(PanelTheme.Palette.accent)
            .frame(width: 7, height: 14)
            .opacity(isBright ? 1 : 0.25)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    isBright = true
                }
            }
            .accessibilityLabel("Writing the answer")
    }
}

/// Vervellum's own caveats about the run — distinct from the model's stated
/// limitations, and never collapsible. A notice exists precisely because something
/// about this answer is less trustworthy than it looks.
struct NoticesView: View {
    @Environment(\.panelTextScale) private var textScale

    let notices: [TurnNotice]

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
            ForEach(notices, id: \.rawValue) { notice in
                Label {
                    Text(notice.message)
                        .font(PanelTheme.Font.caption(textScale))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(PanelTheme.Font.at(10, textScale))
                }
                .foregroundStyle(PanelTheme.Palette.verdict(.mixed))
            }
        }
        .padding(PanelTheme.Space.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelTheme.Palette.verdict(.mixed).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: PanelTheme.Radius.card, style: .continuous))
    }
}

/// What the research could not establish, in the model's own words.
struct LimitationsView: View {
    @Environment(\.panelTextScale) private var textScale

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
            SectionLabel(text: "Limitations")
            Text(text)
                .font(PanelTheme.Font.caption(textScale))
                .foregroundStyle(PanelTheme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// The questions that would reduce the remaining uncertainty. One click asks them.
struct FollowupsView: View {
    @Environment(\.panelTextScale) private var textScale

    let followups: [String]
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
            SectionLabel(text: "Next")
            ForEach(followups, id: \.self) { followup in
                Button {
                    onSelect(followup)
                } label: {
                    HStack(alignment: .top, spacing: PanelTheme.Space.small) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(PanelTheme.Font.at(9, textScale))
                            .padding(.top, 2)
                        Text(followup)
                            .font(PanelTheme.Font.caption(textScale))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(PanelTheme.Palette.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A failed turn: what went wrong, and one button to try again.
struct FailureView: View {
    @Environment(\.panelTextScale) private var textScale

    let message: String
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.small) {
            Label {
                Text(message)
                    .font(PanelTheme.Font.caption(textScale))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(PanelTheme.Font.at(11, textScale))
            }
            .foregroundStyle(PanelTheme.Palette.verdict(.contradicted))

            Button("Try again", action: onRetry)
                .buttonStyle(.plain)
                .font(PanelTheme.Font.caption(textScale))
                .foregroundStyle(PanelTheme.Palette.accent)
        }
        .padding(PanelTheme.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelTheme.Palette.verdict(.contradicted).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: PanelTheme.Radius.card, style: .continuous))
    }
}
