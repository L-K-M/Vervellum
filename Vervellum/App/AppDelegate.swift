import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    /// Carries text that should be dropped into the composer, in `userInfo["text"]`.
    /// Used by the research-the-selection shortcut.
    static let vervellumSeedComposer = Notification.Name("VervellumSeedComposerNotification")
}

/// Wires the app together and owns everything with a lifetime.
///
/// Vervellum has no windows at launch and no Dock icon, so this is the only object
/// that outlives a user interaction: it holds the preferences, the thread store, the
/// research engine, the panel, the status item and the two global shortcuts, and it
/// is what re-registers a shortcut when the user changes one.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences.shared
    private let secrets: SecretStore = KeychainStore()
    private lazy var store = ThreadStore(historyEnabled: preferences.historyEnabled)
    private lazy var engine = ResearchEngine(preferences: preferences.core, secrets: secrets)
    private lazy var updateChecker = UpdateChecker(
        configuration: .init(owner: "L-K-M", repo: "Vervellum"))

    /// Built in `applicationDidFinishLaunching` rather than lazily: its root-view
    /// closure needs to reference the controller itself (to close the panel), which a
    /// lazy property cannot do from inside its own initializer.
    private var panelController: PanelController?
    private var settingsWindow: SettingsWindowController?

    private let summonHotkey = CarbonHotkey(identifier: 1)
    private let selectionHotkey = CarbonHotkey(identifier: 2)
    private var statusItem: NSStatusItem?
    private var runningObserver: AnyCancellable?
    /// Tracks the last run state so a completion — not the publisher's initial
    /// emission — can be told apart from it.
    private var wasRunning = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under XCTest the app is loaded as the test host. Registering global
        // shortcuts, adding a status item, and reading the user's real preferences
        // from a unit-test process would be both wrong and flaky.
        guard !Self.isRunningTests else { return }

        engine.onThreadChanged = { [weak self] thread in
            self?.store.save(thread)
        }

        let panelController = makePanelController()
        self.panelController = panelController
        self.settingsWindow = SettingsWindowController(
            preferences: preferences,
            store: store,
            updateChecker: updateChecker,
            onShortcutsChanged: { [weak self] in self?.registerHotkeys() })

        installMainMenu()
        installStatusItem()
        registerHotkeys()
        updateChecker.start()
        observeRunningState()

        // First launch has no keys, so the panel is the only place the user can find
        // out what is missing — show it once rather than leaving a silent menu-bar icon.
        if preferences.providerSettings.modelEndpoint.isEmpty {
            panelController.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
        summonHotkey.unregister()
        selectionHotkey.unregister()
    }

    /// The app has no windows to restore, so a re-open should summon the panel rather
    /// than doing nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        return true
    }

    // MARK: Panel

    private func makePanelController() -> PanelController {
        let controller = PanelController(preferences: preferences) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(PanelRootView(
                engine: self.engine,
                store: self.store,
                preferences: self.preferences,
                onOpenSettings: { [weak self] in self?.settingsWindow?.show() },
                onClose: { [weak self] in self?.panelController?.hide() }))
        }
        controller.isBusy = { [weak self] in self?.engine.isRunning ?? false }
        // Dismissing the panel is the natural moment to make the thread durable: the
        // store debounces writes by a second, and the user may quit right after.
        controller.onDismiss = { [weak self] in self?.store.flush() }
        controller.selectionProvider = { SelectedTextReader.selectedText() }
        controller.onSeedComposer = { [weak self] text in
            // Redact before the text reaches the composer, not before it is sent: the
            // user must be able to see what will leave the Mac, and correct it, rather
            // than trust that something downstream will clean it up.
            guard self?.preferences.redactSecrets ?? true else {
                NotificationCenter.default.post(name: .vervellumSeedComposer,
                                                object: nil, userInfo: ["text": text])
                return
            }
            let result = SecretRedactor.redact(text)
            NotificationCenter.default.post(
                name: .vervellumSeedComposer, object: nil,
                userInfo: ["text": result.text, "redactions": result.redactionCount])
        }
        return controller
    }

    // MARK: Shortcuts

    /// (Re)registers both global shortcuts from the current preferences.
    ///
    /// A combination another app already owns cannot be registered, and Carbon
    /// reports that as a status code rather than an error — `CarbonHotkey.register`
    /// logs it and returns false so the failure is at least diagnosable instead of
    /// silently doing nothing.
    func registerHotkeys() {
        summonHotkey.onPressed = { [weak self] in self?.panelController?.toggle() }
        selectionHotkey.onPressed = { [weak self] in self?.summonWithSelection() }

        let summon = preferences.summonHotkey
        summonHotkey.unregister()
        if summon.isValid {
            summonHotkey.register(keyCode: summon.keyCode, modifiers: summon.modifiers)
        }

        let selection = preferences.researchSelectionHotkey
        selectionHotkey.unregister()
        if selection.isValid {
            selectionHotkey.register(keyCode: selection.keyCode, modifiers: selection.modifiers)
        }
    }

    /// Summons the panel seeded with the frontmost app's selection, or explains why
    /// it could not be.
    private func summonWithSelection() {
        guard SelectedTextReader.isAuthorized else {
            presentAccessibilityPrompt(wasRevoked: SelectedTextReader.grantWasRevoked())
            return
        }
        SelectedTextReader.rememberGrant()
        panelController?.showWithSelection()
    }

    /// Asks for Accessibility in words, before macOS shows its own prompt.
    ///
    /// The system prompt appears at most once per app per machine and says nothing
    /// about *why*. Explaining first — and offering the Settings pane for the common
    /// case where that one prompt was long ago dismissed — is the difference between
    /// a feature the user enables and one they assume is broken.
    private func presentAccessibilityPrompt(wasRevoked: Bool) {
        let alert = NSAlert()
        alert.messageText = wasRevoked
            ? "Vervellum's Accessibility permission was reset by the update"
            : "Vervellum needs Accessibility to read your selection"
        alert.informativeText = wasRevoked
            ? "macOS ties this permission to an app's code signature, and Vervellum's "
              + "release builds are ad-hoc signed — so the signature changes with every "
              + "update and the grant is dropped. Nothing is wrong with your Mac. Remove "
              + "Vervellum from the Accessibility list and add it again to restore "
              + "\"Research the Selection\".\n\nEvery other feature works without it."
            : "Researching the selected text means reading it from the app you were using, "
              + "which macOS gates behind Accessibility. Vervellum reads the selection only "
              + "when you press this shortcut, and does nothing else with the permission.\n\n"
              + "Every other feature works without it."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        NSApp.activate()
        // No level fiddling needed: the panel sits at `.floating` (3) and a modal
        // alert is at `.modalPanel` (8), so the alert is already above it. This is one
        // of the things choosing the lower panel level buys — at `.popUpMenu` (101) an
        // alert renders *behind* the panel as an invisible modal.
        if alert.runModal() == .alertFirstButtonReturn {
            SelectedTextReader.requestAuthorization()
            SelectedTextReader.openAccessibilitySettings()
        }
    }

    // MARK: Main menu

    /// Installs an App, Edit and Window menu so the standard key equivalents reach the
    /// first responder.
    ///
    /// An `LSUIElement` agent has no menu bar, and it is easy to conclude it therefore
    /// needs no menu. It does: AppKit routes ⌘C, ⌘V, ⌘A, ⌘Z and ⌘Q *through the main
    /// menu's items*, so without one every one of them is silently dead — in the
    /// composer and in every Settings text field. The bar itself stays hidden while the
    /// app is `.accessory`; only the key-equivalent routing matters.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // Settings… (⌘,) in the *main* menu so the shortcut routes app-wide — the
        // status-item copy only fires while that menu is open.
        let settings = appMenu.addItem(withTitle: "Vervellum Settings…",
                                       action: #selector(openSettingsMenuItem),
                                       keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Vervellum",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // No target: each action resolves through the responder chain to whichever
        // text view is first responder, which is the whole point.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSStandardKeyBindingResponding.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Close (⌘W) for the key window. A window's own `performKeyEquivalent` runs
        // before the main menu, and the research panel handles ⌘W there, so this item
        // only ever reaches Settings — which would otherwise beep.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.magnifyingglass",
                                     accessibilityDescription: "Vervellum")
        item.button?.image?.isTemplate = true
        item.menu = makeMenu()
        statusItem = item
    }

    /// Mirrors the run state in the menu bar, and closes the loop when the panel
    /// was dismissed mid-run: the status item shows a busy glyph while research is
    /// in flight, and a soft tick sounds when it finishes *with the panel closed*.
    /// A user watching the panel needs no sound; a user who closed it mid-run does.
    private func observeRunningState() {
        runningObserver = engine.$isRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                guard let self else { return }
                let finishedWhileHidden = self.wasRunning && !isRunning
                    && self.panelController?.isOpen == false
                self.wasRunning = isRunning
                let symbol = isRunning ? "hourglass" : "text.magnifyingglass"
                self.statusItem?.button?.image = NSImage(
                    systemSymbolName: symbol, accessibilityDescription: "Vervellum")
                self.statusItem?.button?.image?.isTemplate = true
                if finishedWhileHidden {
                    NSSound(named: NSSound.Name("Tink"))?.play()
                }
            }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, selector, key) in [
            ("Ask Vervellum…", #selector(summon), ""),
            ("Research the Selection", #selector(summonSelection), ""),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, selector, key) in [
            ("Vervellum Settings…", #selector(openSettingsMenuItem), ","),
            ("Check for Updates…", #selector(checkForUpdates), ""),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // No target: quit routes up the responder chain to NSApp, the way every
        // menu-bar agent's Quit item does.
        menu.addItem(NSMenuItem(title: "Quit Vervellum",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    @objc private func summon() { panelController?.show() }
    @objc private func summonSelection() { summonWithSelection() }
    @objc private func openSettingsMenuItem() { settingsWindow?.show() }
    @objc private func checkForUpdates() { updateChecker.checkNow() }

    // MARK: Helpers

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
