import SwiftUI
import AppKit

/// Everything inside the panel: header, thread, composer.
///
/// The layout is fixed-header / scrolling-middle / fixed-composer, and that shape is
/// load-bearing. A research answer can run to several screens, but the two things the
/// user always needs — what is happening now, and where to type next — must never
/// scroll away.
struct PanelRootView: View {

    /// Read from the preference rather than the environment.
    ///
    /// This view is the one that *publishes* the panel-wide value, and `.environment`
    /// only reaches descendants — a view's own `@Environment` resolves against what its
    /// parent injected, which here is the unscaled default. Reading it back would have
    /// left this body's own chrome (the notices, the model chip) fixed at 1.0 while
    /// everything below it scaled: the exact bug this change exists to remove. The
    /// nested views below keep their `@Environment` reads, because they are descendants.
    private var textScale: Double { preferences.textScale }

    @ObservedObject var engine: ResearchEngine
    @ObservedObject var store: ThreadStore
    @ObservedObject var preferences: Preferences

    var onOpenSettings: () -> Void
    var onClose: () -> Void

    @State private var draft = ""
    @State private var showsHistory = false
    /// Markdown shown above the thread in place of a turn — `/help`, and the `/model`
    /// listing. One slot rather than a flag per command: they are mutually exclusive by
    /// nature (each replaces the last), and Escape has one thing to back out of.
    @State private var notice: String?
    /// How many credential-shaped spans were removed from seeded text, if any.
    @State private var redactionNote: Int?
    /// Set when a question could not be queued because the queue was full. Cleared by
    /// the next submission, so it never outlives the situation it describes.
    @State private var queueFullNote = false
    /// Earlier questions, newest first, for ↑/↓ recall in the composer.
    @State private var recallIndex: Int?

    /// Which command in the completion list the keyboard has highlighted, if any.
    ///
    /// Starts nil, and typing returns it to nil. Nothing is preselected on purpose: with
    /// a highlighted row Return *accepts* the completion, so preselecting the first one
    /// would mean typing `/new` and pressing Return filled the field instead of starting
    /// a thread — the command would become harder to run, not easier.
    @State private var completionIndex: Int?

    /// The row the pointer is over, kept apart from the keyboard's choice.
    ///
    /// One index for both meant leaving the list with the mouse cleared a highlight the
    /// arrow keys had put there — a trackpad brushed on the way past, and Return quietly
    /// went back to declining the half-typed command. The pointer still wins while it is
    /// inside the list, so the two can never disagree about what Return would take; it
    /// just no longer destroys the other one's answer on the way out.
    @State private var hoverIndex: Int?

    /// What is highlighted, and what Return would accept.
    private var effectiveCompletionIndex: Int? { hoverIndex ?? completionIndex }
    /// Whether the thread is scrolled to its end. Streams auto-scroll only while
    /// pinned, so reading back during an answer is never undone by the next token.
    @State private var isPinnedToBottom = true

    /// The measured width of the composer's row, once layout has run.
    @State private var composerRowWidth: CGFloat?

    /// Horizontal room the send button and its spacing take from the composer's row.
    /// Named rather than inlined: the height estimate silently drifts when the button
    /// is restyled, and the bug is invisible until the composer wraps a line early.
    private static let sendButtonReservation: CGFloat = 24 + PanelTheme.Space.small

