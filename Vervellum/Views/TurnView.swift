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
/// paragraphs, which is where a process sample of the frozen app spent its time. (Those
/// views are now `SelectableText`, for the second half of the same story: skipping a
/// body was never going to be enough while the ones that *were* built cost a layout pass
/// each to measure.)
///
/// Comparing the two values the render actually depends on collapses that to the one
/// turn that changed. The callbacks are deliberately left out of the comparison: they
/// capture the engine (a reference that outlives the render) and this row's turn id
/// (which never changes for the life of the row), so a skipped update cannot leave a
/// stale one behind.
///
/// That is an **invariant, not an observation**, and the next callback added here has to
/// keep it: a skipped update means the row keeps the closures from the last render that
/// was not skipped, so they may only read storage that stays live — a reference type, or
/// a `@State`/`@Binding` whose value lives in a box the view graph owns and which
/// therefore reads through to the current value. A closure that captured a *value*
/// snapshot instead — a draft string, an id read off the thread at construction — would
/// go stale silently, with no crash and no failing assertion, which is the worst way for
/// a performance change to be wrong. Anything a callback must see freshly belongs on
/// `ResearchTurn`, which `==` does compare.
struct TurnView: View, Equatable {

    static func == (lhs: TurnView, rhs: TurnView) -> Bool {
        lhs.turn == rhs.turn && lhs.showsProcessTrail == rhs.showsProcessTrail
            && lhs.palette == rhs.palette
    }

    @Environment(\.panelTextScale) private var textScale

    let turn: ResearchTurn
    let showsProcessTrail: Bool
    /// The palette the row was last rendered with. Part of `==` because the theme is a
    /// global (`PanelTheme.palette`), not an input any parent passes down: without this,
    /// a theme change re-renders the panel chrome but every `TurnView` compares equal to
    /// its predecessor and the rendered answer, findings and sources keep the old colours
    /// until their text changes. A value captured here makes the change an input.
    ///
    /// The same holds one level down. Getting this body run again restyles only what it
    /// draws itself, and SwiftUI skips a child whose stored inputs did not change, so
    /// every themed view a turn contains stores the palette too, defaulted where it is
    /// built. `TurnThemeRenderingTests` fails when one of them does not.
    let palette: PanelPalette
    var onRetry: () -> Void
    var onAskFollowup: (String) -> Void
    /// Loads a question and its attachments back into the composer for editing —
    /// seeding, not submitting, so a typo can be fixed rather than re-run verbatim.
    var onSeedComposer: (ResearchTurn) -> Void = { _ in }
    /// Reads back one attachment's stored bytes — called only when a preview is
    /// opened, never per frame: the row itself still shows names alone.
    var attachmentData: (Attachment) -> Data?

