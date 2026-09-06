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
    @State private var showsHelp = false
    /// How many credential-shaped spans were removed from seeded text, if any.
    @State private var redactionNote: Int?
    /// Earlier questions, newest first, for ↑/↓ recall in the composer.
    @State private var recallIndex: Int?
    /// Whether the thread is scrolled to its end. Streams auto-scroll only while
    /// pinned, so reading back during an answer is never undone by the next token.
    @State private var isPinnedToBottom = true

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
            showsHelp = false
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
            showsHelp = false
            recallIndex = nil
        }
        // Opening Settings returns immediately, so refreshing there would sample the
        // state before the user had typed anything. The window tells us when it closes.
        .onReceive(NotificationCenter.default.publisher(for: .vervellumSettingsDidClose)) { _ in
            refreshConfiguredState()
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
                    if engine.thread.isEmpty && !showsHelp {
                        EmptyStateView(isConfigured: isConfigured,
                                       summonShortcut: preferences.summonHotkey.displayString,
                                       onOpenSettings: onOpenSettings)
                            .padding(.top, PanelTheme.Space.section)
                    }
                    if showsHelp {
                        MarkdownBody(markdown: ComposerCommand.helpText,
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
                    // backwards every time the answer grew. The sentinel it carries is
                    // what reports whether the user is still at the bottom.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                        .background(BottomSentinel { pinned in
                            isPinnedToBottom = pinned
                        })
                }
                .padding(.horizontal, PanelTheme.Space.gutter)
                .padding(.vertical, PanelTheme.Space.large)
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
            if let completions = ComposerCommand.completions(for: draft) {
                CommandCompletionsView(completions: completions) { name in
                    draft = "/\(name) "
                }
            }
            HStack(alignment: .bottom, spacing: PanelTheme.Space.small) {
                ComposerView(text: $draft,
                             placeholder: placeholder,
                             submitOnReturn: preferences.submitOnReturn,
                             isEnabled: !engine.isRunning,
                             onSubmit: { submit(draft) },
                             onArrow: recall)
                    // The composer's own width: the panel minus its gutters and the
                    // send button. Measured rather than guessed, so a widened panel
                    // stops growing the field a line too early.
                    .frame(height: ComposerView.height(
                        for: draft,
                        width: preferences.panelWidth - PanelTheme.Space.medium * 2 - 34))

                Button {
                    if engine.isRunning { engine.cancel() } else { submit(draft) }
                } label: {
                    Image(systemName: engine.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(engine.isRunning
                                    ? PanelTheme.Palette.verdict(.contradicted)
                                    : PanelTheme.Palette.accent,
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!engine.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(!engine.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? 0.35 : 1)
                .help(engine.isRunning ? "Stop the research (⌘.)" : "Ask")
                .padding(.bottom, 3)
            }
        }
        .padding(.horizontal, PanelTheme.Space.medium)
        .padding(.vertical, PanelTheme.Space.small)
    }

    private var placeholder: String {
        engine.isRunning ? "Researching…" : "Ask anything — / for commands"
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
        guard !engine.isRunning else { return }
        recallIndex = nil
        redactionNote = nil
        switch ComposerCommand.parse(text) {
        case .none:
            return
        case .ask(let question):
            showsHelp = false
            // The composer is live while the history list is open, and a question
            // asked from there must not run invisibly behind it.
            showsHistory = false
            draft = ""
            engine.ask(question, mode: .research)
        case .direct(let question):
            showsHelp = false
            showsHistory = false
            draft = ""
            engine.ask(question, mode: .direct)
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
            guard let last = engine.thread.turns.last else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(last.transcript, forType: .string)
        case .showHelp:
            draft = ""
            showsHelp = true
        }
    }

    /// What Escape does, in the order a user expects to be able to undo things:
    /// leave the history list, then clear a draft, then close the panel. Closing on
    /// the first press would throw away a half-typed question.
    private func backOut() {
        if showsHistory {
            showsHistory = false
        } else if showsHelp {
            showsHelp = false
        } else if !draft.isEmpty {
            draft = ""
            redactionNote = nil
            // Dropping the draft also ends the recall walk, so the next ↑ starts at the
            // most recent question rather than resuming halfway up the list.
            recallIndex = nil
        } else {
            onClose()
        }
    }

    private func refreshConfiguredState() {
        let keychain: SecretStore = KeychainStore()
        isConfigured = preferences.providerSettings
            .problems(hasModelKey: keychain.hasValue(for: .modelAPIKey),
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
        showsHelp = false
        showsHistory = false
        draft = ""
        recallIndex = nil
        engine.startNewThread()
    }

    private func openThread(_ thread: ResearchThread) {
        showsHistory = false
        showsHelp = false
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
