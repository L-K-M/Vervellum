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
/// * **Return.** A single-line field editor maps Shift-Return and Option-Return to
///   `insertNewlineIgnoringFieldEditor:`, which never fires the field's action — so
///   with a SwiftUI `TextField`, `.onSubmit` sees plain Return only and a modified
///   Return silently does nothing.
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

    /// The composer's text size before the preference is applied.
    static let baseFontSize: CGFloat = 13

    /// One line of padding plus one line of text; the field never starts taller.
    ///
    /// Both bounds scale with the text: a fixed 30pt minimum clips the first line at the
    /// largest setting, and a fixed maximum would show fewer and fewer lines as the text
    /// grew. Six lines stays six lines.
    static func minimumHeight(_ scale: Double) -> CGFloat { 30 * scale }
    /// Roughly six lines. Past that the thread above disappears, which is worse than
    /// scrolling inside the composer.
    static func maximumHeight(_ scale: Double) -> CGFloat { 132 * scale }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: Self.baseFontSize * scale)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        // Smart quotes turn a typed "don't" into a curly apostrophe, which is fine in
        // prose but corrupts a pasted code snippet or URL in a question.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
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
        let wanted = NSFont.systemFont(ofSize: Self.baseFontSize * scale)
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
                                    attributes: [.font: NSFont.systemFont(ofSize: baseFontSize * scale)])
        let container = NSTextContainer(size: NSSize(width: max(width - 8, 1),
                                                    height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 5
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height + 12
        return min(max(used, minimumHeight(scale)), maximumHeight(scale))
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerView
        weak var textView: NSTextView?
        private var showObserver: NSObjectProtocol?

        init(_ parent: ComposerView) {
            self.parent = parent
        }

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
                guard parent.submitOnReturn else { return false }
                parent.onSubmit()
                return true

            // Shift-Return and Option-Return arrive here. With submit-on-Return they
            // insert a newline; with the inverse preference they submit.
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                if parent.submitOnReturn {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                } else {
                    parent.onSubmit()
                }
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

/// Draws the placeholder, which `NSTextView` — unlike `NSTextField` — does not do.
private final class ComposerTextView: NSTextView {
    weak var coordinator: ComposerView.Coordinator?

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
