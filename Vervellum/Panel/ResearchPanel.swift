import AppKit
import KeycapKit

/// The floating window the research thread lives in.
///
/// `NSPanel` rather than `NSWindow`, and with a specific combination of flags that
/// is the whole reason the app feels the way it does:
///
/// * **`.nonactivatingPanel`** — showing the panel does not make Vervellum the
///   active application by itself. That is what lets it appear over a full-screen
///   app without macOS switching Spaces to find Vervellum a home.
/// * **`canBecomeKey` overridden to true** — a borderless panel refuses key status
///   by default, and a panel that cannot become key cannot receive typing. This one
///   override is the difference between a composer that works and one that silently
///   swallows every keystroke.
/// * **`canBecomeMain` left false** — main status belongs to the app the user was
///   actually working in. Taking it would put Vervellum's (nonexistent) menu bar up
///   and make the previous app's title bar go inactive.
final class ResearchPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Invoked when the panel wants to close itself (⌘W, or the close control).
    var onClose: (() -> Void)?

    convenience init(content: NSView) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: PanelPlacement.defaultWidth, height: 600),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)
        // A plain container between the window and the SwiftUI host, rather than
        // installing the hosting view as `contentView` directly. An `NSHostingView`
        // used as a borderless panel's content view drives the *window's* size from
        // its own intrinsic content and grows from the bottom-left origin — so the
        // panel slides sideways and downward as an answer streams in. The container
        // keeps the frame under this class's control; only the content resizes.
        let container = NSView(frame: contentRect(forFrameRect: frame))
        container.autoresizesSubviews = true
        container.wantsLayer = true
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        content.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(content)
        contentView = container
        configure()
    }

    private func configure() {
        isFloatingPanel = true
        // Default already, but stated because the opposite is an active hazard here:
        // with `becomesKeyOnlyIfNeeded` true a non-activating panel becomes key only
        // if the hit view returns true from `needsPanelToBecomeKey`, which `NSView`
        // does not. It has no bearing on a programmatic `makeKey()`.
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // `.floating` (3), not `.popUpMenu` (101). Level orders windows *within* a
        // space, so it plays no part in appearing over a full-screen app — that is
        // entirely `collectionBehavior`'s job below. What a higher level would buy is
        // covering the menu bar, the Dock, and real `NSMenu`s, including the one this
        // app's own status item pops. `.floating` sits above every ordinary window and
        // below all system chrome, which is exactly right for an overlay.
        level = .floating
        isMovable = true
        isReleasedWhenClosed = false
        isRestorable = false
        // `NSPanel` overrides `NSWindow`'s default here and hides on deactivate. Left
        // alone, the panel would vanish the instant Vervellum stopped being frontmost
        // — which is immediately, since the app the user was working in takes focus
        // back. A research run has to outlive that.
        hidesOnDeactivate = false
        animationBehavior = .none
        // The flags that put the panel over another app's full-screen window:
        //   .canJoinAllSpaces        — it exists on every Space, so showing it needs no
        //                              Space switch. A `.moveToActiveSpace` panel would
        //                              drag the user out of their full-screen app.
        //   .canJoinAllApplications  — it may join *other applications'* full-screen
        //                              spaces. This is the one Apple documents for
        //                              floating windows and system overlays;
        //                              `.fullScreenAuxiliary` alone is specified only
        //                              for the same app's own full-screen window.
        //   .fullScreenAuxiliary     — kept alongside it for the same-app case.
        //   .transient               — Mission Control hides the panel rather than
        //                              floating it on top of the overlay, which is what
        //                              `.stationary` would do.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                              .fullScreenAuxiliary, .transient]
    }

    /// Routes the panel's command shortcuts.
    ///
    /// This has to live on the window rather than in the composer or a SwiftUI
    /// modifier: a Command-modified key never reaches `NSTextView`'s
    /// `doCommandBy(_:)`, because AppKit dispatches key *equivalents* through
    /// `performKeyEquivalent(with:)` before the responder chain sees an
    /// `insertNewline:`-style action. Without this, ⌘⏎ and friends are simply dead —
    /// which is worse than not offering them, because the help text promises them.
    ///
    /// Only these exact combinations are intercepted; everything else falls through to
    /// `super`, so ⌘C / ⌘V / ⌘A / ⌘Z keep working in the composer.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Caps Lock, the numeric-pad flag and the function-key flag all show up in
        // `deviceIndependentFlagsMask` without the user having pressed anything extra —
        // and keypad Enter *always* sets `.numericPad`. Comparing the raw set to
        // `.command` therefore kills every shortcut for a Caps Lock user and made the
        // keypad-Enter branch below unreachable. Subtract the incidental flags, then
        // require Command and nothing else.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags == .command else { return super.performKeyEquivalent(with: event) }

        // Return arrives as a key code rather than a character.
        if event.keyCode == UInt16(KeyCode.return) || event.keyCode == UInt16(KeyCode.keypadEnter) {
            post(.submit)
            return true
        }
        // Command-Arrow jumps the thread to its top or bottom. The composer always holds
        // first responder, so ↑/↓ alone reach it, not the thread's scroll view — without
        // these a long transcript can only be scrolled with the pointer.
        if event.keyCode == UInt16(KeyCode.upArrow) {
            post(.scrollToTop)
            return true
        }
        if event.keyCode == UInt16(KeyCode.downArrow) {
            post(.scrollToBottom)
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w":
            onClose?()
            return true
        case "n": post(.newThread);   return true
        case "y": post(.toggleHistory); return true
        case ",": post(.openSettings); return true
        case ".": post(.stop);        return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func post(_ command: PanelCommand) {
        NotificationCenter.default.post(name: .vervellumPanelCommand, object: nil,
                                        userInfo: ["command": command.rawValue])
    }
}

/// A command the panel's chrome can raise for the SwiftUI tree to act on.
///
/// A notification rather than a closure per command: the panel's root view is built
/// once and reused across every summon, so there is no initializer to thread a dozen
/// callbacks through, and the view owns the state each command needs to change.
enum PanelCommand: String {
    /// Escape. The view decides what it backs out of; see `PanelRootView`.
    case escape
    case submit
    case newThread
    case toggleHistory
    case openSettings
    case stop
    /// ⌘↑ — scroll the thread to its first turn.
    case scrollToTop
    /// ⌘↓ — scroll the thread to its latest content.
    case scrollToBottom
}

extension Notification.Name {
    /// Carries a `PanelCommand.rawValue` in `userInfo["command"]`.
    static let vervellumPanelCommand = Notification.Name("VervellumPanelCommandNotification")
}
