import Foundation

/// Runs one research turn to completion. Every platform's engine drives this.
///
/// The pipeline is four calls, in this order, and the order is the design:
///
/// 1. **Plan** — a small JSON call that decides what to look up. Separating this from
///    the answer is what makes the searches deliberate rather than a keyword echo of
///    the question, and it is where the disconfirming-search instruction can bite.
/// 2. **Search** — each planned query, run against the web-search MCP server. The
///    results become a numbered source list that Vervellum, not the model, controls.
/// 3. **Answer** — a streamed call that may cite only those numbers. The user starts
///    reading within a second or two, which is the latency that actually matters.
/// 4. **Assess** — a second JSON call that grades the answer's own claims against the
///    same evidence, harder than the answer stage was asked to be.
///
/// Stage 4 runs *after* stage 3 rather than beside it, even though it does not depend
/// on the prose. Assessing the answer that was actually written is what keeps the
/// verdict table honest; assessing the evidence in parallel would produce a table that
/// quietly disagrees with the paragraph above it.
///
/// **This type is free of any UI or actor isolation, on purpose.** It reports progress
/// by handing a snapshot of the turn to `onUpdate`, which it calls from whatever thread
/// it happens to be running on. Marshalling that onto the UI thread belongs to the
/// caller, because the two platforms answer it differently: macOS hops to the main
/// dispatch queue, while a GTK application must use a GLib idle callback — its main
/// loop is not the dispatch main queue, so a `MainActor` hop there would never run.
final class ResearchRunner: ResearchRunning {

