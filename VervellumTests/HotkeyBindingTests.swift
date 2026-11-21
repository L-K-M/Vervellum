import XCTest
import AppKit
import Carbon.HIToolbox
import KeycapCore
import KeycapKit
@testable import Vervellum

final class HotkeyBindingTests: XCTestCase {

    func testDefaultsAreValidAndDisplayCorrectly() {
        XCTAssertTrue(HotkeyBinding.defaultSummon.isValid)
        XCTAssertEqual(HotkeyBinding.defaultSummon.displayString, "⌃⌥⌘Space")
        XCTAssertEqual(HotkeyBinding.defaultResearchSelection.displayString, "⌃⌥⌘J")
    }

    /// The selection shortcut is the only feature needing Accessibility, so it is
    /// off until the user opts in.
    func testTheSelectionShortcutIsDisabledByDefault() {
        XCTAssertFalse(HotkeyBinding.defaultResearchSelection.enabled)
        XCTAssertFalse(HotkeyBinding.defaultResearchSelection.isValid)
    }

    func testModifierSymbolsAreInCanonicalOrder() {
        let binding = HotkeyBinding(keyCode: 0,
                                    modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey),
                                    keyLabel: "A", enabled: true)
        XCTAssertEqual(binding.modifierSymbols, "⌃⌥⇧⌘")
    }

    /// A disabled binding is never registerable, and so is a bare or Shift-only
    /// key: Shift-A is ordinary text and must not be captured system-wide.
    func testIsInvalidWithoutUsableModifiersOrWhenDisabled() {
        XCTAssertFalse(HotkeyBinding(keyCode: 1, modifiers: 0, keyLabel: "S", enabled: true).isValid)
        XCTAssertFalse(HotkeyBinding(keyCode: 2, modifiers: UInt32(cmdKey),
                                     keyLabel: "D", enabled: false).isValid)

        let shifted = HotkeyBinding(keyCode: 0, modifiers: UInt32(shiftKey),
                                    keyLabel: "A", enabled: true)
        XCTAssertFalse(shifted.isValid)

        let alphaLock = HotkeyBinding(keyCode: 0, modifiers: UInt32(alphaLock),
                                      keyLabel: "A", enabled: true)
        XCTAssertFalse(alphaLock.isValid)
    }

    /// Keycap's family rule: the OS-owned ⌘Q/W/H/M/Space/Tab and ⇧⌘3–6 are
    /// refused, so a registration cannot swallow them. Adding ⌥ or ⌃ makes the
    /// same key usable.
    func testReservedCombosAreRefused() {
        let command = UInt32(cmdKey)
        for keyCode in [KeyCode.q, KeyCode.w, KeyCode.h, KeyCode.m, KeyCode.space, KeyCode.tab] {
            XCTAssertFalse(HotkeyBinding(keyCode: keyCode, modifiers: command,
                                         keyLabel: "X", enabled: true).isValid,
                           "⌘\(keyCode) should be refused")
            XCTAssertTrue(HotkeyBinding(keyCode: keyCode, modifiers: command | UInt32(optionKey),
                                        keyLabel: "X", enabled: true).isValid,
                          "⌥⌘\(keyCode) should be usable")
            XCTAssertTrue(HotkeyBinding(keyCode: keyCode, modifiers: command | UInt32(controlKey),
                                        keyLabel: "X", enabled: true).isValid,
                          "⌃⌘\(keyCode) should be usable")
        }
        for keyCode in [KeyCode.three, KeyCode.four, KeyCode.five, KeyCode.six] {
            XCTAssertFalse(HotkeyBinding(keyCode: keyCode,
                                         modifiers: command | UInt32(shiftKey),
                                         keyLabel: "X", enabled: true).isValid,
                           "⇧⌘\(keyCode) should be refused")
            XCTAssertTrue(HotkeyBinding(keyCode: keyCode,
                                        modifiers: command | UInt32(shiftKey | optionKey),
                                        keyLabel: "X", enabled: true).isValid,
                          "⌥⇧⌘\(keyCode) should be usable")
        }
    }

    /// Bare function keys are the classic launcher shortcut and never collide
    /// with typing, so they are usable without a modifier.
    func testBareFunctionKeysAreUsable() {
        XCTAssertTrue(HotkeyBinding(keyCode: KeyCode.f5, modifiers: 0,
                                    keyLabel: "F5", enabled: true).isValid)
        XCTAssertTrue(HotkeyBinding(keyCode: KeyCode.f12, modifiers: UInt32(shiftKey),
                                    keyLabel: "F12", enabled: true).isValid)
    }

    /// A shortcut saved before Keycap stored the label its own recorder captured,
    /// which differs from the name Keycap's recorder shows for the same key code:
    /// keypad Enter was `↩` rather than `⌅`, and non-printing keys fell back to
    /// `Key <code>` rather than `F5`/`Help`/`⌧`. The hint must show what the
    /// recorder shows, or the two surfaces disagree for a shortcut the user never
    /// re-recorded.
    func testOldSavedLabelsDisplayAsTheRecorderNamesThem() {
        let modifiers = UInt32(cmdKey | optionKey)
        let oldFallback = { (keyCode: UInt32) in "Key \(keyCode)" }
        let cases: [(keyCode: UInt32, oldLabel: String, recorderName: String)] = [
            (KeyCode.keypadEnter, "↩", "⌅"),
            (KeyCode.f5, oldFallback(KeyCode.f5), "F5"),
            (KeyCode.help, oldFallback(KeyCode.help), "Help"),
            (KeyCode.keypadClear, oldFallback(KeyCode.keypadClear), "⌧"),
        ]

        for old in cases {
            let stored = HotkeyBinding(keyCode: old.keyCode, modifiers: modifiers,
                                       keyLabel: old.oldLabel, enabled: true)
            let decoded = HotkeyBinding.decode(stored.jsonString, fallback: .defaultSummon)

            // The stored label survives untouched; only the display follows the
            // recorder's name.
            XCTAssertEqual(decoded, stored)
            XCTAssertEqual(decoded.combo.displayString, "⌥⌘\(old.recorderName)")
            XCTAssertEqual(decoded.displayString, decoded.combo.displayString,
                           "hint and recorder must agree for saved label \(old.oldLabel)")
        }
    }

    /// The recorder names a letter by the current keyboard layout. The hint must
    /// use that same layout-aware name rather than flattening it to the ANSI
    /// position, so a letter label still matches the recorder.
    func testALetterSavedWithItsLayoutCharacterStillMatchesTheRecorder() {
        let layoutName = KeyNames.displayName(for: KeyCode.z)
        let stored = HotkeyBinding(keyCode: KeyCode.z,
                                   modifiers: UInt32(cmdKey | optionKey),
                                   keyLabel: layoutName, enabled: true)
        XCTAssertEqual(stored.displayString, stored.combo.displayString)
        XCTAssertTrue(stored.displayString.hasSuffix(layoutName))
    }

    /// The recorder converts at the boundary: a binding's combo carries the same
    /// key code and Carbon bits, and rebuilding from it round-trips.
    func testKeyComboConversionRoundTrips() {
        let original = HotkeyBinding(keyCode: 49, modifiers: UInt32(cmdKey | optionKey),
                                     keyLabel: "Space", enabled: true)
        let combo = original.combo
        XCTAssertEqual(combo.keyCode, 49)
        XCTAssertEqual(combo.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(HotkeyBinding(combo: combo, keyLabel: original.keyLabel,
                                     enabled: original.enabled),
                       original)
    }

    /// Only the four Carbon hotkey bits are part of a registration; caps lock is
    /// dropped on the way into a combo.
    func testComboDropsNonHotkeyModifierBits() {
        let binding = HotkeyBinding(keyCode: 49, modifiers: UInt32(cmdKey | alphaLock),
                                    keyLabel: "Space", enabled: true)
        XCTAssertEqual(binding.combo.carbonModifiers, UInt32(cmdKey))
    }

    func testJSONRoundTrip() {
        let original = HotkeyBinding(keyCode: 49, modifiers: UInt32(cmdKey | optionKey),
                                     keyLabel: "Space", enabled: true)
        XCTAssertEqual(HotkeyBinding.decode(original.jsonString, fallback: .defaultSummon), original)
    }

    func testDecodeFallsBackOnGarbage() {
        XCTAssertEqual(HotkeyBinding.decode("not json", fallback: .defaultSummon), .defaultSummon)
        XCTAssertEqual(HotkeyBinding.decode(nil, fallback: .defaultSummon), .defaultSummon)
    }

    func testCarbonModifiersMapping() {
        let modifiers = HotkeyModifiers(carbonFlags: UInt32(cmdKey | shiftKey | alphaLock))
        XCTAssertTrue(modifiers.contains(.command))
        XCTAssertTrue(modifiers.contains(.shift))
        XCTAssertFalse(modifiers.contains(.control))
        XCTAssertFalse(modifiers.contains(.option))
    }

    /// A global ⌘C would swallow Copy in every app on the Mac, and ⇧⌘Z is
    /// redo. Vervellum refuses the editing family even though Keycap's own
    /// rule accepts it; adding ⌥ or ⌃ makes a chord no editor binds.
    func testEditingChordsAreRefused() {
        let command = UInt32(cmdKey)
        for keyCode in [KeyCode.a, KeyCode.c, KeyCode.v, KeyCode.x, KeyCode.z] {
            for modifiers in [command, command | UInt32(shiftKey)] {
                let binding = HotkeyBinding(keyCode: keyCode, modifiers: modifiers,
                                            keyLabel: "X", enabled: true)
                XCTAssertFalse(binding.isValid, "\(modifiers) \(keyCode) should be refused")
                XCTAssertTrue(binding.isProtectedEditingShortcut)
                XCTAssertNotNil(binding.registrationProblem)
            }
            XCTAssertTrue(HotkeyBinding(keyCode: keyCode,
                                        modifiers: command | UInt32(optionKey),
                                        keyLabel: "X", enabled: true).isValid,
                          "⌥⌘\(keyCode) is not an editing chord")
            XCTAssertTrue(HotkeyBinding(keyCode: keyCode,
                                        modifiers: command | UInt32(controlKey),
                                        keyLabel: "X", enabled: true).isValid,
                          "⌃⌘\(keyCode) is not an editing chord")
        }
    }

    /// Option and Option-Shift are how accented and alternate characters are
    /// typed, so a global registration on them would eat text composition
    /// everywhere. Function keys and Command/Control combinations are safe.
    func testOptionOnlyCharacterChordsAreRefused() {
        let option = UInt32(optionKey)
        for modifiers in [option, option | UInt32(shiftKey)] {
            let binding = HotkeyBinding(keyCode: KeyCode.c, modifiers: modifiers,
                                        keyLabel: "C", enabled: true)
            XCTAssertFalse(binding.isValid)
            XCTAssertTrue(binding.isOptionOnlyCharacterShortcut)
            XCTAssertNotNil(binding.registrationProblem)
        }
        XCTAssertTrue(HotkeyBinding(keyCode: KeyCode.f12, modifiers: option,
                                    keyLabel: "F12", enabled: true).isValid,
                      "⌥F12 does not type a character")
        XCTAssertFalse(HotkeyBinding(keyCode: KeyCode.leftArrow, modifiers: option,
                                     keyLabel: "←", enabled: true).isValid,
                       "⌥← is word-wise navigation, not a command")
        XCTAssertTrue(HotkeyBinding(keyCode: KeyCode.c,
                                    modifiers: option | UInt32(cmdKey),
                                    keyLabel: "C", enabled: true).isValid,
                      "⌥⌘C is not a typing chord")
        XCTAssertTrue(HotkeyBinding(keyCode: KeyCode.leftArrow,
                                    modifiers: option | UInt32(cmdKey),
                                    keyLabel: "←", enabled: true).isValid,
                      "⌥⌘← is not a typing chord")
    }

    /// The property that refuses a chord and the sentence the pane shows for it are
    /// derived from one rule set; this table pins the mirror property in both
    /// directions across the modifier families and the keys the policy names.
    func testRegistrationProblemAndValidityAlwaysAgree() {
        let modifiers: [UInt32] = [
            UInt32(0), UInt32(cmdKey), UInt32(cmdKey | shiftKey),
            UInt32(optionKey), UInt32(optionKey | shiftKey),
            UInt32(optionKey | cmdKey), UInt32(controlKey | cmdKey),
        ]
        let keys: [UInt32] = [KeyCode.a, KeyCode.c, KeyCode.v, KeyCode.x, KeyCode.z,
                              KeyCode.f12, KeyCode.leftArrow]

        // A bare key is the one refusal family the mirror alone cannot speak
        // for: with no modifiers it is ordinary typing, so both properties
        // must refuse it.
        let bare = HotkeyBinding(keyCode: KeyCode.a, modifiers: 0,
                                 keyLabel: "A", enabled: true)
        XCTAssertFalse(bare.isValid)
        XCTAssertNotNil(bare.registrationProblem)

        // Ground truth for the named refusal families, independent of the
        // mirror below: these catch a classification rule regressing, which a
        // comparison against `registrationProblem` cannot.
        let groundTruth: [(modifiers: UInt32, key: UInt32, expectedValid: Bool)] = [
            (UInt32(cmdKey), KeyCode.c, false),              // ⌘C is a system editing chord
            (UInt32(shiftKey), KeyCode.a, false),            // ⇧A is ordinary typing
            (UInt32(optionKey), KeyCode.c, false),           // ⌥C types a character
            (UInt32(controlKey | cmdKey), KeyCode.c, true),  // ⌃⌘C collides with nothing
            (UInt32(0), KeyCode.f12, true),                  // bare F-key stays registerable
        ]
        for (modifier, key, expectedValid) in groundTruth {
            let binding = HotkeyBinding(keyCode: key, modifiers: modifier,
                                        keyLabel: "X", enabled: true)
            XCTAssertEqual(binding.isValid, expectedValid,
                           "classification changed for modifiers=\(modifier), key=\(key)")
        }

        for enabled in [true, false] {
            for modifier in modifiers {
                for key in keys {
                    let binding = HotkeyBinding(keyCode: key, modifiers: modifier,
                                                keyLabel: "X", enabled: enabled)
                    XCTAssertEqual(binding.isValid,
                                   enabled && binding.registrationProblem == nil,
                                   "validity disagrees for enabled=\(enabled), "
                                   + "modifiers=\(modifier), key=\(key)")
                }
            }
        }
    }

    /// A binding saved before this policy existed is still refused on the next
    /// launch, and the pane's warning names the reason rather than silently
    /// reporting success.
    func testAStoredEditingChordStaysRefused() {
        let stored = HotkeyBinding(keyCode: KeyCode.c, modifiers: UInt32(cmdKey),
                                   keyLabel: "C", enabled: true)
        let decoded = HotkeyBinding.decode(stored.jsonString, fallback: .defaultSummon)
        XCTAssertFalse(decoded.isValid)
        XCTAssertTrue(decoded.registrationProblem?.contains("editing shortcut") ?? false)
    }
}
