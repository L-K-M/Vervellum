import Foundation

/// How hard a turn looks things up — the one dial the reader sets, and the only thing
/// that differs between the four ways to ask a question.
///
/// This used to be `ResearchRunner.Mode`, a bare four-case enum the runner switched on,
/// with its user-facing description spread over three places that could disagree: the
/// enum's own doc comments, `ComposerCommand.catalogue`'s completion rows, and
/// `VervellumLinuxApp.printUsage`. Only three of the four had a name at all — the
/// default was "what you get by typing nothing" — which is most of why four modes read
/// as confusing. One type now owns the name, the command word, the one-line summary and
/// the cost, so the panel chip, the completion list, `/help` and `--help` cannot drift.
///
/// **The order is a claim, and the claim is bounded.** `ordered` runs cheapest-first,
/// and `beginsGroup` marks the two places the reader should be told the scale stops
/// rather than continues:
///
/// * `.direct` is not the bottom rung of the ladder — it is off it. It skips gathering
///   entirely (`ResearchRunner.execute` short-circuits to `answerDirectly`), so there
///   is no evidence, no citation validation and no assessment stage. Everything above
///   it differs in how much it gathers; this differs in whether it gathers.
/// * `.agent` is not a rung above `.deep`. It spends `.deep`'s page and evidence
///   allowance — the budget ternaries read `mode == .research ? normal : deep`, so the
///   two are equal to the character — and differs in *who chooses the next search*: a
///   loop reacting to each result, rather than rounds planned against a digest. It is
///   last because it can cost the most model calls (one per step), not because it looks
///   further.
///
/// Between them, `.research` and `.deep` are a genuine scale: every budget moves the
/// same way and none moves back. That is the only pair of which this is true, which is
/// why the dividers are here in the type rather than left to each front end to draw.
///
/// Raw values are the strings the trace has always logged, so a log line, a bug report
/// and a `threads.json` document all keep reading the same four words.
enum ResearchLevel: String, Codable, CaseIterable, Identifiable, Equatable {

    /// No search at all: answered from the model's own knowledge and badged as
    /// unsourced.
    case direct

    /// The staged pipeline, once: plan searches, run them, read pages, answer over the
    /// numbered sources, then grade the answer against them.
    case research

    /// The staged pipeline, but the plan is allowed to come back. Each round reads what
    /// the last one found and asks for what is still missing; the answer is written once,
    /// over everything gathered.
    ///
    /// Evidence is kept whole rather than summarised between rounds. The answer may cite
    /// only the numbered sources this turn collected, so a digest would buy room by
    /// dissolving the very things the citations point at. Rounds stop when the budget is
    /// close to spent instead.
    case deep

    /// The staged pipeline's tail with a different gatherer: the model chooses one
    /// action at a time — search, read, or stop — and sees what each produced before
    /// choosing the next. See `AGENT-RESEARCH.md`.
    case agent

    var id: String { rawValue }

    /// The levels cheapest-first, as every selector and every list must show them.
    ///
    /// Stated rather than taken from `allCases`, which answers in declaration order.
    /// Declaration order is a thing a later edit moves without meaning anything by it,
    /// and the one it would silently rearrange is the ladder the whole control is. A
    /// test pins this against `allCases` so a case added to one and not the other is a
    /// failure rather than a level nobody can reach.
    static let ordered: [ResearchLevel] = [.direct, .research, .deep, .agent]

    /// The level a question is asked at when nothing says otherwise.
    static let standard: ResearchLevel = .research

    /// What the chip, the selector row and the turn badge call it.
    var displayName: String {
        switch self {
        case .direct: return "No search"
        case .research: return "One pass"
        case .deep: return "Deep rounds"
        case .agent: return "Agent loop"
        }
    }

    /// The slash command and CLI flag that selects this level, without its leading `/`
    /// or `--`.
    ///
    /// Derived from `displayName` by eye rather than by code: a lowercased, hyphenated
    /// display name happens to produce all four of these today, and deriving it would
    /// make a future rename of a *label* silently break a command word somebody has in
    /// a script.
    var command: String {
        switch self {
        case .direct: return "no-search"
        case .research: return "one-pass"
        case .deep: return "deep-rounds"
        case .agent: return "agent-loop"
        }
    }

    /// Command words that still select this level, kept working from before the levels
    /// had names. Never listed in the completion catalogue — one row per level — but
    /// always parsed.
    var aliases: [String] {
        switch self {
        case .direct: return ["direct"]
        case .research: return []
        case .deep: return ["deep-research"]
        case .agent: return ["agent-research"]
        }
    }

