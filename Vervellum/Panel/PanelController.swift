import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted after the panel becomes key, so the composer re-asserts focus on every
    /// summon. The hosting view is reused between summons and SwiftUI's `.onAppear`
    /// does not reliably re-fire for a view that never left the hierarchy.
    static let vervellumPanelDidShow = Notification.Name("VervellumPanelDidShowNotification")
    /// Posted when the panel is about to hide, so views can drop transient state.
    static let vervellumPanelWillHide = Notification.Name("VervellumPanelWillHideNotification")
}

/// Owns the research panel: builds it once, places it, gives it focus, and hands
/// focus back.
///
/// The activation dance is the delicate part. Vervellum is an `.accessory` app with
/// no Dock icon, and it needs to type into a text field over whatever the user was
/// doing — including a full-screen app on another Space. That means:
///
/// 1. Remember which application was frontmost **before** anything is shown.
/// 2. Activate Vervellum, so its non-activating panel is allowed to take key status
///    and receive keystrokes. Because the panel joins all Spaces, this does not pull
///    the user out of a full-screen app.
/// 3. On dismissal, hand activation back to the remembered app — but only if
///    Vervellum is still the active app. If the user dismissed the panel by clicking
///    into something else, that app is already frontmost and yanking focus to the
///    remembered one would be actively wrong.
final class PanelController {

    private let preferences: Preferences
    private let rootView: () -> AnyView

    private var panel: ResearchPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var appToRestoreOnClose: NSRunningApplication?
    /// Whether `show()` captured an app to restore. Distinguishes "the captured app
    /// quit while the panel was open" (restore is nil but this is true → fall back to
    /// Finder) from "there was deliberately nothing to restore".
    private var hadRestoreTarget = false

    private(set) var isOpen = false

    /// Called when the panel is dismissed, so the owner can flush anything pending.
    var onDismiss: (() -> Void)?
    /// Asked for the text to seed the composer with, when summoned via the
    /// research-the-selection shortcut. Returns nil when nothing is selected.
    var selectionProvider: (() -> String?)?
    /// Delivers seeded text to the composer.
    var onSeedComposer: ((String) -> Void)?
    /// Whether research is currently running. Consulted before any automatic
    /// dismissal, never before a deliberate one.
    var isBusy: (() -> Bool)?

    init(preferences: Preferences, rootView: @escaping () -> AnyView) {
        self.preferences = preferences
        self.rootView = rootView
    }

    // MARK: Show / hide

    /// The hotkey action: summon, or dismiss if already showing.
    ///
    /// Re-invoking the shortcut while the panel is open on a *different* screen moves
    /// it to the screen the pointer is on instead of dismissing it — the behaviour
    /// Spotlight and Raycast both have, and the one that makes a hotkey usable on a
    /// multi-display desk.
    func toggle() {
        guard isOpen, let panel else { show(); return }
        let target = Self.screenUnderPointer()
        if let target, panel.screen !== target {
            place(panel, on: target, animated: true)
            focus(panel)
            return
        }
        hide()
    }

    /// Summons the panel and seeds the composer with the frontmost app's selection.
    func showWithSelection() {
        let selected = selectionProvider?()
        show()
        if let selected, !selected.isEmpty {
            onSeedComposer?(selected)
        }
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if !isOpen {
            appToRestoreOnClose = frontmost?.processIdentifier
                == NSRunningApplication.current.processIdentifier ? nil : frontmost
            hadRestoreTarget = appToRestoreOnClose != nil
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel, on: Self.screenUnderPointer(), animated: !isOpen)
        focus(panel)

        if !isOpen {
            installKeyMonitor()
            installResignObserver(for: panel)
            isOpen = true
        }
    }

    /// The application the panel would hand focus back to on dismissal, for a caller
    /// that dismisses it without restoring: Settings takes the panel's place, and
    /// restores this app itself when it closes.
    var applicationToRestore: NSRunningApplication? { appToRestoreOnClose }

