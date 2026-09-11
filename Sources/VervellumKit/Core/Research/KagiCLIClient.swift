import Foundation

/// Searches Kagi by running the `kagi` command-line tool on this machine.
///
/// Kagi has no search API an individual subscriber can just turn on — the hosted Search
/// API is sold separately and per query — so the way to research against Kagi's index is
/// the way its users already reach it from a terminal: the community
/// [kagi-cli](https://github.com/Microck/kagi-cli), which speaks to Kagi with whatever
/// credential the user has already given it. That is the whole point of this backend, and
/// it changes one thing about how Vervellum is configured: **the credential lives in the
/// CLI, not in Vervellum.** `kagi auth` owns it, Vervellum never sees it, and there is
/// nothing new in the keychain. A key stored against this provider anyway is passed to
/// the child as `KAGI_API_KEY`, for someone who would rather keep it here.
///
/// `kagi search` prints JSON on standard output by default, shaped as
/// `{"data":[{"rank":…,"title":…,"url":…,"snippet":…,"published":…}]}` — which
/// `EvidenceExtractor` already reads, because it matches on the shape of a hit rather
/// than on one provider's field names. So this client parses the output and hands it
/// over untouched, exactly as `SearXNGClient` hands over a SearXNG response.
///
/// **The argument vector is the security boundary of this file.** A search query is
/// written by the model, and in deep research that model has read pages that a search
/// found. Running the command through a shell would make a well-chosen query into a
/// command; so there is no shell (`CommandRunner` explains what that guarantees), the
/// query is passed after `--` so it cannot be read as a flag however it begins, and every
/// other argument the model can influence is checked against a fixed set of values before
/// it becomes an argument at all. `SearchBackend.validate` checks argument *names*
/// against the schema and nothing more — an enum in a JSON Schema is a description, not a
/// gate — so the values are checked here.
final class KagiCLIClient: SearchBackend {

    /// Standard output is capped well above a search result and well below anything that
    /// could hurt: twenty hits of JSON is a few tens of kilobytes.
    static let maxOutputBytes = 1_000_000
    /// The longest query that becomes a command-line argument. Far below the `exec`
    /// ceiling, and far above any real search: Kagi's own box takes a phrase.
    static let maxQueryBytes = 8_000
    /// One search's wall clock. Longer than an HTTP search would need, because this one
    /// pays for process startup and the CLI's own connection setup, and short enough that
    /// a hung command cannot hold up a turn the user is watching.
    static let searchTimeout: TimeInterval = 30

    private let executable: URL
    private let apiKey: String?
    private let trace: ResearchTrace
    private let runner: any CommandRunning

    let backendName = "Kagi CLI"

    init(executable: URL,
         apiKey: String?,
         trace: ResearchTrace,
         runner: any CommandRunning = CommandRunner.shared) {
        self.executable = executable
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.trace = trace
        self.runner = runner
    }

    // MARK: Schema

    static let toolName = "kagi_web_search"

    /// The recency windows `kagi search --time` accepts.
    ///
    /// One list, used twice: it is advertised to the model as the schema's `enum` and it
    /// is what a model-written value is checked against. Written out separately in each
    /// place, the two would drift, and drift here is silent — a value the model is
    /// invited to use and then dropped, or one enforced and never offered. Ordered
    /// shortest-first rather than alphabetically, because that is the order the schema
    /// reads best in.
    static let timeRanges = ["day", "week", "month", "year"]

    /// The arguments this client accepts, as a JSON Schema.
    ///
    /// Small for the reason `SearXNGClient`'s is small: every parameter here is one a
    /// research plan can actually use. Kagi's own flags go much further — lenses, custom
    /// bangs, result ordering, a `--follow` that fetches and summarises the top hits —
    /// and none of that belongs to a model. Lenses and bangs are the user's own saved
    /// settings, `--order` only narrows what the ranking already decided, and `--follow`
    /// would make the search command fetch pages behind Vervellum's back, where none of
    /// the page-reading rules apply.
    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "q": [
                "type": "string",
                "description": "The search query.",
            ] as [String: Any],
            "time_range": [
                "type": "string",
                "enum": KagiCLIClient.timeRanges,
                "description": "Optional recency filter. Use it for a question about a "
                    + "current state of affairs.",
            ] as [String: Any],
            "region": [
                "type": "string",
                "description": "Optional two-letter region code such as \"us\", \"de\" "
                    + "or \"ch\", for a question whose answer is local.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["q"],
    ]

