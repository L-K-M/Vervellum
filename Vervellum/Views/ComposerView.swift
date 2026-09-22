import SwiftUI
import AppKit

/// The question field at the foot of the panel.
///
/// An `NSViewRepresentable` around `NSTextView` rather than a SwiftUI `TextField`,
/// for three reasons that each cost a day to discover the hard way:
///
/// * **Focus.** A SwiftUI `@FocusState` inside a reused `NSHostingView` in a
///   non-activating panel does not reliably re-take first responder when the panel is
///   shown again — the view never left the hierarchy, so nothing re-fires. Owning the
///   text view means focus can simply be *asserted*.
/// * **Return.** The selector a modified Return arrives as is a binding-dictionary
///   accident, not a contract: `~\r` is `insertNewlineIgnoringFieldEditor:` and `^\r`
///   is `insertLineBreak:`, while `$\r` has no binding at all and falls back to
///   `insertNewline:` — the selector a plain Return sends. Telling them apart needs
///   the event's modifiers, which a SwiftUI `TextField` never lets you see.
/// * **Growth.** The composer must grow from one line to several as the question gets
///   longer, and then stop. That is a height calculation on the layout manager, not
///   something a `TextField` exposes.
struct ComposerView: NSViewRepresentable {

    @Binding var text: String
    var placeholder: String
    var submitOnReturn: Bool
    /// The panel's text-size preference. Taken as a parameter rather than read from the
    /// environment because `height(for:width:scale:)` is a static measurement the layout
    /// calls before there is a view to read an environment from.
    var scale: Double = 1.0
    var onSubmit: () -> Void
    /// Return true to consume the key. Used for history recall on ↑/↓.
    var onArrow: (Bool) -> Bool = { _ in false }
    /// How many attachments the question already carries, so a paste that would take it
    /// past the limit can say so rather than silently dropping the extras.
    ///
    /// No default either, and for the reason below: one that read zero would let a call
    /// site forget the count and quietly never reach the limit at all, which is the
    /// same silence with a different shape.
    var attachmentCount: Int
    /// What a paste or a drop turned out to be carrying. Called only when it was
    /// carrying something: an ordinary text paste never reaches here.
    ///
    /// No default, deliberately. `paste` consumes the pasteboard whenever the intake
    /// claims it, so a composer built without this handler would swallow an image paste
    /// entirely — no chip, and no text either. One call site wires it; the compiler is
    /// what keeps that true for the second one.
    var onAttach: (AttachmentIntake.Outcome) -> Void

    /// The composer's text size before the preference is applied.
    static let baseFontSize: CGFloat = 13

    /// One line of padding plus one line of text; the field never starts taller.
    ///
    /// Both bounds scale with the text, *proportionally*: a fixed 30pt minimum clips the
    /// first line at the largest setting, and a fixed maximum would show fewer and fewer
    /// lines as the text grew. Scaling both by the same factor is what makes six lines
    /// stay six lines.
    static func minimumHeight(_ scale: Double) -> CGFloat { 30 * sane(scale) }
    /// Roughly six lines. Past that the thread above disappears, which is worse than
    /// scrolling inside the composer.
    static func maximumHeight(_ scale: Double) -> CGFloat { 132 * sane(scale) }