    /// Everything a run needs from the outside world, captured once so the settings
    /// cannot change halfway through a turn.
    ///
    /// It prints redacted. The note on `modelKeys` used to say "never log an
    /// `Environment`", which is a rule held by whoever remembers reading it — and this
    /// value now carries *every* configured provider's key, so the one `print` someone
    /// reaches for while a turn is failing would spill all of them at once rather than
    /// one. All three routes out are overridden, not only the debug one: `print`, string
    /// interpolation and `String(describing:)` take `description` — the interpolation in
    /// a hurried log line is what this is for — `String(reflecting:)` takes
    /// `debugDescription`, and `dump()`, a debugger and a crash reporter go round both
    /// through `Mirror`. Closing two of the three would only have moved the hole.
    ///
    /// Every *printing* path, not memory: an attached debugger reading the stored
    /// properties directly — lldb's `frame variable`, as against `po` — still sees the
    /// keys, and nothing in a value type can prevent that. The guarantee is that no
    /// rendering of this value writes a key somewhere it can be read later.
    struct Environment: CustomStringConvertible, CustomDebugStringConvertible,
                        CustomReflectable {
        var settings: ProviderSettings
        var modelKey: String?
        /// Every configured model provider's key, by profile id.
        ///
        /// A chain needs more than the selected provider's key: the point of falling
        /// back is to reach a *different* endpoint, and each has a secret slot of its
        /// own. Captured with the rest of the environment, once, so a key edited
        /// mid-turn cannot change which credential a later stage sends.
        /// - Note: every configured provider's live key, not just the selected one.
        ///   Turn diagnostics name profiles, never keys.
        var modelKeys: [UUID: String]
        var searchKey: String?
        /// Every configured search provider's key, by profile id.
        ///
        /// `deep` research asks more than one engine, and each has its own slot.
        /// Captured with the rest of the environment for the same reason `modelKeys` is:
        /// a key edited while the turn runs must not change which credential a later
        /// round sends.
        var searchKeys: [UUID: String]
        var readerKey: String?

        /// Which secrets are present, never what they are. Profile ids are safe to name
        /// — they are what the trace already uses to talk about providers — and they are
        /// what makes this description useful enough that nobody wants the real one.
        ///
        /// Fields named one by one rather than interpolating `settings`, which is the
        /// whole point and was the hole in the first version of this. `ProviderSettings`
        /// has no description of its own, so reflection would have printed every stored
        /// property — the endpoints included, and an endpoint is a URL somebody pasted.
        /// Nothing stops one carrying `?api-key=…`: the validator refuses credentials in
        /// a URL's *userinfo*, which is a different part of the address. Listing what may
        /// be shown, rather than removing what may not, also means a field added to
        /// `ProviderSettings` later cannot leak through here by default.
        var description: String {
            let ids = modelKeys.keys.map(\.uuidString).sorted().joined(separator: ", ")
            let searchIDs = searchKeys.keys.map(\.uuidString).sorted().joined(separator: ", ")
            func held(_ secret: String?) -> String { secret == nil ? "absent" : "present" }
            return "Environment(model: \(settings.modelName), "
                // The switch as well as the count. `modelChain` is the *effective* chain,
                // so five configured providers with fallback off print as `providers: 1`
                // — indistinguishable from having configured one, and "why was my spare
                // never tried" is the likeliest question this rendering has to answer.
                + "fallback: \(settings.modelFallback), "
                + "providers: \(settings.modelChain.count), modelKeys: [\(ids)], "
                + "searchKeys: [\(searchIDs)], "
                + "modelKey: \(held(modelKey)), searchKey: \(held(searchKey)), "
                + "readerKey: \(held(readerKey)))"
        }

        var debugDescription: String { description }

        /// The third way this value gets printed, and the one neither description above
        /// covers. `dump()` — and anything else built on `Mirror`, which is most of what
        /// a debugger and a crash reporter use — ignores both and walks the stored
        /// properties instead, which here means every key in the clear. Redacting the
        /// descriptions and leaving reflection alone would have moved the hole rather
        /// than closed it, so the mirror shows the same redacted line.
        var customMirror: Mirror {
            Mirror(self, children: ["description": description], displayStyle: .struct)
        }

        init(settings: ProviderSettings,
             modelKey: String?,
             searchKey: String?,
             readerKey: String? = nil,
             modelKeys: [UUID: String]? = nil,
             searchKeys: [UUID: String]? = nil) {
            self.settings = settings
            self.modelKey = modelKey
            self.searchKey = searchKey
            self.readerKey = readerKey
            // Same shape as `modelKeys` below, and for the same callers: a test or the
            // single-provider construction that knows only the selected engine still
            // gets a map with that engine's key in it rather than an empty one.
            if let searchKeys {
                self.searchKeys = searchKeys
            } else if let searchKey, let selected = settings.selectedSearch {
                self.searchKeys = [selected.id: searchKey]
            } else {
                self.searchKeys = [:]
            }
            // Callers that know only about the selected provider — the tests, and the
            // single-provider construction the Linux front end uses — still get a
            // working one-element chain rather than a chain with no key in it.
            if let modelKeys {
                self.modelKeys = modelKeys
            } else if let modelKey, let selected = settings.selectedModel {
                self.modelKeys = [selected.id: modelKey]
            } else {
                self.modelKeys = [:]
            }
        }

        /// Reads the current settings and secrets. Called at the start of a turn.
        ///
        /// The model key comes from the *selected* provider's own account, not from a
        /// fixed one: each configured provider has a slot of its own, and reading the
        /// wrong one would send a working key to a second provider that has never seen
        /// it. Capturing it here — with the rest of the environment, once — is also what
        /// makes switching providers mid-run impossible.
        init(preferences: CorePreferences, secrets: SecretStore) {
            let settings = preferences.providerSettings
            self.init(settings: settings,
                      modelKey: secrets.modelKey(for: settings),
                      searchKey: secrets.searchKey(for: settings),
                      readerKey: secrets.value(for: .readerAPIKey),
                      modelKeys: secrets.modelKeys(for: settings),
                      searchKeys: secrets.searchKeys(for: settings))
        }
    }

    enum Mode {
        /// The full pipeline.
        case research
        /// No search: answer from the model's own knowledge, badged as unsourced.
        case direct
        /// The full pipeline, but the plan is allowed to come back for more. Each round
        /// reads what the last one found and asks for what is still missing; the answer
        /// is written once, over everything gathered.
        ///
        /// Evidence is kept whole rather than summarised between rounds. The answer may
        /// cite only the numbered sources this turn collected, so a digest would buy
        /// room by dissolving the very things the citations point at. Rounds stop when
        /// the budget is close to spent instead — see `deepRoundsAreWorthwhile`.
        case deep

        /// Every mode but `direct` gathers evidence before answering.
        var searches: Bool { self != .direct }

        /// What the trace calls this. Named here rather than spelled at the call site,
        /// which was a ternary and so had no room for a third answer — it would have
        /// logged `deep` turns as `research` and been right about nothing.
        var traceName: String {
            switch self {
            case .research: return "research"
            case .direct: return "direct"
            case .deep: return "deep"
            }
        }
    }

    /// The most rounds of planning `deep` may run, the first included.
    ///
    /// Three, because the second round is where the gaps the first could not have known
    /// about get asked, and the third is where a gap the second opened gets closed. A
    /// fourth mostly re-asks the third in other words, and each round is
    /// `maxSearches` billed requests.
    static let maxDeepRounds = 3

