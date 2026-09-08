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
private struct HeaderButton: View {
    @Environment(\.panelTextScale) private var textScale

    let symbol: String
    let help: String
    var tint: Color = PanelTheme.Palette.secondaryText
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(PanelTheme.Font.at(10.5, textScale, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20, height: 18)
                .background(isHovering ? PanelTheme.Palette.chipFill : .clear,
                            in: RoundedRectangle(cornerRadius: PanelTheme.Radius.chip, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
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
