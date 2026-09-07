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
    var onSubmit: () -> Void
    /// Return true to consume the key. Used for history recall on ↑/↓.
    var onArrow: (Bool) -> Bool = { _ in false }

    /// One line of padding plus one line of text; the field never starts taller.
    static let minimumHeight: CGFloat = 30
    /// Roughly six lines. Past that the thread above disappears, which is worse than
    /// scrolling inside the composer.
    static let maximumHeight: CGFloat = 132

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
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
        // Never made read-only, not even while a turn is running. The moment a
        // clarification or a follow-up occurs to you is *while* the answer is arriving,
        // and a field that refuses the keystroke loses the thought. What a submitted
        // question does during a run is `ResearchEngine.ask`'s decision, not the text
        // view's — it queues.
        textView.isSelectable = true
        textView.needsDisplay = true
    }

    /// The height the composer wants for its current content, clamped.
    static func height(for text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text.isEmpty ? " " : text,
                                    attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let container = NSTextContainer(size: NSSize(width: max(width - 8, 1),
                                                    height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 5
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height + 12
        return min(max(used, minimumHeight), maximumHeight)
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
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
