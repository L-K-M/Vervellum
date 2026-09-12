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
    private let threadScroller: GTK.Widget
    private let composer: GTK.Widget
    private let sendButton: GTK.Widget
    private let statusLabel: GTK.Widget
    /// One row per attached file, above the composer. Rebuilt rather than diffed, like
    /// the thread: there are at most four of them.
    private let attachmentBox: GTK.Widget
    /// The four level buttons, rebuilt whenever the selection moves.
    private let levelBox: GTK.Widget
    /// What the selected level does and what it may spend, under the buttons.
    ///
    /// Always on screen rather than in a tooltip: the GTK panel has no completion list
    /// and no Settings window, so a tooltip would put the only explanation of the only
    /// research control behind a hover a keyboard never performs.
    private let levelSummary: GTK.Widget

    private var thread = ResearchThread()
    /// What is attached to the question being typed, bytes and all.
    ///
    /// Held here rather than written as it arrives: a question still being typed has no
    /// turn to refer to it, and the store is swept by reachability — see
    /// `PendingAttachment`. `ask` writes them at the moment a turn exists.
    private var pendingAttachments: [PendingAttachment] = []
    private var runningTask: Task<Void, Never>?
    private var isRunning = false
    /// Which turn the running task belongs to. A run cancelled by "New" still reports
    /// back, after the thread has been replaced; without this it would reset the state
    /// of whatever run the user had started since.
    private var runningTurnID: UUID?
    /// When the thread was last drawn. A streamed answer produces a snapshot per token,
    /// and rebuilding the widget tree that often is visibly slow on a long thread.
    private var lastRender = Date.distantPast
    /// Set when a turn is appended, so the next render scrolls to it even if the reader
    /// had scrolled up: a question just asked is always the thing to look at.
    private var scrollToNewest = false

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
        attachmentBox = GTK.verticalBox(spacing: 4)
        levelBox = GTK.horizontalBox(spacing: 4)
        levelSummary = GTK.markupLabel("")
        // Created without a handler: `wireComposer` attaches the real one once `self`
        // is fully initialised. Connecting a placeholder here and another later would
        // leave *both* attached, and the placeholder would still fire.
        sendButton = gtk_button_new_with_label("Ask")!

        threadScroller = GTK.scrolled(threadBox)

        gtk_window_set_child(vv_window(window), root)
        GTK.append(root, header())
        GTK.margins(threadBox, 16)
        GTK.append(root, threadScroller)
        GTK.append(root, footer())

        GTK.addStyle(threadBox, "thread")
        GTK.applyStylesheet(Self.stylesheet(textScale: environment.preferences.textScale))
        wireComposer()
        // Draws the (empty) attachment row once, which is what hides it: GTK4 shows a
        // widget by default, and an empty box still takes its spacing.
        renderAttachments()
        renderLevelSelector()
        render()
    }

    // MARK: Presentation

    /// The shortcut's action. A second press hides the window rather than raising it
    /// again, which is what "toggle" has to mean for a summoned panel.
    ///
    /// "Up" means visible *and* active. On macOS the panel floats above everything,
    /// so visible means on top; here the compositor owns stacking, and a window that
    /// is visible but buried behind the editor the user clicked into is, to them, not
    /// up. Hiding it would make the shortcut appear to do nothing and cost a second
    /// press; presenting it is what the shortcut means.
    func toggle() {
        if gtk_widget_get_visible(window) != 0, gtk_window_is_active(vv_window(window)) != 0 {
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
        GTK.append(footer, attachmentBox)
        GTK.append(footer, levelBox)
        GTK.addStyle(levelSummary, "status")
        GTK.append(footer, levelSummary)

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

    /// Draws the level buttons and the line explaining the selected one.
    ///
    /// Rebuilt rather than restyled in place: `GTK.addStyle` adds a CSS class and there
    /// is no counterpart that removes one, so the row that shows which of four buttons
    /// is selected is the one row that must be thrown away and built again. It is four
    /// buttons; the attachment row above it already works this way.
    ///
    /// The separators are where `ResearchLevel.beginsGroup` says the scale stops — see
    /// that type for why those two places and not others.
    private func renderLevelSelector() {
        GTK.removeAllChildren(of: levelBox)
        let selected = environment.preferences.researchLevel

        for level in ResearchLevel.ordered {
            if level.beginsGroup { GTK.append(levelBox, GTK.verticalSeparator()) }
            // The selected button carries its state in its *label* as well as its CSS
            // class. A theme decides what a class looks like and some decide nothing at
            // all, and a selector whose selection is invisible under the user's theme
            // would be worse than no selector: the bullet is not a decoration, it is the
            // answer to "which one am I asking at".
            let title = level == selected ? "• " + level.displayName : level.displayName
            let button = GTK.button(title) { [weak self] in
                guard let self else { return }
                self.environment.preferences.researchLevel = level
                self.renderLevelSelector()
            }
            GTK.addStyle(button, "level")
            if level == selected { GTK.addStyle(button, "level-selected") }
            // The selected button stays enabled. Disabling it would dim the one button
            // that is meant to stand out, and every theme draws "insensitive" as "you
            // cannot have this" rather than "you already have it". Clicking it again
            // rewrites the same preference and redraws the same row.
            GTK.append(levelBox, button)
        }

        let settings = environment.preferences.providerSettings
        GTK.setMarkup(levelSummary, GTK.escape(selected.summary + " " + selected.cost(settings)))
    }

    private func wireComposer() {
        GTK.onSignal(UnsafeMutableRawPointer(sendButton), "clicked") { [weak self] in
            self?.submitOrStop()
        }
        // A file or an image dropped on the composer is an attachment. A drag carrying
        // only text never reaches here — the target asks for files and images alone — so
        // dragging a selection into the field still inserts it.
        GTK.onDrop(composer) { [weak self] dropped in
            guard let self else { return false }
            // What was actually taken, not an unconditional yes. The return value is the
            // drag's answer to its *source*, and a source offering a move reads a yes as
            // permission to delete the original — so claiming a drop this panel refused
            // in full could take the user's only copy of a file it would not attach. It
            // is also what decides whether GTK shows the drop-failed feedback, which a
            // refusal has earned: the notice in the thread says why, and the cursor
            // should not have said otherwise on the way in.
            return self.receive(dropped)
        }
        GTK.observeKeys(composer) { [weak self] keyval, modifiers in
            guard let self else { return false }
            if GTK.isEscape(keyval) {
                // Escape clears a draft first and only then closes, so a half-typed
                // question is never thrown away by a reflex key press.
                if GTK.text(of: self.composer).isEmpty, self.pendingAttachments.isEmpty {
                    gtk_widget_set_visible(self.window, 0)
                } else {
                    GTK.setText(self.composer, "")
                    // With the draft, because they are one composer: an Escape that
                    // emptied the field and left a screenshot attached would send it
                    // with the next question.
                    self.pendingAttachments = []
                    self.renderAttachments()
                }
                return true
            }
            // Control-V, but only when the clipboard is carrying something a text view
            // cannot show. `readClipboard` answers false for text, and the key then goes
            // to GTK, which pastes it exactly as it always did.
            //
            // Text wins outright, which is a decision and not an oversight. Browsers and
            // office suites put a text or HTML flavour on the clipboard *beside* a copied
            // picture, so preferring the image would turn "copy this paragraph" into "attach
            // a screenshot of it" — a paste that silently does something else is worse than
            // one that cannot reach a flavour. Dragging the image instead is unaffected: a
            // drop offers files and textures alone.
            if GTK.isPaste(keyval, modifiers) {
                return GTK.readClipboard(self.composer) { [weak self] dropped in
                    guard let self else { return }
                    guard let dropped else {
                        // The key was taken — the clipboard said it was holding a file
                        // or a picture — and then the read produced nothing: it changed
                        // under us, or what it held could not be encoded. Said out loud,
                        // because a Ctrl-V that does nothing at all is the worst of the
                        // three outcomes.
                        self.appendNotice("The clipboard's contents could not be read. "
                                          + "Try copying it again.")
                        return
                    }
                    self.receive(dropped)
                }
            }
            guard GTK.isReturn(keyval) else { return false }
            // With submit-on-Return, a bare Return sends and Shift-Return adds a line;
            // with the preference inverted, so are they. Control-Return always sends,
            // the way Command-Return does on macOS, so there is one key that asks
            // whichever way Return is configured.
            let submitOnReturn = self.environment.preferences.submitOnReturn
            let submitting = GTK.hasControl(modifiers)
                || (GTK.hasShift(modifiers) ? !submitOnReturn : submitOnReturn)
            guard submitting else { return false }   // let the text view insert a newline
            // Return never stops a run. A user who types a follow-up while the answer
            // streams and presses Return out of habit must not lose the answer; the
            // draft stays and the key is swallowed, exactly as on macOS. Only the Stop
            // button cancels.
            guard !self.isRunning else { return true }
            self.submit()
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
        pendingAttachments = []
        renderAttachments()
        render()
    }

    /// The button: Ask while idle, Stop while a run is in flight.
    private func submitOrStop() {
        if isRunning {
            runningTask?.cancel()
            return
        }
        submit()
    }

    private func submit() {
        guard !isRunning else { return }
        let text = GTK.text(of: composer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // A dropped file with nothing asked about it was a Return that did nothing
            // whatsoever — the chip sitting there being, as far as the reader could
            // tell, what broke the key. The macOS panel says the same sentence, from the
            // same constant.
            if !pendingAttachments.isEmpty { appendNotice(AttachmentIntake.questionlessMessage) }
            return
        }

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
        case .selectModel(let name):
            GTK.setText(composer, "")
            selectModel(named: name)
        case .ask(let question, let level):
            GTK.setText(composer, "")
            // A typed level is this question's alone; the selector keeps whatever it was
            // set to, and nil means "whatever it says". See `ComposerCommand.ask`.
            ask(question, mode: level ?? environment.preferences.researchLevel,
                attaching: takePendingAttachments())
        }
    }

    /// `/model` — list the configured providers, or switch to one.
    ///
    /// The switch is persisted rather than held for this window: `CorePreferences` is
    /// the same object the next run reads its environment from, and a selection that
    /// lived only in the panel would be forgotten by `vervellum --ask`.
    private func selectModel(named name: String) {
        var settings = environment.preferences.providerSettings
        guard !name.isEmpty else {
            appendNotice(ComposerCommand.modelListing(settings))
            return
        }
        guard settings.selectModel(named: name) else {
            appendNotice(ComposerCommand.unknownModel(name, in: settings))
            return
        }
        environment.preferences.providerSettings = settings
        appendNotice(ComposerCommand.modelListing(settings))
    }

    /// - Parameters:
    ///   - attached: what goes with this question. Passed in rather than read from
    ///     `pendingAttachments`, because a retry asks with the *old turn's* files while
    ///     the composer may be holding files staged for a different question — and
    ///     taking those would destroy them.
    ///   - lostAttachments: whether this question was asked with something attached that
    ///     could not be brought along — only a retry can be, and only when the bytes are
    ///     no longer stored.
    private func ask(_ question: String, mode: ResearchRunner.Mode,
                     attaching attached: [PendingAttachment],
                     lostAttachments: Bool = false) {
        var draft = ResearchTurn(question: question)
        draft.model = environment.preferences.providerSettings.modelName
        draft.level = mode
        if mode == .direct { draft.notices = [.noEvidence] }
        if lostAttachments { draft.addNotice(.attachmentMissing) }
        draft.attachments = attached.map { $0.attachment }
        // Written at the one moment a turn that refers to them exists, and only when the
        // library is being kept: "history off" means the bytes are gone, and a
        // screenshot in a directory beside an erased thread file would be the loudest
        // way to break that. The turn runs with the picture either way — what it is sent
        // is the map below, held in memory for the length of the run.
        if environment.preferences.historyEnabled {
            for pending in attached {
                do {
                    try environment.attachments.write(pending.data, for: pending.attachment)
                } catch {
                    // No path and no error text: a failure here names a file under the
                    // user's home, and this log records shape rather than content.
                    StandardErrorLog().write(.warning, "An attachment could not be stored, "
                        + "so it will not be there when this thread is reopened.")
                    // And said where the reader is looking. The log is for whoever runs
                    // this from a terminal; the notice is for the person who is about to
                    // believe their screenshot is part of the saved thread.
                    draft.addNotice(.attachmentNotStored)
                }
            }
        }
        // Immutable from here: the task's closure cannot capture a mutable variable.
        let turn = draft
        let bytes = Dictionary(attached.map { ($0.id, $0.data) },
                               uniquingKeysWith: { first, _ in first })
        thread.turns.append(turn)
        runningTurnID = turn.id
        isRunning = true
        scrollToNewest = true
        environment.archive.save(persistableThread)
        render()

        // Informational turns (`/help`) are filtered out again by `ResearchContext`;
        // dropping them here just keeps the history honest at the source.
        let history = thread.turns.dropLast().filter { !$0.question.isEmpty }
        let runner = ResearchRunner(
            environment: .init(preferences: environment.preferences, secrets: environment.secrets),
            trace: ResearchTrace(sink: StandardErrorLog()),
            attachmentBytes: { bytes[$0.id] })

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
        guard snapshot.id == runningTurnID,
              let index = thread.turns.firstIndex(where: { $0.id == snapshot.id }) else { return }
        let previous = thread.turns[index]
        thread.turns[index] = snapshot
        thread.updatedAt = Date()

        // A change that only extends the answer is redrawn at most ten times a second.
        // Anything structural — a new stage, sources arriving, verdicts landing — is
        // drawn immediately, because those are the moments the user is waiting for. The
        // final frame is guaranteed by `finish(_:)`, which always draws.
        let structural = SnapshotCoalescer.isStructural(snapshot, relativeTo: previous)
        guard structural || Date().timeIntervalSince(lastRender) >= SnapshotCoalescer.defaultInterval else { return }
        environment.archive.save(persistableThread)
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

    /// Re-asks a turn's question the way it was asked. A turn that is still last is
    /// replaced in place; an older one is asked again at the end, where the answer
    /// belongs — the same rule the macOS engine follows.
    private func retry(_ turn: ResearchTurn) {
        guard !isRunning else { return }
        // The level the turn was asked at, which it now records — so a deep or agent
        // turn is retried as one, rather than quietly re-asked as a single pass.
        let mode = turn.level
        // Asked again means asked with what it was asked with. The bytes are still in
        // the store — the turn being retried is what keeps them reachable — and one
        // whose bytes have gone is dropped rather than listed on a turn that could not
        // see it.
        // Into a local, never into `pendingAttachments`: the composer may be holding
        // files staged for the question the user is typing, and a retry that took them
        // would ask an old question with them and destroy them in the same gesture.
        let again = turn.attachments.compactMap { attachment in
            environment.attachments.data(for: attachment).map {
                PendingAttachment(attachment: attachment, data: $0)
            }
        }
        // What did not come back is said on the new turn. A turn asked with history off
        // never had its bytes written — they lived for the length of that run and no
        // longer — so a retry seconds later would otherwise quietly re-ask the question
        // without the picture. The same notice the runner raises for bytes that have
        // gone, because it is the same fact about the same question.
        let lost = again.count < turn.attachments.count
        if thread.turns.last?.id == turn.id { thread.turns.removeLast() }
        ask(turn.question, mode: mode, attaching: again, lostAttachments: lost)
    }

    /// A message from the panel itself — `/help`, or a command this platform lacks —
    /// shown in the thread as a turn with no question.
    ///
    /// Such turns are rendered but never persisted and never sent as history; both
    /// `persistableThread` and `ResearchContext` key off the empty question.
    // MARK: Attachments

    /// Takes what a drop or a paste turned out to be carrying.
    ///
    /// Anything refused is said in the thread, as a notice: a file that vanishes on
    /// being dropped is indistinguishable from a window that does not accept drops, and
    /// the reader is owed the difference.
    ///
    /// - Returns: whether anything was attached, which a drop answers to its source and
    ///   a paste has no use for.
    @discardableResult
    private func receive(_ dropped: GTK.Dropped) -> Bool {
        let existing = pendingAttachments.count
        let outcome: AttachmentIntake.Outcome
        switch dropped {
        case .files(let paths):
            outcome = AttachmentIntake.read(files: paths.map { URL(fileURLWithPath: $0) },
                                            existing: existing)
        case .image(let data):
            // An image on a clipboard has no name of its own, so it is given the one
            // the macOS side gives it.
            outcome = AttachmentIntake.outcome(
                from: [AttachmentIntake.Candidate(data, name: AttachmentIntake.pastedImageName)],
                existing: existing)
        }
        pendingAttachments.append(contentsOf: outcome.accepted)
        renderAttachments()
        if !outcome.refusals.isEmpty {
            appendNotice(outcome.refusals.joined(separator: "\n\n"))
        }
        return !outcome.accepted.isEmpty
    }

    /// Hands over what the composer is holding and lets go of it, which is what makes
    /// sending and retrying different: a sent question takes the files with it, a retried
    /// one brings its own and leaves these where they are.
    private func takePendingAttachments() -> [PendingAttachment] {
        defer {
            pendingAttachments = []
            renderAttachments()
        }
        return pendingAttachments
    }

    /// Draws one row per attached file, with a way to take each one off again.
    ///
    /// Rebuilt rather than diffed, like the thread and for the same reason: there are at
    /// most `AttachmentIntake.maximumPerQuestion` of them.
    private func renderAttachments() {
        GTK.removeAllChildren(of: attachmentBox)
        gtk_widget_set_visible(attachmentBox, pendingAttachments.isEmpty ? 0 : 1)
        for pending in pendingAttachments {
            let row = GTK.horizontalBox(spacing: 8)
            let glyph = pending.attachment.kind == .image ? "🖼" : "📄"
            let label = GTK.markupLabel(
                "<span size=\"small\">\(glyph) \(GTK.escape(pending.attachment.name)) "
                + "<span alpha=\"60%\">\(GTK.escape(pending.attachment.sizeDescription))</span></span>")
            gtk_widget_set_hexpand(label, 1)
            gtk_label_set_xalign(vv_label(label), 0)
            GTK.append(row, label)
            let id = pending.id
            GTK.append(row, GTK.button("✕") { [weak self] in
                guard let self else { return }
                self.pendingAttachments.removeAll { $0.id == id }
                self.renderAttachments()
            })
            GTK.append(attachmentBox, row)
        }
    }

    private func appendNotice(_ markdown: String) {
        var turn = ResearchTurn(question: "")
        turn.answer = markdown
        turn.stage = .complete
        thread.turns.append(turn)
        scrollToNewest = true
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
        // Sampled before the rebuild, which resets the content height: a reader who
        // had scrolled up to re-read is left where they were; one who was at the end
        // follows the answer as it grows. The rebuild keeps the scroller's value, so
        // without this a new question and its answer landed below the fold.
        let follow = scrollToNewest || GTK.isScrolledToBottom(threadScroller)
        scrollToNewest = false
        GTK.removeAllChildren(of: threadBox)

        if thread.turns.isEmpty {
            GTK.append(threadBox, GTK.markupLabel(Self.emptyStateMarkup(environment: environment)))
        }

        for turn in thread.turns {
            GTK.append(threadBox, turnView(turn))
        }

        gtk_label_set_markup(vv_label(statusLabel),
                             isRunning ? "<span size=\"small\">Researching… press Stop to cancel</span>" : "")
        gtk_button_set_label(vv_button(sendButton), isRunning ? "Stop" : "Ask")

        if follow {
            // One idle hop later, after the new children have been laid out and the
            // adjustment's upper bound reflects them.
            let scroller = threadScroller
            GTK.onMainLoop { GTK.scrollToBottom(scroller) }
        }
    }

    private func turnView(_ turn: ResearchTurn) -> GTK.Widget {
        let box = GTK.verticalBox(spacing: 8)

        if !turn.question.isEmpty {
            let question = GTK.markupLabel(PangoMarkup.question(turn.question))
            GTK.addStyle(question, "question")
            GTK.append(box, question)
            // Honor the same preference as macOS; the status bar still shows activity.
            if environment.preferences.showProcessTrail
                && (!turn.stage.isTerminal || !turn.searches.isEmpty
                    || !turn.reading.isEmpty || turn.stage == .failed) {
                GTK.append(box, GTK.markupLabel(PangoMarkup.trail(turn)))
            }
        }

        if let notices = PangoMarkup.notices(turn.notices) {
            GTK.append(box, GTK.markupLabel(notices))
        }
        if let failure = turn.failure {
            GTK.append(box, GTK.markupLabel(PangoMarkup.failure(failure)))
        }
        // One click re-asks, as on macOS. Retyping the question was the only recourse
        // before, and the composer had been cleared on submit.
        if turn.failure != nil || turn.stage == .cancelled, !turn.question.isEmpty {
            let retry = GTK.button("Try again") { [weak self] in self?.retry(turn) }
            gtk_widget_set_halign(retry, GTK_ALIGN_START)
            GTK.append(box, retry)
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
        let settings = environment.preferences.providerSettings
        let problems = settings.problems(
            hasModelKey: environment.secrets.hasModelKey(for: settings),
            hasSearchKey: environment.secrets.hasSearchKey(for: settings))
        guard problems.isEmpty else {
            return "<span weight=\"bold\">Not configured yet</span>\n\n"
                + GTK.escape(problems.joined(separator: " ")) + "\n\n"
                + GTK.escape("Edit ~/.config/vervellum/settings.json, then store your keys "
                             + "with secret-tool or export VERVELLUM_MODEL_KEY and "
                             + "VERVELLUM_SEARCH_KEY. Keys are read from "
                             + environment.secrets.backendDescription + ".")
        }
        // The hint follows the preference; a hint that says the opposite of what Return
        // does reads as the app being broken.
        let keys = environment.preferences.submitOnReturn
            ? "Return asks · Shift-Return adds a line"
            : "Return adds a line · Shift-Return asks"
        return "<span weight=\"bold\">Ask a question.</span>\n\n"
            + GTK.escape("Vervellum plans web searches, runs them, then writes an answer that "
                         + "cites only what it found — and grades its own claims against that "
                         + "evidence.")
            + "\n\n<span size=\"small\">"
            + GTK.escape(keys + " · Ctrl-Return always asks · Esc clears, then closes · "
                         + "/ for commands")
            + "</span>"
    }

    /// The panel's stylesheet, with the thread scaled by the shared `textScale`
    /// preference.
    ///
    /// One rule on the thread container is enough: GTK's `em` is relative to the
    /// parent's size, and every `size="small"` in the Pango markup is relative to its
    /// label, so headings, trails and citations all scale together. The composer and
    /// header keep the system size, as on macOS. The preference arrives clamped;
    /// `String(format:)` writes the decimal point the CSS parser expects whatever the
    /// user's locale.
    static func stylesheet(textScale: Double) -> String {
        return """
            .thread { font-size: \(String(format: "%.2fem", textScale)); }
            .question { font-size: 1.05em; }
            .composer { border: 1px solid alpha(currentColor, 0.2); border-radius: 8px; }
            .status { opacity: 0.7; }
            .level { padding: 2px 8px; font-size: 0.9em; }
            .level-selected { font-weight: bold; }
            """
    }
}
#endif