    @State private var trailExpanded = false
    @State private var sourcesExpanded = false
    @State private var showsAllSources = false
    @State private var previewedAttachment: Attachment?
    @State private var previewedData: Data?
    /// Keep the comparison collapsed so the displayed answer stays in reading order.
    @State private var showsDraft = false

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
                draftDisclosure
            } else if turn.stage == .answering {
                // The gap between "searching finished" and the first token is the one
                // moment with nothing to show. A caret keeps it alive.
                StreamingCaret()
            }

            if !turn.findings.isEmpty {
                FindingsView(findings: turn.findings, sources: turn.sources) { source in
                    if let url = SourceHarvester.openableURL(source.url) { NSWorkspace.shared.open(url) }
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
                            isExpanded: $sourcesExpanded,
                            showsAll: $showsAllSources)
            }

            if !turn.followups.isEmpty {
                FollowupsView(followups: turn.followups, onSelect: onAskFollowup)
            }
        }
    }

    @ViewBuilder
    private var draftDisclosure: some View {
        if let draft = turn.draftAnswer,
           DraftComparison.isOffered(draft: draft, answer: turn.answer) {
            Button {
                showsDraft.toggle()
            } label: {
                Text(DraftComparison.toggleLabel(expanded: showsDraft))
                    .font(PanelTheme.Font.caption(textScale))
                    .foregroundStyle(PanelTheme.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityHint(DraftComparison.description(for: turn).hint)
            if showsDraft {
                MarkdownBody(markdown: draft, sources: turn.sources, scale: textScale)
                    .padding(.vertical, PanelTheme.Space.hair)
            }
        }
    }

    // MARK: Pieces

    private var question: some View {
        HStack(alignment: .top, spacing: PanelTheme.Space.small) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(PanelTheme.Palette.accent)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
                // `SelectableText` rather than a `Text` with `.textSelection(.enabled)`,
                // and this is the row that made the difference: there is one of these per
                // turn, so the measuring cost of SwiftUI's own selectable text was paid
                // once per turn on every layout pass of the thread. See `SelectableText`.
                SelectableText(text: turn.question,
                               font: PanelTheme.NativeFont.question(textScale),
                               color: PanelTheme.NativePalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                // What was asked *with*, kept beside what was asked. A transcript that
                // showed the words alone would leave a reader wondering what the answer
                // was looking at, months later — and an answer about a screenshot reads
                // as a non-sequitur without it. Names only: the picture was sent on this
                // turn and is not re-sent, and a thumbnail here would mean reading the
                // bytes back for every turn in the thread on every frame.
                if !turn.attachments.isEmpty {
                    ForEach(turn.attachments) { attachment in
                        // Spelled out rather than left as a `Label`, because the name has
                        // to be selectable and a `Label`'s text cannot be without pulling
                        // SwiftUI's `SelectionOverlay` into every attached row. The symbol
                        // and the middle truncation are what the `Label` was giving; the
                        // selection is why this is worth the three extra lines.
                        HStack(spacing: PanelTheme.Space.tight) {
                            HStack(spacing: PanelTheme.Space.tight) {
                                Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
                                    .font(PanelTheme.Font.caption(textScale))
                                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                                // And selectable, like the question above it. Hover shows
                                // the truncated part; only selection gets it into a search
                                // box or a follow-up question.
                                SelectableText(text: attachment.name,
                                               font: PanelTheme.NativeFont.caption(textScale),
                                               color: PanelTheme.NativePalette.tertiaryText,
                                               // The name is the whole record of what the
                                               // answer was looking at, and middle truncation
                                               // eats the timestamp that tells one screenshot
                                               // from the next. Kept anyway — both ends carry
                                               // meaning too, and hover and selection below
                                               // are what recover the part it hides.
                                               layout: .singleLine(.byTruncatingMiddle))
                                Spacer(minLength: 0)
                            }
                            // Named as an attachment, not merely named. The symbol is
                            // decorative to VoiceOver, so this row read out as a bare
                            // file name in the middle of a transcript — which is the
                            // non-sequitur the paragraph above keeps out of the reading
                            // for anyone who can see the icon. The label is read whole,
                            // so the middle truncation does not reach it either.
                            //
                            // `.ignore` because the name is two views rather than one:
                            // without it the symbol and the text would be read as separate
                            // elements and the label below would name neither. It stops short
                            // of the button, which has to stay an element of its own.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Attached "
                                + (attachment.kind == .image ? "image" : "file")
                                + ": " + attachment.name)
                            // Hover has the whole of it, truncation or not. Applied after the
                            // accessibility modifiers rather than before: `.help` sets a help
                            // trait as well as a tooltip, and the element it would have landed
                            // on above is the one `.ignore` discards.
                            .help(attachment.name)
                            // The bytes are still on disk; the name need not be all
                            // there is to look at. Read once on tap, so SwiftUI
                            // updates while the popover is open do not hit disk again.
                            Button {
                                previewedData = attachmentData(attachment)
                                previewedAttachment = attachment
                            } label: {
                                Image(systemName: "eye")
                                    .font(PanelTheme.Font.caption(textScale))
                                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .help("Show the attachment again")
                            .accessibilityLabel("Show attachment \(attachment.name)")
                        }
                        .popover(isPresented: Binding(
                            get: { previewedAttachment?.id == attachment.id },
                            set: { shown in
                                if !shown && previewedAttachment?.id == attachment.id {
                                    previewedAttachment = nil
                                    previewedData = nil
                                }
                            }
                        ), arrowEdge: .top) {
                            AttachmentPreview(attachment: attachment,
                                              data: previewedData)
                        }
                    }
                }
            }
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

                // Distinct from Ask again, which re-runs the question verbatim:
                // this one goes back into the composer to be changed first.
                Button { onSeedComposer(turn) } label: {
                    Label("Edit & re-ask", systemImage: "pencil")
                        .font(PanelTheme.Font.caption(textScale))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
                .help("Put this question back in the composer for editing")
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
    /// An input, so a theme change redraws this view. See `TurnView.palette`.
    var palette: PanelPalette = PanelTheme.palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The caret's opacity for a brightness tick. Under Reduce Motion it is held
    /// steady and dimmed, so a still caret does not read as a solid block of text.
    static func opacity(isBright: Bool, reduceMotion: Bool) -> Double {
        reduceMotion ? 0.6 : (isBright ? 1 : 0.25)
    }

    var body: some View {
        Group {
            if reduceMotion {
                caret.opacity(Self.opacity(isBright: false, reduceMotion: true))
            } else {
                // Removing this subtree also stops an in-flight repeating animation.
                caret.phaseAnimator([false, true]) { view, bright in
                    view.opacity(Self.opacity(isBright: bright, reduceMotion: false))
                } animation: { _ in .easeInOut(duration: 0.55) }
            }
        }
        .accessibilityLabel("Writing the answer")
    }

    private var caret: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(PanelTheme.Palette.accent)
            .frame(width: 7, height: 14)
    }
}

/// Vervellum's own caveats about the run — distinct from the model's stated
/// limitations, and never collapsible. A notice exists precisely because something
/// about this answer is less trustworthy than it looks.
///
/// The tone is a scanning channel, not a replacement for the sentence: a revised
/// answer and an unchecked one are different facts, and one triangle for both is how
/// a panel teaches its reader to ignore the triangle.
struct NoticesView: View {
    @Environment(\.panelTextScale) private var textScale

    let notices: [TurnNotice]
    /// An input, so a theme change redraws this view. See `TurnView.palette`.
    var palette: PanelPalette = PanelTheme.palette

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
            ForEach(notices, id: \.rawValue) { notice in
                Label {
                    Text(notice.message)
                        .font(PanelTheme.Font.caption(textScale))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: notice.tone.symbolName)
                        .font(PanelTheme.Font.at(10, textScale))
                }
                .foregroundStyle(Self.color(for: notice.tone))
            }
        }
        .padding(PanelTheme.Space.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelTheme.Palette.cardFill,
                    in: RoundedRectangle(cornerRadius: PanelTheme.Radius.card, style: .continuous))
    }

    /// The tone's colour. Informational notices use the secondary text colour rather
    /// than a verdict colour, so a status change does not borrow the findings table's
    /// vocabulary.
    private static func color(for tone: NoticeTone) -> Color {
        switch tone {
        case .informational: return PanelTheme.Palette.secondaryText
        case .caution: return PanelTheme.Palette.verdict(.mixed)
        case .critical: return PanelTheme.Palette.verdict(.contradicted)
        }
    }
}

