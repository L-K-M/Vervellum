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
    /// The row the four level buttons live in.
    private let levelBox: GTK.Widget
    /// The buttons themselves, in ladder order, built once and then retitled in place.
    /// See `markSelectedLevel` for why they are not rebuilt.
    private var levelButtons: [(level: ResearchLevel, button: GTK.Widget)] = []
    /// What the selected level does and what it may spend, under the buttons.
    ///
    /// Always on screen rather than in a tooltip: the GTK panel has no completion list
    /// and no Settings window, so a tooltip would put the only explanation of the only
    /// research control behind a hover a keyboard never performs.
    private let levelSummary: GTK.Widget

    /// Every open thread's session, keyed by thread id. `/new` detaches the current
    /// one rather than cancelling its run: the session keeps working in the map —
    /// and keeps persisting its thread — while the new one is on screen. The macOS
    /// `ResearchEngine` holds the same map; there is no `/history` here yet, so a
    /// detached session can only be revisited through a restart, but its run still
    /// completes and is stored.
    private var sessions: [UUID: ResearchSession] = [:]
    /// The thread on screen. A `lazy var` because building the first session needs
    /// `environment`, which `init` itself is what sets — the property is forced at the
    /// end of `init`, once everything it reads exists.
    private lazy var active: ResearchSession = makeSession(thread: ResearchThread())
    /// What is attached to the question being typed, bytes and all.
    ///
    /// Held here rather than written as it arrives: a question still being typed has no
    /// turn to refer to it, and the store is swept by reachability — see
    /// `PendingAttachment`. `ask` writes them at the moment a turn exists.
    private var pendingAttachments: [PendingAttachment] = []
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
        buildLevelSelector()
        // Forced here, once `init` is done and `environment` exists — see the
        // property for why it is lazy. Registering is what retains a session after
        // it is detached: the map is the only strong owner of one nobody can see.
        sessions[active.id] = active
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

    /// Builds the row of level buttons, once.
    ///
    /// The separators are where `ResearchLevel.beginsGroup` says the scale stops — see
    /// that type for why those two places and not others.
    private func buildLevelSelector() {
        for level in ResearchLevel.ordered {
            if level.beginsGroup { GTK.append(levelBox, GTK.verticalSeparator()) }
            let button = GTK.button(level.displayName) { [weak self] in
                guard let self else { return }
                self.environment.preferences.researchLevel = level
                self.markSelectedLevel()
            }
            GTK.addStyle(button, "level")
            GTK.append(levelBox, button)
            levelButtons.append((level, button))
        }
        markSelectedLevel()
    }

    /// Marks which level the next question will be asked at, and says what it spends.
    ///
    /// The buttons are retitled and restyled where they stand rather than the row being
    /// torn down and rebuilt, which is what the attachment row above does. Two reasons,
    /// and the first is a bug rather than a preference:
    ///
    /// * **This row is a selection, and it is redrawn from inside one of its own
    ///   buttons' click handlers.** Rebuilding would destroy the widget the keyboard is
    ///   focused on at the moment it is being activated, so a reader who tabbed to
    ///   `Deep rounds` and pressed Space would have the focus come out somewhere else —
    ///   and it would also be destroying a widget during its own signal emission, which
    ///   GObject survives only because emission holds a reference to the closure. The
    ///   attachment row has neither problem: nothing in it is focusable and it is
    ///   redrawn from outside itself.
    /// * A rebuild of four buttons for a one-character change is visible as a flicker.
    ///
    /// The selection is carried in the *label* as well as in a CSS class, because a
    /// theme decides what a class looks like and some decide nothing at all. The bullet
    /// is not decoration: it is the answer to "which one am I asking at", and it is what
    /// a screen reader reads.
    private func markSelectedLevel() {
        let selected = environment.preferences.researchLevel
        for (level, button) in levelButtons {
            let isSelected = level == selected
            GTK.setButtonTitle(button, isSelected ? "• " + level.displayName : level.displayName)
            if isSelected {
                GTK.addStyle(button, "level-selected")
            } else {
                GTK.removeStyle(button, "level-selected")
            }
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
            // Shift- and Alt-Return always break a line, whichever way the
            // preference points — it governs a bare Return only. The toggle used to
            // invert both keys, which left "Return inserts a newline" mode with no
            // way to break a line at all. Control-Return always sends, the way
            // Command-Return does on macOS, so that mode still has a key that asks.
            // Checked in this order so Ctrl-Shift-Return breaks a line too, matching
            // Cmd-Shift-Return on the macOS side.
            if GTK.hasShift(modifiers) || GTK.hasAlt(modifiers) { return false }
            let submitting = GTK.hasControl(modifiers)
                || self.environment.preferences.submitOnReturn
            guard submitting else { return false }   // let the text view insert a newline
            // Return never stops a run. A user who types a follow-up while the answer
            // streams and presses Return out of habit must not lose the answer; the
            // draft stays and the key is swallowed, exactly as on macOS. Only the Stop
            // button cancels.
            guard !self.active.isRunning else { return true }
            self.submit()
            return true
        }
    }

    // MARK: Actions

    private func newThread() {
        // Detached, not cancelled: a run in flight on the old session keeps going —
        // the map holds it, and its finished thread is still saved to the archive.
        activate(makeSession(thread: ResearchThread()))
        GTK.setText(composer, "")
        pendingAttachments = []
        renderAttachments()
    }

    /// The button: Ask while idle, Stop while a run is in flight.
    private func submitOrStop() {
        if active.isRunning {
            active.cancel()
            return
        }
        submit()
    }

    private func submit() {
        guard !active.isRunning else { return }
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
            // set to, and nil means "whatever it says" — resolved inside `ask`. See
            // `ComposerCommand.ask`.
            //
            // The flag goes up *before* the call, like the retry button's: `ask`
            // appends the turn and publishes synchronously, so the render that runs
            // inside it must already know to follow. Reset if nothing started.
            scrollToNewest = true
            let outcome = active.ask(question, mode: level,
                                     attachments: takePendingAttachments())
            if outcome != .started { scrollToNewest = false }
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

    /// Builds a session over one thread and wires its callbacks to this window.
    ///
    /// The callbacks do two different jobs, which is why `onChange` is not simply
    /// "repaint": every session persists its own thread — a detached run is still
    /// writing the thread it will be reopened as — while only the session on screen
    /// is drawn.
    private func makeSession(thread: ResearchThread) -> ResearchSession {
        let session = ResearchSession(
            thread: thread,
            preferences: environment.preferences,
            secrets: environment.secrets,
            logSink: StandardErrorLog(),
            attachmentStore: environment.attachments,
            deliver: { GTK.onMainLoop($0) },
            after: { GTK.after($0, $1) })
        session.onChange = { [weak self] session in
            guard let self else { return }
            // Saved whether or not the session is on screen: the archive upserts by
            // thread id, so a detached run writes its own thread and no other.
            self.environment.archive.save(session.persistableThread)
            guard session === self.active else { return }
            self.render()
        }
        session.onRunningChange = { [weak self] session in
            guard let self else { return }
            if !session.isRunning {
                // The debounced save above is for mid-stream; a run that has settled —
                // completed, failed or stopped — is written through to disk now, so a
                // detached session's last word survives the window being closed.
                self.environment.archive.save(session.persistableThread)
                self.environment.archive.flush()
            }
            guard session === self.active else { return }
            self.render()
        }
        // `onQueueReturned` is intentionally unwired: the composer refuses questions
        // while a run is up (`submit` gates on `isRunning`), so this front end never
        // builds the queue the macOS one hands back.
        return session
    }

    /// Puts a session on screen. The old one is left in the map untouched — that is
    /// the whole mechanism, not a step that forgot to cancel.
    private func activate(_ session: ResearchSession) {
        sessions[session.id] = session
        active = session
        // A settled session can never be shown again (there is no /history here yet)
        // and its final thread was already saved and flushed by `onRunningChange`,
        // so drop it rather than letting the map grow for the life of the window.
        sessions = sessions.filter { $0.value === session || $0.value.isRunning }
        render()
    }

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

    /// A message from the panel itself — `/help`, or a command this platform lacks —
    /// shown in the thread as a turn with no question.
    ///
    /// Such turns are rendered but never persisted and never sent as history; both
    /// `persistableThread` and `ResearchContext` key off the empty question.
    private func appendNotice(_ markdown: String) {
        var turn = ResearchTurn(question: "")
        turn.answer = markdown
        turn.stage = .complete
        // The flag first: appending publishes synchronously, so `render` runs inside
        // the call and must already know it should follow.
        scrollToNewest = true
        active.appendLocalTurn(turn)
    }

    // MARK: Rendering

    /// Rebuilds the thread box from the session on screen.
    ///
    /// There is no redraw throttle of its own here: the session's `SnapshotCoalescer`
    /// already paces published snapshots to ~10 Hz — the same rule `lastRender` used
    /// to implement by hand — so each `onChange` is worth a render.
    private func render() {
        // Sampled before the rebuild, which resets the content height: a reader who
        // had scrolled up to re-read is left where they were; one who was at the end
        // follows the answer as it grows. The rebuild keeps the scroller's value, so
        // without this a new question and its answer landed below the fold.
        let follow = scrollToNewest || GTK.isScrolledToBottom(threadScroller)
        scrollToNewest = false
        GTK.removeAllChildren(of: threadBox)

        if active.thread.turns.isEmpty {
            GTK.append(threadBox, GTK.markupLabel(Self.emptyStateMarkup(environment: environment)))
        }

        for turn in active.thread.turns {
            GTK.append(threadBox, turnView(turn))
        }

        gtk_label_set_markup(vv_label(statusLabel),
                             active.isRunning
                                ? "<span size=\"small\">Researching… press Stop to cancel</span>" : "")
        gtk_button_set_label(vv_button(sendButton), active.isRunning ? "Stop" : "Ask")

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
        // `isRetryable` is the same property `ResearchSession.retry` guards on, so
        // a turn it would refuse never shows the button that asks for it.
        if turn.failure != nil || turn.stage == .cancelled, turn.isRetryable {
            let retry = GTK.button("Try again") { [weak self] in
                // Refused while a run is in flight — `retry` would no-op, but the
                // scroll flag would already be set, and the next render would jump
                // for a question that was never re-asked.
                guard let self, !self.active.isRunning else { return }
                // Set before the call: retrying appends and publishes synchronously,
                // so the render that runs inside it must already know to follow.
                self.scrollToNewest = true
                self.active.retry(turn.id)
            }
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
        // does reads as the app being broken. Shift- and Alt-Return add a line either
        // way, so the off-variant points at Ctrl-Return as the asking key instead.
        let keys = environment.preferences.submitOnReturn
            ? "Return asks · Shift-Return adds a line"
            : "Return adds a line · Ctrl-Return asks"
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