    /// Whether the providers are configured, sampled rather than computed.
    ///
    /// Checking this needs a Keychain read, and a computed property would perform one
    /// on **every** SwiftUI render — which during a streamed answer is many times a
    /// second. It is refreshed when the panel is summoned and after Settings closes,
    /// which are the only moments it can change.
    @State private var isConfigured = false

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                title: engine.thread.title,
                isRunning: engine.isRunning,
                showsHistory: $showsHistory,
                onNewThread: newThread,
                onStop: { engine.cancel() },
                onOpenSettings: onOpenSettings,
                onClose: onClose)

            Divider().overlay(PanelTheme.Palette.hairline)

            if showsHistory {
                HistoryView(store: store,
                            onOpen: openThread,
                            onDelete: deleteThread,
                            onClose: { showsHistory = false })
            } else {
                thread
            }

            Divider().overlay(PanelTheme.Palette.hairline)
            composer
        }
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.Radius.panel, style: .continuous))
        // The text-size preference, published to the whole panel from one place. Every
        // view reads it out of the environment instead of being handed it, so a new one
        // cannot quietly render at a fixed size the setting does not move — which is how
        // the setting came to move the answer prose and nothing else.
        .environment(\.panelTextScale, preferences.textScale)
        // The research-the-selection shortcut drops the frontmost app's selection
        // into the composer. It arrives as a notification because the panel's SwiftUI
        // tree is built once and reused, so there is no initializer to pass it to.
        .onReceive(NotificationCenter.default.publisher(for: .vervellumSeedComposer)) { note in
            guard let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
            showsHistory = false
            notice = nil
            // Appended, not replaced: a user who typed half a question and then hit
            // the selection shortcut meant to add to it.
            draft = draft.isEmpty ? text : draft + "\n\n" + text
            redactionNote = (note.userInfo?["redactions"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vervellumPanelDidShow)) { _ in
            refreshConfiguredState()
        }
        // Also on first build: the panel is constructed and shown in the same turn, so
        // without this the very first frame renders the not-configured state even for a
        // configured user.
        .onAppear(perform: refreshConfiguredState)
        // Reset the transient sub-views when the panel goes away, so the next summon
        // opens on the thread rather than wherever the user happened to be. The draft
        // is deliberately kept — a half-typed question should survive a dismissal.
        .onReceive(NotificationCenter.default.publisher(for: .vervellumPanelWillHide)) { _ in
            showsHistory = false
            notice = nil
            recallIndex = nil
        }
        // Opening Settings returns immediately, so refreshing there would sample the
        // state before the user had typed anything. The window tells us when it closes.
        .onReceive(NotificationCenter.default.publisher(for: .vervellumSettingsDidClose)) { _ in
            refreshConfiguredState()
            // Delete All and history off/on erase stored threads. Release the open
            // copy too; archive tombstones also reject any late runner snapshots.
            if store.isHistoryEnabled, !engine.thread.isEmpty,
               !store.library.threads.contains(where: { $0.id == engine.thread.id }) {
                engine.startNewThread()
                recallIndex = nil
            }
        }
        // Command shortcuts raised by the panel window. See `PanelCommand`.
        .onReceive(NotificationCenter.default.publisher(for: .vervellumPanelCommand)) { note in
            guard let raw = note.userInfo?["command"] as? String,
                  let command = PanelCommand(rawValue: raw) else { return }
            switch command {
            case .escape: backOut()
            // Through the composer's own submit, not straight to `submit`: this is a key
            // that sends a question, and the rule beside `onSubmit` is that whatever key
            // sends a question is the key that takes the highlighted command. With
            // nothing highlighted it falls through to `submit` — which is not what it
            // used to do either, since `submit` now declines a half-typed command rather
            // than asking it. Both changes are this branch's, and both are the point.
            case .submit: submitFromComposer()
            case .newThread: newThread()
            case .toggleHistory: showsHistory.toggle()
            case .openSettings:
                onOpenSettings()
            case .stop: engine.cancel()
            }
        }
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PanelTheme.Space.section) {
                    if engine.thread.isEmpty && notice == nil {
                        EmptyStateView(isConfigured: isConfigured,
                                       summonShortcut: preferences.summonHotkey.displayString,
                                       onOpenSettings: onOpenSettings,
                                       onSeedComposer: { draft = $0 })
                            .padding(.top, PanelTheme.Space.section)
                    }
                    if let notice {
                        MarkdownBody(markdown: notice,
                                     sources: [], scale: preferences.textScale)
                            .padding(.top, PanelTheme.Space.medium)
                    }
                    ForEach(engine.thread.turns) { turn in
                        TurnView(turn: turn,
                                 showsProcessTrail: preferences.showProcessTrail,
                                 onRetry: { engine.retry(turn.id) },
                                 onAskFollowup: askFollowup)
                            .id(turn.id)
                    }
                    // A scroll anchor rather than scrolling to the last turn: the last
                    // turn's own id points at its *top*, so pinning to it would jump
                    // backwards every time the answer grew.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, PanelTheme.Space.gutter)
                .padding(.vertical, PanelTheme.Space.large)
                // Keep observation alive outside lazy children, but inside the scroll content.
                .background(BottomSentinel { pinned in isPinnedToBottom = pinned })
            }
            .overlay(alignment: .bottom) {
                if !isPinnedToBottom, engine.isRunning {
                    jumpToLatest(proxy)
                }
            }
            .animation(PanelTheme.Motion.disclosure, value: isPinnedToBottom)
            .onChange(of: engine.thread.turns.last?.answer) { _, _ in
                guard isPinnedToBottom else { return }
                scrollToBottom(proxy)
            }
            .onChange(of: draft) { _, _ in
                // Any edit invalidates the highlight: the list is filtered by what has
                // been typed, so an index kept across a keystroke could point past the
                // end of the shorter list, or at a command the user has just filtered out.
                // Both of them: the pointer's row is an index into the same list.
                completionIndex = nil
                hoverIndex = nil
            }
            .onChange(of: engine.thread.turns.count) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private static let bottomAnchor = "vervellum.bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // Unanimated: an animated scroll re-targeted on every streamed token fights
        // itself and the text visibly judders.
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }

    /// The way back to the stream after scrolling up mid-answer. Tapping it scrolls,
    /// and the sentinel then re-pins, so follow mode resumes on its own.
    private func jumpToLatest(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy)
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(PanelTheme.Font.caption(textScale))
                .padding(.horizontal, PanelTheme.Space.medium)
                .padding(.vertical, PanelTheme.Space.small)
                .background(PanelTheme.Palette.accent,
                            in: Capsule(style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .padding(.bottom, PanelTheme.Space.small)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
            if let redactionNote {
                Label("\(redactionNote) credential-shaped value\(redactionNote == 1 ? "" : "s") "
                      + "removed from the captured text.",
                      systemImage: "eye.slash")
                    .font(PanelTheme.Font.caption(textScale))
                    .foregroundStyle(PanelTheme.Palette.verdict(.mixed))
                    .padding(.horizontal, PanelTheme.Space.small)
            }
            if preferences.providerSettings.modelProfiles.count > 1 {
                modelPicker
            }
            if queueFullNote {
                Label("Up to \(ResearchEngine.maxQueued) questions can wait at once. "
                      + "Stop the run, or remove one below.",
                      systemImage: "exclamationmark.circle")
                    .font(PanelTheme.Font.caption(textScale))
                    .foregroundStyle(PanelTheme.Palette.verdict(.mixed))
                    .padding(.horizontal, PanelTheme.Space.small)
            }
            if !engine.queue.isEmpty {
                QueuedQuestionsView(queued: engine.queue) { engine.removeQueued($0) }
            }
            if let completions = visibleCompletions {
                CommandCompletionsView(completions: completions,
                                       selected: effectiveCompletionIndex,
                                       onHover: { hoverIndex = $0 }) { name in
                    accept(completion: name)
                }
            }
            HStack(alignment: .bottom, spacing: PanelTheme.Space.small) {
                ComposerView(text: $draft,
                             placeholder: placeholder,
                             submitOnReturn: preferences.submitOnReturn,
                             scale: preferences.textScale,
                             // Return takes the highlighted command when there is one,
                             // and otherwise asks. The send button below never takes a
                             // highlighted row — clicking is not a way to pick from a
                             // list — but it declines a half-typed command just as
                             // Return does, so the same text cannot mean two things.
                             //
                             // `onSubmit` is the user's submit gesture, not the Return
                             // key: with submit-on-Return off, `ComposerView` routes
                             // Shift-Return here instead. Whatever key sends a question
                             // is the key that takes the highlighted command.
                             onSubmit: { submitFromComposer() },
                             onArrow: moveThroughCompletionsOrHistory)
                    // The composer's height for its content, laid out at the width the
                    // row will actually give it: the measured row width minus what the
                    // send button and its spacing take. Measured rather than derived
                    // from the panel-width preference, which is unclamped while
                    // PanelPlacement clamps the real panel on a small display or a
                    // Stage Manager slice — a height computed against a width that no
                    // longer exists wraps the field a line too early. The estimate only
                    // bridges the first frame, before any layout has happened.
                    .frame(height: ComposerView.height(
                        for: draft,
                        width: (composerRowWidth ?? estimatedComposerRowWidth)
                            - Self.sendButtonReservation,
                        scale: preferences.textScale))

                // Stop and Ask are both live during a run, side by side, because both
                // are now reachable: the composer stays editable, so a question typed
                // mid-run has somewhere to go. One button that changed meaning would
                // make Stop unreachable the moment anything was typed.
                if engine.isRunning {
                    CircularComposerButton(symbol: "stop.fill",
                                           tint: PanelTheme.Palette.verdict(.contradicted),
                                           help: "Stop the research (⌘.)",
                                           action: { engine.cancel() })
                }
                CircularComposerButton(symbol: "arrow.up",
                                       tint: PanelTheme.Palette.accent,
                                       help: unfinishedCommandHelp
                                           ?? (engine.isRunning ? "Ask next" : "Ask"),
                                       isEnabled: isAskable,
                                       action: { submit(draft) })
            }
            // Measured on the row, not the composer: the composer's own width already
            // excludes the send button, and subtracting the reservation from it too
            // would under-estimate and wrap early — the very bug this fixes.
            .background(GeometryReader { geometry in
                Color.clear.onAppear { composerRowWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in
                        composerRowWidth = width
                    }
            })
        }
        .padding(.horizontal, PanelTheme.Space.medium)
        .padding(.vertical, PanelTheme.Space.small)
    }

    /// Width the composer's row should have, per the width preference — used only
    /// until real geometry arrives. Same arithmetic the row itself applies.
    private var estimatedComposerRowWidth: CGFloat {
        preferences.panelWidth - PanelTheme.Space.medium * 2
    }

    /// Whether the draft is something to send.
    ///
    /// Blank is the obvious case. A slash word still being typed is the other: Return
    /// declines it rather than spending a request on `/h`, and a send button that did
    /// spend one would make the same text mean two different things depending on
    /// whether the user reached for the mouse. Disabled rather than silently ignored,
    /// because a button can show the state and a key press cannot.
    private var isAskable: Bool {
        !isDraftBlank && !ComposerCommand.isHalfTypedCommand(draft)
    }

    /// Why the send button is dim, when it is dim for something the reader can fix.
    ///
    /// The same sentence `submit` speaks, deliberately: grey says a button is off, never
    /// what would turn it on, and a reader who cannot hear the announcement is exactly
    /// the one left looking at it.
    private var unfinishedCommandHelp: String? {
        guard !isDraftBlank, ComposerCommand.isHalfTypedCommand(draft) else { return nil }
        return Self.unfinishedCommandCopy
    }

    /// Said twice — once to the eye as a tooltip, once to VoiceOver from `submit` — and
    /// the comment there already promised they were the same sentence. Now they are.
    private static let unfinishedCommandCopy = "Finish the command name"
    /// Spoken by both ways out of the list — Escape, and ↑ off the top. Named because
    /// two literals for one transition is how a screen reader ends up describing the
    /// same thing two ways after somebody tunes the wording at one of them.
    private static let leftCommandListCopy = "Left the command list"

    private var isDraftBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The placeholder says what a question typed *now* will do. "Researching…" used to
    /// describe the panel's state, which was accurate and useless: the field was
    /// disabled, so there was nothing the reader could act on.
    private var placeholder: String {
        guard engine.isRunning else { return "Ask anything — / for commands" }
        return engine.queue.isEmpty ? "Ask a follow-up — it runs next" : "Ask another — it joins the queue"
    }

    /// One round composer button, styled once so Stop and Ask match.
    private struct CircularComposerButton: View {

        @Environment(\.panelTextScale) private var textScale
        let symbol: String
        let tint: Color
        let help: String
        var isEnabled = true
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(PanelTheme.Font.at(11, textScale, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(tint, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.35)
            .help(help)
            .accessibilityLabel(help)
            .padding(.bottom, 3)
        }
    }

    /// The questions waiting their turn, each removable.
    ///
    /// Shown rather than merely counted: a question the user typed and can no longer
    /// see is a question they will type again, and one they cannot withdraw is a
    /// provider request they cannot call off.
    private struct QueuedQuestionsView: View {

        @Environment(\.panelTextScale) private var textScale
        let queued: [ResearchEngine.QueuedQuestion]
        var onRemove: (UUID) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
                ForEach(queued) { item in
                    HStack(spacing: PanelTheme.Space.small) {
                        Image(systemName: "clock")
                            .font(PanelTheme.Font.at(9, textScale))
                            .foregroundStyle(PanelTheme.Palette.tertiaryText)
                        Text(item.mode == .direct ? "/direct \(item.question)" : item.question)
                            .font(PanelTheme.Font.caption(textScale))
                            .foregroundStyle(PanelTheme.Palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Button { onRemove(item.id) } label: {
                            Image(systemName: "xmark")
                                .font(PanelTheme.Font.at(8, textScale, weight: .semibold))
                                .foregroundStyle(PanelTheme.Palette.tertiaryText)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove this waiting question")
                        .accessibilityLabel("Remove the waiting question")
                    }
                    .padding(.horizontal, PanelTheme.Space.small)
                    .padding(.vertical, 3)
                    .background(PanelTheme.Palette.chipFill,
                                in: RoundedRectangle(cornerRadius: PanelTheme.Radius.chip,
                                                     style: .continuous))
                }
            }
            .accessibilityLabel("\(queued.count) question\(queued.count == 1 ? "" : "s") waiting")
        }
    }

    /// Which provider answers the next question, changed where the question is typed.
    ///
    /// Shown only when there is more than one to choose between: with a single provider
    /// the control offers no choice, and the model that answered is already recorded on
    /// every turn. `/model` reaches the same setting from the keyboard.
    private var modelPicker: some View {
        Menu {
            ForEach(preferences.providerSettings.modelProfiles) { profile in
                Button {
                    var settings = preferences.providerSettings
                    settings.selectedModelID = profile.id
                    preferences.providerSettings = settings
                    refreshConfiguredState()
                } label: {
                    if profile.id == preferences.providerSettings.selectedModel?.id {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Text(profile.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: PanelTheme.Space.tight) {
                Image(systemName: "cpu")
                    .font(PanelTheme.Font.at(9, textScale))
                Text(preferences.providerSettings.selectedModel?.displayName ?? "No model")
                    .font(PanelTheme.Font.caption(textScale))
                    .lineLimit(1)
            }
            .foregroundStyle(PanelTheme.Palette.secondaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, PanelTheme.Space.small)
        .help("The provider the next question is asked with (/model)")
        .accessibilityLabel("Model provider")
    }

    private struct CommandCompletionsView: View {

        @Environment(\.panelTextScale) private var textScale
        let completions: [ComposerCommand.Entry]
        /// The highlighted row — the pointer's while it is inside, otherwise the
        /// keyboard's — or nil while the user is still typing.
        var selected: Int?
        /// Pointing at a row highlights it, so the mouse and the arrow keys cannot
        /// disagree about which command Return would take. Reports the *pointer's* row
        /// only; the caller keeps the keyboard's separately, so leaving the list hands
        /// the highlight back rather than throwing it away.
        var onHover: (Int?) -> Void = { _ in }
        var onSelect: (String) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(completions.enumerated()), id: \.element.id) { index, command in
                    Button { onSelect(command.name) } label: {
                        HStack(spacing: PanelTheme.Space.small) {
                            Text("/\(command.name)")
                                .font(PanelTheme.Font.citation(textScale))
                                .foregroundStyle(PanelTheme.Palette.accent)
                            Text(command.summary)
                                .font(PanelTheme.Font.at(11, textScale))
                                .foregroundStyle(PanelTheme.Palette.secondaryText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, PanelTheme.Space.small)
                        .padding(.vertical, 3)
                        .background(index == selected
                            ? PanelTheme.Palette.accent.opacity(0.18)
                            : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // On the button, not on the label inside it. A `Button` folds its
                    // label's children into one element, and a trait applied in there is
                    // carried up only as an implementation detail — `.isSelected` is the
                    // one this list cannot afford to lose, since it is the whole reason
                    // the highlight means anything to VoiceOver. The highlight was colour
                    // alone before, which said nothing about which command Return takes.
                    .accessibilityAddTraits(index == selected ? .isSelected : [])
                    // Says what activation actually does. Several of these commands take
                    // an argument, so a row fills the field rather than running it —
                    // which is not what "button named /new" would lead you to expect if
                    // you could not see the trailing space appear.
                    .accessibilityHint("Fills the composer with this command")
                    // Claims only. A row that clears on exit can wipe the highlight the
                    // pointer has just moved onto, because the leaving row's exit and the
                    // entering row's enter are separate tracking events with no
                    // guaranteed order — and an exiting row cannot know it was superseded.
                    .onHover { inside in if inside { onHover(index) } }
                }
            }
            .padding(.vertical, PanelTheme.Space.tight)
            // A group rather than a pile of buttons: without this, arriving here by
            // VoiceOver gives no sense of having entered anything, and the rows' hints
            // are the only clue what they are.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Command completions")
            // The container is the reliable "the mouse left" signal: its hover stays true
            // over any row and over the padding between them, so moving between rows
            // never clears while leaving the list always does. What that clears is the
            // pointer's claim alone — a keyboard highlight underneath it survives.
            .onHover { inside in if !inside { onHover(nil) } }
            .background(PanelTheme.Palette.cardFill,
                        in: RoundedRectangle(cornerRadius: PanelTheme.Radius.card, style: .continuous))
        }
    }

    // MARK: Actions

    private func submit(_ text: String) {
        // A half-typed command on screen — `/h` under `history` and `help` — is a command
        // being chosen, and `parse` would send it to the model as a question, spending a
        // real request on a typo. Declining keeps the text so the next keystroke finishes
        // the word, which is what `/direct` with no argument already does below.
        //
        // Here rather than beside the Return key, because Return is not the only way in:
        // the panel's own submit shortcut calls this directly, and so would anything
        // added later. The send button knows the rule too, but only so it can grey itself
        // out — a button can show the state, and this is where the state is enforced.
        guard !ComposerCommand.isHalfTypedCommand(text) else {
            // A dead key is indistinguishable from a broken one, and the greyed-out send
            // button is not where a reader's eyes are when they press Return. Both, then:
            // the notice for anyone looking at the panel, the announcement for anyone
            // who is not. Cleared by Escape like every other notice.
            notice = Self.unfinishedCommandCopy
            announce(Self.unfinishedCommandCopy)
            return
        }
        recallIndex = nil
        redactionNote = nil
        queueFullNote = false
        switch ComposerCommand.parse(text) {
        case .none:
            return
        case .ask(let question):
            notice = nil
            // The composer is live while the history list is open, and a question
            // asked from there must not run invisibly behind it.
            showsHistory = false
            handle(engine.ask(question, mode: .research))
        case .direct(let question):
            notice = nil
            showsHistory = false
            handle(engine.ask(question, mode: .direct))
        case .deepResearch(let question):
            notice = nil
            showsHistory = false
            handle(engine.ask(question, mode: .deep))
        case .newThread:
            draft = ""
            newThread()
        case .openHistory:
            draft = ""
            showsHistory = true
        case .openSettings:
            draft = ""
            onOpenSettings()
        case .copyLastAnswer:
            draft = ""
            engine.flushProgress()
            guard let last = engine.thread.turns.last else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(last.transcript, forType: .string)
        case .showHelp:
            draft = ""
            notice = ComposerCommand.helpText
        case .selectModel(let name):
            draft = ""
            selectModel(named: name)
        }
    }

    /// `/model` — list the configured providers, or switch to one by name.
    ///
    /// The switch is a preference write, not panel state: the next turn reads its
    /// environment from `CorePreferences`, and a selection held only here would be
    /// forgotten the moment the panel was rebuilt.
    private func selectModel(named name: String) {
        var settings = preferences.providerSettings
        guard !name.isEmpty else {
            notice = ComposerCommand.modelListing(settings)
            return
        }
        guard settings.selectModel(named: name) else {
            notice = ComposerCommand.unknownModel(name, in: settings)
            return
        }
        preferences.providerSettings = settings
        refreshConfiguredState()
        notice = ComposerCommand.modelListing(settings)
    }

    /// Clears the composer only when the question was actually taken.
    ///
    /// A full queue keeps the text: emptying the field for a question that was refused
    /// is how you lose one, and the note beside the composer says what to do about it.
    private func handle(_ outcome: ResearchEngine.AskOutcome) {
        switch outcome {
        case .started, .queued:
            draft = ""
        case .queueFull:
            queueFullNote = true
        case .ignored:
            break
        }
    }

    /// What Escape does, in the order a user expects to be able to undo things:
    /// leave the history list, then clear a draft, then close the panel. Closing on
    /// the first press would throw away a half-typed question.
    private func backOut() {
        if effectiveCompletionIndex != nil {
            // Undoes the highlight before anything else, so Escape steps back out of the
            // command list without also throwing away the question being typed.
            //
            // Either index, because Return honours either: checking `completionIndex`
            // alone left Escape doing nothing visible on a row the *pointer* had
            // highlighted, and the next Return still accepted it. Splitting the two
            // indices is what made that possible, so this is the other half of it.
            completionIndex = nil
            hoverIndex = nil
            // Leaving the list changes what Return does, exactly as entering it did, and
            // a change of meaning nobody is told about is the thing the announcements on
            // the way in exist to prevent.
            announce(Self.leftCommandListCopy)
        } else if showsHistory {
            showsHistory = false
        } else if notice != nil {
            notice = nil
        } else if !draft.isEmpty {
            draft = ""
            redactionNote = nil
            queueFullNote = false
            // Dropping the draft also ends the recall walk, so the next ↑ starts at the
            // most recent question rather than resuming halfway up the list.
            recallIndex = nil
        } else {
            onClose()
        }
    }

    private func refreshConfiguredState() {
        let keychain: SecretStore = KeychainStore()
        let settings = preferences.providerSettings
        isConfigured = settings
            .problems(hasModelKey: keychain.hasModelKey(for: settings),
                      hasSearchKey: keychain.hasSearchKey(for: settings))
            .isEmpty
    }

    /// A suggested follow-up, clicked.
    ///
    /// It asks straight away when the composer is empty, which is the whole point of
    /// the affordance. When the user has already typed something it loads the composer
    /// instead of submitting — destroying a half-written question to run a suggestion
    /// nobody confirmed would be the wrong trade, and the text view's own undo can put
    /// the draft back.
    private func askFollowup(_ question: String) {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draft = question
            recallIndex = nil
            return
        }
        submit(question)
    }

    private func newThread() {
        notice = nil
        showsHistory = false
        queueFullNote = false
        // The engine first: `startNewThread` drops any waiting questions, and doing it
        // after clearing the draft keeps the two from racing over the composer.
        engine.startNewThread()
        draft = ""
        recallIndex = nil
    }

    /// Deleting the open thread must take it out of the engine too, or the next
    /// change the engine publishes writes the deleted thread back into the library.
    /// The history list stays open and the draft is kept: the user is tidying, not
    /// starting over.
    private func deleteThread(_ thread: ResearchThread) {
        store.delete(id: thread.id)
        if engine.thread.id == thread.id {
            engine.startNewThread()
            recallIndex = nil
        }
    }

    private func openThread(_ thread: ResearchThread) {
        showsHistory = false
        notice = nil
        recallIndex = nil
        draft = ""
        engine.replaceThread(with: thread)
    }

    /// The command list currently on screen, if any.
    private var visibleCompletions: [ComposerCommand.Entry]? {
        ComposerCommand.completions(for: draft)
    }

    /// Fills the composer with the chosen command, exactly as clicking the row does.
    ///
    /// It does not *run* the command. A completion is a way to finish typing, and
    /// several of these take an argument — `/model gpt-4o`, `/direct <question>` — so
    /// running on selection would make the argument unreachable for half the list. The
    /// trailing space is where the argument goes; a command that takes none is one more
    /// Return away, which is what clicking has always cost.
    private func accept(completion name: String) {
        // Replaces the whole draft, which cannot discard a typed argument: the list is
        // only open while `isBareCommandWord` holds, and the first space closes it. So
        // there is never an argument in the field for this to lose.
        draft = "/\(name) "
        completionIndex = nil
        // Both, here, rather than leaving the hover to the draft change that follows.
        // `onChange(of: draft)` does clear it, so this is not a fix — it is the same
        // pair `backOut` and that handler clear together, kept together in the third
        // place that touches them.
        hoverIndex = nil
        // Ends the recall walk, the way submitting does. Choosing a command is a decision
        // about what the field holds, and leaving the walk open means a later ↑ — once an
        // argument makes the list close — replaces that choice with a question from
        // history.
        recallIndex = nil
    }

    /// Return from the composer: take the highlighted command, or ask.
    private func submitFromComposer() {
        if let completions = visibleCompletions,
           let index = effectiveCompletionIndex, completions.indices.contains(index) {
            let name = completions[index].name
            accept(completion: name)
            // The last keystroke in the sequence the other announcements narrate, and the
            // one that was silent: Return closed the list and rewrote the field without
            // moving the focus, so a reader arrowing through the list heard every step up
            // to the one that mattered. Spoken here rather than inside `accept`, which the
            // mouse also reaches — the rule in `announce` is that only keys speak.
            announce("Selected /\(name)")
            return
        }
        submit(draft)
    }

    /// ↑/↓ drive the command list while it is open, and the question history otherwise.
    ///
    /// The list wins because it is the thing on screen: an arrow key that walked past a
    /// visible list to change the text underneath it would be startling. Nothing is lost:
    /// a visible completion list means the draft starts with a slash, and recall declines
    /// on a non-empty draft — unless a walk is already open, which is why `accept` and
    /// `submit` both close one.
    private func moveThroughCompletionsOrHistory(_ up: Bool) -> Bool {
        guard let completions = visibleCompletions, !completions.isEmpty else {
            return recall(up)
        }
        // Stepping from whatever is highlighted, including a row the pointer put there —
        // ↓ from a hovered row should reach the next one, not the top. The hover is then
        // dropped, because a pointer that is no longer moving must not keep out-voting
        // the keys: it sends no further events, so without this the arrows would walk an
        // index nothing draws. Moving the mouse again claims the highlight back.
        //
        // A nil back from `moveSelection` always means a row was left: ↑ into an
        // unhighlighted list enters at the *bottom* rather than answering nil — that is
        // the documented "↓ enters at the top, ↑ enters at the bottom" — so the only
        // route to nil is stepping up off row 0. The announcement below cannot fire for
        // an exit that did not happen.
        //
        // A highlight that is no longer a row reads as no highlight, exactly as
        // `submitFromComposer` treats one. Today `onChange(of: draft)` clears both
        // indices so this cannot bite; doing it here makes the paragraph above true by
        // construction instead of by that convention — a stale index past the end would
        // otherwise reach `moveSelection` and could answer nil for an exit nobody made.
        let startIndex = effectiveCompletionIndex.flatMap {
            completions.indices.contains($0) ? $0 : nil
        }
        let moved = ComposerCommand.moveSelection(startIndex, up: up,
                                                  count: completions.count)
        hoverIndex = nil
        completionIndex = moved
        if moved == nil {
            // ↑ off the top is a way out of the list, and leaving changes what Return
            // does exactly as Escape's does. Only `announceSelection` spoke here, and it
            // has nothing to say about nil — so the one exit a reader is most likely to
            // take by accident was the silent one.
            announce(Self.leftCommandListCopy)
        } else {
            announceSelection(moved, in: completions)
        }
        return true
    }

    /// Speaks the highlighted command, because nothing else will.
    ///
    /// `.accessibilityAddTraits(.isSelected)` only speaks while a VoiceOver cursor sits
    /// on the row, and during ↑/↓ the focus never leaves the text field — so the trait
    /// flips in silence and Return quietly changes meaning. The position goes with the
    /// name: this is the only feedback while arrowing, and "help" alone says neither that
    /// it is a command nor how far down the list it sits.
    ///
    /// Called from the arrow keys alone, not from every write to `completionIndex`. The
    /// mouse writes it too, and announcing there would talk over VoiceOver every time the
    /// pointer crossed a row — noise aimed squarely at the people this is for.
    private func announceSelection(_ index: Int?, in completions: [ComposerCommand.Entry]) {
        guard let index, completions.indices.contains(index) else { return }
        announce("/\(completions[index].name), \(index + 1) of \(completions.count)")
    }

    /// Speaks one line to VoiceOver.
    ///
    /// Only ever from a key the reader pressed. Every announcement here exists because
    /// a keystroke changed what Return will do without moving the focus, and a mouse
    /// gesture that did the same would be talking over them for nothing.
    ///
    /// The withheld-send announcement in `submit` is the one to watch: `submit` is the
    /// chokepoint rather than a key handler, so it holds today only because the send
    /// button greys itself out on the same predicate and cannot reach the guard. A
    /// caller added later that is not a keystroke would need to say so.
    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: message])
    }

    /// ↑/↓ walk back through this thread's earlier questions, the way a shell does.
    /// Only acts on an empty or recalled draft, so it never eats an arrow press in
    /// the middle of editing a long question.
    private func recall(_ up: Bool) -> Bool {
        let questions = engine.thread.turns.map(\.question).reversed().map { $0 }
        guard !questions.isEmpty else { return false }
        if recallIndex == nil && !draft.isEmpty { return false }

        if up {
            let next = (recallIndex ?? -1) + 1
            guard next < questions.count else { return true }
            recallIndex = next
            draft = questions[next]
        } else {
            // The index points into a *particular* thread's list, and opening a thread
            // from history swaps that list underneath it. Re-validate before indexing:
            // recalling five deep and then opening a one-turn thread would otherwise
            // read past the end and crash.
            guard let current = recallIndex, current < questions.count else {
                recallIndex = nil
                return false
            }
            if current == 0 {
                recallIndex = nil
                draft = ""
            } else {
                recallIndex = current - 1
                draft = questions[current - 1]
            }
        }
        return true
    }
}