/// What the research could not establish, in the model's own words.
struct LimitationsView: View {
    @Environment(\.panelTextScale) private var textScale

    let text: String
    /// An input, so a theme change redraws this view. See `TurnView.palette`.
    var palette: PanelPalette = PanelTheme.palette

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
            SectionLabel(text: "Limitations")
            SelectableText(text: text,
                           font: PanelTheme.NativeFont.caption(textScale),
                           color: PanelTheme.NativePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The questions that would reduce the remaining uncertainty. One click asks them.
struct FollowupsView: View {
    @Environment(\.panelTextScale) private var textScale

    let followups: [String]
    /// An input, so a theme change redraws this view. See `TurnView.palette`.
    var palette: PanelPalette = PanelTheme.palette
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
            SectionLabel(text: "Next")
            // Identified by offset, not by the string: the model can suggest the same
            // follow-up twice, and two identical ids make SwiftUI's identity ambiguous —
            // a warning in the console and a tap that can activate the other row.
            // `onSelect` still receives the string, so a duplicate tap asks the right
            // question either way.
            ForEach(Array(followups.enumerated()), id: \.offset) { _, followup in
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
    /// An input, so a theme change redraws this view. See `TurnView.palette`.
    var palette: PanelPalette = PanelTheme.palette
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
