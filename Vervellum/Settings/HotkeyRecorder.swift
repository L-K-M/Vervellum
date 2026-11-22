import SwiftUI
import KeycapKit

/// A SwiftUI control that records a global shortcut into Vervellum's persisted
/// `HotkeyBinding`.
///
/// Keycap's `ShortcutRecorder` owns the recording rules: Escape cancels, a bare
/// ⌫ is a no-op (`HotkeyBinding` cannot express "no shortcut"), and a combo that
/// is not a usable global hotkey beeps and keeps recording. This wrapper is the
/// boundary: it converts to and from `KeyCombo` and keeps the stored JSON shape
/// and the `enabled` flag. A new recording stores the label resolved by Keycap.
struct HotkeyRecorder: View {
    @Binding var binding: HotkeyBinding

    var body: some View {
        ShortcutRecorder(
            combo: Binding(
                get: { binding.combo },
                set: { newCombo in
                    // `.ignore` means a delete never arrives here; a real recording
                    // always carries a combo.
                    guard let newCombo else { return }
                    var updated = binding
                    updated.keyCode = newCombo.keyCode
                    updated.modifiers = newCombo.carbonModifiers
                    updated.keyLabel = KeyNames.displayName(for: newCombo.keyCode)
                    binding = updated
                }),
            deleteAction: .ignore,
            placeholder: "Click to record",
            recordingPrompt: "Type shortcut…")
    }
}
