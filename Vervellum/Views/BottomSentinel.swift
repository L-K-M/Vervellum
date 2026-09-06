import SwiftUI
import AppKit

/// Reports whether the enclosing `NSScrollView` is pinned to the bottom.
///
/// This exists for one behaviour: a streamed answer auto-scrolls only while the
/// user is *at* the bottom. Without it, scrolling up to re-read during a stream
/// is undone by the very next token — the panel fights the reader for the whole
/// answer, which is the single most annoying thing a streaming UI can do.
///
/// The mechanism is a zero-size NSView parked at the bottom of the scroll
/// content. SwiftUI on macOS 14 has no scroll-position API, so the sentinel
/// walks up to the enclosing `NSScrollView` and observes its clip view's bounds:
/// any scroll — wheel, drag, keyboard, or a programmatic `scrollTo` — re-evaluates
/// pinned-ness, as does the document growing (a new token) or the panel resizing.
struct BottomSentinel: NSViewRepresentable {

    /// How close to the bottom counts as pinned, in points. Generous enough that
    /// a fractional layout rounding does not read as "the user scrolled away".
    static let tolerance: CGFloat = 32

    var onPinChanged: (Bool) -> Void

    func makeNSView(context: Context) -> SentinelView {
        SentinelView(onPinChanged: onPinChanged)
    }

    func updateNSView(_ nsView: SentinelView, context: Context) {
        nsView.onPinChanged = onPinChanged
    }

    final class SentinelView: NSView {
        var onPinChanged: (Bool) -> Void

        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var lastPinned = true

        init(onPinChanged: @escaping (Bool) -> Void) {
            self.onPinChanged = onPinChanged
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        /// The SwiftUI tree is reused across summons, so the enclosing scroll view
        /// can change without this view being rebuilt — re-resolve every time the
        /// window changes.
        private func attach() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []

            var view = superview
            while view != nil, !(view is NSScrollView) { view = view?.superview }
            guard let scrollView = view as? NSScrollView, window != nil else { return }
            self.scrollView = scrollView

            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            scrollView.documentView?.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            // Scrolling (wheel, drag, keys, or a programmatic scrollTo) is honest:
            // whatever it leaves visible is what the user is looking at.
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.recompute(fromScroll: true) })
            // The document growing is not. While pinned, a new token makes the
            // document taller than the visible area *before* the follow scroll
            // lands, and unpinning in that gap would close the follow gate one
            // token into every answer.
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: scrollView.documentView,
                queue: .main
            ) { [weak self] _ in self?.recompute(fromScroll: false) })
            recompute(fromScroll: true)
        }

        private func recompute(fromScroll: Bool) {
            guard let scrollView else { return }
            if !fromScroll, lastPinned { return }
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let visibleBottom = scrollView.contentView.bounds.maxY
            let pinned = visibleBottom >= documentHeight - BottomSentinel.tolerance
            guard pinned != lastPinned else { return }
            lastPinned = pinned
            onPinChanged(pinned)
        }
    }
}
