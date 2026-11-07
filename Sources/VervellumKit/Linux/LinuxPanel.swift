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
    /// One chip per question waiting behind a running turn, above the composer.
    /// Rebuilt rather than diffed, for the same reason as the attachment row: there
    /// are at most `ResearchSession.maxQueued` of them, and none of them is focusable
    /// from the reader's point of view except its remove button, which is activated
    /// from outside itself.
    private let queueBox: GTK.Widget
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

    /// Every open thread's session, keyed by thread id. `/clear` detaches the current
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
    // Empty-state redraws must not repeatedly launch keyring processes.
    private var cachedEmptyState: String?

    /// Whether a status-line ticker chain is already scheduled. Each tick re-arms
    /// itself, so starting a second chain — a queued question beginning its run
    /// inside the old chain's one-second window — would repaint twice a second, then
    /// three times, for as long as runs keep following each other.
    private var isStatusTickerArmed = false
    /// The live answer label of each rendered turn, so streaming growth can repaint one
    /// label instead of the whole thread. Cleared on every full rebuild — the widgets
    /// die with the rebuild (`gtk_box_remove` drops the last reference), and a stored
    /// pointer to one would be a pointer into freed memory.
    private var turnAnswerLabels: [UUID: GTK.Widget] = [:]
    /// What the last render drew. The diff against the next snapshot decides between
    /// the in-place answer update and a full rebuild.
    private var lastRenderedTurns: [ResearchTurn] = []

    /// Turns whose first draft is open. The window rebuilds from scratch, so this
    /// cannot live on the widget.
    private var expandedDrafts: Set<UUID> = []
    /// Whether the thread area is showing the history list rather than the thread.
    /// Left by Escape, by opening a thread, or by asking a question.
    private var showsHistory = false

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
        queueBox = GTK.verticalBox(spacing: 4)
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
        cachedEmptyState = nil
        if active.thread.turns.isEmpty { render() }
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

        let history = GTK.button("History") { [weak self] in
            guard let self else { return }
            self.showsHistory.toggle()
            self.render()
        }
        GTK.addStyle(history, "level")
        GTK.append(bar, history)
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
        GTK.append(footer, queueBox)
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
                // Readiness depends on the level, so the cached empty state is stale.
                self.cachedEmptyState = nil
                if self.active.thread.turns.isEmpty { self.render() }
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
        GTK.observeKeys(composer) { [weak self] keyval, modifiers, pasteShortcutMatches in
            guard let self else { return false }
            if GTK.isEscape(keyval) {
                // The order a user expects to be able to undo things: leave the
                // history list, then clear a draft and whatever is attached to it,
                // then close. Closing on the first press would throw away both a
                // half-typed question and the list they were reading.
                if self.showsHistory {
                    self.showsHistory = false
                    self.render()
                    return true
                }
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
            if GTK.shouldInterceptPaste(shortcutMatches: pasteShortcutMatches,
                                        controlPressed: GTK.hasControl(modifiers),
                                        shiftPressed: GTK.hasShift(modifiers)) {
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
            // Return never stops a run. A follow-up typed while the answer streams
            // is queued by `ask`, the way the macOS composer is live during a run;
            // a full queue keeps the text rather than swallowing it. Only the Stop
            // button cancels.
            self.submit()
            return true
        }
    }

    // MARK: Actions

    private func newThread() {
        cachedEmptyState = nil
        // Detached, not cancelled: a run in flight on the old session keeps going —
        // the map holds it, and its finished thread is still saved to the archive.
        showsHistory = false
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
        let text = GTK.text(of: composer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // A dropped file with nothing asked about it was a Return that did nothing
            // whatsoever — the chip sitting there being, as far as the reader could
            // tell, what broke the key. The macOS panel says the same sentence, from the
            // same constant.
            if !pendingAttachments.isEmpty { appendNotice(AttachmentIntake.questionlessMessage) }
            return
        }
        // A slash word still being typed is a command being chosen, not a question.
        // The macOS composer declines to send one — `isHalfTypedCommand` is the rule,
        // tested in Core — and this front end had no counterpart: Return on `/`, `/de`
        // or any partial word spent a request asking the model that word, while the
        // empty state advertised "/ for commands". The same sentence is used; it is
        // not shared only because the macOS copy lives in the SwiftUI view.
        guard !ComposerCommand.isHalfTypedCommand(text) else {
            appendNotice("Finish the command name")
            return
        }

        switch ComposerCommand.parse(text) {
        case .none:
            return
        case .newThread:
            newThread()
        case .showHelp:
            GTK.setText(composer, "")
            appendNotice(ComposerCommand.helpText(legend: .linux))
        case .openSettings:
            GTK.setText(composer, "")
            appendNotice("Settings live in `~/.config/vervellum/settings.json`. "
                         + "Edit it and the next run reads the new values.")
        case .openHistory:
            GTK.setText(composer, "")
            showsHistory = true
            render()
        case .copyLastAnswer:
            GTK.setText(composer, "")
            // The same text macOS puts on the pasteboard: the last turn's plain-text
            // transcript, not a selection the reader has no practical way to make in
            // a GTK label.
            guard let last = Self.turnToCopy(in: active.thread) else {
                appendNotice("There is no answer to copy yet.")
                return
            }
            GTK.setClipboardText(composer, last.transcript)
            appendNotice("Copied the answer.")
        case .selectModel(let name):
            GTK.setText(composer, "")
            selectModel(named: name)
        case .ask(let question, let level):
            // A typed level is this question's alone; the selector keeps whatever it was
            // set to, and nil means "whatever it says" — resolved inside `ask`. See
            // `ComposerCommand.ask`.
            //
            // The flag goes up *before* the call, like the retry button's: `ask`
            // appends the turn and publishes synchronously, so the render that runs
            // inside it must already know to follow. Nothing that did not start a turn
            // switches it on.
            //
            // The composer is emptied *before* the call for the same synchronous reason,
            // and restored when the question was not taken. A full queue keeps the
            // text, exactly as on macOS: emptying the field for a question that was
            // refused is how you lose one, and the chip row below says what to do
            // about it.
            let followWasOn = scrollToNewest
            scrollToNewest = true
            // A question asked from the history view is the reader leaving it — the
            // thread they were reading stays in the archive unchanged.
            showsHistory = false
            let attachments = takePendingAttachments()
            GTK.setText(composer, "")
            switch active.ask(question, mode: level, attachments: attachments) {
            case .started:
                break
            case .queued:
                scrollToNewest = followWasOn
            case .queueFull, .ignored:
                // Words and attachments both go back: the question was not taken, so
                // nothing about it may be lost on the way to saying so.
                GTK.setText(composer, question)
                pendingAttachments = attachments
                renderAttachments()
                scrollToNewest = followWasOn
            }
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
            // Between snapshots the window would not repaint at all — a thirty-second
            // fetch looks frozen. The ticker repaints the status line each second,
            // which is the clock macOS's trail runs on (`TimelineView`).
            if session.isRunning { self.startStatusTicker() }
            self.render()
        }
        // A stopped or failed run hands its queue back, so a Stop is not the one
        // gesture that destroys a typed question. Words and attachments both travel:
        // the bytes of a pasted screenshot exist nowhere else. Appended to whatever
        // is in the composer, not replacing it — a reader who typed half a new
        // question and then stopped the run meant to keep both.
        session.onQueueReturned = { [weak self] session, questions in
            guard let self, session === self.active, !questions.isEmpty else { return }
            let returned = questions.map(\.question).joined(separator: "\n\n")
            let typed = GTK.text(of: self.composer).trimmingCharacters(in: .whitespacesAndNewlines)
            GTK.setText(self.composer, typed.isEmpty ? returned : typed + "\n\n" + returned)
            self.pendingAttachments.append(contentsOf: questions.flatMap(\.attachments))
            self.renderAttachments()
        }
        return session
    }

    /// Puts a session on screen. The old one is left in the map untouched — that is
    /// the whole mechanism, not a step that forgot to cancel.
    private func activate(_ session: ResearchSession) {
        sessions[session.id] = session
        active = session
        // A settled session stays in the map so the history list can reopen its
        // thread — but only while that thread is still openable. Anything else (an
        // abandoned empty thread, a thread the archive has since evicted) is dropped
        // here, so the map tracks the archive rather than outliving the window.
        pruneSessions(keeping: session)
        // A session brought back while its run is still going needs the clock too.
        if session.isRunning { startStatusTicker() }
        render()
    }

    /// Keeps only the sessions the reader can still reach: the one on screen, any
    /// still running, and any whose thread is still in the archive.
    private func pruneSessions(keeping session: ResearchSession) {
        let archived = Set(environment.archive.library.threads.map(\.id))
        sessions = sessions.filter {
            archived.contains($0.key) || $0.value === session || $0.value.isRunning
        }
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
            GTK.append(row, Self.attachmentRemovalButton(named: pending.attachment.name) { [weak self] in
                guard let self else { return }
                self.pendingAttachments.removeAll { $0.id == id }
                self.renderAttachments()
            })
            GTK.append(attachmentBox, row)
        }
    }

    /// Draws one chip per question waiting behind a running turn — shown rather than
    /// merely counted, because a question the reader typed and cannot see is one they
    /// will type again, and one they cannot withdraw is a provider request they
    /// cannot call off. Each names the level it will run at (the queue can hold
    /// questions asked at different levels) and its attachments (whose bytes are
    /// invisible once the ask clears the chip row above).
    private func renderQueue() {
        GTK.removeAllChildren(of: queueBox)
        let queued = active.queue
        gtk_widget_set_visible(queueBox, queued.isEmpty ? 0 : 1)
        if queued.count >= ResearchSession.maxQueued {
            GTK.append(queueBox, GTK.markupLabel(
                "<span size=\"small\" foreground=\"#9a6a10\">⚠ Up to "
                + "\(ResearchSession.maxQueued) questions can wait at once. "
                + "Stop the run, or remove one below.</span>"))
        }
        for item in queued {
            let row = GTK.horizontalBox(spacing: 8)
            let detail = item.mode.displayName
                + (item.attachments.isEmpty ? "" : " · \u{1F4CE}\(item.attachments.count)")
            let label = GTK.markupLabel(
                "<span size=\"small\">⏳ \(GTK.escape(String(item.question.prefix(90)))) "
                + "<span alpha=\"60%\">\(GTK.escape(detail))</span></span>")
            gtk_widget_set_hexpand(label, 1)
            gtk_label_set_xalign(vv_label(label), 0)
            GTK.append(row, label)
            let id = item.id
            GTK.append(row, GTK.button("✕") { [weak self] in
                self?.active.removeQueued(id)
            })
            GTK.append(queueBox, row)
        }
    }

    /// The file-specific semantics behind the deliberately compact visual button.
    /// Internal so the Linux GTK smoke test exercises the exact control the row uses.
    static func attachmentRemovalButton(named name: String,
                                        action: @escaping () -> Void) -> GTK.Widget {
        let button = GTK.button("✕", action)
        GTK.setAccessibleLabel("Remove \(name) attachment", on: button)
        return button
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
        // A notice is written into the thread, so the thread has to be what is on
        // screen: a command typed from the history list (`/help`, `/copy`, `/model`)
        // would otherwise answer into a view the reader cannot see.
        showsHistory = false
        active.appendLocalTurn(turn)
    }

    // MARK: Rendering

    /// Rebuilds the thread box from the session on screen.
    ///
    /// There is no redraw throttle of its own here: the session's `SnapshotCoalescer`
    /// already paces published snapshots to ~10 Hz — the same rule `lastRender` used
    /// to implement by hand — so each `onChange` is worth a render.
    private func render() {
        let turns = active.thread.turns
        // The in-place path. Streaming growth of the live answer is the change that
        // arrives at snapshot pace — ten times a second on a long answer — and a full
        // rebuild for it re-parses the markup of every turn the reader is not looking
        // at, on a thread long enough to feel it. One label is repainted instead.
        if turns.count == lastRenderedTurns.count,
           let old = lastRenderedTurns.last,
           let live = turns.last,
           turns.dropLast().elementsEqual(lastRenderedTurns.dropLast()),
           Self.isAnswerGrowth(old, live),
           let label = turnAnswerLabels[live.id] {
            lastRenderedTurns = turns
            // The same scroll contract as a full render, sampled before the label's
            // height changes: follow the growth only from the bottom.
            let follow = scrollToNewest || GTK.isScrolledToBottom(threadScroller)
            scrollToNewest = false
            gtk_label_set_markup(vv_label(label),
                                 PangoMarkup.answer(live.answer, sources: live.sources))
            if follow {
                let scroller = threadScroller
                GTK.onMainLoop { GTK.scrollToBottom(scroller) }
            }
            return
        }

        // Sampled before the rebuild, which resets the content height: a reader who
        // had scrolled up to re-read is left where they were; one who was at the end
        // follows the answer as it grows. The rebuild keeps the scroller's value, so
        // without this a new question and its answer landed below the fold.
        let follow = scrollToNewest || GTK.isScrolledToBottom(threadScroller)
        scrollToNewest = false
        GTK.removeAllChildren(of: threadBox)
        turnAnswerLabels = [:]

        // The history list replaces the thread rather than covering it: there is one
        // content area, and a list the reader cannot scroll is not a list. While it is
        // up the live thread keeps saving — `onChange` re-renders whatever view is on,
        // and the rows are rebuilt from the archive on every entry, so a detached
        // run's updates are there the next time the list opens.
        if showsHistory {
            renderHistory()
        } else {
            if active.thread.turns.isEmpty {
                let markup = cachedEmptyState ?? Self.emptyStateMarkup(environment: environment)
                cachedEmptyState = markup
                GTK.append(threadBox, GTK.markupLabel(markup))
            }

            for turn in active.thread.turns {
                GTK.append(threadBox, turnView(turn))
            }
        }
        lastRenderedTurns = active.thread.turns

        gtk_label_set_markup(vv_label(statusLabel),
                             showsHistory
                                ? "<span size=\"small\">Escape goes back to the thread</span>"
                                : (runningStatusMarkup() ?? ""))
        gtk_button_set_label(vv_button(sendButton), active.isRunning ? "Stop" : "Ask")
        renderQueue()

        if follow, !showsHistory {
            // One idle hop later, after the new children have been laid out and the
            // adjustment's upper bound reflects them.
            let scroller = threadScroller
            GTK.onMainLoop { GTK.scrollToBottom(scroller) }
        }
    }

    /// The running status line: progress from the live turn, a clock beside it, and
    /// the way out. Shared by `render` and the ticker so the two can never disagree
    /// about what the run is doing.
    private func runningStatusMarkup() -> String? {
        guard active.isRunning,
              let running = active.thread.turns.last(where: { !$0.stage.isTerminal })
        else { return nil }
        let elapsed = Formatting.duration(Date().timeIntervalSince(running.askedAt))
        return "<span size=\"small\">\(GTK.escape(running.runningProgressLabel))… "
            + "<span alpha=\"60%\">\(elapsed)</span> · Stop cancels</span>"
    }

    /// Starts the ticker unless a chain is already running; the chain itself decides
    /// when to stop.
    private func startStatusTicker() {
        guard !isStatusTickerArmed else { return }
        isStatusTickerArmed = true
        tickStatusLine()
    }

    /// Re-arms itself every second while the session on screen is running, repainting
    /// the status line so the clock ticks and the stage line moves between snapshots.
    /// A one-shot that re-arms rather than a repeating source: each tick re-decides
    /// whether another is wanted, so a run that ends stops the chain by itself.
    private func tickStatusLine() {
        guard active.isRunning else {
            isStatusTickerArmed = false
            return
        }
        // The history list owns the status line while it is up (it says how to leave).
        if !showsHistory, let markup = runningStatusMarkup() {
            gtk_label_set_markup(vv_label(statusLabel), markup)
        }
        GTK.after(1) { [weak self] in self?.tickStatusLine() }
    }

    /// Whether `live` is `old` with the same answer plus more of it, and nothing else
    /// changed — the one case worth painting in place, and only when there was already
    /// an answer to grow: the empty-to-first-chunk step swaps the caret widget for the
    /// answer label and stays a full rebuild.
    /// Compared on copies with the answer blanked, so every other field — stage,
    /// sources, notices, draft, the transient in-flight counts — must be equal for
    /// this to say yes. Anything else a snapshot carries is a different kind of
    /// change and takes the full rebuild.
    static func isAnswerGrowth(_ old: ResearchTurn, _ live: ResearchTurn) -> Bool {
        // Strictly longer, not merely prefixed: an unchanged turn is not growth.
        // `render()` also runs when nothing in the turns moved — the end of a run, a
        // panel-only change — and those must take the full path, which is the one that
        // repaints the status line and the Stop/Ask button.
        guard old.id == live.id,
              !old.answer.isEmpty,
              live.answer != old.answer,
              live.answer.hasPrefix(old.answer)
        else { return false }
        var before = old
        var after = live
        before.answer = ""
        after.answer = ""
        return before == after
    }

    /// The saved threads, newest first, one row each: title, turn count, age, open,
    /// delete. Built from the archive on entry (see `render`), so a thread a detached
    /// run finished a minute ago appears with its final turn count.
    private func renderHistory() {
        let threads = environment.archive.library.threads
        guard !threads.isEmpty else {
            GTK.append(threadBox, GTK.markupLabel(
                "<span size=\"small\">No saved threads yet. Ask something.</span>"))
            return
        }
        for thread in threads {
            let row = GTK.horizontalBox(spacing: 8)
            let turns = "\(thread.turns.count) turn\(thread.turns.count == 1 ? "" : "s")"
            let label = GTK.markupLabel(
                "\(GTK.escape(thread.title))\n"
                + "<span size=\"small\" alpha=\"60%\">\(turns) · "
                + GTK.escape(Formatting.relativeDate(thread.updatedAt)) + "</span>")
            gtk_widget_set_hexpand(label, 1)
            gtk_label_set_xalign(vv_label(label), 0)
            GTK.append(row, GTK.button(content: label) { [weak self] in
                guard let self else { return }
                self.openThread(thread)
            })
            let id = thread.id
            GTK.append(row, GTK.button("✕") { [weak self] in
                self?.deleteThread(id: id)
            })
            GTK.append(threadBox, row)
        }
    }

    /// Opens a saved thread. A session already in the map is resumed rather than
    /// rebuilt — it may be a detached run still writing that thread, and a second
    /// session over one thread is exactly what the map exists to avoid.
    private func openThread(_ thread: ResearchThread) {
        showsHistory = false
        if let existing = sessions[thread.id] {
            activate(existing)
        } else {
            activate(makeSession(thread: thread))
        }
    }

    /// Removes a thread from the archive, and with it the session working on it:
    /// the archive's tombstone keeps the session's next save from resurrecting what
    /// the reader just removed, and `discard` stops a detached run outright.
    private func deleteThread(id: UUID) {
        environment.archive.delete(id: id)
        sessions[id]?.discard()
        sessions.removeValue(forKey: id)
        if active.thread.id == id {
            // Before `activate`, which renders: the reader is still in the list.
            showsHistory = true
            activate(makeSession(thread: ResearchThread()))
        } else {
            render()
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
            GTK.onLinkActivated(answer) { [weak self] in self?.handleLink($0) ?? true }
            // Registered for the in-place streaming update; see `turnAnswerLabels`.
            turnAnswerLabels[turn.id] = answer
            GTK.append(box, answer)
            if DraftComparison.isOffered(draft: turn.draftAnswer, answer: turn.answer),
               let draft = turn.draftAnswer {
                let open = expandedDrafts.contains(turn.id)
                let toggle = GTK.button(open ? DraftComparison.hideLabel : DraftComparison.showLabel) { [weak self] in
                    guard let self else { return }
                    if self.expandedDrafts.contains(turn.id) {
                        self.expandedDrafts.remove(turn.id)
                    } else {
                        self.expandedDrafts.insert(turn.id)
                    }
                    self.render()
                }
                gtk_widget_set_halign(toggle, GTK_ALIGN_START)
                // The same explanation the macOS disclosure carries as an
                // accessibility hint: without it the button is a label that
                // expands something, and a tooltip is where GTK readers look.
                gtk_widget_set_tooltip_text(toggle,
                    "The findings grade this draft, not the answer above")
                GTK.append(box, toggle)
                if open {
                    let shown = GTK.markupLabel(PangoMarkup.answer(draft, sources: turn.sources))
                    GTK.onLinkActivated(shown) { [weak self] in self?.handleLink($0) ?? true }
                    GTK.append(box, shown)
                }
            }
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
                GTK.onLinkActivated(label) { [weak self] in self?.handleLink($0) ?? true }
                GTK.append(box, label)
            }
        }
        if let followups = PangoMarkup.followups(turn.followups) {
            let label = GTK.markupLabel(followups)
            GTK.onLinkActivated(label) { [weak self] in self?.handleLink($0) ?? true }
            GTK.append(box, label)
        }
        return box
    }

    /// A link in the thread: a follow-up asks, anything else opens in the browser.
    ///
    /// Always reports itself handled. Returning false for a URI it refused would hand
    /// it straight back to GTK's default handler, which launches *any* scheme —
    /// including `file://`. Since the markup is built from model output, refusing has
    /// to mean refusing.
    private func handleLink(_ uri: String) -> Bool {
        if uri.hasPrefix(PangoMarkup.askScheme) {
            askFollowup(String(uri.dropFirst(PangoMarkup.askScheme.count)))
            return true
        }
        GTK.openLink(uri)
        return true
    }

    /// The turn `/copy` means: the last real question's transcript. A panel notice
    /// (a `/help` reply, the "Copied the answer." line itself) is a turn with no
    /// question, so it is skipped — `/copy` twice in a row must copy the same answer
    /// both times, not the notice the first one printed.
    static func turnToCopy(in thread: ResearchThread) -> ResearchTurn? {
        thread.turns.last { !$0.question.isEmpty }
    }

    /// What a follow-up link does — the macOS rule, kept identical on purpose: submit
    /// when the composer holds nothing, load into the field when it does. A half-typed
    /// question or a pending attachment is not something a suggestion may silently
    /// replace, and a question asked from a link carries no attachments at all — so
    /// a screenshot pasted for a question still being written must stay put.
    private func askFollowup(_ encoded: String) {
        guard let question = encoded.removingPercentEncoding else { return }
        let typed = GTK.text(of: composer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty, pendingAttachments.isEmpty else {
            GTK.setText(composer, question)
            if !pendingAttachments.isEmpty {
                appendNotice("Put in the composer — Return sends it with the attachment"
                             + (pendingAttachments.count == 1 ? "" : "s"))
            }
            return
        }
        // Set before the call: asking appends and publishes synchronously, so the
        // render that runs inside it must already know to follow.
        scrollToNewest = true
        if active.ask(question, mode: nil, attachments: []) != .started {
            scrollToNewest = false
        }
    }

    private static func emptyStateMarkup(environment: LinuxEnvironment) -> String {
        let settings = environment.preferences.providerSettings
        let level = environment.preferences.researchLevel
        let problems = ProviderReadiness.problems(settings: settings,
                                                  level: level,
                                                  secrets: environment.secrets)
        guard problems.isEmpty else {
            return "<span weight=\"bold\">Not configured yet</span>\n\n"
                + GTK.escape(problems.joined(separator: " ")) + "\n\n"
                + GTK.escape("Edit ~/.config/vervellum/settings.json to resolve the items above. "
                             + "When a configured provider needs a key, store it with secret-tool "
                             + "or export VERVELLUM_MODEL_KEY / VERVELLUM_SEARCH_KEY. Keys are read from "
                             + environment.secrets.backendDescription + ".")
        }
        // The hint follows the preference; a hint that says the opposite of what Return
        // does reads as the app being broken. Shift- and Alt-Return add a line either
        // way, so the off-variant points at Ctrl-Return as the asking key instead.
        let keys = environment.preferences.submitOnReturn
            ? "Return asks · Shift-Return adds a line"
            : "Return adds a line · Ctrl-Return asks"
        let introduction = level.searches
            ? "Vervellum plans web searches, runs them, then writes an answer that cites "
                + "only what it found — and grades its own claims against that evidence."
            : "No search sends the question only to the selected model. It does not "
                + "search, cite sources, or run the evidence assessment."
        return "<span weight=\"bold\">Ask a question.</span>\n\n"
            + GTK.escape(introduction)
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
