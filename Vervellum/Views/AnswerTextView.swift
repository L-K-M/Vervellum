import AppKit
import SwiftUI

/// Where the pointer is, over which citation.
struct CitationHover: Equatable {
    /// The source the chip under the pointer names.
    let source: Source
    /// The chip's rectangle in the text view's own coordinates, for the popover to
    /// point at.
    let rect: CGRect
}

/// One block of the answer, drawn by AppKit so a citation can answer a hover.
///
/// A SwiftUI `Text` renders an `AttributedString` beautifully and will not say what is
/// under the pointer. There is no per-run hit testing on it and no way to attach a
/// gesture to a run, so `[21]` cannot show what it cites without leaving the panel. That
/// is the whole reason this view exists — everything else about it is an attempt to give
/// back what `Text` was doing for free.
///
/// TextKit 1, deliberately. The view is built from an explicit
/// storage/layout-manager/container stack through `NSTextView(frame:textContainer:)`,
/// because the hit test below is `NSLayoutManager`'s and a text view that quietly
/// adopted TextKit 2 would hand back a `layoutManager` of nil. The paragraphs here are
/// short and static; none of what TextKit 2 is faster at applies.
struct AnswerTextView: NSViewRepresentable {

    let attributed: NSAttributedString
    /// The turn's sources, so a chip's address can be turned back into the thing it
    /// cites. Passed as a list and indexed once per update rather than searched on every
    /// mouse movement.
    let sources: [Source]
    /// Reported on every change, including nil when the pointer leaves a chip.
    var onHover: (CitationHover?) -> Void

    func makeNSView(context: Context) -> HoverTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // Both components spelled `CGFloat`. `NSSize.init(width:height:)` is overloaded
        // across the numeric types, and `0` paired with a bare `.greatestFiniteMagnitude`
        // gives the solver nothing to pick from — it reads as ambiguous, and the whole
        // function body then fails to type-check around it.
        let container = NSTextContainer(size: NSSize(width: CGFloat(0),
                                                     height: CGFloat.greatestFiniteMagnitude))
        // The padding is AppKit's default two points on each side, and it would show up
        // as the answer sitting inset from everything stacked beside it.
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let view = HoverTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        // Grows downward, never sideways: the container's width follows the frame
        // SwiftUI hands over, so the text wraps at the width it is actually drawn at
        // rather than at one this file guessed.
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        // Chips are accent-coloured, not blue and underlined. `linkTextAttributes` wins
        // over the run's own attributes for a link, so leaving it at the default would
        // repaint every citation in the system link style — and the font is left out on
        // purpose, so the run's monospaced face survives.
        view.linkTextAttributes = [.foregroundColor: PanelTheme.NativePalette.accent,
                                   .cursor: NSCursor.pointingHand]
        // The text view must not fight the height SwiftUI gives it, and must not stretch
        // the panel to fit an unbreakable line.
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onHover = onHover
        view.sourcesByURL = Self.index(sources)
        view.textStorage?.setAttributedString(attributed)
        return view
    }

    func updateNSView(_ view: HoverTextView, context: Context) {
        view.onHover = onHover
        view.sourcesByURL = Self.index(sources)
        // Compared before assigning: an answer is re-rendered on every streamed chunk,
        // and replacing identical storage would drop the reader's selection each time.
        if view.textStorage?.isEqual(to: attributed) != true {
            // Kept across the replacement, which is what the comparison above could not
            // do: a streamed answer is never identical to the last one, so the guard
            // spared the selection only in the case where there was none to lose. A
            // reader dragging across a sentence while the rest of the answer arrives had
            // it dropped several times a second.
            let previous = view.textStorage?.string
            let selection = view.selectedRanges
            view.textStorage?.setAttributedString(attributed)
            // An *append*, not merely a fit. Checking only that the old ranges still fit
            // kept a selection across a replacement long enough to hold it — a revision
            // swapping the answer, this view reused for another turn — and the reader
            // would be left holding a highlight over words they never chose, which is
            // what a copy from the panel would then take.
            if let previous, attributed.string.hasPrefix(previous),
               selection.allSatisfy({ NSMaxRange($0.rangeValue) <= attributed.length }) {
                view.selectedRanges = selection
            }
            // Every glyph after the edit has just moved, and a popover on screen is
            // pointing at where its chip used to be. It would right itself on the next
            // mouse movement, but a streamed answer replaces this several times a second
            // and the reader is not moving the pointer while they read.
            // Hopped, not called here. `updateNSView` runs inside SwiftUI's own update
            // pass, and `schedule(nil)` reaches `onHover?(nil)` synchronously — which
            // writes the parent's state in the middle of reading it. The runtime warns,
            // and the dismissal can be dropped, which would leave exactly the stale
            // popover this line exists to remove. One turn of the main queue makes it an
            // ordinary change. Repeats are free: `schedule` returns immediately when
            // there is nothing showing and nothing pending.
            DispatchQueue.main.async { view.schedule(nil) }
        }
        // `linkTextAttributes` is set once in `makeNSView`: it is a constant, nothing
        // resets it, and replacing the storage does not touch it. Assigning it again per
        // streamed chunk was work on the hottest path in the panel, and it implied to a
        // reader that the value can change.
    }

    /// Sources by address, keyed the way the lookup will ask for them.
    ///
    /// Through `URL` on both sides, which is the point: the chip carries a `URL` built
    /// from `source.url`, and the hit test asks with its `absoluteString`. `URL` can
    /// normalise on the way through — percent-encoding, a trailing slash — so keying by
    /// the raw string would mean a chip whose address needed normalising silently
    /// stopped answering, with nothing to notice. The raw string stands in for an
    /// address `URL` refuses entirely, which cannot have produced a chip either.
    ///
    /// Last wins on a duplicate, which cannot happen for a turn's own list — the
    /// harvester numbers one entry per address — but a dictionary literal would trap on
    /// one rather than pick, and a crash is not the price of a malformed source list.
    private static func index(_ sources: [Source]) -> [String: Source] {
        sources.reduce(into: [:]) { $0[URL(string: $1.url)?.absoluteString ?? $1.url] = $1 }
    }

    /// The height this text needs at the width SwiftUI is offering.
    ///
    /// Without this the view reports its intrinsic size, which for a text view is the
    /// size of its current frame — so the first layout pass would decide the answer is
    /// zero points tall and every pass after it would agree.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: HoverTextView,
                      context: Context) -> CGSize? {
        // A nil width means "how big would you like to be"; an infinite one means "as
        // wide as you like". Neither is a width to wrap at, and both arrive during
        // sizing — so the text is measured unwrapped and the parent decides.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? CGFloat.greatestFiniteMagnitude
        let size = nsView.sizeFitting(attributed, width: width)
        return CGSize(width: min(width, size.width), height: size.height)
    }
}

