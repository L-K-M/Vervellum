import SwiftUI
import AppKit

/// Everything inside the panel: header, thread, composer.
///
/// The layout is fixed-header / scrolling-middle / fixed-composer, and that shape is
/// load-bearing. A research answer can run to several screens, but the two things the
/// user always needs — what is happening now, and where to type next — must never
/// scroll away.
struct PanelRootView: View {

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
            case .submit: submit(draft)
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
                                 scale: preferences.textScale,
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
                .font(PanelTheme.Font.caption)
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
                    .font(PanelTheme.Font.caption)
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
                    .font(PanelTheme.Font.caption)
                    .foregroundStyle(PanelTheme.Palette.verdict(.mixed))
                    .padding(.horizontal, PanelTheme.Space.small)
            }
            if !engine.queue.isEmpty {
                QueuedQuestionsView(queued: engine.queue) { engine.removeQueued($0) }
            }
            if let completions = ComposerCommand.completions(for: draft) {
                CommandCompletionsView(completions: completions) { name in
                    draft = "/\(name) "
                }
            }
            HStack(alignment: .bottom, spacing: PanelTheme.Space.small) {
                ComposerView(text: $draft,
                             placeholder: placeholder,
                             submitOnReturn: preferences.submitOnReturn,
                             onSubmit: { submit(draft) },
                             onArrow: recall)
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
                            - Self.sendButtonReservation))

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
                                       help: engine.isRunning ? "Ask next" : "Ask",
                                       isEnabled: !isDraftBlank,
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
        let symbol: String
        let tint: Color
        let help: String
        var isEnabled = true
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
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
        let queued: [ResearchEngine.QueuedQuestion]
        var onRemove: (UUID) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: PanelTheme.Space.tight) {
                ForEach(queued) { item in
                    HStack(spacing: PanelTheme.Space.small) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(PanelTheme.Palette.tertiaryText)
                        Text(item.mode == .direct ? "/direct \(item.question)" : item.question)
                            .font(PanelTheme.Font.caption)
                            .foregroundStyle(PanelTheme.Palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Button { onRemove(item.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
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
                    .font(.system(size: 9))
                Text(preferences.providerSettings.selectedModel?.displayName ?? "No model")
                    .font(PanelTheme.Font.caption)
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
        let completions: [ComposerCommand.Entry]
        var onSelect: (String) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(completions) { command in
                    Button { onSelect(command.name) } label: {
                        HStack(spacing: PanelTheme.Space.small) {
                            Text("/\(command.name)")
                                .font(PanelTheme.Font.citation(1.0))
                                .foregroundStyle(PanelTheme.Palette.accent)
                            Text(command.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(PanelTheme.Palette.secondaryText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, PanelTheme.Space.small)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, PanelTheme.Space.tight)
            .background(PanelTheme.Palette.cardFill,
                        in: RoundedRectangle(cornerRadius: PanelTheme.Radius.card, style: .continuous))
        }
    }

    // MARK: Actions

    private func submit(_ text: String) {
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
        if showsHistory {
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
                      hasSearchKey: keychain.hasValue(for: .searchAPIKey))
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
