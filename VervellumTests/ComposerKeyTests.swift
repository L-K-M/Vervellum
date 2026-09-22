import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// Stands in for the SwiftUI state the composer's draft is bound to.
///
/// At file scope rather than nested in the suite, so it takes on none of the suite's
/// main-actor isolation and a binding's closures can reach it from wherever SwiftUI
/// would call them.
private final class Draft {
    var text: String
    init(_ text: String) { self.text = text }
}

/// Which key sends a question and which one opens a line.
///
/// The composer owns both answers, and neither is AppKit's default. A modified Return
/// never fires a field's action, so nothing would send; and `NSTextView`'s own
/// `insertLineBreak:` inserts U+2028 LINE SEPARATOR rather than a newline, so the
/// character that reached the model would not be the one the user typed. Both fail
/// silently, which is what earns them a suite: the panel goes on looking like it works.
///
/// A modified Return arrives as one of several selectors, and which one is AppKit's
/// choice rather than Vervellum's: Option-Return is `insertNewlineIgnoringFieldEditor:`,
/// Control-Return is `insertLineBreak:`, and Shift-Return is `insertNewline:` — the
/// standard bindings carry no `$\r` at all, so it falls back to the plain-Return
/// selector and can only be told apart by the modifiers recorded on the way in.
/// The selectors are pinned here because the composer's promise is about the gesture,
/// and a binding that differs by keyboard layout or macOS version must not change
/// what the key does.
@MainActor
final class ComposerKeyTests: XCTestCase {

    /// A composer bound to `draft`, counting what it sends into `submissions`.
    private func coordinator(submitOnReturn: Bool,
                             draft: Draft,
                             submissions: @escaping () -> Void) -> ComposerView.Coordinator {
        ComposerView(text: Binding(get: { draft.text }, set: { draft.text = $0 }),
                     placeholder: "",
                     submitOnReturn: submitOnReturn,
                     onSubmit: submissions,
                     attachmentCount: 0,
                     onAttach: { _ in })
            .makeCoordinator()
    }

