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

    /// The rule two things now share: the list is open for exactly these inputs, and
    /// Return is withheld for exactly these inputs. Pinned directly so the shape cannot
    /// be loosened by accident on its way to either caller.
    func testWhatCountsAsACommandWordStillBeingTyped() {
        XCTAssertTrue(ComposerCommand.isBareCommandWord("/"))
        XCTAssertTrue(ComposerCommand.isBareCommandWord("/h"))
        XCTAssertTrue(ComposerCommand.isBareCommandWord("  /model  "),
                      "outer space is trimmed, so a trailing space is still a bare word")
        XCTAssertFalse(ComposerCommand.isBareCommandWord("/model g"), "an argument ends it")
        XCTAssertFalse(ComposerCommand.isBareCommandWord("what is swift"))
        XCTAssertFalse(ComposerCommand.isBareCommandWord("and/or, in logic"))
        XCTAssertFalse(ComposerCommand.isBareCommandWord(""))
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

    /// An empty list can never produce a selection, whichever way the arrow went.
    ///
    /// The *no preselection until an arrow* policy this used to be named for is the
    /// view's initial `nil`, not arithmetic — the entry points are covered by
    /// `testDownEntersAtTheTopAndUpEntersAtTheBottom`.
    func testAnEmptyListNeverYieldsASelection() {
        XCTAssertNil(ComposerCommand.moveSelection(nil, up: true, count: 0))
        XCTAssertNil(ComposerCommand.moveSelection(nil, up: false, count: 0))
        // A selection left over from a list that has just collapsed — the slash deleted
        // while an arrow key was already on its way. Only the nil seed was pinned, so a
        // guard moved below the switch would have kept passing.
        XCTAssertNil(ComposerCommand.moveSelection(0, up: false, count: 0))
        XCTAssertNil(ComposerCommand.moveSelection(0, up: true, count: 0))
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

    /// An index below the list is as possible as one beyond it, and both paths used to
    /// clamp only the top. Up returned -2 for -1 (`min(-1, last)` is `-1`, not `0`);
    /// down survived -1 only by luck, since `min(-1 + 1, last)` lands on `0`, and
    /// returned a negative for anything deeper. A negative result highlights nothing and
    /// makes the view's `indices.contains` guard turn an intended accept into a submit —
    /// with a slash command in the field.
    func testAnIndexBelowTheListIsClampedToo() {
        XCTAssertNil(ComposerCommand.moveSelection(-1, up: true, count: 2),
                     "clamped to the first row, and stepping up from there deselects")
        XCTAssertEqual(ComposerCommand.moveSelection(-1, up: false, count: 2), 0)
        // Past the one value the down path got right by accident.
        XCTAssertEqual(ComposerCommand.moveSelection(-2, up: false, count: 2), 0,
                       "down from below the list enters at the top, as it does from nothing")
        XCTAssertEqual(ComposerCommand.moveSelection(-5, up: false, count: 3), 0)
        XCTAssertNil(ComposerCommand.moveSelection(-5, up: true, count: 3),
                     "and up from below the list still deselects")
    }

    /// The list shrinks as the user types, and the view clears the highlight on every
    /// edit — but the arithmetic must not trust that and index past the end.
    func testAnIndexBeyondAShrunkListIsClamped() {
        XCTAssertEqual(ComposerCommand.moveSelection(9, up: false, count: 2), 1)
        // The value that would trap on `index + 1` rather than clamp.
        XCTAssertEqual(ComposerCommand.moveSelection(Int.max, up: false, count: 2), 1)
        XCTAssertEqual(ComposerCommand.moveSelection(9, up: true, count: 2), 0,
                       "clamped to the last row, then stepped up from there")
        // The other extreme of the same guarantee. The up path is safe because it clamps
        // through `min` *before* subtracting; a refactor that mirrored the down path's
        // shape as `index + 1 > last` would behave identically for 9 and trap here.
        XCTAssertEqual(ComposerCommand.moveSelection(Int.max, up: true, count: 2), 0)
        // `Int.min + 1` does not overflow, so the down path survives — but say so rather
        // than leave the bottom end of "any integer" resting on that being noticed.
        XCTAssertEqual(ComposerCommand.moveSelection(Int.min, up: false, count: 2), 0)
        XCTAssertNil(ComposerCommand.moveSelection(Int.min, up: true, count: 2))
    }

    // MARK: What Return does with a list on screen

    /// A slash word still being typed is not a question. `parse` would send `/h` to the
    /// model — it treats an unknown slash word as prose — and with `history` and `help`
    /// listed under it that spends a real request on a typo.
    func testAHalfTypedCommandIsNotAQuestion() {
        XCTAssertTrue(ComposerCommand.isHalfTypedCommand("/h"))
        XCTAssertTrue(ComposerCommand.isHalfTypedCommand("/c"))
        XCTAssertTrue(ComposerCommand.isHalfTypedCommand("/"))
    }

    /// An exact command still submits, or the list would break every command it lists.
    func testACompleteCommandIsNotWithheld() {
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/new"))
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/history"))
        // Trailing space and case are how a command arrives after `accept` fills it in.
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/model "))
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/NEW"))
        // An alias `parse` knows but the catalogue does not list: no list is on screen,
        // so there is nothing to be in the middle of.
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/clear"))
        // `/direct` alone is already withheld by `parse` returning nil, and must not be
        // withheld twice — the composer's own note explains what it wants.
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/direct"))
    }

    /// Every word the list offers has to submit on its own, or Return withholds a
    /// command the user can see and has finished typing — and accepting the completion
    /// would not help, because the trailing space trims back to the same word and the
    /// list comes straight back. A deadlock with no feedback at all.
    ///
    /// The invariant holds today: `parse` knows every catalogue name. It is pinned
    /// because it is a relationship between two lists that are edited separately, and
    /// adding a word to one of them is the obvious way to break it.
    func testEveryOfferedCommandCanBeSubmitted() {
        XCTAssertFalse(ComposerCommand.catalogue.isEmpty)
        for entry in ComposerCommand.catalogue {
            XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/\(entry.name)"),
                           "/\(entry.name) is offered in the list, but Return would withhold it")
        }
    }

    /// Ordinary questions must reach the engine untouched, slashes and all.
    func testAQuestionIsNeverWithheld() {
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("what is swift"))
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("and/or, in logic"))
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/direct why is the sky blue"))
        // The in-between case, and the one the guard's own comment is about: an unknown
        // slash word that has gained an argument. The list closed at the space, so this
        // is prose again — and if `completions(for:)` ever widened to match past the
        // command word, this is the assertion that would catch a question being eaten.
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/h why is the sky blue"),
                       "an argument closes the list, so an unknown prefix plus prose asks")
        // No list is on screen for a slash word that prefixes nothing, so it stays a
        // question — the pre-existing behaviour this rule deliberately does not touch.
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/zzz"))
        XCTAssertFalse(ComposerCommand.isHalfTypedCommand(""))
    }

    /// The arrow keys hand themselves to the command list whenever one is on screen, so
    /// what stops ↑/↓ from hijacking `/model gpt-4o` — and Return from replacing it with
    /// `/model ` — is the list disappearing the moment an argument exists.
    ///
    /// The boundary is the first character *of* the argument, not the space before it:
    /// the input is trimmed before matching, so `/model ` is still just the command word.
    /// That case is harmless — accepting the completion there rewrites `/model ` as
    /// `/model `, which changes nothing — and it keeps the list up while the reader is
    /// deciding whether they meant to type an argument at all.
    func testTheListDisappearsOnceAnArgumentExists() {
        XCTAssertNotNil(ComposerCommand.completions(for: "/model"))
        XCTAssertNotNil(ComposerCommand.completions(for: "/model "),
                        "a trailing space is trimmed away, so this is still the bare command")
        XCTAssertNil(ComposerCommand.completions(for: "/model g"),
                     "one character of argument is enough to hand the arrows back")
        XCTAssertNil(ComposerCommand.completions(for: "/model gpt-4o"))
        XCTAssertNil(ComposerCommand.completions(for: "/direct what is the time"))
    }

    /// Typing a slash and nothing else offers everything, which is the list the arrow
    /// keys are most often used on.
    func testABareSlashOffersTheWholeCatalogue() {
        let everything = ComposerCommand.completions(for: "/")
        XCTAssertNotNil(everything, "a bare slash offers the whole catalogue, not nothing")
        XCTAssertEqual(everything?.count, ComposerCommand.catalogue.count)
    }
}
