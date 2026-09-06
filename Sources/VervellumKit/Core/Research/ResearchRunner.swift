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
final class ResearchRunner {

    /// Everything a run needs from the outside world, captured once so the settings
    /// cannot change halfway through a turn.
    struct Environment {
        var settings: ProviderSettings
        var modelKey: String?
        var searchKey: String?

        init(settings: ProviderSettings, modelKey: String?, searchKey: String?) {
            self.settings = settings
            self.modelKey = modelKey
            self.searchKey = searchKey
        }

        /// Reads the current settings and secrets. Called at the start of a turn.
        init(preferences: CorePreferences, secrets: SecretStore) {
            self.init(settings: preferences.providerSettings,
                      modelKey: secrets.value(for: .modelAPIKey),
                      searchKey: secrets.value(for: .searchAPIKey))
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
        guard let endpoint = ProviderSettings.chatCompletionsURL(from: settings.modelEndpoint) else {
            throw ResearchError("The model endpoint is not a usable URL. Check the provider settings.")
        }

        let chat = ChatCompletionsClient(url: endpoint, model: settings.modelName,
                                         apiKey: environment.modelKey, trace: trace,
                                         transport: transport)
        let today = ResearchContext.todayString()

        trace.log("Turn started mode=\(mode == .direct ? "direct" : "research") history=\(history.count)")

        if mode == .direct {
            try await answerDirectly(chat: chat, question: question, history: history, today: today)
            return
        }

        // 1 — connect to search first. A missing or rejected search key should fail
        // before the (billable, slower) planning call, not after it.
        guard let searchKey = environment.searchKey,
              let searchEndpoint = ProviderSettings.validatedEndpointURL(settings.searchEndpoint) else {
            throw ResearchError("The web-search key or endpoint is missing. Check the provider settings.")
        }
        update { $0.stage = .planning }
        let search = SearchMCPClient(endpoint: searchEndpoint, apiKey: searchKey,
                                     trace: trace, transport: transport)
        try await search.connect()
        try Task.checkCancellation()

        // 2 — plan.
        // Built up rather than written as a nested literal: a heterogeneous literal in
        // an `Any` position cannot be inferred.
        var toolDescriptor: [String: Any] = ["name": search.tool?.name ?? ""]
        if let description = search.tool?.description, !description.isEmpty {
            toolDescriptor["description"] = description
        }
        toolDescriptor["inputSchema"] = search.tool?.inputSchema ?? [String: Any]()

        let planContext = ResearchContext.assemble(
            question: question, history: history, today: today,
            extra: ["search_tool": toolDescriptor])
        if planContext.trimmed { update { $0.addNotice(.contextTrimmed) } }

        let planObject = try await chat.completeJSON(
            system: ResearchPrompts.plan(maxSearches: Self.maxSearches, today: today),
            payload: planContext.payload, label: "Plan")
        let plan = try PlanParser.parse(planObject, maxSearches: Self.maxSearches)
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
            try await answerDirectly(chat: chat, question: question, history: history, today: today)
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
        }

        let harvested = EvidenceExtractor.sources(from: rawResults)
        // Trimmed to what fits the evidence budget *before* it becomes the turn's source
        // list. The model is only shown the kept prefix, so a turn that recorded the
        // full list would validate the answer's citations against sources the model
        // never saw, and would offer the reader a source list the answer could not have
        // used.
        let (evidence, droppedSources) = ResearchContext.evidence(from: harvested)
        let sources = Array(harvested.prefix(evidence.count))
        update { $0.sources = sources }
        if droppedSources > 0 {
            trace.log("Evidence budget dropped \(droppedSources) sources")
            update { $0.addNotice(.evidenceTrimmed) }
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

        let answer = try await chat.streamText(
            system: ResearchPrompts.answer, payload: answerContext.payload, label: "Answer"
        ) { [weak self] chunk in
            self?.update { $0.answer += chunk }
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
            let assessObject = try await chat.completeJSON(
                system: ResearchPrompts.assess, payload: assessContext.payload, label: "Assess")
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

    /// The `/direct` path: one streamed call, no search, no citations.
    private func answerDirectly(chat: ChatCompletionsClient,
                                question: String,
                                history: [ResearchTurn],
                                today: String) async throws {
        update { $0.stage = .answering }
        let context = ResearchContext.assemble(question: question, history: history, today: today)
        if context.trimmed { update { $0.addNotice(.contextTrimmed) } }
        _ = try await chat.streamText(
            system: ResearchPrompts.direct, payload: context.payload, label: "Direct answer"
        ) { [weak self] chunk in
            self?.update { $0.answer += chunk }
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