    /// What the rounds have found, for the follow-up planner to read the gaps in.
    ///
    /// Titles and snippets, capped, and never page text. This goes to a call that chooses
    /// the next queries and cites nothing, so it can be as lossy as it likes — which is
    /// exactly why the *evidence* is not summarised the same way: only the answer cites,
    /// and it must have the sources themselves.
    private static func digest(of sources: [Source]) -> String {
        // `suffix`, not `prefix`. This list is cumulative, so once several engines over
        // several rounds push it past the cap, taking from the front would show a later
        // planner the round-one material it has already planned against and hide what the
        // round before it just found — the opposite of reading the gaps.
        sources.suffix(40).enumerated().map { index, source in
            let snippet = source.snippet.prefix(200)
            return "\(index + 1). \(source.title) — \(snippet)"
        }.joined(separator: "\n")
    }

    /// The most searches one *plan* may ask for. Past three or four the marginal source
    /// rarely changes the answer.
    ///
    /// Not the same as the number of billed requests, which it used to be. A `deep` turn
    /// puts each planned search to every engine still answering, over as many as
    /// `maxDeepRounds` rounds, so the ceiling on requests is this times the engines times
    /// the rounds. That is the cost of a wider net and it is the reader's to choose by
    /// configuring a second engine — but it should be said plainly here rather than left
    /// for someone to discover on a metered account.
    static let maxSearches = 4

    private let environment: Environment
    private let trace: ResearchTrace
    private let transport: HTTPTransport

    /// The turn being run, and where to report it. Instance state rather than threaded
    /// through every stage: a runner executes exactly one turn, and passing an
    /// `inout`-taking closure down into an escaping streaming callback is not
    /// expressible without making it escape anyway.
    private var current: ResearchTurn?
    private var report: ((ResearchTurn) -> Void)?

    init(environment: Environment, trace: ResearchTrace, transport: HTTPTransport = .shared) {
        self.environment = environment
        self.trace = trace
        self.transport = transport
    }

    // MARK: Running

    /// Runs `turn` to a terminal stage and returns it.
    ///
    /// Never throws: a failure, a cancellation and a success are all states *of the
    /// turn*, because a half-finished answer with its sources is still worth showing.
    /// `onUpdate` receives a snapshot after every mutation, including one per streamed
    /// chunk.
    func run(_ turn: ResearchTurn,
             mode: Mode,
             history: [ResearchTurn],
             onUpdate: @escaping (ResearchTurn) -> Void) async -> ResearchTurn {
        current = turn
        report = onUpdate

        do {
            try await execute(question: turn.question, mode: mode, history: history)
            update { turn in
                turn.stage = .complete
                turn.duration = Date().timeIntervalSince(turn.askedAt)
            }
        } catch {
            // Cancellation reaches here two ways: as `CancellationError` from a
            // `Task.checkCancellation()` between stages, and as `ResearchError.cancelled`
            // from the transport, because URLSession surfaces a cancelled task as
            // `URLError.cancelled` rather than as a Swift concurrency error. Both are a
            // cancellation, not a failure — reporting the second as "Research failed"
            // would blame the user's configuration for their own Stop press.
            let cancelled = error is CancellationError
                || (error as? ResearchError) == ResearchError.cancelled
                || Task.isCancelled
            if cancelled {
                update { turn in
                    turn.stage = .cancelled
                    turn.duration = Date().timeIntervalSince(turn.askedAt)
                }
            } else {
                trace.warn("Run failed: \(ResearchError.safeLabel(for: error))")
                update { turn in
                    turn.failure = (error as? ResearchError)?.message
                        ?? "Research failed. Check the provider settings and try again."
                    turn.stage = .failed
                    turn.duration = Date().timeIntervalSince(turn.askedAt)
                }
            }
            // A partial answer is kept on purpose — a half-written answer with its
            // sources is still worth showing — and it deserves the same scrutiny as a
            // whole one. The validation after a successful stream is never reached on
            // this path, and a literal URL the model wrote in paragraph two must carry
            // its warning even if the user stopped in paragraph three.
            update { turn in
                if !turn.answer.isEmpty {
                    turn.applyCitationValidation(sourceCount: turn.sources.count)
                }
            }
        }
        let finished = current ?? turn
        current = nil
        report = nil
        return finished
    }

    /// Applies `body` to the turn and reports the result.
    private func update(_ body: (inout ResearchTurn) -> Void) {
        guard var turn = current else { return }
        body(&turn)
        current = turn
        report?(turn)
    }