    /// One line saying what this level *does*, for the completion row and the selector.
    ///
    /// Mechanism rather than magnitude, deliberately. "Deeper" and "more thorough" are
    /// the words that made four modes hard to tell apart in the first place; what
    /// distinguishes these is who decides the next search and how many times it is
    /// asked, which is a fact and fits on a line.
    var summary: String {
        switch self {
        case .direct:
            // No dash in the middle: this line is printed after an em-dash in `/help`
            // and after a two-column gutter in `--help`, and "No search — Answers from
            // the model alone — nothing…" reads as one sentence broken twice.
            return "Answers from the model alone, with nothing searched, cited or checked"
        case .research:
            return "Plans one round of searches, answers from what it finds, then checks the answer against it"
        case .deep:
            return "Comes back for up to \(ResearchRunner.maxDeepRounds) rounds, "
                + "each asking for what the last one could not have known it was missing"
        case .agent:
            return "The model picks one search or page read at a time, and stops when it "
                + "judges the question settled"
        }
    }

    /// What a turn at this level may spend, in the reader's terms.
    ///
    /// Generated from the constants the runner actually enforces, and from the settings
    /// in front of the reader, rather than typed out — a hand-written cost line is a
    /// promise that stops being true the first time a constant moves, and this one is
    /// read by someone deciding whether to spend money.
    ///
    /// `engines` is why `settings` is a parameter rather than this being a stored
    /// string: a deep round puts every planned search to *every* configured engine, so
    /// the request ceiling is rounds × searches × engines. `ResearchRunner.maxSearches`
    /// says in as many words that this should be stated plainly rather than discovered
    /// on a metered account.
    func cost(_ settings: ProviderSettings) -> String {
        switch self {
        case .direct:
            return "One model call. No search, no pages read, and no assessment stage."
        case .research:
            return "Up to \(ResearchRunner.maxSearches) searches and "
                + "\(PageReaderFactory.maxPages) pages read, on a "
                + "\(evidence(ResearchContext.maxEvidenceCharacters)) evidence budget."
        case .deep:
            let engines = max(1, settings.searchProfiles.count)
            let fanOut = engines == 1
                ? "your one configured search engine"
                : "each of your \(engines) configured search engines"
            return "Up to \(ResearchRunner.maxDeepRounds) rounds of "
                + "\(ResearchRunner.maxSearches) searches, every one of them put to "
                + "\(fanOut), and up to \(PageReaderFactory.maxDeepPages) pages read, on a "
                + "\(evidence(ResearchContext.maxDeepEvidenceCharacters)) evidence budget."
        case .agent:
            return "Up to \(ResearchRunner.maxAgentSteps) steps, at most "
                + "\(ResearchRunner.maxAgentSearches) of them searches, and up to "
                + "\(PageReaderFactory.maxDeepPages) pages read — the same "
                + "\(evidence(ResearchContext.maxDeepEvidenceCharacters)) budget as "
                + "\(ResearchLevel.deep.displayName), spent a step at a time rather than a "
                + "round at a time. Each step is its own model call."
        }
    }

    /// Whether a rule is drawn above this level in a list of all four.
    ///
    /// The groups are `[.direct] | [.research, .deep] | [.agent]`, and both rules say
    /// the same thing in the same place: the scale stops here. See the type's docs for
    /// why each one is true — briefly, the first separates *whether* it gathers from
    /// *how much*, and the second separates a bigger budget from a different gatherer
    /// spending the same one.
    var beginsGroup: Bool {
        switch self {
        case .direct: return false
        case .research, .agent: return true
        case .deep: return false
        }
    }

    /// Every level but `direct` gathers evidence before answering.
    var searches: Bool { self != .direct }

    /// What the trace calls this.
    ///
    /// The raw value, which is what it has always logged. Kept as a name of its own
    /// rather than spelling `rawValue` at the call sites, because these four strings are
    /// grepped in bug reports and pinned by tests: they are an interface, and a reader
    /// renaming `displayName` should be able to see that this is not it.
    var traceName: String { rawValue }

    /// The level a command word selects, or nil when the word names no level.
    static func named(_ word: String) -> ResearchLevel? {
        let lowered = word.lowercased()
        return ordered.first { $0.command == lowered || $0.aliases.contains(lowered) }
    }

    /// A character budget as the reader would say it: "70,000", not "70000".
    ///
    /// Its own formatter each time rather than a shared one: `NumberFormatter` is not
    /// thread-safe on Linux, unlike Darwin, and this is called from whichever thread is
    /// drawing.
    private func evidence(_ characters: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: characters)) ?? String(characters)
        return "\(number)-character"
    }
}
