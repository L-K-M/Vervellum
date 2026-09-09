import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The search backend that is a program rather than a server.
///
/// Most of what is worth asserting here is the **argument vector**: it is the whole
/// security surface of running a local command with a query a model wrote, and it is the
/// one part of the design that a later convenience could quietly undo.
final class KagiCLIClientTests: XCTestCase {

    private let executable = URL(fileURLWithPath: "/opt/test/bin/kagi")

    private func client(_ runner: StubCommandRunner, apiKey: String? = nil) -> KagiCLIClient {
        KagiCLIClient(executable: executable, apiKey: apiKey,
                      trace: ResearchTrace(sink: SilentLog()), runner: runner)
    }

    // MARK: The argument vector

    /// The shape of an ordinary search, asserted whole. A vector is easy to extend by
    /// accident, and every flag added here is a flag the model did not ask for.
    func testAnOrdinarySearchRunsExactlyThisCommand() throws {
        let command = try KagiCLIClient.command(for: ["q": "stellar parallax"])
        XCTAssertEqual(command.arguments,
                       ["search", "--format", "json", "--", "stellar parallax"])
        XCTAssertTrue(command.dropped.isEmpty)
    }

    /// The query goes after `--`, so a query beginning with a dash is a query. This is
    /// the reason the separator is there at all: in deep research the model writing it
    /// has read pages that an earlier search returned, and `--follow 5` reaching the
    /// tool as a flag would make the search command fetch pages behind Vervellum's back.
    func testAQueryIsAlwaysPassedAfterTheSeparator() throws {
        for query in ["--follow 5", "-x", "--format pretty", "--template {{url}}"] {
            let command = try KagiCLIClient.command(for: ["q": query])
            XCTAssertEqual(command.arguments.dropLast(2).last, "json",
                           "a flag was appended after the format: \(command.arguments)")
            XCTAssertEqual(Array(command.arguments.suffix(2)), ["--", query], query)
        }
    }

    /// A shell is never involved, so shell syntax in a query is text. Asserted on the
    /// vector because that is where it would stop being true — the vector reaches
    /// `Process` as separate strings, and nothing in this path builds a command line.
    func testShellSyntaxInAQueryStaysText() throws {
        let query = "rust; rm -rf / && curl $(whoami) `id` | sh"
        let command = try KagiCLIClient.command(for: ["q": query])
        XCTAssertEqual(command.arguments.last, query)
        XCTAssertEqual(command.arguments.count, 5,
                       "the query was split rather than passed whole: \(command.arguments)")
    }

    /// An enum in a JSON Schema is a description, not a gate: `SearchBackend.validate`
    /// checks argument *names*, so a value that becomes a command-line argument is
    /// checked here or nowhere.
    func testARecencyWindowIsCheckedAgainstWhatKagiAccepts() throws {
        for window in ["day", "week", "month", "year"] {
            let command = try KagiCLIClient.command(for: ["q": "q", "time_range": window])
            XCTAssertEqual(command.arguments, ["search", "--format", "json",
                                               "--time", window, "--", "q"])
        }
        // Case is the model's to get wrong; a value Kagi never defined is not.
        let upper = try KagiCLIClient.command(for: ["q": "q", "time_range": "DAY"])
        XCTAssertEqual(upper.arguments, ["search", "--format", "json", "--time", "day", "--", "q"])

        for invented in ["recent", "hour", "--follow 5", ""] {
            let command = try KagiCLIClient.command(for: ["q": "q", "time_range": invented])
            XCTAssertEqual(command.arguments, ["search", "--format", "json", "--", "q"],
                           "\(invented) reached the command line")
        }
        // Dropped, and said so — but only by name. The search is still worth running.
        XCTAssertEqual(try KagiCLIClient.command(for: ["q": "q", "time_range": "recent"]).dropped,
                       ["time_range"])
    }