    // MARK: Pipeline

    private func execute(question: String, mode: Mode, history: [ResearchTurn]) async throws {
        let settings = environment.settings
        let problems = settings.problems(hasModelKey: environment.modelKey != nil,
                                         hasSearchKey: environment.searchKey != nil,
                                         requiresSearch: mode.searches)
        guard problems.isEmpty else {
            throw ResearchError("Vervellum is not configured yet. " + problems.joined(separator: " "))
        }
        guard ProviderSettings.chatCompletionsURL(from: settings.modelEndpoint) != nil else {
            throw ResearchError("The model endpoint is not a usable URL. Check the provider settings.")
        }

        // Every model call this turn makes goes through the chain, which is the selected
        // provider alone when fallback is off — the gate is in `ProviderSettings`, where
        // `modelChain` collapses to `[selected]`, and it is named here because a reader
        // otherwise has to open another file to be sure the off switch is wired to
        // anything. A switch renames the turn's model and posts a notice, so the
        // attribution shown to the reader is always the provider that actually produced
        // the words.
        let chain = ModelChain(profiles: settings.modelChain, keys: environment.modelKeys,
                               trace: trace, transport: transport)
        // Nothing is hooked here. Both halves of what the reader is told — the name on
        // the turn and the note explaining it — are settled after the stage that produced
        // the words, because both are statements about the answer. A turn whose answer
        // streamed from the selection can still fall through for the assessment, and a
        // notice fired there would say "the next provider answered instead" over an
        // answer the badge correctly credits to the selection. So the chain is asked who
        // answered, at the one moment the question has a right answer, rather than
        // announcing every provider it starts.
        let today = ResearchContext.todayString()

        trace.log("Turn started mode=\(mode.traceName) history=\(history.count)")

        if mode == .direct {
            try await answerDirectly(chain: chain, question: question, history: history, today: today)
            return
        }

        // 1 — connect to search first. A missing or rejected search key should fail
        // before the (billable, slower) planning call, not after it.
        //
        // Which backend that is comes from the selected search provider: an MCP server
        // that advertises its own tool, or a SearXNG instance answering its JSON API
        // directly. Everything below this line is written against `SearchBackend` and
        // does not know which — the planner writes arguments against whatever schema was
        // advertised, and `EvidenceExtractor` walks any result shape.
        guard let searchProfile = settings.selectedSearch else {
            throw ResearchError("No web-search provider is configured. Check the provider settings.")
        }
        update { $0.stage = .planning }
        let search = try SearchBackendFactory.make(profile: searchProfile,
                                                  apiKey: environment.searchKey,
                                                  trace: trace, transport: transport)
        try await search.connect()
        try Task.checkCancellation()

        // The selected engine, and for `deep` every other configured one behind it.
        //
        // The selected engine still throws when it cannot be built or connected, in every
        // mode: a turn whose chosen engine is misconfigured should say so rather than
        // quietly research with somebody else. The extras are best effort — the posture
        // `ModelChain` takes toward a half-configured provider — because adding a second
        // engine must not be able to break a turn the first can serve alone.
        //
        // Worth having because two engines disagree. Different indexes and different
        // ranking mean different top results, and for a question worth several rounds the
        // disagreement is most of what the second engine is for. Overlap costs nothing:
        // `EvidenceExtractor.sources` deduplicates by URL across everything it is handed,
        // and it is handed every round's results at once.
        var engines: [SearchBackend] = [search]
        if mode == .deep {
            for profile in settings.searchProfiles where profile.id != searchProfile.id {
                do {
                    let spare = try SearchBackendFactory.make(
                        profile: profile, apiKey: environment.searchKeys[profile.id],
                        trace: trace, transport: transport)
                    try await spare.connect()
                    engines.append(spare)
                } catch is CancellationError {
                    throw ResearchError.cancelled
                } catch let error as ResearchError where error == .cancelled {
                    throw error
                } catch {
                    // Everything else, not only `ResearchError`. The comment above promises
                    // a spare cannot break a turn the selected engine can serve alone, and
                    // a catch narrowed to one error type does not keep that promise: the
                    // transport is entitled to throw `URLError` and the chain's own
                    // fallback code already says in as many words that a non-`ResearchError`
                    // can reach it. Only a Stop propagates.
                    let reason = (error as? ResearchError)?.message ?? String(describing: error)
                    trace.warn("Search engine \(profile.displayName) is not usable: \(reason)")
                }
                try Task.checkCancellation()
            }
            trace.log("Deep research over \(engines.count) search engine(s)")
        }

        // 2 — plan.
        let planContext = ResearchContext.assemble(
            question: question, history: history, today: today,
            extra: ["search_tool": search.toolDescriptor])
        if planContext.trimmed { update { $0.addNotice(.contextTrimmed) } }

        // Parsed *inside* the chain, not after it. A provider that answers with valid
        // JSON in the wrong shape has failed at the same job as one that answers with
        // no JSON at all, and only the second was worth another provider while the
        // first killed the turn. `PlanParser`'s own messages give the game away — "Try
        // again or choose another model" is the advice the chain exists to take.
        let plan = try await chain.perform("Plan") { chat in
            let object = try await chat.completeJSON(
                system: ResearchPrompts.plan(maxSearches: Self.maxSearches, today: today),
                payload: planContext.payload, label: "Plan")
            return try PlanParser.parse(object, maxSearches: Self.maxSearches)
        }
        update { turn in
            turn.reading = plan.reading
            turn.searches = plan.searches
        }
        trace.log("Plan: \(plan.searches.count) searches")
        try Task.checkCancellation()

        // The planner is allowed to decide that a question needs no evidence — a
        // definition, a calculation, a transformation of text the user supplied — and
        // `PlanParser` preserves that as an empty list rather than an error. Honour it:
        // answer from the model alone, badged exactly as `/direct` is, instead of failing
        // the turn with "no sources were found" for a question that never asked for any.
        // The reading stays on the turn, because it is where the planner says why.
        if plan.searches.isEmpty {
            trace.log("Plan asked for no searches; answering without evidence")
            update { turn in
                turn.addNotice(.noEvidence)
                // The reading is also the discriminator between "the planner chose not
                // to search" and "/direct" (see `wasAskedDirectly`): a planner that
                // returned an empty list and no reading would otherwise make Retry
                // re-ask in direct mode, skipping the planner the user never opted out of.
                if turn.reading.isEmpty {
                    turn.reading = "The planner decided this question needs no web evidence."
                }
            }
            try await answerDirectly(chain: chain, question: question, history: history, today: today)
            return
        }

        // 3 — search. Sequential on purpose: the MCP session is stateful, and one
        // JSON-RPC id sequence over one connection is the only shape the server
        // documents. Four searches at ~1s each is well inside the user's patience.
        update { $0.stage = .searching }
        var rawResults: [Any] = []
        var searchFailures: [String] = []
        var attempted = 0

        // One round's searches, asked of every engine still in the running. Returns the
        // engines that answered with something, so a later round can stop asking the ones
        // that did not — the plan is written against the selected engine's `inputSchema`,
        // and an engine declaring a different one refuses those arguments every time. It
        // costs a request per search to find that out once; it should not cost one per
        // round.
        func runSearches(_ planned: [PlannedSearch], across asked: [SearchBackend]) async throws
            -> [SearchBackend] {
            var productive: Set<ObjectIdentifier> = []
            for step in planned {
                try Task.checkCancellation()
                for engine in asked {
                    do {
                        let label = asked.count > 1
                            ? "Search \(attempted + 1) via \(engine.backendName)"
                            : "Search \(attempted + 1)"
                        let result = try await trace.stage(label) {
                            try await engine.search(arguments: step.arguments)
                        }
                        // Structure only — keys, counts and sizes, never a title or a
                        // link — so a result the extractor cannot read is diagnosable
                        // from a log that must not contain results.
                        // The same label the stage used, so two engines answering one
                        // planned search do not emit two identical lines about different
                        // shapes — which is the case this log exists for.
                        trace.log(label + " result shape: "
                                  + "\(EvidenceExtractor.shape(of: result))")
                        rawResults.append(result)
                        productive.insert(ObjectIdentifier(engine))
                    } catch is CancellationError {
                        throw ResearchError.cancelled
                    } catch let error as ResearchError where error == .cancelled {
                        throw error
                    } catch {
                        // One failed search must not lose the others, and in `deep` that
                        // now means the other engines and every earlier round too — a turn
                        // may have spent a dozen billed requests before reaching here.
                        // Narrowed to `ResearchError` this caught none of the failures the
                        // transport can raise on its own. A cancellation is not a failed
                        // search and still propagates.
                        let reason = (error as? ResearchError)?.message ?? String(describing: error)
                        trace.warn("Search \(attempted + 1) failed on "
                                   + "\(engine.backendName): \(reason)")
                        searchFailures.append(reason)
                    }
                }
                // Counted whether the attempts succeeded or failed, and once per planned
                // search rather than once per request: "2 of 3" is about the plan the
                // reader can see, not about how many engines it was put to.
                attempted += 1
                update { $0.searchesCompleted = attempted }
            }
            return asked.filter { productive.contains(ObjectIdentifier($0)) }
        }

        engines = try await runSearches(plan.searches, across: engines)

        // 3a — later rounds, `deep` only. Each reads what is on the table and asks for
        // what the first round could not have known was missing, because the gap does not
        // exist until something has been looked up.
        //
        // Evidence is carried whole between rounds rather than summarised. The answer may
        // cite only the numbered sources this turn collected, so a digest would buy room
        // by dissolving the things the citations point at. Rounds stop as the budget
        // fills instead — and the budget is asked with the same trimmer that will decide
        // what the answer sees, rather than a second rule that could disagree with it.
        // The follow-up *planner* is given a digest, which is a different matter: it
        // chooses queries and never cites.
        // `maxDeepRounds > 1` before the range: `2...1` is a runtime trap rather than an
        // empty loop, so setting the ceiling to one round would crash every deep turn
        // instead of quietly doing one. The constant is meant to be tuneable.
        if mode == .deep, !engines.isEmpty, Self.maxDeepRounds > 1 {
            var everySearch = plan.searches
            for round in 2...Self.maxDeepRounds {
                try Task.checkCancellation()
                let soFar = EvidenceExtractor.sources(from: rawResults)
                guard ResearchContext.evidence(from: soFar).dropped == 0 else {
                    trace.log("Round \(round) not run: the evidence budget is already full")
                    break
                }

                update { $0.stage = .planning }
                let followContext = ResearchContext.assemble(
                    question: question, history: history, today: today,
                    extra: ["search_tool": search.toolDescriptor,
                            "found": Self.digest(of: soFar)])
                // `try?`, because a later round failing to plan is not a reason to lose
                // the turn. Everything gathered so far is still good evidence and still
                // answers the question; the rounds are an improvement on one pass, not a
                // precondition for any answer at all. The loop already treats an *empty*
                // plan as a clean stop, and an unparseable one had no such courtesy — so
                // a malformed reply on round three discarded two rounds of billed
                // searches, which is the most expensive way this feature could fail.
                let follow = try? await chain.perform("Plan \(round)") { chat in
                    let object = try await chat.completeJSON(
                        system: ResearchPrompts.deepFollowUp(maxSearches: Self.maxSearches,
                                                             today: today,
                                                             round: round,
                                                             of: Self.maxDeepRounds),
                        payload: followContext.payload, label: "Plan \(round)")
                    return try PlanParser.parse(object, maxSearches: Self.maxSearches)
                }
                // Before the guard, because `try?` swallows the cancellation too: a Stop
                // during planning must end the turn rather than quietly settle for the
                // evidence already in hand.
                try Task.checkCancellation()
                guard let follow else {
                    trace.warn("Round \(round) could not be planned; "
                               + "answering from the evidence already gathered")
                    break
                }

                // An empty plan is the documented way to stop, not a failure: a round with
                // nothing left worth asking should say so rather than fill its quota.
                guard !follow.searches.isEmpty else {
                    trace.log("Round \(round) found nothing left to ask; stopping")
                    break
                }

                everySearch += follow.searches
                // The reader sees every round's searches, not just the first plan's:
                // `searchesCompleted` counts against this list, and a list that stopped
                // growing would leave the progress label counting past its own total.
                update { $0.searches = everySearch }
                update { $0.stage = .searching }
                engines = try await runSearches(follow.searches, across: engines)
                if engines.isEmpty {
                    trace.warn("No search engine is still answering; stopping the rounds")
                    break
                }
            }
        }

        var harvested = EvidenceExtractor.sources(from: rawResults)

        // 3b — read the pages behind the top sources, if the user asked for that.
        //
        // Before the budget, not after: what the model is shown has to be decided with
        // the page text in hand, or a page would be fetched and then silently dropped.
        // Still inside the searching stage — see `ResearchTurn.runningProgressLabel` for
        // why this does not get a `ResearchStage` case of its own.
        harvested = await readPages(harvested, settings: settings)
        try Task.checkCancellation()

        // Trimmed to what fits the evidence budget *before* it becomes the turn's source
        // list. The model is only shown the kept prefix, so a turn that recorded the
        // full list would validate the answer's citations against sources the model
        // never saw, and would offer the reader a source list the answer could not have
        // used.
        let (evidence, droppedSources, withheldPageText) = ResearchContext.evidence(from: harvested)
        var sources = Array(harvested.prefix(evidence.count))
        // A page that did not fit is cleared from the source too, so the list the reader
        // sees and the evidence the model saw agree about which pages were read.
        for index in sources.indices where withheldPageText.contains(sources[index].number) {
            sources[index].fullText = nil
        }
        let kept = sources
        update { turn in
            turn.sources = kept
            turn.pagesRead = kept.filter { $0.wasRead }.count
        }
        if droppedSources > 0 {
            trace.log("Evidence budget dropped \(droppedSources) sources")
            update { $0.addNotice(.evidenceTrimmed) }
        }
        if !withheldPageText.isEmpty {
            trace.log("Evidence budget withheld \(withheldPageText.count) page texts")
            update { $0.addNotice(.pageTextTrimmed) }
        }
        trace.log("Evidence: \(sources.count) sources from \(rawResults.count) results")

        guard !sources.isEmpty else {
            // Two different situations used to share one message that blamed the
            // question for both. Say which it was: the searches themselves failed, or the
            // server answered and nothing usable came back.
            if rawResults.isEmpty, let reason = searchFailures.first {
                throw ResearchError("Every web search failed. " + reason)
            }
            throw ResearchError(
                "The web search returned no usable sources for this question. Try rephrasing "
                + "it, or use /direct to answer without evidence.")
        }
        try Task.checkCancellation()

        // 4 — answer, streamed.
        update { $0.stage = .answering }
        let searchesRun: [[String: String]] = plan.searches.map {
            ["purpose": $0.purpose, "query": $0.displayQuery]
        }
        let answerExtra: [String: Any] = [
            "reading": plan.reading,
            "searches_run": searchesRun,
            "evidence": evidence,
            "highest_source_number": evidence.compactMap { $0["number"] as? Int }.max() ?? 0,
        ]
        let answerContext = ResearchContext.assemble(
            question: question, history: history, today: today, extra: answerExtra)
        if answerContext.trimmed { update { $0.addNotice(.contextTrimmed) } }

        // A provider that dies mid-sentence has already streamed text into the turn, and
        // the next provider starts its answer from the beginning. Without the reset the
        // two would be concatenated into a paragraph neither model wrote — so the
        // fragment is discarded before the retry. The reader sees the answer restart,
        // which is honest, rather than a seam they cannot see.
        let answer = try await chain.perform("Answer", beforeRetry: { [weak self] in
            self?.update { $0.answer = "" }
        }) { chat in
            try await chat.streamText(
                system: ResearchPrompts.answer, payload: answerContext.payload, label: "Answer"
            ) { [weak self] chunk in
                self?.update { $0.answer += chunk }
            }
        }
        recordAnsweringModel(from: chain)
        update { $0.applyCitationValidation(sourceCount: sources.count) }
        try Task.checkCancellation()

        // 5 — assess.
        update { $0.stage = .assessing }
        // Assessment is a fresh call: carry the reading and budgeted history too.
        let assessContext = ResearchContext.assemble(
            question: question, history: history, today: today,
            extra: ["answer": answer, "evidence": evidence, "reading": plan.reading])
        if assessContext.trimmed { update { $0.addNotice(.contextTrimmed) } }
        // A failure here — a reply the parser cannot read, an output limit smaller
        // than eight findings, a transient 5xx — must not fail the turn. The answer has
        // streamed, been validated and been read; marking it failed would label it
        // wrong, drop it from every later turn's context (which keeps `.complete` turns
        // only), and blame the question for an assessment that was cut off. So the turn
        // completes without findings and says, in a notice, that nothing was checked.
        // Cancellation still propagates: a Stop is a Stop.
        let assessment: AssessmentParser.Assessment
        do {
            let assessObject = try await chain.perform("Assess") { chat in
                try await chat.completeJSON(
                    system: ResearchPrompts.assess, payload: assessContext.payload, label: "Assess")
            }
            assessment = try AssessmentParser.parse(assessObject, sourceCount: sources.count)
        } catch let error as ResearchError where error != ResearchError.cancelled && !Task.isCancelled {
            trace.warn("Assessment unavailable: \(error.message)")
            update { $0.addNotice(.assessmentUnavailable) }
            return
        }
        update { turn in
            turn.findings = assessment.findings
            turn.limitations = assessment.limitations
            turn.followups = assessment.followups
            for notice in assessment.notices { turn.addNotice(notice) }
        }
        trace.log("Assessment: \(assessment.findings.count) findings in "
                  + String(format: "%.1fs", trace.elapsed))
    }