    /// A scale that can safely become a font size and a frame height.
    ///
    /// `CorePreferences` clamps the preference on read, so nothing odd should reach here.
    /// It is clamped again anyway because this end is where it would hurt: a NaN scale
    /// becomes a NaN frame height, which is layout warnings and a field nobody can see,
    /// and a zero becomes a composer of no height that cannot be typed into or fixed.
    /// Clamping on read as well as on write is the same rule every bounded value in
    /// `CorePreferences` already follows, for the same reason — a settings file a crash
    /// interrupted must not be able to produce an app the user cannot recover.
    /// Only NaN is treated as "not a number". An infinity is *out of range*, not
    /// garbage, so it saturates like any other out-of-range value — which is what makes
    /// the clamp uniform: everything above the range lands on the ceiling, everything
    /// below it on the floor, and only a value that is no number at all falls back to
    /// unscaled. Guarding on `isFinite` instead sent infinity to 1.0 while 1000 went to
    /// 3.0, so two scales that are both "far too large" produced different geometry.
    private static func sane(_ scale: Double) -> Double {
        guard !scale.isNaN else { return 1 }
        return min(max(scale, 0.5), 3)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: Self.baseFontSize * Self.sane(scale))
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        // Smart quotes turn a typed "don't" into a curly apostrophe, which is fine in
        // prose but corrupts a pasted code snippet or URL in a question.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // Files and images dropped on the composer are attachments — added to what an
        // NSTextView already accepts rather than put in its place.
        //
        // The union is the whole of it. `registerForDraggedTypes` *replaces* a view's
        // registration; it does not add to it. An NSTextView registers its own text
        // flavours when it is built, and a view registered for none of the types on a
        // drag is never offered the drag at all — so passing this list alone would have
        // taken text dropped from another app and made it land nowhere, with the
        // fall-through in `performDragOperation` never reached because the drop never
        // arrived. Reading the current list first keeps both halves.
        textView.registerForDraggedTypes(
            textView.registeredDraggedTypes + PasteboardIntake.draggedTypes)
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        context.coordinator.textView = textView
        context.coordinator.observePanelNotifications()
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only write back when the model genuinely diverged: assigning `string`
        // resets the insertion point, so doing it on every keystroke would make the
        // caret jump to the end mid-word.
        if textView.string != text { textView.string = text }
        // Applied on every update, not only at construction: the text-size slider moves
        // while the panel is open, and an NSTextView keeps whatever font it was given.
        //
        // The font is then applied to the storage explicitly as well. With
        // `isRichText = false` the text view holds one font for everything and setting
        // `font` should already reach it, but the panel measures the composer's height
        // from the same scale in the same frame — so if it ever did not, the box and the
        // glyphs inside it would disagree until the draft was retyped. This makes that
        // impossible to get wrong rather than relying on the setter's reach.
        let wanted = NSFont.systemFont(ofSize: Self.baseFontSize * Self.sane(scale))
        if textView.font != wanted {
            textView.font = wanted
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            if whole.length > 0 {
                textView.textStorage?.addAttribute(.font, value: wanted, range: whole)
            }
        }
        // Never made read-only, not even while a turn is running. The moment a
        // clarification or a follow-up occurs to you is *while* the answer is arriving,
        // and a field that refuses the keystroke loses the thought. What a submitted
        // question does during a run is `ResearchEngine.ask`'s decision, not the text
        // view's — it queues.
        textView.isSelectable = true
        textView.needsDisplay = true
    }

    /// The height the composer wants for its current content, clamped.
    static func height(for text: String, width: CGFloat, scale: Double = 1.0) -> CGFloat {
        let storage = NSTextStorage(string: text.isEmpty ? " " : text,
                                    attributes: [.font: NSFont.systemFont(ofSize: baseFontSize * sane(scale))])
        let container = NSTextContainer(size: NSSize(width: max(width - 8, 1),
                                                    height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 5
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = contentHeight(of: layout, in: container) + 12
        return min(max(used, minimumHeight(scale)), maximumHeight(scale))
    }

    /// How far down the container the laid-out text reaches, counting the empty line a
    /// trailing line break opens.
    ///
    /// `usedRect(for:)` measures line fragments that hold *glyphs*, and the line a final
    /// Shift-Return opens holds none: the text system puts it in the extra line fragment
    /// instead, which that rect excludes. Measuring the glyphs alone is why Shift-Return
    /// at the end of a question appeared to swallow it. The field kept its old height
    /// while the caret moved onto a line below the visible box, so the scroll view
    /// scrolled to follow the caret and took the question the user had just typed out of
    /// sight. The newline was there; the room for it was not.
    ///
    /// Both rects are measured from the top of the same container, so the lower edge of
    /// whichever reaches further is the height the field needs. The extra fragment is
    /// claimed by container rather than read unconditionally: the layout manager owns one
    /// at a time and hands it to whichever container the empty line falls in, so the
    /// container is the part of it that says such a line exists at all.
    ///
    /// Asking the layout manager rather than testing the string for a trailing "\n" is
    /// what keeps this right for text that arrived from somewhere else. A question pasted
    /// from another app can end in CR or CRLF, and the line the text system opens for
    /// those is the same one it opens for the Return the user pressed.
    private static func contentHeight(of layout: NSLayoutManager,
                                      in container: NSTextContainer) -> CGFloat {
        let glyphs = layout.usedRect(for: container).maxY
        guard layout.extraLineFragmentTextContainer === container else { return glyphs }
        return max(glyphs, layout.extraLineFragmentUsedRect.maxY)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerView
        weak var textView: NSTextView?
        private var showObserver: NSObjectProtocol?

        init(_ parent: ComposerView) {
            self.parent = parent
        }

        /// The modifiers on the key event currently being handled.
        ///
        /// `doCommandBy` is handed a selector, not the event — and the selector alone
        /// cannot tell a modified Return from a plain one. The standard bindings map
        /// `~\r` to `insertNewlineIgnoringFieldEditor:` and `^\r` to `insertLineBreak:`
        /// but carry no `$\r` at all, so Shift-Return falls back to the bare-Return
        /// binding and arrives as `insertNewline:` — the selector this view treats as
        /// "ask". Left intercepted that way, the press submits the question.
        /// `NSTextView`'s own `insertNewline:` avoids the same trap by reading the
        /// modifiers off `NSApp.currentEvent` and redirecting to a line break, which
        /// is the whole reason Shift-Return ever broke a line; this interception sits
        /// in front of that redirect, so it has to repeat the check on the same flags.
        ///
        /// `ComposerTextView` records the flags in `interpretKeyEvents`, the funnel
        /// every route to the delegate shares: `keyDown`, `performKeyEquivalent`
        /// and the input context all dispatch commands through it, so a Shift-Return
        /// can arrive here with `keyDown` never having run. A stash rather than
        /// `NSApp.currentEvent` so a test can set it — a test cannot make a
        /// synthetic `keyDown` the current event.
        var eventModifiers: NSEvent.ModifierFlags = []

        deinit {
            if let showObserver { NotificationCenter.default.removeObserver(showObserver) }
        }

        /// Re-asserts focus every time the panel is summoned. See the type's docs.
        func observePanelNotifications() {
            showObserver = NotificationCenter.default.addObserver(
                forName: .vervellumPanelDidShow, object: nil, queue: .main
            ) { [weak self] _ in
                // One run-loop hop: at notification time the panel has only just
                // become key, and making first responder in the same turn is
                // occasionally undone by AppKit's own focus restoration.
                DispatchQueue.main.async { self?.claimFocus() }
            }
        }

        func claimFocus() {
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
            // NSRange offsets are UTF-16 units, not Characters: `string.count` would
            // land mid-surrogate for any emoji or non-BMP character in a pasted question.
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        /// Handles Return and the arrow keys before the field editor does.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // A modified Return lands here too: `$\r` has no binding, so
                // Shift-Return falls back to this selector — and a modified Return
                // breaks a line whatever `submitOnReturn` says. Command is not in
                // the set because `performKeyEquivalent` claims ⌘⏎ before the event
                // reaches the view; Shift, Option and Control are checked so that
                // every remaining modified Return opens a line rather than asking.
                // See `eventModifiers` for why the flags, not the selector, decide.
                if !eventModifiers.isDisjoint(with: [.shift, .option, .control]) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                guard parent.submitOnReturn else { return false }
                parent.onSubmit()
                return true

            // The modified-Return selectors that *do* have standard bindings:
            // `~\r` is `insertNewlineIgnoringFieldEditor:` (Option-Return) and `^\r`
            // is `insertLineBreak:` (Control-Return). Both always break a line,
            // whatever `submitOnReturn` says — and with a real `\n`, not the U+2028
            // LINE SEPARATOR `NSTextView`'s own `insertLineBreak:` would insert,
            // which is not the character the user typed. Shift-Return never reaches
            // here under the standard dictionary, but a `DefaultKeyBinding.dict`
            // can map it to either selector, so both stay handled.
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true

            case #selector(NSResponder.moveUp(_:)):
                return parent.onArrow(true)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onArrow(false)
            default:
                return false
            }
        }
    }
}