    func testARegionIsTwoLettersOrItIsDropped() throws {
        let valid = try KagiCLIClient.command(for: ["q": "q", "region": "CH"])
        XCTAssertEqual(valid.arguments, ["search", "--format", "json", "--region", "ch", "--", "q"])

        for invalid in ["switzerland", "c", "-c", "--region", "c h"] {
            let command = try KagiCLIClient.command(for: ["q": "q", "region": invalid])
            XCTAssertEqual(command.arguments, ["search", "--format", "json", "--", "q"],
                           "\(invalid) reached the command line")
            XCTAssertEqual(command.dropped, ["region"])
        }
    }

    /// A search with nothing to search for is a model slip, and running it would spend a
    /// query to be told so.
    func testAnEmptyQueryIsRefused() {
        for query in ["", "   ", "\n"] {
            XCTAssertThrowsError(try KagiCLIClient.command(for: ["q": query]))
        }
        XCTAssertThrowsError(try KagiCLIClient.command(for: [:]))
    }

    /// The schema is still the contract for argument *names*, and an invented one means
    /// the model misread it.
    func testInventedArgumentNamesAreRefused() async {
        let runner = StubCommandRunner { _ in .kagiResults([]) }
        do {
            _ = try await client(runner).search(arguments: ["q": "q", "lens": "2"])
            XCTFail("an unknown argument was accepted")
        } catch {
            XCTAssertTrue(runner.calls.isEmpty, "the command ran anyway")
        }
    }

    // MARK: The environment

    /// A search command is a third-party binary. It is handed what it needs to find its
    /// own configuration and reach Kagi, and nothing else this process happens to hold —
    /// which, in a research app, is several other providers' keys.
    func testTheChildEnvironmentCarriesOnlyWhatTheToolNeeds() {
        let base = [
            "PATH": "/usr/bin", "HOME": "/home/tester", "LANG": "en_US.UTF-8",
            "XDG_CONFIG_HOME": "/home/tester/.config",
            "KAGI_SESSION_TOKEN": "session-value",
            "VERVELLUM_MODEL_KEY": "the model key", "VERVELLUM_READER_KEY": "the reader key",
            "AWS_SECRET_ACCESS_KEY": "unrelated", "SSH_AUTH_SOCK": "/tmp/agent",
        ]
        let environment = KagiCLIClient.childEnvironment(apiKey: nil, base: base)

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["HOME"], "/home/tester")
        XCTAssertEqual(environment["XDG_CONFIG_HOME"], "/home/tester/.config")
        // The user's own Kagi credential still reaches the tool, or launching Vervellum
        // from a shell that exports it would look like the tool being broken.
        XCTAssertEqual(environment["KAGI_SESSION_TOKEN"], "session-value")