    /// Reads the pages behind the highest-ranked sources, when page reading is on.
    ///
    /// Best-effort throughout, and deliberately so. A reader that cannot be built (a
    /// missing key, an unusable endpoint), a handshake that fails, a page behind a
    /// consent wall — none of those fails the turn. They leave every source with its
    /// snippet, which is exactly the behaviour of the mode that is off, and the notice
    /// says so rather than the run collapsing over an enrichment.
    private func readPages(_ sources: [Source], settings: ProviderSettings) async -> [Source] {
        guard settings.pageReading != .off, !sources.isEmpty else { return sources }

        let reader: PageReading?
        do {
            reader = try PageReaderFactory.make(settings: settings, readerKey: environment.readerKey,
                                                trace: trace, transport: transport)
            try await reader?.connect()
        } catch {
            trace.warn("Page reading unavailable: \(ResearchError.safeLabel(for: error))")
            update { $0.addNotice(.noPagesRead) }
            return sources
        }
        guard let reader else { return sources }

        let targets = Array(sources.prefix(PageReaderFactory.maxPages))
        update { $0.pagesAttempted = targets.count }
        // Not `trace.stage`, which is for throwing work: reading never throws, because
        // a page that cannot be read is a source that keeps its snippet.
        let started = trace.elapsed
        let pages = await reader.read(targets)
        // Interpolate the name, format only the number — the shape the other trace lines
        // in this file already use.
        trace.log("Read pages via \(reader.readerName) in "
                  + String(format: "%.1fs", trace.elapsed - started))

        var enriched = sources
        for index in enriched.indices {
            guard let text = pages[enriched[index].number], !text.isEmpty else { continue }
            enriched[index].fullText = text
        }
        let read = pages.values.filter { !$0.isEmpty }.count
        update { $0.pagesRead = read }
        trace.log("Pages read: \(read) of \(targets.count)")
        if read == 0 { update { $0.addNotice(.noPagesRead) } }
        return enriched
    }

