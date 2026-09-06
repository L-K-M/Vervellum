#if os(Linux)
import Foundation
import CGtk

/// The Linux research window.
///
/// ## What this is not
///
/// It is not the macOS panel. On GNOME Wayland — Ubuntu's default — a client cannot
/// position its own window, cannot keep it above other windows, and has no layer-shell
/// protocol to fall back on; `gtk_window_move`, `set_position` and `set_keep_above` do
/// not exist in GTK4 at all. So this is an ordinary window that the compositor places,
/// summoned and dismissed by a desktop shortcut. Pretending otherwise would mean
/// shipping an X11-only escape hatch on a backend GTK has already deprecated.
///
/// What *is* the same is everything behind it: the same `ResearchRunner`, the same
/// prompts, the same citation rules, the same verdict table, the same thread archive.
/// The window is a renderer.
///
/// Rendering rebuilds the thread box from scratch on each change rather than diffing.
/// A research thread is a handful of turns, GTK label construction is cheap at that
/// scale, and the alternative is a widget-reuse cache whose bugs would be invisible
/// until an answer rendered stale text.
final class LinuxPanel {

    private let environment: LinuxEnvironment
    private let window: GTK.Widget
    private let threadBox: GTK.Widget
    private let composer: GTK.Widget
    private let sendButton: GTK.Widget
    private let statusLabel: GTK.Widget

    private var thread = ResearchThread()
    private var runningTask: Task<Void, Never>?
    private var isRunning = false
    /// Which turn the running task belongs to. A run cancelled by "New" still reports
    /// back, after the thread has been replaced; without this it would reset the state
    /// of whatever run the user had started since.
    private var runningTurnID: UUID?
    /// When the thread was last drawn. A streamed answer produces a snapshot per token,
    /// and rebuilding the widget tree that often is visibly slow on a long thread.
    private var lastRender = Date.distantPast

    init(application: UnsafeMutablePointer<GtkApplication>,
         environment: LinuxEnvironment = .shared) {
        self.environment = environment

        window = gtk_application_window_new(application)!
        GTK.hideOnClose(window)
        gtk_window_set_title(vv_window(window), "Vervellum")
        gtk_window_set_default_size(vv_window(window), 560, 680)

        let root = GTK.verticalBox(spacing: 0)
        threadBox = GTK.verticalBox(spacing: 18)
        composer = GTK.textView()
        statusLabel = GTK.markupLabel("")
        // Created without a handler: `wireComposer` attaches the real one once `self`
        // is fully initialised. Connecting a placeholder here and another later would
        // leave *both* attached, and the placeholder would still fire.
        sendButton = gtk_button_new_with_label("Ask")!

        gtk_window_set_child(vv_window(window), root)
        GTK.append(root, header())
        GTK.margins(threadBox, 16)
        GTK.append(root, GTK.scrolled(threadBox))
        GTK.append(root, footer())

        GTK.applyStylesheet(Self.stylesheet)
        wireComposer()
        render()
    }

    // MARK: Presentation

    /// The shortcut's action. A second press hides the window rather than raising it
    /// again, which is what "toggle" has to mean for a summoned panel.
    func toggle() {
        if gtk_widget_get_visible(window) != 0 {
            gtk_widget_set_visible(window, 0)
        } else {
            show()
        }
    }

    func show() {
        gtk_window_present(vv_window(window))
        gtk_widget_grab_focus(composer)
    }

    // MARK: Chrome

    private func header() -> GTK.Widget {
        let bar = GTK.horizontalBox(spacing: 8)
        GTK.margins(bar, 10)

        let title = GTK.markupLabel("<span weight=\"bold\">Vervellum</span>")
        gtk_widget_set_hexpand(title, 1)
        GTK.append(bar, title)

        GTK.append(bar, GTK.button("New") { [weak self] in self?.newThread() })
        GTK.append(bar, GTK.button("Close") { [weak self] in
            guard let self else { return }
            gtk_widget_set_visible(self.window, 0)
        })
        return bar
    }

    private func footer() -> GTK.Widget {
        let footer = GTK.verticalBox(spacing: 4)
        GTK.margins(footer, 10)

        GTK.addStyle(statusLabel, "status")
        GTK.append(footer, statusLabel)

        let row = GTK.horizontalBox(spacing: 8)
        // The composer grows with its content and then scrolls. Those two scrolled-window
        // properties are the entire supported recipe; a manual size-allocate handler is
        // the usual wrong answer.
        let composerScroller = GTK.scrolled(composer, maxHeight: 140)
        gtk_widget_set_hexpand(composerScroller, 1)
        GTK.addStyle(composerScroller, "composer")
        GTK.append(row, composerScroller)
        GTK.append(row, sendButton)
        GTK.append(footer, row)
        return footer
    }

