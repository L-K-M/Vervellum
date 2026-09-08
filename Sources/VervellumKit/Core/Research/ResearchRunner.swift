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
            func held(_ secret: String?) -> String { secret == nil ? "absent" : "present" }
            return "Environment(model: \(settings.modelName), "
                // The switch as well as the count. `modelChain` is the *effective* chain,
                // so five configured providers with fallback off print as `providers: 1`
                // — indistinguishable from having configured one, and "why was my spare
                // never tried" is the likeliest question this rendering has to answer.
                + "fallback: \(settings.modelFallback), "
                + "providers: \(settings.modelChain.count), modelKeys: [\(ids)], "
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
             modelKeys: [UUID: String]? = nil) {
            self.settings = settings
            self.modelKey = modelKey
            self.searchKey = searchKey
            self.readerKey = readerKey
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
                      modelKeys: secrets.modelKeys(for: settings))
        }
    }

    enum Mode {
        /// The full pipeline.
        case research
        /// No search: answer from the model's own knowledge, badged as unsourced.
        case direct
    }

    /// The most searches one turn may run. Each is a billed request, and past three or
    /// four the marginal source rarely changes the answer.
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
                                         requiresSearch: mode != .direct)
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
        chain.onSwitch = { [weak self] profile in
            self?.update { turn in
                turn.model = profile.model
                turn.addNotice(.modelFellBack)
            }
        }
        let today = ResearchContext.todayString()

        trace.log("Turn started mode=\(mode == .direct ? "direct" : "research") history=\(history.count)")

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
        for (index, planned) in plan.searches.enumerated() {
            try Task.checkCancellation()
            do {
                let result = try await trace.stage("Search \(index + 1)/\(plan.searches.count)") {
                    try await search.search(arguments: planned.arguments)
                }
                // Structure only — keys, counts and sizes, never a title or a link — so a
                // result the extractor cannot read is diagnosable from a log that must
                // not contain results.
                trace.log("Search \(index + 1) result shape: \(EvidenceExtractor.shape(of: result))")
                rawResults.append(result)
            } catch let error as ResearchError where error != ResearchError.cancelled {
                // One failed search must not lose the other three. Record it and go on;
                // if every search fails, the first reason is what the user is told below.
                // A cancellation is not a failed search and propagates.
                trace.warn("Search \(index + 1) failed: \(error.message)")
                searchFailures.append(error.message)
            }
            // Counted whether the attempt succeeded or failed: "2 of 3" means two
            // attempts are done, and a failed attempt is done.
            update { $0.searchesCompleted = index + 1 }
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
        // The same check the research path makes after its answer. A Stop pressed
        // mid-stream ends the stream rather than failing it, and without this the
        // fragment would be completed, persisted and sent as history to every later
        // turn in the thread.
        try Task.checkCancellation()
        // Citations are meaningless here, but a model that emitted a URL anyway is
        // exactly the failure the badge needs to warn about.
        update { $0.applyCitationValidation(sourceCount: 0) }
    }
}
