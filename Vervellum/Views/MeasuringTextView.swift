import AppKit

/// An `NSTextView` that can say how much room its text needs at a given width, without
/// disturbing the layout it is drawing from.
///
/// Every text view the panel puts on screen sits inside an `NSViewRepresentable` that
/// implements `sizeThatFits`, and that is a rule rather than a habit. A representable
/// which does not implement it is measured through
/// `AppKitPlatformViewHost.intrinsicLayoutTraits`, and that path ends in
/// `systemLayoutSizeFittingSize:` — a whole `NSISEngine` built, populated with
/// constraints, solved and torn down, once per hosted view per layout pass. It is also
/// re-entrant: configuring an AppKit control invalidates its intrinsic content size,
/// which invalidates the host's layout, which schedules the next pass. `SelectableText`
/// carries the process sample of what that costs in a long thread.
///
/// TextKit 1 throughout, deliberately. `AnswerTextView`'s citation hit test is
/// `NSLayoutManager`'s, and a text view that quietly adopted TextKit 2 would hand back a
/// `layoutManager` of nil. The paragraphs here are short and static; none of what
/// TextKit 2 is faster at applies.
class MeasuringTextView: NSTextView {

    /// A TextKit 1 storage → layout manager → container stack, wired and ready to hand
    /// to `NSTextView(frame:textContainer:)`.
    ///
    /// All three are returned although a caller that builds a text view keeps only the
    /// container: ownership runs text view → container → layout manager → storage, so
    /// the other two stay alive without being held. Returned anyway because a *measuring*
    /// stack has no text view above it and must hold all three itself.
    ///
    /// - Parameter tracksWidth: whether the container follows its text view's width.
    ///   True for a stack a view draws from, so the text wraps at the width SwiftUI
    ///   actually gave it rather than at one this file guessed. False for one used only
    ///   for measurement — where an assigned width has to survive until the measurement
    ///   is taken — and for text that must not wrap at all.
    ///
    /// A caller building a text view must keep the whole tuple alive until
    /// `NSTextView(frame:textContainer:)` has run — `withExtendedLifetime` is enough.
    /// The container's reference to its layout manager is `unowned`, so a storage and
    /// layout manager nobody holds die at the binding that discarded them, and `init`
    /// then adopts a container pointing at freed memory: whether the view ends up with
    /// a usable zombie stack or none at all is a heap accident, which is how the panel
    /// came to draw some blocks of an answer and blank the rest — measured correctly by
    /// `sizeThatFits` (that stack is a different one) either way.
    static func makeStack(tracksWidth: Bool)
        -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // Both components spelled `CGFloat`. `NSSize.init(width:height:)` is overloaded
        // across the numeric types, and `0` paired with a bare `.greatestFiniteMagnitude`
        // gives the solver nothing to pick from — it reads as ambiguous, and the whole
        // function body then fails to type-check around it.
        let container = NSTextContainer(size: NSSize(width: CGFloat(0),
                                                     height: CGFloat.greatestFiniteMagnitude))
        // The padding is AppKit's default two points on each side, and it would show up
        // as the text sitting inset from everything stacked beside it.
        container.lineFragmentPadding = 0
        container.widthTracksTextView = tracksWidth
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    /// The stack this view is measured on, built once and kept.
    ///
    /// Not the live one, which is the obvious thing to do and is wrong twice over: its
    /// container has `widthTracksTextView` set — so an assigned size is overwritten at
    /// the next layout, and a measurement taken at some other width would be answered
    /// from a container that had already snapped back — and laying out the visible view
    /// in the middle of being asked how big it wants to be is how a text view ends up
    /// flickering at one size while reporting another.
    ///
    /// Not a fresh one per question either. SwiftUI asks `sizeThatFits` more than once
    /// per layout pass and an answer is re-rendered on every streamed chunk, so building
    /// and discarding a storage, a layout manager and a container each time lays the
    /// whole paragraph out from scratch on the hottest path in the panel.
    ///
    /// Per view rather than one shared by the type, which is what makes the "has this
    /// changed" tests in `sizeFitting` worth making: a single stack would be reloaded by
    /// whichever view measured last, so every one of them would find another's text in it
    /// and lay out from scratch anyway.
    private lazy var measuring = MeasuringTextView.makeStack(tracksWidth: false)

    /// How much room this text needs at a given width.
    ///
    /// Every assignment is guarded because each one throws away the layout the stack is
    /// holding, and the common case — the same view asked the same question again while
    /// the thread around it changed — is answered from the layout it already has.
    ///
    /// - Parameter maximumLines: `0` for as many lines as the text needs, or a cap. One,
    ///   for text that has to stay on its row and truncate instead of wrapping.
    func sizeFitting(_ attributed: NSAttributedString,
                     width: CGFloat,
                     maximumLines: Int = 0) -> CGSize {
        let (storage, layout, container) = measuring
        if !storage.isEqual(to: attributed) { storage.setAttributedString(attributed) }
        let wanted = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if container.size != wanted { container.size = wanted }
        if container.maximumNumberOfLines != maximumLines {
            container.maximumNumberOfLines = maximumLines
        }
        // `usedRect` is only meaningful once layout has run, and asking for it does not
        // itself trigger one.
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}
