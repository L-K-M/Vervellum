import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class ComposerCommandTests: XCTestCase {

    func testPlainTextIsAQuestion() {
        XCTAssertEqual(ComposerCommand.parse("  Why is the sky blue?  "),
                       .ask("Why is the sky blue?"))
    }

    func testBlankInputIsNothing() {
        XCTAssertNil(ComposerCommand.parse(""))
        XCTAssertNil(ComposerCommand.parse("   \n "))
    }

    func testParsesKnownCommands() {
        XCTAssertEqual(ComposerCommand.parse("/new"), .newThread)
        XCTAssertEqual(ComposerCommand.parse("/clear"), .newThread)
        XCTAssertEqual(ComposerCommand.parse("/history"), .openHistory)
        XCTAssertEqual(ComposerCommand.parse("/settings"), .openSettings)
        XCTAssertEqual(ComposerCommand.parse("/copy"), .copyLastAnswer)
        XCTAssertEqual(ComposerCommand.parse("/help"), .showHelp)
        XCTAssertEqual(ComposerCommand.parse("/direct what is 2+2"), .direct("what is 2+2"))
    }

    func testCommandsAreCaseInsensitive() {
        XCTAssertEqual(ComposerCommand.parse("/NEW"), .newThread)
        XCTAssertEqual(ComposerCommand.parse("/Direct hi"), .direct("hi"))
    }

    /// The reason parsing is strict: a question that happens to start with a path
    /// must stay a question rather than becoming an unknown-command error.
    func testAnUnknownSlashWordIsPartOfTheQuestion() {
        XCTAssertEqual(ComposerCommand.parse("/etc/hosts is world readable, right?"),
                       .ask("/etc/hosts is world readable, right?"))
        XCTAssertEqual(ComposerCommand.parse("/usr/bin/env"), .ask("/usr/bin/env"))
    }

    /// "/direct" alone is a mode the user is about to type into, not an empty
    /// question — submitting it must do nothing rather than ask a blank question.
    func testBareDirectIsNotSubmittable() {
        XCTAssertNil(ComposerCommand.parse("/direct"))
        XCTAssertNil(ComposerCommand.parse("/direct   "))
    }

    func testCompletionsMatchAPartialCommand() {
        let matches = ComposerCommand.completions(for: "/h")
        XCTAssertEqual(matches?.map(\.name), ["history", "help"])
    }

    func testCompletionsListEverythingForABareSlash() {
        XCTAssertEqual(ComposerCommand.completions(for: "/")?.count, ComposerCommand.catalogue.count)
    }

    func testNoCompletionsOnceAWordFollows() {
        XCTAssertNil(ComposerCommand.completions(for: "/direct what"))
        XCTAssertNil(ComposerCommand.completions(for: "plain question"))
        XCTAssertNil(ComposerCommand.completions(for: "/zzz"))
    }

    func testHelpTextListsEveryCommand() {
        for command in ComposerCommand.catalogue {
            XCTAssertTrue(ComposerCommand.helpText.contains("/\(command.name)"),
                          "help text is missing /\(command.name)")
        }
    }

    // MARK: /model

    /// Unlike `/direct`, a bare `/model` is a complete request — "show me what there
    /// is" — so it parses rather than waiting for an argument.
    func testABareModelCommandParsesAsAListing() {
        XCTAssertEqual(ComposerCommand.parse("/model"), .selectModel(""))
        XCTAssertEqual(ComposerCommand.parse("/models"), .selectModel(""))
    }

    func testModelTakesTheRestOfTheLineAsAName() {
        XCTAssertEqual(ComposerCommand.parse("/model gpt-4o"), .selectModel("gpt-4o"))
        XCTAssertEqual(ComposerCommand.parse("  /model   The Fast One  "),
                       .selectModel("The Fast One"))
    }

    func testModelIsOfferedInTheCompletionList() {
        XCTAssertEqual(ComposerCommand.completions(for: "/mo")?.map(\.name), ["model"])
    }

    /// The listing marks the active provider, because "which model answered this" is
    /// the question the whole panel exists to keep answerable.
    func testTheModelListingMarksOnlyTheActiveProvider() {
        let fast = ModelProfile.new(name: "Fast", endpoint: "https://a.example.com/v1", model: "mini")
        let big = ModelProfile.new(name: "Careful", endpoint: "https://b.example.com/v1", model: "max")
        let lines = ComposerCommand.modelListing(
            ProviderSettings(modelProfiles: [fast, big], selectedModelID: big.id))
            .components(separatedBy: "\n")

        let fastLine = lines.first { $0.contains("Fast") }
        let carefulLine = lines.first { $0.contains("Careful") }
        XCTAssertNotNil(fastLine)
        XCTAssertNotNil(carefulLine)
        XCTAssertFalse(fastLine?.contains("(active)") ?? true)
        XCTAssertTrue(carefulLine?.contains("(active)") ?? false)
        // The identifier is shown too, so two providers on the same model are told apart.
        XCTAssertTrue(carefulLine?.contains("max") ?? false)
    }

    func testTheModelListingSaysSoWhenNothingIsConfigured() {
        let listing = ComposerCommand.modelListing(ProviderSettings(modelProfiles: []))
        XCTAssertTrue(listing.contains("No model provider is configured"))
    }

    // MARK: Completion-list navigation

    /// Return accepts the highlighted row, so a preselected first row would turn typing
    /// `/new` + Return from "start a thread" into "finish the word".
    func testNothingIsHighlightedUntilAnArrowIsPressed() {
        XCTAssertNil(ComposerCommand.moveSelection(nil, up: true, count: 0))
        XCTAssertNil(ComposerCommand.moveSelection(nil, up: false, count: 0))
    }

    func testDownEntersAtTheTopAndUpEntersAtTheBottom() {
        XCTAssertEqual(ComposerCommand.moveSelection(nil, up: false, count: 3), 0)
        XCTAssertEqual(ComposerCommand.moveSelection(nil, up: true, count: 3), 2)
    }

    func testWalksTheList() {
        XCTAssertEqual(ComposerCommand.moveSelection(0, up: false, count: 3), 1)
        XCTAssertEqual(ComposerCommand.moveSelection(1, up: false, count: 3), 2)
        XCTAssertEqual(ComposerCommand.moveSelection(2, up: true, count: 3), 1)
    }

    /// There is nothing below the last row, so ↓ stays put rather than wrapping to the
    /// top and losing the user's place.
    func testDownStopsAtTheBottom() {
        XCTAssertEqual(ComposerCommand.moveSelection(2, up: false, count: 3), 2)
    }

    /// ↑ off the top hands the keyboard back to the text field. Wrapping to the bottom
    /// would leave no way back to typing without reaching for the mouse.
    func testUpOffTheTopReturnsToTyping() {
        XCTAssertNil(ComposerCommand.moveSelection(0, up: true, count: 3))
    }

    /// A single command is the common case — `/h` matches only `/history` — and it must
    /// still be reachable from both directions.
    func testASingleRowIsReachableAndStable() {
        XCTAssertEqual(ComposerCommand.moveSelection(nil, up: false, count: 1), 0)
        XCTAssertEqual(ComposerCommand.moveSelection(nil, up: true, count: 1), 0)
        XCTAssertEqual(ComposerCommand.moveSelection(0, up: false, count: 1), 0)
        XCTAssertNil(ComposerCommand.moveSelection(0, up: true, count: 1))
    }

    /// The list shrinks as the user types, and the view clears the highlight on every
    /// edit — but the arithmetic must not trust that and index past the end.
    func testAnIndexBeyondAShrunkListIsClamped() {
        XCTAssertEqual(ComposerCommand.moveSelection(9, up: false, count: 2), 1)
        XCTAssertEqual(ComposerCommand.moveSelection(9, up: true, count: 2), 8)
    }

    /// Typing a slash and nothing else offers everything, which is the list the arrow
    /// keys are most often used on.
    func testABareSlashOffersTheWholeCatalogue() {
        XCTAssertEqual(ComposerCommand.completions(for: "/")?.count,
                       ComposerCommand.catalogue.count)
    }
}