    /// A text view holding `text` with the caret at the end, where a question is typed
    /// from.
    private func field(holding text: String) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return textView
    }

    /// The point of the whole file — and the way the press actually arrives. The
    /// standard bindings have no `$\r`, so Shift-Return reaches `doCommandBy` as
    /// `insertNewline:`, the selector a plain Return sends; only the modifiers
    /// `interpretKeyEvents` stashed on `eventModifiers` keep it from asking.
    func testShiftReturnArrivesAsInsertNewlineAndBreaksALine() {
        let draft = Draft("a question")
        var sent = 0
        let composer = coordinator(submitOnReturn: true, draft: draft) { sent += 1 }
        let textView = field(holding: draft.text)
        composer.eventModifiers = .shift

        XCTAssertTrue(composer.textView(textView,
                                        doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(textView.string, "a question\n")
        XCTAssertEqual(sent, 0, "a modified Return never asks")
    }

    /// The same fallback under a different flag: an Option-Return that a custom
    /// `DefaultKeyBinding.dict` — or a layout whose bindings differ — sends to
    /// `insertNewline:` still opens a line. (`~\r` normally arrives as
    /// `insertNewlineIgnoringFieldEditor:`, pinned below.)
    func testOptionReturnViaInsertNewlineBreaksALine() {
        let draft = Draft("a question")
        var sent = 0
        let composer = coordinator(submitOnReturn: true, draft: draft) { sent += 1 }
        let textView = field(holding: draft.text)
        composer.eventModifiers = .option

        XCTAssertTrue(composer.textView(textView,
                                        doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(textView.string, "a question\n")
        XCTAssertEqual(sent, 0, "a modified Return never asks")
    }

    /// The modifiers beat the preference: under "Return inserts a newline" a
    /// Shift-Return still opens a line rather than asking — the chord for asking
    /// in that mode is ⌘Return, handled at the panel level.
    func testShiftReturnUnderTheInvertedPreferenceStillBreaksALine() {
        let draft = Draft("a question")
        var sent = 0
        let composer = coordinator(submitOnReturn: false, draft: draft) { sent += 1 }
        let textView = field(holding: draft.text)
        composer.eventModifiers = .shift

        XCTAssertTrue(composer.textView(textView,
                                        doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(textView.string, "a question\n")
        XCTAssertEqual(sent, 0, "a modified Return never asks")
    }

    /// The selector Shift-Return sends on a system whose bindings do define `$\r` —
    /// a `DefaultKeyBinding.dict`, or a macOS whose table differs. The composer takes
    /// the key rather than leaving it to the text view, and inserts a newline rather
    /// than the U+2028 LINE SEPARATOR `insertLineBreak:` would have produced.
    func testLineBreakSelectorEntersANewline() {
        let draft = Draft("a question")
        var sent = 0
        let composer = coordinator(submitOnReturn: true, draft: draft) { sent += 1 }
        let textView = field(holding: draft.text)

        XCTAssertTrue(composer.textView(textView,
                                        doCommandBy: #selector(NSResponder.insertLineBreak(_:))),
                      "the composer takes the key rather than leaving it to the text view")
        XCTAssertEqual(textView.string, "a question\n")
        XCTAssertEqual(sent, 0, "opening a line is not asking the question")
    }

    /// The whole claim, end to end: a real Shift-Return event through
    /// `interpretKeyEvents`, which resolves the binding itself rather than trusting
    /// this file's word for which selector arrives. `ComposerTextView` stashes the
    /// event's flags on the way in, and the answer must still be a newline — under
    /// the standard dictionary, with no `$\r`, the press falls back to
    /// `insertNewline:` and only the modifiers keep it from asking.
    func testARealShiftReturnEventBreaksALine() {
        let draft = Draft("a question")
        var sent = 0
        let composer = coordinator(submitOnReturn: true, draft: draft) { sent += 1 }
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
        textView.string = draft.text
        textView.setSelectedRange(NSRange(location: (draft.text as NSString).length, length: 0))
        textView.delegate = composer
        textView.coordinator = composer
        // In a window, though never shown: without one the view has no input
        // context, and `interpretKeyEvents` may resolve nothing at all.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = textView

        let shiftReturn = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: .shift, timestamp: 0,
                                           windowNumber: 0, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r",
                                           isARepeat: false, keyCode: UInt16(KeyCode.return))!
        textView.interpretKeyEvents([shiftReturn])

        XCTAssertEqual(textView.string, "a question\n")
        XCTAssertEqual(sent, 0, "a modified Return never asks")
        window.contentView = nil
    }

    /// Option-Return is the same gesture under a different selector.
    func testOptionReturnEntersANewlineToo() {
        let draft = Draft("a question")
        var sent = 0
        let composer = coordinator(submitOnReturn: true, draft: draft) { sent += 1 }
        let textView = field(holding: draft.text)

        let ignoringFieldEditor = #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        XCTAssertTrue(composer.textView(textView, doCommandBy: ignoringFieldEditor))
        XCTAssertEqual(textView.string, "a question\n")
        XCTAssertEqual(sent, 0)
    }

    /// The other half of the default: plain Return asks, and leaves the draft alone so a
    /// queued question is the text the user meant to send.
    func testPlainReturnAsksAndInsertsNothing() {
        let draft = Draft("a question")
        var sent = 0
        let composer = coordinator(submitOnReturn: true, draft: draft) { sent += 1 }
        let textView = field(holding: draft.text)

        XCTAssertTrue(composer.textView(textView,
                                        doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(textView.string, "a question")
        XCTAssertEqual(sent, 1)
    }

    /// With the preference inverted, plain Return is the newline — but Shift-Return is
    /// not the trade it used to be. The preference governs a bare Return only; a
    /// modified Return breaks a line either way, and ⌘⏎ (handled at the panel level,
    /// not here) is the key that asks. The old swap left this mode with no way to open
    /// a line at all, which is why it went.
    ///
    /// Plain Return is *declined* rather than handled, and the decline is the newline in
    /// that mode. So the handed-back key is pressed rather than left to the comment: the
    /// claim worth pinning is not that the composer stepped aside, it is that what lands
    /// when it does is a newline, which is the whole of what this mode offers.
    func testTheInvertedPreferenceMovesOnlyBareReturn() {
        let draft = Draft("a question")
        var sent = 0
        let composer = coordinator(submitOnReturn: false, draft: draft) { sent += 1 }
        let textView = field(holding: draft.text)

        XCTAssertFalse(composer.textView(textView,
                                         doCommandBy: #selector(NSResponder.insertNewline(_:))),
                       "declined, so the text view is left to insert this one itself")
        textView.insertNewline(textView)
        XCTAssertEqual(textView.string, "a question\n", "and what it inserts is a newline")
        XCTAssertEqual(sent, 0)

        XCTAssertTrue(composer.textView(textView,
                                        doCommandBy: #selector(NSResponder.insertLineBreak(_:))))
        XCTAssertEqual(textView.string, "a question\n\n",
                       "Shift-Return still opens a line — the preference never moves it")
        XCTAssertEqual(sent, 0, "nothing asks; ⌘Return carries that under this preference")
    }

    /// The two modified-Return selectors are one gesture rather than two, in either mode.
    ///
    /// Which of them a press arrives as is AppKit's business and can differ by keyboard
    /// layout and by macOS version, so the composer treats them identically — and both
    /// always insert a newline, whichever way the preference points. The
    /// submit-on-Return side of that is pinned a test above; this is the side that would
    /// otherwise be left to inference, and inference is what the pair exists to remove.
    func testBothModifiedReturnsBreakALineUnderTheInvertedPreference() {
        for selector in [#selector(NSResponder.insertLineBreak(_:)),
                         #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))] {
            let draft = Draft("a question")
            var sent = 0
            let composer = coordinator(submitOnReturn: false, draft: draft) { sent += 1 }
            let textView = field(holding: draft.text)

            XCTAssertTrue(composer.textView(textView, doCommandBy: selector), "\(selector)")
            XCTAssertEqual(textView.string, "a question\n", "\(selector)")
            XCTAssertEqual(sent, 0, "\(selector) never asks")
        }
    }
}
