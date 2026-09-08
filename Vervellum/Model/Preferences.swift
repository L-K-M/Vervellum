import Foundation
import SwiftUI
import ServiceManagement

/// User-facing settings for the macOS app.
///
/// The settings both platforms share — the provider endpoints, history, the process
/// trail, submit-on-Return, redaction, text scale — live in `CorePreferences`, together
/// with their defaults and clamping, so a change to a shared default reaches Linux too.
/// This class adds the ones that only exist here (the panel's edge, size and dismissal
/// behaviour, the two global shortcuts, the login item) and republishes the lot to
/// SwiftUI.
///
/// Every numeric value is clamped **on read as well as on write**: a preferences file
/// corrupted by a crash, an interrupted sync, or a hand edit must not be able to produce
/// a zero-width panel the user can neither see nor fix.
///
/// Secrets are deliberately absent — API keys live in the Keychain (`KeychainStore`),
/// never here, because this file is plain text in the user's preferences folder.
final class Preferences: ObservableObject {

    static let shared = Preferences()

    /// The settings shared with the Linux build.
    let core: CorePreferences

    /// Invoked after any setting has been written, with the new value already stored.
    ///
    /// Distinct from `objectWillChange`, and that is the whole point: `objectWillChange`
    /// fires *before* the write, so a subscriber that read a value from it would get the
    /// old one. The panel has to re-place itself from the *new* width the moment the
    /// slider moves, so it needs a hook on the other side of the store.
    var onChanged: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        core = CorePreferences(store: UserDefaultsSettingsStore(defaults: defaults))
        // `CorePreferences.onChange` already fires after its write, so it can drive both
        // halves: the SwiftUI republish and the after-the-fact notification.
        core.onChange = { [weak self] in
            self?.objectWillChange.send()
            self?.onChanged?()
        }
    }

    // MARK: macOS-only defaults

    enum Default {
        static let summonHotkey = HotkeyBinding.defaultSummon
        static let researchSelectionHotkey = HotkeyBinding.defaultResearchSelection
        static let panelSide = PanelSide.trailing
        static let panelWidth = PanelPlacement.defaultWidth
        static let panelHeight = PanelPlacement.defaultCenteredHeight
        /// Off by design. A research run takes tens of seconds and the answer is meant
        /// to be read while working; dismissing on click-away would throw the result
        /// away at the exact moment it became useful.
        static let dismissOnFocusLoss = false
        static let launchAtLogin = false
    }

    private enum Key {
        static let summonHotkey = "summonHotkey"
        static let researchSelectionHotkey = "researchSelectionHotkey"
        static let panelSide = "panelSide"
        static let panelWidth = "panelWidth"
        static let panelHeight = "panelHeight"
        static let dismissOnFocusLoss = "dismissOnFocusLoss"
    }

    // MARK: Shared settings, forwarded

    var providerSettings: ProviderSettings {
        get { core.providerSettings }
        set { core.providerSettings = newValue }
    }

    var historyEnabled: Bool {
        get { core.historyEnabled }
        set { core.historyEnabled = newValue }
    }

    /// How the panel looks. See `PanelPalette`.
    var panelPalette: PanelPalette {
        get { core.panelPalette }
        set { core.panelPalette = newValue }
    }

    var showProcessTrail: Bool {
        get { core.showProcessTrail }
        set { core.showProcessTrail = newValue }
    }

    var submitOnReturn: Bool {
        get { core.submitOnReturn }
        set { core.submitOnReturn = newValue }
    }

    var redactSecrets: Bool {
        get { core.redactSecrets }
        set { core.redactSecrets = newValue }
    }

    /// Body-text scale for the thread, 0.85–1.4.
    var textScale: Double {
        get { core.textScale }
        set { core.textScale = newValue }
    }

    // MARK: Shortcuts

    var summonHotkey: HotkeyBinding {
        get { HotkeyBinding.decode(defaults.string(forKey: Key.summonHotkey), fallback: Default.summonHotkey) }
        set { set(newValue.jsonString, Key.summonHotkey) }
    }

    var researchSelectionHotkey: HotkeyBinding {
        get {
            HotkeyBinding.decode(defaults.string(forKey: Key.researchSelectionHotkey),
                                 fallback: Default.researchSelectionHotkey)
        }
        set { set(newValue.jsonString, Key.researchSelectionHotkey) }
    }

    // MARK: Panel

    var panelSide: PanelSide {
        get {
            guard let raw = defaults.string(forKey: Key.panelSide),
                  let side = PanelSide(rawValue: raw) else { return Default.panelSide }
            return side
        }
        set { set(newValue.rawValue, Key.panelSide) }
    }

    var panelWidth: CGFloat {
        get {
            CGFloat(CorePreferences.clamped(
                defaults.object(forKey: Key.panelWidth) as? Double, Double(Default.panelWidth),
                Double(PanelPlacement.minimumWidth)...Double(PanelPlacement.maximumWidth)))
        }
        set {
            setNumber(CorePreferences.clamp(
                Double(newValue),
                Double(PanelPlacement.minimumWidth)...Double(PanelPlacement.maximumWidth)),
                      Key.panelWidth)
        }
    }

    var panelHeight: CGFloat {
        get {
            CGFloat(CorePreferences.clamped(
                defaults.object(forKey: Key.panelHeight) as? Double, Double(Default.panelHeight),
                Double(PanelPlacement.minimumHeight)...2000))
        }
        set {
            setNumber(CorePreferences.clamp(Double(newValue),
                                            Double(PanelPlacement.minimumHeight)...2000),
                      Key.panelHeight)
        }
    }

    var dismissOnFocusLoss: Bool {
        get { defaults.object(forKey: Key.dismissOnFocusLoss) as? Bool ?? Default.dismissOnFocusLoss }
        set { set(newValue, Key.dismissOnFocusLoss) }
    }

    // MARK: Launch at login

    /// Mirrors `SMAppService`'s own state rather than a stored flag, so a login item the
    /// user removed in System Settings is reflected here instead of the toggle lying
    /// about it.
    ///
    /// Anything other than `.enabled` counts as off. `.requiresApproval` — what you get
    /// when the user switches the item off in System Settings — is deliberately *not*
    /// treated as "on but pending", because re-registering behind the user's back is
    /// exactly the behaviour that gets an app distrusted.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    // `register()` throws `kSMErrorAlreadyRegistered` if it is already on.
                    if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                } else {
                    if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                }
            } catch {
                // Never the provider of a user-facing string: this is a system error, and
                // the toggle re-reads the real status on the next redraw anyway.
                NSLog("Vervellum: could not change the login item (status "
                      + "\(SMAppService.mainApp.status.rawValue))")
            }
            onChanged?()
        }
    }

    // MARK: Storage helpers

    private func set(_ value: Bool, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        onChanged?()
    }

    private func set(_ value: String, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        onChanged?()
    }

    /// One numeric setter only: `CGFloat` and `Double` convert implicitly in Swift, so
    /// an overload for each would be ambiguous at every call site.
    private func setNumber(_ value: Double, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        onChanged?()
    }
}

/// Backs `CorePreferences` with `UserDefaults` on macOS.
///
/// A class because `SettingsStore` is `AnyObject`-constrained: the Linux
/// implementation caches its file in memory and needs reference semantics, and the
/// protocol is shared.
final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func string(for key: String) -> String? { defaults.string(forKey: key) }
    func double(for key: String) -> Double? { defaults.object(forKey: key) as? Double }
    func bool(for key: String) -> Bool? { defaults.object(forKey: key) as? Bool }

    func setString(_ value: String?, for key: String) { defaults.set(value, forKey: key) }
    func setDouble(_ value: Double?, for key: String) { defaults.set(value, forKey: key) }
    func setBool(_ value: Bool?, for key: String) { defaults.set(value, forKey: key) }
}
