import Carbon.HIToolbox

/// Virtual key codes used by Vervellum's global shortcuts and panel key handling
/// (US layout, position-based — the *label* shown to the user is captured from the
/// event at record time, so a non-US layout still displays the right key).
enum KeyCode {
    static let escape: UInt32 = UInt32(kVK_Escape)          // 53
    static let `return`: UInt32 = UInt32(kVK_Return)        // 36
    static let keypadEnter: UInt32 = UInt32(kVK_ANSI_KeypadEnter) // 76
}