/// Draws the placeholder, and takes what is pasted or dropped on it that is not text.
///
/// `NSTextView` handles the text half of both gestures already and does it better than
/// anything written here would; these overrides claim the cases it would otherwise turn
/// into a file path or a "you can't drop that" bounce, and hand everything else back.
/// Internal rather than private so `ComposerKeyTests` can feed a real Shift-Return
/// event through `interpretKeyEvents` — the fallback that decides the selector is
/// exactly the thing the suite exists to pin, and that only happens end to end.
final class ComposerTextView: NSTextView {
    weak var coordinator: ComposerView.Coordinator?

    /// Records the press's modifiers for `doCommandBy`, which is handed a selector
    /// rather than the event. See `eventModifiers` for why a selector cannot tell
    /// a Shift-Return from a plain one.
    ///
    /// `interpretKeyEvents` is the funnel rather than `keyDown` because keyDown is
    /// only one of the routes that reach it — the window offers every press to
    /// `performKeyEquivalent` first, and `NSTextView` answers that pass by running
    /// the key bindings itself. A Shift-Return can therefore arrive at
    /// `doCommandBy` with `keyDown` never having run. Reading the flags off the
    /// event array also avoids `NSApp.currentEvent`, which keeps holding the *last*
    /// event after dispatch ends and so is only the trigger during real dispatch.
    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        coordinator?.eventModifiers = eventArray.first?.modifierFlags ?? []
        isInterpretingKeyEvents = true
        defer { isInterpretingKeyEvents = false }
        super.interpretKeyEvents(eventArray)
    }

    /// Set while `interpretKeyEvents` is dispatching, so `doCommandBySelector`
    /// knows the flags are already the event's own rather than reaching for
    /// `NSApp.currentEvent` — which would clobber the stash for a synthetic
    /// `interpretKeyEvents` call (a test's) with whatever was dispatched before it.
    private var isInterpretingKeyEvents = false

    /// The one call that always runs before the delegate is consulted, whichever
    /// route the event took — so it doubles as a second place to record the flags,
    /// off `NSApp.currentEvent`, which during real dispatch is the event itself.
    /// Covers any path that reaches the delegate without `interpretKeyEvents`;
    /// skipped while inside it, where the flags are already set. Outside dispatch
    /// the current event is a leftover rather than the trigger, and a stale
    /// `.keyDown` could carry a dead press's flags — but a stray modified flag can
    /// only turn an ask into a line break, never the other way, so it errs safe.
    override func doCommandBySelector(_ selector: Selector) {
        if !isInterpretingKeyEvents,
           let event = NSApp.currentEvent, event.type == .keyDown {
            coordinator?.eventModifiers = event.modifierFlags
        }
        super.doCommandBySelector(selector)
    }

    // MARK: Pasting and dropping

    /// A paste that is carrying a file or an image attaches it; anything else pastes.
    ///
    /// `PasteboardIntake` decides which of the two this is — with Core's
    /// `AttachmentIntake` deciding what may be attached at all — and it is deliberately
    /// conservative: a pasteboard carrying text as well as a picture pastes the text.
    /// This override only routes.
    ///
    /// Every entry point, not only this one. `AppDelegate.installMainMenu` builds the
    /// Edit menu by hand — Undo, Redo, Cut, Copy, Paste, Select All — so there is no
    /// "Paste and Match Style" item to carry ⌥⇧⌘V, and it is tempting to conclude that
    /// `pasteAsPlainText(_:)` therefore cannot be reached. It can: a key *binding* is
    /// not a key equivalent. Anyone may map the selector to any key in
    /// `~/Library/KeyBindings/DefaultKeyBinding.dict`, and that route runs through
    /// `interpretKeyEvents` to this responder without consulting a menu at all.
    ///
    /// What a bypass costs is the reason to close it rather than argue about how likely
    /// it is: the same pasteboard would attach or not depending on which key was
    /// pressed, and the worse half is silent — an image-only board handed to
    /// `super.pasteAsPlainText` inserts nothing, with no refusal to read.
    ///
    /// Forwarding is exact rather than approximate, because `isRichText` is false: a
    /// plain-text view has one font for everything, so "paste", "paste and match style"
    /// and "paste as rich text" are already the same paste. There is no styling for the
    /// forward to flatten.
    override func paste(_ sender: Any?) {
        guard let coordinator else { return super.paste(sender) }
        let outcome = PasteboardIntake.read(NSPasteboard.general,
                                            existing: coordinator.parent.attachmentCount)
        guard !outcome.isEmpty else { return super.paste(sender) }
        coordinator.parent.onAttach(outcome)
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    /// Says a drag is welcome before it lands, so the cursor shows a copy rather than the
    /// "no" badge. Text drags still go to `super`, which has its own answer for them.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carries(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carries(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let coordinator, carries(sender) else { return super.performDragOperation(sender) }
        // `textWins: false`: `carries` has already said this drag is holding a picture
        // or a file, and the text beside a dragged image is the page's address, not
        // something anybody meant to paste.
        let outcome = PasteboardIntake.read(sender.draggingPasteboard,
                                            existing: coordinator.parent.attachmentCount,
                                            textWins: false)
        guard !outcome.isEmpty else { return super.performDragOperation(sender) }
        coordinator.parent.onAttach(outcome)
        return true
    }

    /// Whether a drag is carrying something this composer would attach.
    ///
    /// Asked before the drop as well as during it, because the answer decides what the
    /// cursor promises — and a drag that showed a copy badge and then did nothing would
    /// be worse than one that refused up front.
    private func carries(_ sender: any NSDraggingInfo) -> Bool {
        PasteboardIntake.carriesAttachment(sender.draggingPasteboard)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder = coordinator?.parent.placeholder else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: ComposerView.baseFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