    /// Dismisses the panel. With `restoringActivation` false the app that was active
    /// before the panel is *not* brought back — the caller is about to show a window
    /// of its own and will do that when it closes.
    func hide(restoringActivation: Bool = true) {
        guard isOpen, let panel else { return }
        isOpen = false
        NotificationCenter.default.post(name: .vervellumPanelWillHide, object: nil)
        removeObservers()

        let side = preferences.panelSide
        let target = PanelPlacement.entryFrame(for: panel.frame, side: side)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: false)
        } completionHandler: { [weak self, weak panel] in
            // The summon shortcut can be pressed again inside the 110 ms fade. Ordering
            // out unconditionally would then hide the panel the user had just asked for,
            // leaving a hotkey that appears to do nothing every other press.
            guard self?.isOpen != true else { return }
            panel?.orderOut(nil)
        }

        if restoringActivation {
            restoreActivation()
        } else {
            appToRestoreOnClose = nil
            hadRestoreTarget = false
        }
        onDismiss?()
    }

    // MARK: Building

    private func makePanel() -> ResearchPanel {
        let hosting = NSHostingView(rootView: rootView())
        // Stop the hosting view from proposing a window size of its own; the frame is
        // computed by `PanelPlacement` and nothing else is allowed to move it.
        hosting.sizingOptions = []
        let panel = ResearchPanel(content: hosting)
        panel.onClose = { [weak self] in self?.hide() }
        return panel
    }

    /// The screen the pointer is on — the one the user is looking at. `NSScreen.main`
    /// is the screen with the *key window*, which on a multi-display desk is often
    /// not where the user just pressed the shortcut.
    static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    private func place(_ panel: ResearchPanel, on screen: NSScreen?, animated: Bool) {
        guard let screen = screen ?? NSScreen.main else { return }
        let side = preferences.panelSide
        let frame = PanelPlacement.frame(in: screen.visibleFrame,
                                         side: side,
                                         width: preferences.panelWidth,
                                         height: preferences.panelHeight)
        guard animated else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            return
        }
        panel.setFrame(PanelPlacement.entryFrame(for: frame, side: side), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Brings the app forward and makes the panel key, then tells the composer to
    /// claim first responder. See the type's documentation for why this is safe over
    /// a full-screen app.
    private func focus(_ panel: ResearchPanel) {
        // Order in BEFORE activating. Activation moves the user to the space holding
        // the app's frontmost ordered-in window; with the all-spaces panel already on
        // the current space, that space is the one they are looking at. (The one way
        // to still get pulled elsewhere is a Settings window left open on another
        // Space — a deliberate act, and it goes back on close.)
        panel.orderFrontRegardless()
        // A non-activating panel can be ordered in without activating, but the window
        // server routes keystrokes to the *active application's* key window — so
        // without this the composer would show a caret and receive nothing.
        NSApp.activate()
        panel.makeKey()
        NotificationCenter.default.post(name: .vervellumPanelDidShow, object: nil)
    }

    /// Hands activation back cooperatively.
    ///
    /// `yieldActivation(to:)` tells macOS that Vervellum is *giving up* focus rather
    /// than the other app *taking* it. Without the yield, the handoff looks like
    /// focus-stealing to the window server, which can defer or drop it — leaving the
    /// user typing into a window that is not actually frontmost.
    private func yieldActivation(to application: NSRunningApplication) {
        NSApp.yieldActivation(to: application)
        application.activate(options: [.activateAllWindows])
    }

    // MARK: Dismissal rules

    /// Watches for the panel losing key status.
    ///
    /// Unlike Spotlight, losing focus does **not** dismiss by default. A research run
    /// takes tens of seconds and the answer is meant to be read while working, so a
    /// panel that vanished the moment the user clicked back into their editor would
    /// throw away exactly the thing they asked for. The behaviour is a preference for
    /// people who want the Spotlight feel.
    private func installResignObserver(for panel: ResearchPanel) {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.preferences.dismissOnFocusLoss else { return }
            guard NSApp.modalWindow == nil else { return }
            // Even with the preference on, a run in flight keeps the panel up. A
            // provider's own authentication sheet, a system alert, or the user glancing
            // at another window all resign key status — losing a 40-second answer to
            // any of them would be indefensible.
            guard self.isBusy?() != true else { return }
            self.hide()
        }
    }

    /// Escape, and the shortcuts that only make sense while the panel is up.
    ///
    /// A local monitor rather than SwiftUI key handling: the panel hosts a text view,
    /// and a SwiftUI `.onKeyPress` competes with the field editor for Escape in a way
    /// that is inconsistent across macOS versions. The monitor sees the event first
    /// and can decide, once, whether the panel or the field editor should have it.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            // While an input method is composing, Escape belongs to the candidate
            // window — stealing it makes CJK input impossible.
            if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            guard event.keyCode == UInt16(KeyCode.escape) else { return event }
            // Escape is handed to the SwiftUI tree rather than closing here, because
            // what it should do depends on state this class cannot see: it clears a
            // draft, or leaves the history list, and only closes the panel when there
            // is nothing left to back out of. A local monitor runs *before* the
            // responder chain, so this is the only place the ordering can be decided.
            NotificationCenter.default.post(name: .vervellumPanelCommand, object: nil,
                                            userInfo: ["command": PanelCommand.escape.rawValue])
            return nil
        }
    }

    private func removeObservers() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    private func restoreActivation() {
        // Only hand activation back if Vervellum is still the active app — i.e. the
        // panel was dismissed by Escape or the shortcut. If the user dismissed it by
        // clicking another app, that app is already frontmost.
        guard NSApp.isActive else {
            appToRestoreOnClose = nil
            hadRestoreTarget = false
            return
        }
        if let restore = appToRestoreOnClose, !restore.isTerminated {
            yieldActivation(to: restore)
        } else if hadRestoreTarget {
            // The remembered app quit while the panel was open. With nothing to hand
            // focus back to, Vervellum — an agent with no menu bar of its own — would
            // be left "frontmost" with no windows; fall back to the Finder.
            if let finder = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.finder").first {
                yieldActivation(to: finder)
            }
        }
        appToRestoreOnClose = nil
        hadRestoreTarget = false
    }
}
