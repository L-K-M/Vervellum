import SwiftUI
import AppKit

/// The panel's title bar.
///
/// A borderless panel has no system title bar, so this stands in for one — and it is
/// also the drag handle, because a panel the user cannot move is a panel that is
/// eventually in the way.
struct PanelHeaderView: View {

    @Environment(\.panelTextScale) private var textScale

    let title: String
    let isRunning: Bool
    @Binding var showsHistory: Bool

    var onNewThread: () -> Void
    var onStop: () -> Void
    var onOpenSettings: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: PanelTheme.Space.small) {
            Image(systemName: "text.magnifyingglass")
                .font(PanelTheme.Font.at(11, textScale, weight: .semibold))
                .foregroundStyle(PanelTheme.Palette.accent)

            Text(showsHistory ? "Earlier threads" : title)
                .font(PanelTheme.Font.at(12, textScale, weight: .medium))
                .foregroundStyle(PanelTheme.Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: PanelTheme.Space.small)

            if isRunning {
                HeaderButton(symbol: "stop.fill",
                             help: "Stop the research (⌘.)",
                             tint: PanelTheme.Palette.verdict(.contradicted),
                             action: onStop)
            }
            HeaderButton(symbol: "square.and.pencil", help: "New thread (⌘N)", action: onNewThread)
            HeaderButton(symbol: showsHistory ? "clock.fill" : "clock",
                         help: "Earlier threads (⌘Y)") {
                showsHistory.toggle()
            }
            HeaderButton(symbol: "gearshape", help: "Settings (⌘,)", action: onOpenSettings)
            HeaderButton(symbol: "xmark", help: "Close (Esc)", action: onClose)
        }
        .padding(.horizontal, PanelTheme.Space.medium)
        .padding(.vertical, PanelTheme.Space.small)
        .contentShape(Rectangle())
        // The whole bar drags the window, the way a real title bar does. `.gesture`
        // rather than the window's `isMovableByWindowBackground`, which would let a
        // drag anywhere in the thread move the panel and make text selection useless.
        .background(WindowDragHandle())
    }
}

/// A small square icon button, styled once so every header control matches.
struct HeaderButton: View {
    @Environment(\.panelTextScale) private var textScale

    let symbol: String
    let help: String
    var tint: Color = PanelTheme.Palette.secondaryText
    var action: () -> Void

    /// How far the tappable area extends past the glyph's frame, per axis.
    ///
    /// The drawn frame is 20×18 — smaller than the ~24 pt a pointer aims at — and the
    /// buttons sit `PanelTheme.Space.small` (6 pt) apart, so the horizontal expansion is
    /// derived from half that spacing: neighbouring hit areas exactly meet without
    /// overlapping, for any spacing value. 4 pt vertical stays inside the header's own
    /// 6 pt padding.
    static let hitExpansionX: CGFloat = PanelTheme.Space.small / 2
    static let hitExpansionY: CGFloat = 4

    /// The glyph's drawn frame, in the button's own coordinates.
    static let glyphFrame = CGRect(x: 0, y: 0, width: 20, height: 18)

    /// Padding that grows the button's real frame past the glyph, applied to the label
    /// so it is part of the button's own frame. With `.plain` style and
    /// `.contentShape(Rectangle())` this makes the whole expanded frame the hit target,
    /// the hover region and the tooltip region — all three agree, because the shape is
    /// the button's actual frame rather than a rect drawn outside it, which hit testing
    /// is not guaranteed to honor.
    static var hitPadding: EdgeInsets {
        EdgeInsets(top: hitExpansionY, leading: hitExpansionX,
                   bottom: hitExpansionY, trailing: hitExpansionX)
    }

    /// The inverse of `hitPadding`, applied last so the button's layout footprint stays
    /// the glyph's 20×18 and the header's spacing is unchanged.
    static var inverseHitPadding: EdgeInsets {
        EdgeInsets(top: -hitExpansionY, leading: -hitExpansionX,
                   bottom: -hitExpansionY, trailing: -hitExpansionX)
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(PanelTheme.Font.at(10.5, textScale, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: Self.glyphFrame.width, height: Self.glyphFrame.height)
                // The visible chip stays glyph-sized; only the hit and hover
                // regions grow.
                .background(isHovering ? PanelTheme.Palette.chipFill : .clear,
                            in: RoundedRectangle(cornerRadius: PanelTheme.Radius.chip, style: .continuous))
            // Inside the label, so the padding is part of the label's — and with
            // `.plain` style the button's — own frame: the default hit area is the
            // label's 20×18 bounds, and padding applied outside the Button grows
            // the container, not the button, so taps in the ring would never reach
            // the action.
            .padding(Self.hitPadding)
            // Inside the label and after the padding. `.plain` hit-tests the label's
            // content, so without this only the glyph's own pixels take a click, and
            // a content shape on the Button itself does not reach into the label.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The button's frame is now the expanded 26×26, so hit testing, hover and
        // the tooltip all cover the same area. The inverse padding below is
        // load-bearing for layout: it restores the 20×18 footprint in the HStack, so
        // header spacing is pixel-identical to before — and because the expansion is
        // half the 6 pt spacing, neighbouring buttons' 26×26 frames still exactly meet
        // without overlapping. Do not remove the inverse padding (spacing would grow)
        // and do not move the hit padding outside the Button (the container would
        // grow, not the button, and taps in the ring would not reach the action).
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .padding(Self.inverseHitPadding)
    }
}

/// Lets a drag anywhere in the header move the panel.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        // The header sits behind buttons; let clicks through to them, and only take
        // the ones that land on the bar itself.
        override func hitTest(_ point: NSPoint) -> NSView? {
            super.hitTest(point) === self ? self : nil
        }
    }
}