    private func wireComposer() {
        GTK.onSignal(UnsafeMutableRawPointer(sendButton), "clicked") { [weak self] in
            self?.submitOrStop()
        }
        GTK.observeKeys(composer) { [weak self] keyval, modifiers in
            guard let self else { return false }
            if GTK.isEscape(keyval) {
                // Escape clears a draft first and only then closes, so a half-typed
                // question is never thrown away by a reflex key press.
                if GTK.text(of: self.composer).isEmpty {
                    gtk_widget_set_visible(self.window, 0)
                } else {
                    GTK.setText(self.composer, "")
                }
                return true
            }
            guard GTK.isReturn(keyval) else { return false }
            // With submit-on-Return, a bare Return sends and Shift-Return adds a line;
            // with the preference inverted, so are they.
            let submitOnReturn = self.environment.preferences.submitOnReturn
            let submitting = GTK.hasShift(modifiers) ? !submitOnReturn : submitOnReturn
            guard submitting else { return false }   // let the text view insert a newline
            self.submitOrStop()
            return true
        }
    }

    // MARK: Actions

    private func newThread() {
        runningTask?.cancel()
        // Cleared now rather than when the cancelled run reports back. Until `finish`
        // arrives — which takes as long as the in-flight request takes to notice the
        // cancellation — a press of Ask would otherwise be read as Stop and swallowed,
        // which looks exactly like the button ignoring the user.
        runningTask = nil
        runningTurnID = nil
        isRunning = false
        thread = ResearchThread()
        GTK.setText(composer, "")
        render()
    }

