import Carbon.HIToolbox
import KeycapKit

/// A user-configurable global hotkey: a virtual key code plus Carbon modifier
/// flags, an on/off switch, and a human label captured at record time.
/// Persisted as JSON in `UserDefaults`; registered via `CarbonHotkey` (which needs
/// no permission). See PLAN.md §5.
///
/// The combo is converted to and from Keycap's `KeyCombo` at the recorder
/// boundary; the persisted shape is Vervellum's own and must not change.
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier-flag bits (`cmdKey | optionKey | …`).
    var modifiers: UInt32
    /// The label captured at record time, preserved in JSON for older builds.
    var keyLabel: String
    var enabled: Bool

    /// The persisted values as Keycap's combo. `HotkeyModifiers(carbonFlags:)`
    /// keeps only the four Carbon hotkey bits; caps lock and the other Cocoa
    /// flags were never part of a `RegisterEventHotKey` registration.
    var combo: KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: HotkeyModifiers(carbonFlags: modifiers))
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String, enabled: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
        self.enabled = enabled
    }

    /// Builds a binding from a Keycap combo, preserving the stored label and flag.
    init(combo: KeyCombo, keyLabel: String, enabled: Bool) {
        self.init(keyCode: combo.keyCode, modifiers: combo.carbonModifiers,
                  keyLabel: keyLabel, enabled: enabled)
    }

    /// Registerable only when enabled and a usable global hotkey. Keycap's family
    /// rule refuses the OS-owned ⌘Q/W/H/M/Space/Tab (and ⇧⌘3–6) so a registration
    /// cannot swallow them, and accepts bare F1–F20 because function keys do not
    /// collide with typing. A Shift-only chord is still ordinary text.
    /// Vervellum adds one rule of its own on top of Keycap's, because a global
    /// hotkey is registered with Carbon for the whole system rather than for this
    /// app: an editing command would be swallowed everywhere, not only while the
    /// panel is open.
    ///
    /// Option-only chords stay allowed, though some of them type a character. They
    /// are common summon shortcuts (⌥Space), and refusing them would switch off
    /// shortcuts people already have saved, with a warning only Settings shows.
    ///
    /// Derived from `registrationProblem` rather than re-listing the rules, so the
    /// property that refuses a chord and the sentence the Shortcuts pane shows for
    /// it cannot drift apart.
    var isValid: Bool { enabled && registrationProblem == nil }

    /// Command (+ optional Shift) on a key every editor binds for editing.
    ///
    /// ⌘C/V/X/A/Z and their ⇧ variants (⇧⌘Z redo, ⇧⌘V paste-and-match-style) are
    /// the chords a global registration would take away from every text field on
    /// the Mac. Adding ⌥ or ⌃ makes a different chord that no editor binds, so
    /// those stay allowed.
    private static let protectedEditingKeys: Set<UInt32> = [
        KeyCode.a, KeyCode.c, KeyCode.v, KeyCode.x, KeyCode.z,
    ]

    /// Whether this binding is a global version of a system editing command.
    var isProtectedEditingShortcut: Bool {
        let modifiers = combo.modifiers
        guard modifiers.contains(.command),
              modifiers.intersection([.option, .control]).isEmpty
        else { return false }
        return Self.protectedEditingKeys.contains(keyCode)
    }

    /// Why this binding cannot be registered, in words the Shortcuts pane can
    /// show; nil when it can be registered. The recorder is Keycap's, so it
    /// accepts a combo this property refuses — the warning beside it is what
    /// keeps that honest, and `isValid` is what keeps the chord off the system.
    var registrationProblem: String? {
        guard enabled else { return nil }
        if isProtectedEditingShortcut {
            return "\(displayString) is a system editing shortcut, so Vervellum doesn't "
                + "register it globally. Record a different one."
        }
        if !combo.isUsableGlobalHotkey {
            return "\(displayString) can't be used as a global shortcut, so Vervellum "
                + "doesn't register it. Record a new one."
        }
        return nil
    }

    /// The modifier glyphs in canonical macOS order (⌃⌥⇧⌘).
    var modifierSymbols: String { combo.modifiers.symbols }

    /// Uses the recorder's key naming so the panel hint matches it.
    var displayString: String { combo.displayString }

    // MARK: Persistence

    /// Decodes a binding from its stored JSON string, or returns `fallback`.
    static func decode(_ json: String?, fallback: HotkeyBinding) -> HotkeyBinding {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(HotkeyBinding.self, from: data) else { return fallback }
        return value
    }

    /// Encodes the binding to a JSON string for `UserDefaults`.
    var jsonString: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Defaults

    /// Summon / dismiss the research panel. ⌃⌥⌘Space — three modifiers, so it can't
    /// collide with Spotlight (⌘Space) or an input-source switch (⌃Space).
    static let defaultSummon = HotkeyBinding(keyCode: UInt32(kVK_Space),
                                             modifiers: UInt32(controlKey | optionKey | cmdKey),
                                             keyLabel: "Space", enabled: true)

    /// Summon the panel *and* seed the composer with the frontmost app's selected
    /// text. Off by default: it is the one path that needs Accessibility, so the
    /// user opts in from Settings ▸ Shortcuts rather than being prompted at launch.
    static let defaultResearchSelection = HotkeyBinding(keyCode: UInt32(kVK_ANSI_J),
                                                        modifiers: UInt32(controlKey | optionKey | cmdKey),
                                                        keyLabel: "J", enabled: false)
}
