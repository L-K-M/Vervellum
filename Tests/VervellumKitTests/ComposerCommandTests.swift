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
                       .ask("Why is the sky blue?", level: nil))
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
        XCTAssertEqual(ComposerCommand.parse("/no-search what is 2+2"),
                       .ask("what is 2+2", level: .direct))
    }

    func testCommandsAreCaseInsensitive() {
        XCTAssertEqual(ComposerCommand.parse("/NEW"), .newThread)
        XCTAssertEqual(ComposerCommand.parse("/No-Search hi"), .ask("hi", level: .direct))
    }

    /// The reason parsing is strict: a question that happens to start with a path
    /// must stay a question rather than becoming an unknown-command error.
    func testAnUnknownSlashWordIsPartOfTheQuestion() {
        XCTAssertEqual(ComposerCommand.parse("/etc/hosts is world readable, right?"),
                       .ask("/etc/hosts is world readable, right?", level: nil))
        XCTAssertEqual(ComposerCommand.parse("/usr/bin/env"), .ask("/usr/bin/env", level: nil))
    }

    /// Every level word carries its question and declines without one, so a `parse`
    /// branch that fell through would send "/deep-rounds …" to a model as prose — the
    /// failure the whole half-typed-command guard exists to prevent.
    func testEveryLevelCarriesItsQuestionAndDeclinesWithoutOne() {
        for level in ResearchLevel.ordered {
            XCTAssertEqual(ComposerCommand.parse("/\(level.command) who owns the cobalt"),
                           .ask("who owns the cobalt", level: level),
                           "/\(level.command) must carry its question at its own level")
            // Bare: a level with no question yet, so the composer keeps the text.
            XCTAssertNil(ComposerCommand.parse("/\(level.command)"))
            XCTAssertNil(ComposerCommand.parse("/\(level.command)   "))
            // The hyphen is part of the word, not a separator: `commandWord` refuses a
            // command word containing whitespace, and would have refused these too if
            // the names had been spelled with spaces.
            XCTAssertEqual(ComposerCommand.parse("/\(level.command.uppercased()) why"),
                           .ask("why", level: level))
        }
    }

    /// The words these levels answered to before they had names still work, and are
    /// deliberately *not* in the completion list: seven rows for four levels is the
    /// confusion the levels exist to remove. A reader with `/deep-research` in muscle
    /// memory or in a script must still land somewhere.
    func testOlderCommandNamesStillSelectTheirLevel() {
        XCTAssertEqual(ComposerCommand.parse("/direct hi"), .ask("hi", level: .direct))
        XCTAssertEqual(ComposerCommand.parse("/deep-research hi"), .ask("hi", level: .deep))
        XCTAssertEqual(ComposerCommand.parse("/agent-research hi"), .ask("hi", level: .agent))
        let listed = Set(ComposerCommand.catalogue.map(\.name))
        for level in ResearchLevel.ordered {
            XCTAssertTrue(listed.contains(level.command),
                          "every level needs exactly one row: \(level.command)")
            for alias in level.aliases {
                XCTAssertFalse(listed.contains(alias), "an alias must not take a row: \(alias)")
            }
        }
    }

    /// Each level is offered in the list, so Return must be able to submit it — the
    /// invariant `testEveryOfferedCommandCanBeSubmitted` pins for the catalogue as a
    /// whole, named here for the rows the levels add.
    func testLevelsAreOfferedAndComplete() {
        // `XCTAssertNotNil` on a `contains` would have passed for any non-nil list,
        // including one the row is missing from — the assertion has to name the row.
        XCTAssertEqual(ComposerCommand.completions(for: "/deep")?.map(\.name),
                       ["deep-rounds"])
        for level in ResearchLevel.ordered {
            XCTAssertFalse(ComposerCommand.isHalfTypedCommand("/\(level.command)"),
                           "an exact command name must not withhold Return")
        }
    }

    /// A bare level word is a level the user is about to type into, not an empty
    /// question — submitting it must do nothing rather than ask a blank question.
    func testBareLevelIsNotSubmittable() {
        XCTAssertNil(ComposerCommand.parse("/no-search"))
        XCTAssertNil(ComposerCommand.parse("/no-search   "))
    }

    /// The one-shot contract, from the parser's end: a question with no level word
    /// carries **no** level, and the front ends read that nil as "whatever the selector
    /// says". A parser that answered `.research` here would hard-code the old default
    /// and silently ignore a reader who had moved the chip.
    func testAQuestionWithNoCommandCarriesNoLevel() {
        XCTAssertEqual(ComposerCommand.parse("who owns the cobalt"),
                       .ask("who owns the cobalt", level: nil))
        // An unknown slash word is a question too, and just as level-less.
        XCTAssertEqual(ComposerCommand.parse("/etc/hosts?"), .ask("/etc/hosts?", level: nil))
    }

    /// `/help` explains the levels as a group rather than as four unrelated commands,
    /// because the relationship between them is the thing no per-row summary can carry —
    /// and it is what made four modes confusing before they were levels.
    func testHelpTextExplainsTheLevelsTogether() {
        let help = ComposerCommand.helpText
        for level in ResearchLevel.ordered {
            XCTAssertTrue(help.contains(level.displayName),
                          "help text is missing the level \(level.displayName)")
        }
        XCTAssertTrue(help.contains("How hard to look"))
        XCTAssertTrue(help.contains("without moving the selector"),
                      "help must say a typed level is one question only")
    }

    func testCompletionsMatchAPartialCommand() {
        let matches = ComposerCommand.completions(for: "/h")
        XCTAssertEqual(matches?.map(\.name), ["history", "help"])
    }

    /// A slash and nothing else offers everything — the list the arrow keys are most
    /// often used on, since it is the one a reader opens to see what there is.
    func testCompletionsListEverythingForABareSlash() {
        XCTAssertNotNil(ComposerCommand.completions(for: "/"), "not nothing")
        XCTAssertEqual(ComposerCommand.completions(for: "/")?.count, ComposerCommand.catalogue.count)
    }

    /// The ceiling two things now share: the list can only open on one of these inputs,
    /// and Return is only withheld inside them. Neither is the same set — `/zzz` is a bare
    /// command word that opens nothing and is sent as typed — so what is pinned here is
    /// the shape both narrow down from, which cannot be loosened by accident on its way to
    /// either caller.
    func testWhatCountsAsACommandWordStillBeingTyped() {
        XCTAssertTrue(ComposerCommand.isBareCommandWord("/"))
        XCTAssertTrue(ComposerCommand.isBareCommandWord("/h"))
        XCTAssertTrue(ComposerCommand.isBareCommandWord("  /model  "),
                      "outer space is trimmed, so a trailing space is still a bare word")
        XCTAssertFalse(ComposerCommand.isBareCommandWord("/model g"), "an argument ends it")
        // A newline is trimmed at the edges like a space, because the interior test counts
        // it as whitespace and the two sets have to agree. They did not: `/h` followed by
        // Shift-Return closed the list, slipped the withhold, and asked the model "/h".
        XCTAssertTrue(ComposerCommand.isBareCommandWord("/h\n"), "a trailing newline is an edge")
        XCTAssertTrue(ComposerCommand.isBareCommandWord("\n/h"), "so is a leading one")
        XCTAssertFalse(ComposerCommand.isBareCommandWord("/model\ng"), "an interior one ends it")
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

    /// Unlike a level word, a bare `/model` is a complete request — "show me what there
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
        // The guard reads `count > 0`, not `count != 0`, and only the zero half of that
        // was pinned. A "tidier" `let last = max(count - 1, 0)` would keep every
        // assertion above green while handing back row 0 of a list that has no rows.
        XCTAssertNil(ComposerCommand.moveSelection(nil, up: false, count: -1))
        XCTAssertNil(ComposerCommand.moveSelection(0, up: true, count: -1))
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
        // The composer is multiline: Shift-Return puts a newline in the field. Return
        // must still decline the half-typed word underneath it rather than asking it.
        XCTAssertTrue(ComposerCommand.isHalfTypedCommand("/h\n"))
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
            // Three forms. The spaced one is what `accept` leaves in the field, so if a
            // command were withheld in that shape, picking it from the list would brick
            // Return for it — the trailing space trims back to the same word, the list
            // comes straight back, and nothing ever sends. The newline is the same shape
            // arrived at by habit: Shift-Return after a command that is already complete.
            // It only stays sendable while `parse` trims the set `isBareCommandWord`
            // trims, and neither says so out loud, so this is what holds them together.
            for candidate in ["/\(entry.name)", "/\(entry.name) ", "/\(entry.name)\n"] {
                XCTAssertFalse(ComposerCommand.isHalfTypedCommand(candidate),
                               "\(candidate) is offered in the list, but Return withholds it")
            }
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

    // MARK: What the list offers

    /// The list highlights its first row only while the command word is unfinished,
    /// because a highlighted row is one Return will *take*. `isHalfTypedCommand` is that
    /// condition — the same predicate that decides whether Return would otherwise be
    /// withheld, which is why the two can never disagree about a bare command word.
    func testTheWordsAnOfferedRowWouldFinish() {
        for unfinished in ["/dee", "/h", "/mod"] {
            XCTAssertTrue(ComposerCommand.isHalfTypedCommand(unfinished),
                          "\(unfinished) would be left without an offer")
        }
        // And a command already typed in full is not offered anything: `/new` and Return
        // starts a thread, exactly as it did before the list highlighted anything.
        for finished in ["/new", "/help", "/model", "/history", "/copy"] {
            XCTAssertFalse(ComposerCommand.isHalfTypedCommand(finished),
                           "\(finished) would be completed instead of run")
        }
        // The edges either side of a command word, which is where a later tweak to the
        // trimming or the matching would show up first. A trailing space is trimmed, so
        // `/model ` is still the bare command and false for the same reason `/model` is;
        // the first character of an argument stops it being a command word at all; and
        // an empty field has no word to finish.
        for notOffered in ["", "/model ", "/model deep"] {
            XCTAssertFalse(ComposerCommand.isHalfTypedCommand(notOffered),
                           "\(notOffered) should not read as an unfinished word")
        }
        // A bare slash *is* one, and is the input most likely to be mistaken for the
        // empty case above: `parse` reads it as a question, and Return sending "/" to a
        // model is the spend this predicate exists to prevent.
        XCTAssertTrue(ComposerCommand.isHalfTypedCommand("/"))
    }

    /// The whole "what will Return do" contract, which used to live in the view where
    /// nothing could reach it.
    func testTheListOffersItsFirstRowOnlyWhenTakingItWouldHelp() throws {
        // Unwrapped, so a nil stops the test here with the cause named. Carried on
        // unguarded it would fail in the two offer cases immediately below — as a bare
        // nil-against-0 mismatch, which says nothing about where the nil came from —
        // while two of the four `XCTAssertNil` cases, the two fed these completions,
        // would pass on the wrong grounds. The other two are handed a literal nil and a
        // literal empty list and are about those, not about this.
        let rows = try XCTUnwrap(ComposerCommand.completions(for: "/h"),
                                 "\"/h\" always has something to complete")

        XCTAssertEqual(ComposerCommand.offeredRowIndex(explicit: nil, isDismissed: false,
                                                       draft: "/h", completions: rows), 0,
                       "an unfinished word is what the offer exists for")
        XCTAssertEqual(ComposerCommand.offeredRowIndex(explicit: nil, isDismissed: false,
                                                       draft: "/", completions: rows), 0,
                       "a bare slash is an unfinished word, and the offer is what stands "
                        + "between Return and spending a request on \"/\"")
        XCTAssertNil(ComposerCommand.offeredRowIndex(explicit: nil, isDismissed: true,
                                                     draft: "/h", completions: rows),
                     "leaving the list has to stay left, or the exit is invisible")
        // `rows`, not the completions for "/new". This function treats the list as
        // opaque, and the assertion is about the *word* — passing "/new"'s own list
        // would let the test pass through the empty-list guard if `completions(for:)`
        // ever stopped answering for a finished command, which is the one branch this
        // line exists to hold.
        XCTAssertNil(ComposerCommand.offeredRowIndex(explicit: nil, isDismissed: false,
                                                     draft: "/new", completions: rows),
                     "offering a row under a finished command would fill the field "
                        + "instead of starting a thread")
        // A different leg of the same guard, and the one nothing else here reaches.
        // `/new` is refused for being a *complete* command — it passes
        // `isBareCommandWord`, has completions, and falls at `parse`. `/model deep` is
        // refused one step earlier, for not being a bare word at all. Only this case
        // holds that step: a change to how the word is found could let an
        // argument-bearing draft through while every assertion above stayed green.
        XCTAssertNil(ComposerCommand.offeredRowIndex(explicit: nil, isDismissed: false,
                                                     draft: "/model deep", completions: rows),
                     "a draft carrying an argument is not a word being typed, and "
                        + "Return has to run it rather than complete it")
        XCTAssertNil(ComposerCommand.offeredRowIndex(explicit: nil, isDismissed: false,
                                                     draft: "/h", completions: nil))
        XCTAssertNil(ComposerCommand.offeredRowIndex(explicit: nil, isDismissed: false,
                                                     draft: "/h", completions: []),
                     "an empty list has no row to offer, whatever the word looks like")
    }

    /// A row the reader walked or hovered to is theirs, and none of the conditions on
    /// the *offer* may take it away — the offer is what happens in the absence of a
    /// choice, not a filter over one.
    func testAChosenRowSurvivesEveryConditionOnTheOffer() {
        XCTAssertEqual(ComposerCommand.offeredRowIndex(explicit: 0, isDismissed: false,
                                                       draft: "/new",
                                                       completions: ComposerCommand.completions(for: "/new")),
                       0,
                       "arrowing onto the row under a finished /new is a gesture that "
                        + "deserves its own answer, even though the offer declines to "
                        + "make it unasked")
        XCTAssertEqual(ComposerCommand.offeredRowIndex(explicit: 1, isDismissed: true,
                                                       draft: "/h",
                                                       completions: ComposerCommand.completions(for: "/h")),
                       1,
                       "a row the reader walked to outlives the exit that cleared the offer")
        // And the pass-through is unchecked against the list, which is the decision the
        // doc comment spends ten lines on. Pinned here so a later "defensive" bounds
        // check has to argue with a failing test rather than arrive as a tidy-up.
        XCTAssertEqual(ComposerCommand.offeredRowIndex(explicit: 99, isDismissed: false,
                                                       draft: "/h",
                                                       completions: ComposerCommand.completions(for: "/h")),
                       99,
                       "a choice is handed back without being measured against the list")
        XCTAssertEqual(ComposerCommand.offeredRowIndex(explicit: 0, isDismissed: true,
                                                       draft: "", completions: nil), 0,
                       "every condition on the offer at once, and the choice still wins")

        // Except a negative, which is no row in any list and so is no choice either.
        // The offer rules answer instead — here, row 0 under a half-typed word.
        XCTAssertEqual(ComposerCommand.offeredRowIndex(explicit: -1, isDismissed: false,
                                                       draft: "/h",
                                                       completions: ComposerCommand.completions(for: "/h")),
                       0,
                       "a negative choice is no choice; the offer answers")
        XCTAssertNil(ComposerCommand.offeredRowIndex(explicit: -1, isDismissed: true,
                                                     draft: "/h",
                                                     completions: ComposerCommand.completions(for: "/h")),
                     "and with nothing to fall back to, nothing is offered")
    }

}