/// The text view itself: everything above is wiring, and this is the part that answers
/// "what is under the pointer".
final class HoverTextView: NSTextView {

    // A click on a chip opens the source in the reader's browser, and that is deliberate
    // — `NSTextView`'s own handling of a `.link` run, left alone. It is what
    // `linkTextAttributes` above advertises with a pointing hand, and the only place a
    // citation can lead: the panel shows a preview of a source, never the page. Said
    // here because the behaviour is inherited rather than written, and inherited
    // behaviour is what gets "fixed" by someone who cannot find the code for it.

    var onHover: ((CitationHover?) -> Void)?
    /// The turn's sources by address, so a chip can be turned back into what it cites
    /// without walking the list on every mouse movement.
    var sourcesByURL: [String: Source] = [:]

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
    /// Per view rather than one shared by the type, which is what makes the two "has
    /// this changed" tests in `sizeFitting` worth making: a single stack would be reloaded
    /// by whichever block measured last, so every question would find another block's
    /// text in it and lay out from scratch anyway.
    private lazy var measuring: (NSTextStorage, NSLayoutManager, NSTextContainer) = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat(0),
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return (storage, layout, container)
    }()

    /// How much room this text needs at a given width.
    ///
    /// Both assignments are guarded because either one throws away the layout the stack
    /// is holding, and the common case — the same block asked the same question again
    /// while the answer around it changed — is answered from the layout it already has.
    func sizeFitting(_ attributed: NSAttributedString, width: CGFloat) -> CGSize {
        let (storage, layout, container) = measuring
        if !storage.isEqual(to: attributed) { storage.setAttributedString(attributed) }
        let wanted = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if container.size != wanted { container.size = wanted }
        // `usedRect` is only meaningful once layout has run, and asking for it does not
        // itself trigger one.
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// How long the pointer must rest on a chip before its source appears.
    ///
    /// Long enough that crossing a paragraph on the way somewhere else does not open
    /// anything, short enough that stopping on a number feels like an answer rather than
    /// a wait. Read text is dense with chips, and a popover per chip brushed past would
    /// make the answer unreadable — which is the opposite of what this is for.
    private static let dwell: TimeInterval = 0.35

    private var pending: DispatchWorkItem?
    /// What `pending` will show when it fires. Kept beside the work item because
    /// "is a wait already running *for this chip*" and "is a wait running" are
    /// different questions, and `schedule` has to answer the first one.
    private var pendingHover: CitationHover?
    private var showing: CitationHover?
    /// Held so `updateTrackingAreas` can tell whether this view's own area is already
    /// installed. Not `trackingAreas.isEmpty`: `NSTextView` installs areas of its own —
    /// the link cursor is one — so the list is never empty and says nothing about this.
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Added once and then left alone, which is what `.inVisibleRect` below is for:
        // AppKit maintains the area's rect itself, so there is nothing for a rebuild to
        // bring up to date. `updateTrackingAreas` is not rare — a superview laying out,
        // a sibling resizing and a scrolling pass all reach it — so removing and
        // re-adding meant allocating a tracking area on each of them, and mutating the
        // list under a pointer that is resting on a chip is the one place a `mouseExited`
        // nobody made could come from. That reaches `schedule(nil)`, and the popover the
        // reader is reading would close with no movement to re-earn it.
        guard hoverTracking == nil else { return }
        // `.inVisibleRect` keeps the area correct as the thread scrolls without this
        // view being asked to rebuild it — and makes the zero rect below the right one,
        // since AppKit then maintains it.
        //
        // `.activeAlways`, not `.activeInKeyWindow`: the panel is a `.nonactivatingPanel`
        // and `PanelController` shows it without focus whenever the reader summoned it
        // without meaning to type, so keying it is not a precondition for looking at it.
        // Under `.activeInKeyWindow` a visible, unfocused panel would answer no hover at
        // all — the first thing anyone tries. It does not reintroduce tracking from
        // behind another window, because a tracking area only delivers while the pointer
        // is over the visible rect, and an occluded view has none.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        schedule(citation(at: convert(event.locationInWindow, from: nil)))
    }

    /// Scrolling brings a chip to the pointer rather than the pointer to the chip, and
    /// sends no `mouseMoved` for it: what arrives is the tracking area's enter event, on
    /// whichever block scrolled under a hand that never went anywhere. Without this the
    /// chip directly beneath the cursor is dead until the mouse is nudged — the same
    /// class of miss the resize below is here for. Entering over prose costs nothing:
    /// `schedule(nil)` returns immediately when nothing is showing and nothing pending.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        schedule(citation(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        schedule(nil)
    }

    /// A resize rewraps the text, so a chip can move to another line under a pointer
    /// that never went anywhere and sent no `mouseMoved`. The answer is dismissed and
    /// re-earned by the next movement.
    ///
    /// Scrolling needs nothing here, which is worth saying because the obvious hook —
    /// `reflectScrolledClipView` — would never fire anyway: the thread scrolls in a
    /// SwiftUI `ScrollView`, so this view has no `NSClipView` above it. It also needs
    /// nothing: the rect is in this view's own coordinates and the whole view travels,
    /// so a popover anchored to it goes along with the chip it points at.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        schedule(nil)
    }

    /// And on any other width change, which is most of them.
    ///
    /// A live resize is the *window* being dragged. The panel's width is a preference
    /// with a slider behind it, applied programmatically to an open panel — and a
    /// sibling appearing or a section disclosing moves this view's width too. None of
    /// those is a live resize, and every one of them rewraps the text under a pointer
    /// that never moved and sent no `mouseMoved`.
    ///
    /// Width only: a height change never rewraps, and a streamed answer changes height
    /// on every chunk. The hop is for the same reason as the one in `updateNSView` —
    /// this can run inside a layout pass, and `schedule(nil)` writes the parent's state.
    override func setFrameSize(_ newSize: NSSize) {
        let rewrapped = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        guard rewrapped else { return }
        DispatchQueue.main.async { [weak self] in self?.schedule(nil) }
    }

    func schedule(_ hover: CitationHover?) {
        // What the view is *heading for*, which is the pending target while a wait is
        // running and the shown one otherwise. Comparing against `showing` alone was the
        // bug: a pointer resting on a chip has nothing showing yet, so moving off it
        // asked "is nil different from nil", answered no, and returned — leaving the
        // chip's work item alive to open a popover a third of a second later, over prose
        // the pointer had already left. The commonest gesture there is, and the exact
        // failure the dwell is supposed to prevent rather than cause.
        //
        // Comparing against the pending target rather than cancelling unconditionally
        // matters just as much in the other direction: a pointer that is resting rather
        // than perfectly still sends a stream of `mouseMoved` for the same chip, and
        // restarting the wait on each one would mean the popover never appeared at all.
        guard hover != (pending == nil ? showing : pendingHover) else { return }
        pending?.cancel()
        pending = nil
        pendingHover = nil
        // Leaving is immediate; arriving waits. A popover that lingers over prose the
        // pointer has moved on from is the one failure mode a dwell cannot excuse.
        guard let hover else {
            // Only when something was actually on screen. A pointer brushing a chip and
            // leaving before the wait is up cancels the work item above and nothing
            // else: `showing` is nil, so the parent's hover is nil too, and reporting
            // nil at it again is a `@State` write — an invalidation per chip brushed,
            // on the path this file spends its whole length keeping quiet.
            guard showing != nil else { return }
            showing = nil
            onHover?(nil)
            return
        }
        // The pointer left this chip for a neighbour and came back before the
        // neighbour's wait was up: this chip's popover is still on screen, and the
        // neighbour's work item was cancelled just above, so there is nothing left to
        // wait *for*. Dwelling again would leave the same popover exactly where it is
        // and then announce it a second time a third of a second later.
        guard hover != showing else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.pendingHover = nil
            self?.showing = hover
            self?.onHover?(hover)
        }
        pending = work
        pendingHover = hover
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: work)
    }

    /// The citation under a point in this view's coordinates, or nil.
    private func citation(at point: CGPoint) -> CitationHover? {
        // `numberOfGlyphs` as well as the storage's length: the two are not the same
        // question during a streamed edit, and every call below is a geometry query that
        // raises rather than answering when handed glyph 0 of 0. A range exception
        // inside `mouseMoved` is a crash while the reader is doing nothing but reading.
        guard let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0,
              layout.numberOfGlyphs > 0 else { return nil }
        let origin = textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)

        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: container,
                                      fractionOfDistanceThroughGlyph: &fraction)
        // `glyphIndex(for:in:)` answers the *nearest* glyph, never nil — so a pointer in
        // the margin beside a short line comes back pointing at that line's last
        // character. Without this the popover would open from the whitespace next to a
        // chip, which is exactly where a pointer on its way past sits.
        //
        // The bound is asked again rather than trusted from the guard above: the count
        // there was read before this call, and asking for a glyph index is what forces
        // layout — which during a streamed replacement is the moment the count changes.
        // A range past the end raises rather than answering, inside `mouseMoved`.
        guard glyph != NSNotFound, glyph < layout.numberOfGlyphs else { return nil }
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                            in: container)
        guard glyphRect.contains(inContainer) else { return nil }

        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var effective = NSRange(location: 0, length: 0)
        let attributes = storage.attributes(at: index, effectiveRange: &effective)
        // `.link` arrives as either, depending on how the string was built. Both are
        // read rather than one being promised, because a string built the other way is
        // not a crash — it is a chip that silently stops answering.
        let url: URL?
        switch attributes[.link] {
        case let value as URL: url = value
        case let value as String: url = URL(string: value)
        default: url = nil
        }
        guard let url, let source = sourcesByURL[url.absoluteString] else { return nil }

        // Clipped to the line the pointer is on. `boundingRect(forGlyphRange:)` returns
        // the *union* of the fragments a range covers, so a grouped chip the line broke
        // at one of its commas — `[3,7,11]` at the narrowest width — unions into a band
        // the full width of the column, and a popover anchored to that points at the
        // blank space between two lines. A chip on one line is unaffected: its union is
        // already inside its own fragment.
        let chip = layout.boundingRect(
            forGlyphRange: layout.glyphRange(forCharacterRange: effective,
                                             actualCharacterRange: nil),
            in: container)
            .intersection(layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
        return CitationHover(source: source,
                             rect: chip.offsetBy(dx: origin.x, dy: origin.y))
    }
}
