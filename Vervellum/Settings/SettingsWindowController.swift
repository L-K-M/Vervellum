import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the Settings window closes, so the panel can re-read anything that
    /// might have changed — chiefly whether the providers are configured, which needs a
    /// Keychain hit and so is sampled rather than computed.
    static let vervellumSettingsDidClose = Notification.Name("VervellumSettingsDidCloseNotification")
    /// Raised by the General pane to put the panel on screen (or take it away) while
    /// the panel settings are being adjusted. Carries a `Bool` in `userInfo["previewing"]`.
    ///
    /// A notification rather than a closure threaded through `SettingsView`: the pane
    /// that raises it is three `TabView` levels below the window controller, and the
    /// object that can act on it — `AppDelegate`, which owns the panel — is above both.
    static let vervellumPanelPreviewChanged = Notification.Name("VervellumPanelPreviewChangedNotification")
}

/// Hosts the SwiftUI settings in a standard titled window.
///
/// An `.accessory` app has no menu bar and no `Settings` scene, so the window is
/// presented on demand — and the app switches to `.regular` while it is open, because
/// a window that cannot take focus is a window whose text fields cannot be typed in.
/// It reverts to `.accessory` on close so the Dock icon does not linger.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let preferences: Preferences
    private let store: ThreadStore
    private let updateChecker: UpdateChecker
    private let onShortcutsChanged: () -> Void

    private weak var appToRestoreOnClose: NSRunningApplication?

    init(preferences: Preferences,
         store: ThreadStore,
         updateChecker: UpdateChecker,
         onShortcutsChanged: @escaping () -> Void) {
        self.preferences = preferences
        self.store = store
        self.updateChecker = updateChecker
        self.onShortcutsChanged = onShortcutsChanged
    }

    /// Opens the window. `remembered` is the application the panel was going to hand
    /// focus back to; when Settings is opened from the panel it takes over that duty,
    /// because by then the panel has been dismissed and Vervellum itself is frontmost.
    func show(restoring remembered: NSRunningApplication? = nil) {
        if let remembered {
            appToRestoreOnClose = remembered
        } else if NSApp.activationPolicy() != .regular {
            let frontmost = NSWorkspace.shared.frontmostApplication
            appToRestoreOnClose = frontmost?.processIdentifier
                == NSRunningApplication.current.processIdentifier ? nil : frontmost
        }

        if window == nil {
            let root = SettingsView(preferences: preferences,
                                    store: store,
                                    updateChecker: updateChecker,
                                    onShortcutsChanged: onShortcutsChanged)
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.minSize]

            let window = NSWindow(contentViewController: hosting)
            window.title = "Vervellum Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 520))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("VervellumSettingsWindow")
            self.window = window
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Ordering a miniaturized window front does not deminiaturize it — "Settings…"
        // would appear to do nothing while the window sat in the Dock.
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Take the preview panel back before anything else: it was put up by this
        // window, and a preview left floating after Settings closed would look like a
        // panel that had summoned itself.
        NotificationCenter.default.post(name: .vervellumPanelPreviewChanged, object: nil,
                                        userInfo: ["previewing": false])
        NotificationCenter.default.post(name: .vervellumSettingsDidClose, object: nil)
        let restore = appToRestoreOnClose
        appToRestoreOnClose = nil
        NSApp.revertToAccessoryIfNoOrdinaryWindows(excluding: window)
        if let restore, !restore.isTerminated {
            NSApp.yieldActivation(to: restore)
            restore.activate(options: [.activateAllWindows])
        }
    }
}