    var toolDescriptor: [String: Any] {
        [
            "name": Self.toolName,
            "description": "Search the web through Kagi. Returns titles, links and short "
                + "summaries.",
            "inputSchema": Self.inputSchema,
        ]
    }

    private static var propertyKeys: Set<String> {
        guard let properties = inputSchema["properties"] as? [String: Any] else { return [] }
        return Set(properties.keys)
    }

    // MARK: SearchBackend

    /// Each call is one short-lived process with no shared state; two in flight share
    /// nothing but the metered account, whose rate limit is Kagi's to enforce.
    let supportsConcurrentCalls = true

    /// Nothing to do: the executable was found while the settings were being read, which
    /// is where a missing program is a fixable configuration problem rather than a failed
    /// research turn. Running it here to see whether it works would spend a real Kagi
    /// search to learn what the first search learns anyway — the same reasoning that
    /// keeps `SearXNGClient.connect()` a no-op.
    func connect() async throws {
        trace.log("Search backend ready (Kagi CLI)")
    }

    func search(arguments: [String: Any]) async throws -> Any {
        try validate(arguments,
                     required: Self.inputSchema["required"] as? [String] ?? ["q"],
                     properties: Self.propertyKeys)
        let command = try Self.command(for: arguments)
        // Only the argument's name, never the value it carried. A dropped argument is
        // the model's slip and the search is still worth running, but the string it
        // wrote is not something to put in a log.
        for name in command.dropped {
            trace.log("Kagi search argument ignored: \(name) was not a value Kagi accepts")
        }

        let environment = Self.childEnvironment(
            apiKey: apiKey, base: ProcessInfo.processInfo.environment)

        let (status, output) = try await trace.stage("Kagi search") {
            try await self.runner.run(executable: self.executable,
                                      arguments: command.arguments,
                                      environment: environment,
                                      limit: Self.maxOutputBytes,
                                      timeout: Self.searchTimeout)
        }

        guard status == 0 else {
            // The status and nothing else. Standard error is never even read — a
            // provider's own words do not reach a log line here any more than they do
            // from an HTTP error, and a CLI is entitled to print a key it was given back
            // at you in a diagnostic.
            throw ResearchError(
                "The Kagi command-line tool exited with status \(status). Run "
                + "`kagi search \"test\"` in a terminal to see what it says; if it asks "
                + "for credentials, run `kagi auth`.")
        }
        // Two different failures, told apart. A tool that printed nothing and one that
        // printed the wrong thing are fixed in different places, and the `--format` hint
        // leads nowhere for the first.
        guard !output.isEmpty else {
            throw ResearchError(
                "The Kagi command-line tool exited without printing anything. Run "
                + "`kagi search \"test\"` in a terminal to see what it does with a "
                + "simple query.")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: output) else {
            throw ResearchError(
                "The Kagi command-line tool did not return JSON. Check that `kagi search` "
                + "prints JSON in a terminal — it is the default, and `--format` in a "
                + "config file can change it.")
        }
        return parsed
    }

    // MARK: The command

