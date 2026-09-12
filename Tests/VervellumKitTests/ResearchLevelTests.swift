import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The level table is read by the panel chip, the GTK button row, the completion list,
/// `/help` and `--help`. Everything here is an invariant one of those five depends on
/// and none of them can check for itself.
final class ResearchLevelTests: XCTestCase {

    /// `ordered` is the ladder every selector draws, and it is written out by hand so a
    /// case moved in the declaration cannot silently reorder the rungs. The cost of
    /// writing it out is that a case added to the enum and not to the array would be a
    /// level nobody can reach — which is what this pins.
    func testOrderedHoldsEveryLevelExactlyOnce() {
        XCTAssertEqual(Set(ResearchLevel.ordered), Set(ResearchLevel.allCases))
        XCTAssertEqual(ResearchLevel.ordered.count, ResearchLevel.allCases.count)
    }

    /// The scale runs cheapest-first, and `direct` is the end that gathers nothing.
    func testTheLadderRunsFromNoSearchUpwards() {
        XCTAssertEqual(ResearchLevel.ordered.first, .direct)
        XCTAssertEqual(ResearchLevel.ordered.dropFirst().filter { !$0.searches }, [],
                       "every level above the first gathers evidence")
    }

    /// The raw values are what the trace logs and what `threads.json` stores. Renaming
    /// one silently orphans every saved turn that carries it and every log line anyone
    /// has ever grepped, so they are pinned here rather than left to `String(describing:)`.
    func testRawValuesAreTheNamesTheTraceHasAlwaysLogged() {
        XCTAssertEqual(ResearchLevel.ordered.map(\.rawValue),
                       ["direct", "research", "deep", "agent"])
        for level in ResearchLevel.ordered {
            XCTAssertEqual(level.traceName, level.rawValue)
        }
    }

    /// Two levels answering to one word would make the word mean whichever came first in
    /// the table, which is not a thing a reader can be told.
    func testEveryCommandWordIsUniqueAndResolves() {
        var words: Set<String> = []
        for level in ResearchLevel.ordered {
            for word in [level.command] + level.aliases {
                XCTAssertTrue(words.insert(word).inserted, "\(word) names two levels")
                XCTAssertEqual(ResearchLevel.named(word), level)
                XCTAssertEqual(ResearchLevel.named(word.uppercased()), level,
                               "command words are matched case-insensitively")
            }
        }
        XCTAssertNil(ResearchLevel.named("exhaustive"))
        XCTAssertNil(ResearchLevel.named(""))
    }

    /// The words the levels answered to before they had names. Spelled out rather than
    /// read from `aliases`, because a test that asked the table would pass just as
    /// happily if somebody emptied it — and what is being protected is a command word
    /// sitting in somebody's shell script.
    func testTheOlderNamesStillResolve() {
        XCTAssertEqual(ResearchLevel.named("direct"), .direct)
        XCTAssertEqual(ResearchLevel.named("deep-research"), .deep)
        XCTAssertEqual(ResearchLevel.named("agent-research"), .agent)
    }

    /// The rules sit where the scale stops meaning "more of the same": above `research`,
    /// which is where gathering starts at all, and above `agent`, which spends `deep`'s
    /// budget rather than a larger one. See `ResearchLevel` for the argument.
    func testTheGroupRulesFallEitherSideOfTheTwoRungs() {
        XCTAssertEqual(ResearchLevel.ordered.filter(\.beginsGroup), [.research, .agent])
    }

    /// Every level needs a name, a command and both lines of explanation: the picker
    /// draws all four for all of them, and an empty one would render as a blank row
    /// rather than as an error anybody notices.
    func testEveryLevelIsFullyDescribed() {
        let settings = ProviderSettings()
        for level in ResearchLevel.ordered {
            XCTAssertFalse(level.displayName.isEmpty)
            XCTAssertFalse(level.command.isEmpty)
            XCTAssertFalse(level.summary.isEmpty)
            XCTAssertFalse(level.cost(settings).isEmpty)
            XCTAssertFalse(level.command.contains(" "),
                           "a command word containing whitespace can never be parsed")
        }
    }

    /// The cost lines are generated from the constants the runner enforces, which is the
    /// only way they stay true: a hand-written "up to 4 searches" stops being true the
    /// first time somebody moves `maxSearches`, and it is read by a person deciding
    /// whether to spend money.
    func testCostLinesComeFromTheRunnersOwnConstants() {
        let settings = ProviderSettings()
        XCTAssertTrue(ResearchLevel.deep.cost(settings)
            .contains("\(ResearchRunner.maxDeepRounds) rounds"))
        XCTAssertTrue(ResearchLevel.agent.cost(settings)
            .contains("\(ResearchRunner.maxAgentSteps) steps"))
        XCTAssertTrue(ResearchLevel.agent.cost(settings)
            .contains("\(ResearchRunner.maxAgentSearches) of them searches"))
        XCTAssertTrue(ResearchLevel.research.cost(settings)
            .contains("\(ResearchRunner.maxSearches) searches"))
        // The level that gathers nothing must not advertise a budget it cannot spend.
        XCTAssertFalse(ResearchLevel.direct.cost(settings).contains("searches"))
    }

    /// A deep round puts every planned search to every configured engine, so the same
    /// level costs a different amount on two installs. The line has to say which one the
    /// reader is on, or it understates the bill on exactly the setup that pays most.
    func testTheDeepCostLineCountsTheReadersOwnSearchEngines() {
        var one = ProviderSettings()
        one.searchProfiles = [SearchProfile.new(name: "A", endpoint: "https://a.example")]
        XCTAssertTrue(ResearchLevel.deep.cost(one).contains("your one configured search engine"),
                      ResearchLevel.deep.cost(one))

        var two = one
        two.searchProfiles.append(SearchProfile.new(name: "B", endpoint: "https://b.example"))
        XCTAssertTrue(ResearchLevel.deep.cost(two).contains("each of your 2 configured search engines"),
                      ResearchLevel.deep.cost(two))

        // No engine configured yet is still "one" rather than "zero": the turn runs
        // against the selected engine, and a settings file with an empty list is a
        // machine that cannot research at all — a cost line is not where that is said.
        XCTAssertTrue(ResearchLevel.deep.cost(ProviderSettings())
            .contains("your one configured search engine"))
    }
}