    /// The `/direct` path: one streamed call, no search, no citations.
    private func answerDirectly(chain: ModelChain,
                                question: String,
                                history: [ResearchTurn],
                                today: String) async throws {
        update { $0.stage = .answering }
        let context = ResearchContext.assemble(question: question, history: history, today: today)
        if context.trimmed { update { $0.addNotice(.contextTrimmed) } }
        // Same reset as the research path's answer stage, for the same reason.
        _ = try await chain.perform("Direct answer", beforeRetry: { [weak self] in
            self?.update { $0.answer = "" }
        }) { chat in
            try await chat.streamText(
                system: ResearchPrompts.direct, payload: context.payload, label: "Direct answer"
            ) { [weak self] chunk in
                self?.update { $0.answer += chunk }
            }
        }
        recordAnsweringModel(from: chain)
        // The same check the research path makes after its answer. A Stop pressed
        // mid-stream ends the stream rather than failing it, and without this the
        // fragment would be completed, persisted and sent as history to every later
        // turn in the thread.
        try Task.checkCancellation()
        // Citations are meaningless here, but a model that emitted a URL anyway is
        // exactly the failure the badge needs to warn about.
        update { $0.applyCitationValidation(sourceCount: 0) }
    }

    /// Records which provider produced the answer, on every turn.
    ///
    /// Called straight after the answering stage, before the assessment can move the
    /// chain on. Until now this was written only when a fallback happened, so the badge
    /// in `TurnView` appeared exactly when something had gone wrong and stayed blank the
    /// rest of the time — which is close to the opposite of what a field documented as
    /// "the model that produced the answer" is for.
    private func recordAnsweringModel(from chain: ModelChain) {
        guard let profile = chain.lastAnswered else {
            // Unreachable: every caller sits directly after a `perform` that returned,
            // and every return writes this. If it ever trips, the wiring is wrong in
            // exactly the way this function exists to fix, and a blank badge is the only
            // symptom — so fail where it can be found instead.
            assertionFailure("The answer streamed but no provider was recorded for it.")
            // And a line for the builds where that assertion is compiled out, which are
            // the ones a reader would be running when they noticed the blank badge.
            trace.warn("The answer finished with no provider recorded; the turn is unattributed.")
            return
        }
        update { turn in
            turn.model = profile.model
            // The note goes with the name, and says what the name shows: the answer came
            // from somewhere other than the selection.
            if profile.id != chain.head?.id { turn.addNotice(.modelFellBack) }
        }
    }
}