    /// The argument vector for one search, plus the names of any arguments dropped.
    ///
    /// Pure, so the exact vector a set of model-written arguments produces is a thing a
    /// test can assert — which is the only way to keep the promise at the top of this
    /// file from quietly decaying into string building.
    static func command(for arguments: [String: Any]) throws -> (arguments: [String], dropped: [String]) {
        guard let query = arguments["q"] as? String else {
            throw ResearchError("The search query was not text. Try another model.")
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchError("The model wrote an empty search query. Try another model.")
        }
        // A single argument has a hard ceiling at the `exec` boundary — 128 KiB on Linux,
        // more on macOS — and a planner that has just read three pages is capable of
        // putting a paragraph of one into `q`. Failing here says what is wrong; failing
        // in the spawn says "could not start the search command", which is a sentence
        // about the settings and would send the reader to the wrong screen.
        guard query.utf8.count <= maxQueryBytes else {
            throw ResearchError(
                "The search query is too long to pass to a command (\(query.utf8.count) "
                + "bytes). A query is a handful of words; try another model.")
        }

        // These flag names are a contract with the `kagi` tool, not with Kagi: they were
        // checked against kagi-cli's documented `search` command, and a major version of
        // it is a reason to check them again.
        var argv = ["search", "--format", "json"]
        var dropped: [String] = []

        // No `!isEmpty` guard on either value below. An empty string is a legal
        // `type: string` and reaches here like any other, and skipping it silently would
        // hide the one slip that is hardest to see in a trace: the argument the model
        // sent, that did nothing, and that nothing said anything about.
        if let time = arguments["time_range"] as? String {
            if timeRanges.contains(time.lowercased()) {
                argv += ["--time", time.lowercased()]
            } else {
                dropped.append("time_range")
            }
        }
        if let region = arguments["region"] as? String {
            // Two ASCII letters, which is every region code Kagi takes. Checked rather
            // than trusted because this becomes an argument: a value that began with a
            // dash would be a flag to any parser that read it before its own `--`.
            let lowered = region.lowercased()
            if lowered.count == 2, lowered.allSatisfy({ $0.isASCII && $0.isLetter }) {
                argv += ["--region", lowered]
            } else {
                dropped.append("region")
            }
        }

        // Everything after `--` is a positional argument, whatever it looks like. Without
        // it a query beginning with a dash would be read as a flag — and a query is the
        // one part of this vector that a page found by an earlier search can influence.
        argv += ["--", query]
        return (argv, dropped)
    }

    /// The child's whole environment.
    ///
    /// Built rather than inherited. A search command is a third-party binary, and there
    /// is no reason for it to be handed the model key, the reader key, or anything else
    /// this process was started with — so it gets the four variables any program needs to
    /// find its own configuration, plus Kagi's own credential variables when they are
    /// already set in this environment.
    ///
    /// Those credential variables are passed through rather than dropped because someone
    /// who launched Vervellum from a shell that exports `KAGI_SESSION_TOKEN` has already
    /// said where their credential lives, and a child that could not see it would fail in
    /// a way that looks like the CLI being broken. A key stored in Vervellum wins over an
    /// inherited `KAGI_API_KEY`: it is the more deliberate of the two.
    static func childEnvironment(apiKey: String?, base: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for name in passedThrough {
            if let value = base[name] { environment[name] = value }
        }
        if let apiKey, !apiKey.isEmpty { environment["KAGI_API_KEY"] = apiKey }
        return environment
    }

    /// `HOME` and `XDG_CONFIG_HOME` are how the CLI finds `~/.config/kagi-cli/config.toml`;
    /// `PATH` is for whatever it runs itself; `LANG` decides how it renders text;
    /// `TMPDIR` keeps anything it spools out of the world-readable `/tmp`. The three
    /// `KAGI_` variables are the credentials it documents.
    ///
    /// The proxy variables are here because leaving them out produces the worst kind of
    /// bug report. On a network that requires a proxy the tool would reach nothing, the
    /// search would end at the timeout, and the failure message says to try `kagi search`
    /// in a terminal — where it works, because a terminal has these set. Both cases are
    /// listed: the lowercase spellings are the older convention and plenty of tools read
    /// only those.
    static let passedThrough = ["PATH", "HOME", "XDG_CONFIG_HOME", "LANG", "TMPDIR",
                                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                                "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                                "KAGI_SESSION_TOKEN", "KAGI_API_KEY", "KAGI_API_TOKEN"]
}