    private func submitOrStop() {
        if isRunning {
            runningTask?.cancel()
            return
        }
        let text = GTK.text(of: composer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch ComposerCommand.parse(text) {
        case .none:
            return
        case .newThread:
            newThread()
        case .showHelp:
            GTK.setText(composer, "")
            appendNotice(ComposerCommand.helpText)
        case .openSettings, .openHistory:
            GTK.setText(composer, "")
            appendNotice("That command is macOS-only for now. Settings live in "
                         + "`~/.config/vervellum/settings.json`.")
        case .copyLastAnswer:
            GTK.setText(composer, "")
            appendNotice("Select the answer text and copy it — there is no clipboard "
                         + "command on Linux yet.")
        case .ask(let question):
            GTK.setText(composer, "")
            ask(question, mode: .research)
        case .direct(let question):
            GTK.setText(composer, "")
            ask(question, mode: .direct)
        }
    }

    private func ask(_ question: String, mode: ResearchRunner.Mode) {
        var draft = ResearchTurn(question: question)
        draft.model = environment.preferences.providerSettings.modelName
        if mode == .direct { draft.notices = [.noEvidence] }
        // Immutable from here: the task's closure cannot capture a mutable variable.
        let turn = draft
        thread.turns.append(turn)
        runningTurnID = turn.id
        isRunning = true
        render()

        // Informational turns (`/help`) are filtered out again by `ResearchContext`;
        // dropping them here just keeps the history honest at the source.
        let history = thread.turns.dropLast().filter { !$0.question.isEmpty }
        let runner = ResearchRunner(
            environment: .init(preferences: environment.preferences, secrets: environment.secrets),
            trace: ResearchTrace(sink: StandardErrorLog()))

        runningTask = Task { [weak self] in
            let finished = await runner.run(turn, mode: mode, history: history) { snapshot in
                // Back onto the GTK loop. Not `DispatchQueue.main` and not `MainActor`:
                // a GLib main loop drains neither, so either would leave the window
                // frozen with no error to show for it.
                GTK.onMainLoop { self?.apply(snapshot) }
            }
            GTK.onMainLoop {
                self?.apply(finished)
                self?.finish(finished.id)
            }
        }
    }

    private func apply(_ snapshot: ResearchTurn) {
        guard let index = thread.turns.firstIndex(where: { $0.id == snapshot.id }) else { return }
        let previous = thread.turns[index]
        thread.turns[index] = snapshot
        thread.updatedAt = Date()

        // A change that only extends the answer is redrawn at most ten times a second.
        // Anything structural — a new stage, sources arriving, verdicts landing — is
        // drawn immediately, because those are the moments the user is waiting for. The
        // final frame is guaranteed by `finish(_:)`, which always draws.
        let structural = previous.stage != snapshot.stage
            || previous.sources.count != snapshot.sources.count
            || previous.findings.count != snapshot.findings.count
            || previous.notices != snapshot.notices
        guard structural || Date().timeIntervalSince(lastRender) >= 0.1 else { return }
        render()
    }

    private func finish(_ id: UUID) {
        // Only the run that is actually current may clear the running state. See
        // `runningTurnID`.
        guard runningTurnID == id else { return }
        runningTurnID = nil
        isRunning = false
        runningTask = nil
        environment.archive.save(persistableThread)
        environment.archive.flush()
        render()
    }

    /// A message from the panel itself — `/help`, or a command this platform lacks —
    /// shown in the thread as a turn with no question.
    ///
    /// Such turns are rendered but never persisted and never sent as history; both
    /// `persistableThread` and `ResearchContext` key off the empty question.
    private func appendNotice(_ markdown: String) {
        var turn = ResearchTurn(question: "")
        turn.answer = markdown
        turn.stage = .complete
        thread.turns.append(turn)
        render()
    }

    /// The thread as it is stored: research only, with the panel's own notices removed.
    private var persistableThread: ResearchThread {
        var stored = thread
        stored.turns.removeAll { $0.question.isEmpty }
        return stored
    }

    // MARK: Rendering

    private func render() {
        lastRender = Date()
        GTK.removeAllChildren(of: threadBox)

        if thread.turns.isEmpty {
            GTK.append(threadBox, GTK.markupLabel(Self.emptyStateMarkup(environment: environment)))
        }

        for turn in thread.turns {
            GTK.append(threadBox, turnView(turn))
        }

        gtk_label_set_markup(vv_label(statusLabel),
                             isRunning ? "<span size=\"small\">Researching… press Ask again to stop</span>" : "")
        gtk_button_set_label(vv_button(sendButton), isRunning ? "Stop" : "Ask")
    }

    private func turnView(_ turn: ResearchTurn) -> GTK.Widget {
        let box = GTK.verticalBox(spacing: 8)

        if !turn.question.isEmpty {
            let question = GTK.markupLabel(PangoMarkup.question(turn.question))
            GTK.addStyle(question, "question")
            GTK.append(box, question)
            GTK.append(box, GTK.markupLabel(PangoMarkup.trail(turn)))
        }

        if let notices = PangoMarkup.notices(turn.notices) {
            GTK.append(box, GTK.markupLabel(notices))
        }
        if let failure = turn.failure {
            GTK.append(box, GTK.markupLabel(PangoMarkup.failure(failure)))
        }
        if !turn.answer.isEmpty {
            let answer = GTK.markupLabel(PangoMarkup.answer(turn.answer, sources: turn.sources))
            GTK.onLinkActivated(answer, Self.openLink)
            GTK.append(box, answer)
        }
        if let findings = PangoMarkup.findings(turn.findings) {
            GTK.append(box, GTK.markupLabel(findings))
        }
        if let limitations = PangoMarkup.limitations(turn.limitations) {
            GTK.append(box, GTK.markupLabel(limitations))
        }
        if !turn.sources.isEmpty {
            let validation = CitationValidator.validate(answer: turn.answer,
                                                        sourceCount: turn.sources.count)
            let cited = Set(turn.citedSources(using: validation).map(\.number))
            if let markup = PangoMarkup.sources(turn.sources, cited: cited) {
                let label = GTK.markupLabel(markup)
                GTK.onLinkActivated(label, Self.openLink)
                GTK.append(box, label)
            }
        }
        if let followups = PangoMarkup.followups(turn.followups) {
            GTK.append(box, GTK.markupLabel(followups))
        }
        return box
    }

    /// Opens a link, and always reports it as handled.
    ///
    /// Returning false for a URI it refused would hand it straight back to GTK's default
    /// handler, which launches *any* scheme — including `file://`. Since the markup is
    /// built from model output, refusing has to mean refusing.
    private static func openLink(_ uri: String) -> Bool {
        GTK.openLink(uri)
        return true
    }

    private static func emptyStateMarkup(environment: LinuxEnvironment) -> String {
        let problems = environment.preferences.providerSettings.problems(
            hasModelKey: environment.secrets.hasValue(for: .modelAPIKey),
            hasSearchKey: environment.secrets.hasValue(for: .searchAPIKey))
        guard problems.isEmpty else {
            return "<span weight=\"bold\">Not configured yet</span>\n\n"
                + GTK.escape(problems.joined(separator: " ")) + "\n\n"
                + GTK.escape("Edit ~/.config/vervellum/settings.json, then store your keys "
                             + "with secret-tool or export VERVELLUM_MODEL_KEY and "
                             + "VERVELLUM_SEARCH_KEY. Keys are read from "
                             + environment.secrets.backendDescription + ".")
        }
        return "<span weight=\"bold\">Ask a question.</span>\n\n"
            + GTK.escape("Vervellum plans web searches, runs them, then writes an answer that "
                         + "cites only what it found — and grades its own claims against that "
                         + "evidence.")
            + "\n\n<span size=\"small\">"
            + GTK.escape("Return asks · Shift-Return adds a line · Esc clears, then closes · "
                         + "/ for commands")
            + "</span>"
    }

    private static let stylesheet = """
        .question { font-size: 1.05em; }
        .composer { border: 1px solid alpha(currentColor, 0.2); border-radius: 8px; }
        .status { opacity: 0.7; }
        """
}
#endif
