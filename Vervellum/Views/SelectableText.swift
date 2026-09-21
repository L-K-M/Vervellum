import AppKit
import SwiftUI

/// Selectable text, drawn by AppKit so that *measuring* it does not cost a layout pass.
///
/// This is what `.textSelection(.enabled)` should have been. SwiftUI implements that
/// modifier on macOS by putting an `NSTextField` behind the `Text` — its own
/// `SelectionOverlay` representable — and that representable reports no `sizeThatFits`.
/// So every selectable label in the panel was measured the expensive way, through
/// `AppKitPlatformViewHost.intrinsicLayoutTraits` → `systemLayoutSizeFittingSize:`: an
/// `NSISEngine` built, constrained, solved and thrown away, per view per layout pass.
///
/// Worse, configuring the field invalidates it. A process sample of the frozen panel has
/// the circle in it three separate times:
///
/// ```
/// SelectionOverlay.updateNSView → -[NSControl setFont:] → -[NSCell setFont:]
///   → -[NSTextFieldCell _invalidateEffectiveFont]
///     → -[NSTextField invalidateIntrinsicContentSize]
///       → AppKitPlatformViewHost._layoutMetricsInvalidatedForHostedView()
///         → enqueueLayoutInvalidation() → GraphHost.asyncTransaction
/// ```
///
/// Setting the text field up dirties the host, which schedules the transaction that sets
/// the text field up again. One of these sat on every row of the thread — the question —
/// so each pass also re-measured and re-placed the whole `LazyVStack`, and the cost of a
/// pass grew with the thread while `SnapshotCoalescer` kept republishing at 10 Hz. Past
/// some thread length a pass no longer fits in 100 ms, the backlog stops draining, and
/// the panel never comes back: in that sample the main thread spends all 1030 of its
/// samples inside `GraphHost.flushTransactions` and not one of them waiting for an
/// event. That is the freeze this view exists to remove, and it is the second one of its
/// kind — `TurnView` holds the first.
///
/// The cure is the one `AnswerTextView` already had, and the reason the *answer* was
/// never part of the problem: report the size from `sizeThatFits`, measured on a stack of
/// this view's own, and never let AppKit's intrinsic-size machinery into the loop. What
/// changes for a reader is nothing — the text is still selectable, still copyable, still
/// themed. What changes for VoiceOver is the role: this reads as a text area rather than
/// as static text, which is the same trade the answer prose has always made.
struct SelectableText: NSViewRepresentable {

    /// How the text is laid out — which is also how it is measured, and the two must not
    /// disagree or the view reports one size and draws another.
    ///
    /// Named `TextLayout` rather than `Layout` because SwiftUI has a protocol by that
    /// name and this file imports it; a nested type would win the lookup, and a reader
    /// should not have to know that to read the declaration.
    enum TextLayout: Equatable {
        /// Wraps at the width SwiftUI offers and grows downward. Ordinary prose.
        case wrapping
        /// One line, truncated where the mode says. For a name that has to stay on its
        /// row; the whole of it is still there to select and copy.
        case singleLine(NSLineBreakMode)
        /// Laid out at its natural width and never wrapped, for content a horizontal
        /// `ScrollView` carries. Code, where a wrap would change what the text says.
        case unwrapped
    }

    let text: String
    /// The face, as an `NSFont`. Passed in rather than applied by the caller for the
    /// reason `MarkdownText` gives: a `.font()` modifier on a representable reaches the
    /// SwiftUI wrapper, not the glyphs inside it, so text styled from outside would
    /// silently render at the system default.
    var font: NSFont
    /// The colour, for the same reason — `.foregroundStyle` would not reach it either.
    var color: NSColor
    var layout: TextLayout = .wrapping

    /// Whether the text follows the width it is given, or keeps its own.
    private var wraps: Bool { layout != .unwrapped }

    /// The line cap the container needs, which is the other half of `.singleLine`: the
    /// container decides how many lines are laid out, and the paragraph style in
    /// `attributed` decides what the last one does when it runs out of room.
    private var maximumLines: Int {
        if case .singleLine = layout { return 1 }
        return 0
    }

