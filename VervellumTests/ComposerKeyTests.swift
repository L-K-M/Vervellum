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
/// A modified Return arrives as one of two selectors, and which one is AppKit's choice
/// rather than Vervellum's: Shift-Return is `insertLineBreak:` and Option-Return is
/// `insertNewlineIgnoringFieldEditor:`. Both are pinned here because the composer's
/// promise is about the gesture rather than the selector, and a binding that differs by
/// keyboard layout or by macOS version must not change what the key does.
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

    /// The point of the whole file: the key that is advertised as adding a line adds a
    /// line, and adds a newline rather than the separator AppKit would have inserted.
    func testShiftReturnEntersANewline() {
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

    /// With the preference inverted, plain Return and a modified Return trade places: the
    /// key that opened a line now asks, and the key that asked now opens a line.
    ///
    /// Plain Return is *declined* rather than handled, and the decline is the newline in
    /// that mode. So the handed-back key is pressed rather than left to the comment: the
    /// claim worth pinning is not that the composer stepped aside, it is that what lands
    /// when it does is a newline, which is the whole of what this mode offers.
    func testTheInvertedPreferenceTradesTheTwoKeys() {
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
        XCTAssertEqual(sent, 1, "Shift-Return is what asks under this preference")
        XCTAssertEqual(textView.string, "a question\n", "and asking adds nothing of its own")
    }

    /// The two modified-Return selectors are one gesture rather than two, in either mode.
    ///
    /// Which of them a press arrives as is AppKit's business and can differ by keyboard
    /// layout and by macOS version, so the composer treats them identically and the
    /// preference is the only thing that decides what they do. The submit-on-Return side
    /// of that is pinned a test above; this is the side that would otherwise be left to
    /// inference, and inference is what the pair exists to remove.
    func testBothModifiedReturnsAskUnderTheInvertedPreference() {
        for selector in [#selector(NSResponder.insertLineBreak(_:)),
                         #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))] {
            let draft = Draft("a question")
            var sent = 0
            let composer = coordinator(submitOnReturn: false, draft: draft) { sent += 1 }
            let textView = field(holding: draft.text)

            XCTAssertTrue(composer.textView(textView, doCommandBy: selector), "\(selector)")
            XCTAssertEqual(sent, 1, "\(selector)")
            XCTAssertEqual(textView.string, "a question", "\(selector) inserts nothing")
        }
    }
}