        for leaked in ["VERVELLUM_MODEL_KEY", "VERVELLUM_READER_KEY",
                       "AWS_SECRET_ACCESS_KEY", "SSH_AUTH_SOCK"] {
            XCTAssertNil(environment[leaked], leaked)
        }
        XCTAssertEqual(Set(environment.keys).subtracting(KagiCLIClient.passedThrough), [],
                       "an unlisted variable reached the child")
    }

    /// A key stored in Vervellum is the more deliberate of the two, so it wins over one
    /// that happens to be exported in the environment.
    func testAStoredKeyOverridesAnInheritedOne() {
        let environment = KagiCLIClient.childEnvironment(
            apiKey: "stored", base: ["KAGI_API_KEY": "inherited"])
        XCTAssertEqual(environment["KAGI_API_KEY"], "stored")

        let inherited = KagiCLIClient.childEnvironment(
            apiKey: nil, base: ["KAGI_API_KEY": "inherited"])
        XCTAssertEqual(inherited["KAGI_API_KEY"], "inherited")
        // An empty stored key is not a key, and must not blank out a working one.
        let empty = KagiCLIClient.childEnvironment(
            apiKey: "", base: ["KAGI_API_KEY": "inherited"])
        XCTAssertEqual(empty["KAGI_API_KEY"], "inherited")
    }

    // MARK: Reading what it printed

    /// The output is handed on untouched, exactly as a SearXNG response is: the extractor
    /// matches on the shape of a hit, so a client that reshaped Kagi's JSON would be
    /// doing work that can only lose something.
    func testResultsBecomeSourcesThroughTheOrdinaryExtractor() async throws {
        let runner = StubCommandRunner { call in
            guard call.arguments.first == "search" else { return .unrouted }
            return .kagiResults([(url: "https://a.example/one", title: "One"),
                                 (url: "https://b.example/two", title: "Two")])
        }
        let result = try await client(runner).search(arguments: ["q": "parallax"])
        let sources = EvidenceExtractor.sources(from: [result])

        XCTAssertEqual(sources.map(\.url), ["https://a.example/one", "https://b.example/two"])
        XCTAssertEqual(sources.map(\.title), ["One", "Two"])
        XCTAssertEqual(sources.map(\.number), [1, 2])
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.executable, executable)
        // The bounds travel with the call rather than living inside the runner, so a
        // command that hangs or floods is stopped by the caller that knows what is
        // reasonable.
        XCTAssertEqual(runner.calls.first?.limit, KagiCLIClient.maxOutputBytes)
        XCTAssertEqual(runner.calls.first?.timeout, KagiCLIClient.searchTimeout)
    }

    /// A tool that failed says so with a status. Its own words are never read — standard
    /// error goes to the null device — because a CLI is entitled to print a credential it
    /// was handed back at you in a diagnostic, and this app does not put a provider's text
    /// in a log or on screen.
    func testANonZeroExitFailsWithTheStatusAndNothingElse() async {
        let runner = StubCommandRunner { _ in
            .output(status: 2, text: "error: KAGI_API_KEY=secret-value is invalid")
        }
        do {
            _ = try await client(runner).search(arguments: ["q": "q"])
            XCTFail("a failed command was treated as a result")
        } catch let error as ResearchError {
            XCTAssertTrue(error.message.contains("2"), error.message)
            XCTAssertFalse(error.message.contains("secret-value"), error.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A tool configured to print something else — `--format pretty` in a config file is
    /// enough — is a configuration problem with a name, not an empty result set.
    func testOutputThatIsNotJSONIsAFailureRatherThanNoResults() async {
        for text in ["", "1. Rust — https://rust-lang.org", "<html></html>"] {
            let runner = StubCommandRunner { _ in .output(status: 0, text: text) }
            do {
                _ = try await client(runner).search(arguments: ["q": "q"])
                XCTFail("non-JSON output was accepted: \(text)")
            } catch {}
        }
    }

    // MARK: Finding the program

    /// `resolve` is a filesystem question with a filesystem answer, and it is asked while
    /// the settings are read so that "not installed" is a configuration problem rather
    /// than a failed research turn.
    func testResolvingFindsARealProgramAndRefusesAMissingOne() {
        let runner = CommandRunner()
        // Present on both platforms, and found through the fixed directory list even
        // when `PATH` is whatever a test runner happened to inherit.
        XCTAssertNotNil(runner.resolve(command: "sh"))
        XCTAssertEqual(runner.resolve(command: "/bin/sh")?.path, "/bin/sh")

        XCTAssertNil(runner.resolve(command: "vervellum-no-such-program-xyzzy"))
        XCTAssertNil(runner.resolve(command: "/bin/vervellum-no-such-program-xyzzy"))
        XCTAssertNil(runner.resolve(command: ""))
        XCTAssertNil(runner.resolve(command: "   "))
        // A directory is not a program.
        XCTAssertNil(runner.resolve(command: "/bin/sh/nonsense"))
    }

    /// `PATH` alone is not the list, and the reason is a real bug rather than caution: a
    /// macOS menu-bar agent is launched by `launchd` with a `PATH` that contains none of
    /// the places a CLI installs itself.
    func testTheSearchListCoversWhereCLIsActuallyInstall() {
        let directories = Set(CommandRunner.searchDirectories)
        for expected in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            XCTAssertTrue(directories.contains(expected), expected)
        }
        XCTAssertTrue(directories.contains(NSHomeDirectory() + "/.local/bin"))
        XCTAssertTrue(directories.contains(NSHomeDirectory() + "/.cargo/bin"))
        // A relative entry would make the program found depend on the working directory.
        XCTAssertTrue(CommandRunner.searchDirectories.allSatisfy { $0.hasPrefix("/") })
    }
}