    /// The string as AppKit draws it.
    private var attributed: NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if case .singleLine(let mode) = layout {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = mode
            attributes[.paragraphStyle] = paragraph
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    func makeNSView(context: Context) -> MeasuringTextView {
        let (_, _, container) = MeasuringTextView.makeStack(tracksWidth: wraps)
        container.maximumNumberOfLines = maximumLines
        if !wraps {
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        }

        let view = MeasuringTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        // Never horizontally resizable, in either layout. A text view that sizes its own
        // frame to its text is a second opinion about how wide this view is, and a second
        // opinion is how the feedback loop at the top of this file starts. The width comes
        // from `sizeThatFits` and nowhere else.
        //
        // What the layouts differ on is the *container*: a wrapping one tracks the frame
        // SwiftUI hands over, so the text breaks where it is actually drawn, while an
        // unwrapped one is given all the room there is and lays the code out on one line
        // for the scroll view above it to carry.
        view.isHorizontallyResizable = false
        view.autoresizingMask = []
        if wraps { view.autoresizingMask = [.width] }
        // The view must not fight the size SwiftUI gives it, and must not stretch the
        // panel to fit an unbreakable line.
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.textStorage?.setAttributedString(attributed)
        return view
    }

    func updateNSView(_ view: MeasuringTextView, context: Context) {
        // The container first, and above the guard below rather than after it.
        // `sizeThatFits` measures with whatever `layout` says *now*, so a container still
        // configured for the previous one would draw something other than the size this
        // view reports — the disagreement `TextLayout` says must not happen. A layout
        // change need not touch the string, so the guard would drop it entirely.
        //
        // No call site varies its layout today, and comparing against the container's own
        // state makes this a no-op while none does: `makeStack(tracksWidth:)` and
        // `makeNSView` set exactly these two. It is here so that a call site which starts
        // varying one is not silently wrong.
        if let container = view.textContainer,
           container.maximumNumberOfLines != maximumLines
               || container.widthTracksTextView != wraps {
            container.maximumNumberOfLines = maximumLines
            container.widthTracksTextView = wraps
            view.autoresizingMask = []
            if wraps {
                view.autoresizingMask = [.width]
            } else {
                container.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                        height: CGFloat.greatestFiniteMagnitude)
            }
        }
        // Built once. The property is computed, so every mention of it below would
        // otherwise allocate another string — and a paragraph style with it under
        // `.singleLine` — per row per pass, on the path this file exists to keep cheap.
        let updated = attributed
        // Compared before assigning, for the reason `AnswerTextView` gives: replacing
        // identical storage drops whatever the reader had selected, and every one of
        // these is re-rendered whenever the thread publishes — ten times a second while
        // an answer streams.
        guard view.textStorage?.isEqual(to: updated) != true else { return }
        // Kept only when the words themselves did not change. None of this text streams:
        // what moves it is the theme or the text-size setting, which restyle the same
        // string, and a selection across one of those should survive. A *different*
        // string means the row was reused for another turn, and carrying a highlight over
        // words nobody chose is what a copy from the panel would then take.
        let sameWords = view.textStorage?.string == updated.string
        let selection = view.selectedRanges
        view.textStorage?.setAttributedString(updated)
        if sameWords { view.selectedRanges = selection }
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: MeasuringTextView,
                      context: Context) -> CGSize? {
        // A nil width means "how big would you like to be"; an infinite one means "as
        // wide as you like". Neither is a width to wrap at, and both arrive during
        // sizing — so the text is measured unwrapped and the parent decides. An
        // `.unwrapped` layout asks for that whatever is proposed.
        let width: CGFloat
        if wraps, let offered = proposal.width, offered.isFinite, offered > 0 {
            width = offered
        } else {
            width = CGFloat.greatestFiniteMagnitude
        }
        let size = nsView.sizeFitting(attributed, width: width, maximumLines: maximumLines)
        return CGSize(width: min(width, size.width), height: size.height)
    }
}
