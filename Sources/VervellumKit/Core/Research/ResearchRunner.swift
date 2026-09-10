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
        /// the budget is close to spent instead — the check is inline in `execute`,
        /// asked with the same trimmer that decides what the answer sees.
        ///
        /// What a round may ask for is documented in `deepFollowUp`'s prompt: searches
        /// against the gap, and page reads by the digest's stable source numbers —
        /// the two moves the rounds exist to make.
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
    ///
    /// Each entry keeps the turn's own source number rather than being renumbered for the
    /// digest. The planner's output feeds stages that act on sources — which page to read
    /// in full is the planned one — and a local 1…40 numbering would make those answers
    /// point at the wrong page whenever the digest starts past source 40 or a linked page
    /// took number 1.
    private static func digest(of sources: [Source]) -> String {
        // `suffix`, not `prefix`. This list is cumulative, so once several engines over
        // several rounds push it past the cap, taking from the front would show a later
        // planner the round-one material it has already planned against and hide what the
        // round before it just found — the opposite of reading the gaps.
        //
        // A fetched page is marked rather than re-summarised: the planner asks for
        // pages by number, and without the mark it cannot tell what it already has —
        // it would spend fetches re-requesting pages the turn read a round ago.
        sources.suffix(40).map { source in
            let snippet = source.snippet.prefix(200)
            let fetched = source.wasRead ? " [read]" : ""
            return "\(source.number). \(source.title)\(fetched) — \(snippet)"
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
    private let transport: any HTTPTransporting
    /// How a search backend that is a *program* rather than a server is run. Held
    /// alongside the transport and for the same reason: it is the seam a test replaces to
    /// drive a whole turn without the thing on the other side existing.
    private let commandRunner: any CommandRunning
    /// The bytes behind an attachment on the turn being run.
    ///
    /// A closure rather than a store, so this file does no file IO and a test can attach
    /// an image without a directory existing. It answers nil for an attachment whose
    /// bytes are gone — a library copied without its attachments folder — and the turn
    /// carries on without the picture, saying `attachmentMissing` so the reader knows.
    ///
    /// It has no default, deliberately. A default of "no bytes, ever" would compile
    /// everywhere and leave any caller that forgot it with a build where every
    /// attachment is silently unreadable — a feature dead on arrival with one trace line
    /// to show for it. A front end with no attachments says so in one line instead.
    private let attachmentBytes: (Attachment) -> Data?

    /// The turn being run, and where to report it. Instance state rather than threaded
    /// through every stage: a runner executes exactly one turn, and passing an
    /// `inout`-taking closure down into an escaping streaming callback is not
    /// expressible without making it escape anyway.
    private var current: ResearchTurn?
    private var report: ((ResearchTurn) -> Void)?

    init(environment: Environment, trace: ResearchTrace,
         transport: any HTTPTransporting = HTTPTransport.shared,
         commandRunner: any CommandRunning = CommandRunner.shared,
         attachmentBytes: @escaping (Attachment) -> Data?) {
        self.environment = environment
        self.trace = trace
        self.transport = transport
        self.commandRunner = commandRunner
        self.attachmentBytes = attachmentBytes
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

    /// The current turn's attachments, split into what each stage can use: text to inline
    /// in the payload, images to hang off the user message.
    ///
    /// Done once per turn rather than per stage, because reading and base64-encoding a
    /// four-megabyte screenshot twice is two seconds of the user's turn spent producing
    /// bytes that are identical.
    ///
    /// Only counts reach the trace. A file name is the user's own text, and this log has
    /// the same rule for it as for a page's: it records shape, never content.
    ///
    /// An attachment that cannot be sent — its bytes gone, or text that no longer
    /// decodes — raises `attachmentMissing` on the turn rather than disappearing. The
    /// turn still lists it, because it is a record of what was asked; saying nothing
    /// would leave a reader with an answer that ignores a file for no visible reason.
    private func preparedAttachments() -> (payload: [[String: String]],
                                           images: [ChatCompletionsClient.ImagePart],
                                           imageNames: [String]) {
        let attachments = current?.attachments ?? []
        guard !attachments.isEmpty else { return ([], [], []) }

        var payload: [[String: String]] = []
        var images: [ChatCompletionsClient.ImagePart] = []
        var imageNames: [String] = []
        var lost: [String] = []
        for attachment in attachments {
            // Empty bytes are no more readable than bytes that are gone, and an image
            // part carrying an empty `data:` URL is a thing no provider can do anything
            // with. `Attachment.make` refuses an empty file, so this is storage that was
            // truncated rather than anything a user chose.
            guard let data = attachmentBytes(attachment), !data.isEmpty else {
                lost.append(attachment.name)
                continue
            }
            switch attachment.kind {
            case .image:
                images.append(ChatCompletionsClient.ImagePart(
                    mediaType: attachment.mediaType, base64: data.base64EncodedString()))
                // Kept beside the bytes because a provider without eyes needs the *name*
                // and nothing else: an image that cannot be sent has to be named to the
                // model as unavailable, exactly as a lost one is.
                imageNames.append(attachment.name)
                // And named when it *is* sent, which was the asymmetry: a withheld
                // image was announced by name while a delivered one arrived as
                // anonymous pixels. A question is written about files the way the user
                // sees them — "compare a.png and b.png", "the top left of the second
                // screenshot" — and with four allowed per question, a model given
                // pictures in order and no names cannot resolve either one.
                //
                // `sent` rather than a bare entry, so the withheld merges below can tell
                // the two apart and never list one image as both sent and unavailable.
                payload.append(["name": attachment.name, "sent": "yes"])
            case .text:
                // Re-decoded rather than trusted: the record says what the bytes were
                // when they were stored, and the bytes are what is being sent now. A
                // file that no longer decodes counts as lost, for the same reason bytes
                // that are gone do — it is not being sent, and the reader has to know.
                if let text = Attachment.text(from: data) {
                    payload.append(["name": attachment.name, "text": text])
                } else {
                    lost.append(attachment.name)
                }
            case .other:
                // A kind a later build wrote. Nothing here knows how to send it, which
                // is a thing the reader has to be told rather than a thing to guess at.
                lost.append(attachment.name)
            }
        }
        // The model is told which names did not make it, not only the reader. Without
        // this it sees one of two attachments and has no idea the other existed, and the
        // answer prompt's rule about an attachment that is not present has nothing to
        // fire on. `unavailable` rather than an absent entry, because "there was a file
        // called this and you cannot see it" is the fact worth carrying.
        for name in lost { payload.append(["name": name, "unavailable": "yes"]) }
        // Counted, not derived. `payload.count - lost.count` was right only because the
        // loop above appends the lost names into `payload`, and nothing said so — a
        // third kind of entry would have made the log quietly wrong, in the one place
        // somebody looks to find out why their file was ignored.
        let sentText = payload.filter { $0["text"] != nil }.count
        trace.log("Attachments: \(images.count) image(s), \(sentText) text file(s)"
                  + (lost.isEmpty ? "" : ", \(lost.count) that could not be sent"))
        if !lost.isEmpty { update { $0.addNotice(.attachmentMissing) } }
        return (payload, images, imageNames)
    }

    /// The `extra` for an attempt that will carry no images: every picture named as
    /// unavailable rather than as sent.
    ///
    /// One function rather than three copies, because it encodes a policy and not a
    /// shape. The sent markers come off first — this payload belongs to a request with
    /// no image parts in it, so each one is about to be listed the other way, and a file
    /// named twice with opposite answers is worse than one named neither way. Spelled
    /// out three times, an edit to either marker that reached two sites would leave the
    /// third quietly telling the model something else.
    private static func namingImagesUnavailable(
        _ base: [String: Any],
        _ attachments: (payload: [[String: String]],
                        images: [ChatCompletionsClient.ImagePart],
                        imageNames: [String])) -> [String: Any] {
        base.merging([
            "attachments": attachments.payload.filter { $0["sent"] == nil }
                + attachments.imageNames.map { ["name": $0, "unavailable": "yes"] },
        ]) { _, new in new }
    }

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
        let attachments = preparedAttachments()

        if mode == .direct {
            try await answerDirectly(chain: chain, question: question, history: history,
                                     today: today, attachments: attachments)
            return
        }

        // 1 — connect to search first. A missing or rejected search key should fail
        // before the (billable, slower) planning call, not after it.
        //
        // Which backend that is comes from the selected search provider: an MCP server
        // that advertises its own tool, a SearXNG instance answering its JSON API
        // directly, or the Kagi command-line tool on this machine. Everything below this
        // line is written against `SearchBackend` and does not know which — the planner
        // writes arguments against whatever schema was advertised, and
        // `EvidenceExtractor` walks any result shape.
        guard let searchProfile = settings.selectedSearch else {
            throw ResearchError("No web-search provider is configured. Check the provider settings.")
        }
        update { $0.stage = .planning }
        let search = try SearchBackendFactory.make(profile: searchProfile,
                                                  apiKey: environment.searchKey,
                                                  trace: trace, transport: transport,
                                                  commandRunner: commandRunner)
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
                        trace: trace, transport: transport, commandRunner: commandRunner)
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

        // 1b — read what the question linked to, before anything is planned.
        //
        // Before the planner, not alongside the search results, because a link the user
        // pasted is not a candidate source — it is part of the question. What the page
        // says changes which searches are worth running: "is this benchmark sound?"
        // cannot be planned until the benchmark has been read. Reading it afterwards
        // would spend the whole search budget on the guesses a planner makes when it
        // has only the URL to go on.
        let (linked, linkedAttempts) = await readLinkedPages(in: question, settings: settings)
        // Reading three pages can take most of a minute at the per-page timeout, and
        // `PageReading.read` does not throw — so a Stop pressed during it is noticed
        // here rather than after a planning call the user has already cancelled.
        try Task.checkCancellation()

        // 2 — plan.
        var planExtra: [String: Any] = ["search_tool": search.toolDescriptor]
        // The whole text, not an excerpt as `linked_pages` gets. A linked page is
        // arbitrarily long and was fetched on the model's behalf; an attachment was
        // already truncated to `maxTextCharacters` when it was stored, and it is usually
        // the thing the question is *about* — a planner given half a log plans searches
        // for the half it saw.
        if !attachments.payload.isEmpty { planExtra["attachments"] = attachments.payload }
        if !linked.isEmpty {
            // Excerpts, not the pages. This call chooses queries and cites nothing, so
            // it needs to know what each page is about rather than what it says in full
            // — the same division the `deep` follow-up planner already makes. The whole
            // text goes to the answer, which is the call that may cite it.
            planExtra["linked_pages"] = linked.map { source in
                [
                    "number": source.number,
                    "url": source.url,
                    "title": source.title,
                    "excerpt": ResearchContext.shorten(source.fullText ?? "",
                                                       to: Self.linkedExcerptCharacters),
                ]
            }
        }
        let planContext = ResearchContext.assemble(
            question: question, history: history, today: today, extra: planExtra)
        if planContext.trimmed { update { $0.addNotice(.contextTrimmed) } }

        // Parsed *inside* the chain, not after it. A provider that answers with valid
        // JSON in the wrong shape has failed at the same job as one that answers with
        // no JSON at all, and only the second was worth another provider while the
        // first killed the turn. `PlanParser`'s own messages give the game away — "Try
        // again or choose another model" is the advice the chain exists to take.
        let planImages = attachments.images
        // The second payload for a planner with no eyes, built exactly as the answer
        // stage builds its own. This used to argue the other way — that naming a picture
        // the provider was not sent would be "a sentence about something that is not
        // there" — and the answer stage settles that argument against it. A question
        // *about* a screenshot, planned by a model with no screenshot and nothing saying
        // one was meant to be there, is planned from the words alone; being told the
        // picture exists and is unavailable is what lets it plan around the fact.
        let withheldPlanContext = planImages.isEmpty ? nil : ResearchContext.assemble(
            question: question, history: history, today: today,
            extra: Self.namingImagesUnavailable(planExtra, attachments))
        // Recorded, not logged, inside the closure: the closure runs once per provider
        // attempt, so a chain falling back through two providers without eyes wrote the
        // line twice and made one decision look like two. Same shape as the answer
        // stage's `sentImages`, which is where the pattern came from.
        var sentPlanImages = false
        let plan = try await chain.perform("Plan") { chat in
            // The planner is shown the picture when the provider can take one: an image
            // is very often what the question is *about*, and planning searches from the
            // words alone is the commonest way to search for the wrong thing.
            let images = chat.imagesWillBeSent ? planImages : []
            let object = try await chat.completeJSON(
                system: ResearchPrompts.plan(maxSearches: Self.maxSearches, today: today,
                                             hasLinkedPages: !linked.isEmpty,
                                             // `planImages`, not `images`: the turn
                                             // either carries attachments or it does
                                             // not, and which provider this attempt
                                             // reached does not change that. The payload
                                             // below says which of them actually came.
                                             hasAttachments: !planImages.isEmpty
                                                 || !attachments.payload.isEmpty),
                payload: images.isEmpty ? (withheldPlanContext ?? planContext).payload
                                        : planContext.payload,
                withoutImages: images.isEmpty ? nil : withheldPlanContext?.payload,
                label: "Plan", images: images)
            // Read after the call, not before: the provider may have refused the picture
            // and been sent the question without it, which is what `withheldImages`
            // records. Set before the call, this said "sent" for an image the endpoint
            // had just rejected.
            sentPlanImages = !images.isEmpty && !chat.withheldImages
            return try PlanParser.parse(object, maxSearches: Self.maxSearches)
        }
        // Said in the trace, because the turn's own notice is raised by the answer stage:
        // a plan made without the screenshot, on a chain that fell back to a provider
        // with no eyes, otherwise looks in the log exactly like a plan made with it.
        // The withheld payload is a superset of the ordinary one — the same evidence
        // plus an entry naming each picture — so it can trip the trimming budget where
        // the ordinary one did not, and the notice belongs to whichever payload actually
        // went. `addNotice` refuses a duplicate, so a retry that trims twice says it once.
        if !sentPlanImages, withheldPlanContext?.trimmed == true {
            update { $0.addNotice(.contextTrimmed) }
        }
        if !planImages.isEmpty, !sentPlanImages {
            trace.log("Plan: \(planImages.count) image(s) withheld — "
                      + "this provider is not being sent images")
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
        if plan.searches.isEmpty, linked.isEmpty {
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
            try await answerDirectly(chain: chain, question: question, history: history,
                                     today: today, attachments: attachments)
            return
        }
        if plan.searches.isEmpty {
            // The other half of that branch: a plan with no searches and a question that
            // carried links is not an unsourced turn — it is "read this and tell me",
            // which the linked pages answer on their own. It keeps the evidence path so
            // the answer is written over numbered sources it can cite, rather than being
            // badged `noEvidence` over pages Vervellum actually read.
            trace.log("Plan asked for no searches; answering from the linked page(s)")
        }

        // 3 — search. Stateless engines answer every (query, engine) pair
        // concurrently — deep mode multiplies searches by engines by rounds, and
        // serialising that is latency bought with nothing. Stateful backends (an MCP
        // session is one JSON-RPC id sequence over one connection) stay serial: the
        // protocol documents no other shape.
        update { $0.stage = .searching }
        var rawResults: [Any] = []
        var searchFailures: [String] = []
        /// The display query of every planned search that produced nothing usable on
        /// any engine — whether the engines errored or the index held nothing. Fed to
        /// the follow-up planner as `failed_queries`: a round that cannot tell "asked
        /// and got nothing" from "never asked" re-asks the dead query in new words and
        /// spends the budget proving the same nothing twice.
        var failedQueries: [String] = []
        var attempted = 0

        // One round's searches, asked of every engine still in the running. Returns the
        // engines that answered with something, so a later round can stop asking the ones
        // that did not — the plan is written against the selected engine's `inputSchema`,
        // and an engine declaring a different one refuses those arguments every time. It
        // costs a request per search to find that out once; it should not cost one per
        // round.
        //
        // Stateless engines run every pair of the round concurrently; stateful ones
        // stay serial. All shared state is mutated in this task only: the concurrent
        // tasks produce value-typed outcomes and the parent applies them as they
        // arrive, and the results are buffered and appended in (step, engine) order at
        // the end, because source numbering follows insertion order and a race would
        // renumber the evidence between runs of an identical turn.
        func runSearches(_ planned: [PlannedSearch], across asked: [SearchBackend]) async throws
            -> [SearchBackend] {
            // What one (step, engine) pair settled, whatever way it went. `Any` is the
            // raw JSON the extractor walks; it is produced in the task and only read in
            // the parent, which is what `@unchecked Sendable` certifies by hand.
            struct Outcome: @unchecked Sendable {
                let step: Int
                let engine: Int
                let result: Any?
                let fruitful: Bool
                let failure: String?
            }

            let indexed = Array(asked.enumerated())
            let stateless = indexed.filter { $0.element.supportsConcurrentCalls }
            let stateful = indexed.filter { !$0.element.supportsConcurrentCalls }

            var productive: Set<ObjectIdentifier> = []
            var fruitfulByStep: [Int: Int] = [:]
            var buffered: [Outcome] = []
            // Progress counts *planned searches*, not (search, engine) pairs — "2 of 3"
            // is about the plan the reader can see. A step completes when its last pair
            // does, whichever engine's that was.
            var pairsLeft = Dictionary(uniqueKeysWithValues: planned.indices.map { ($0, asked.count) })

            func apply(_ outcome: Outcome, engine: SearchBackend) {
                if let result = outcome.result {
                    // Structure only — keys, counts and sizes, never a title or a
                    // link — so a result the extractor cannot read is diagnosable
                    // from a log that must not contain results.
                    // The same label the stage used, so two engines answering one
                    // planned search do not emit two identical lines about different
                    // shapes — which is the case this log exists for.
                    trace.log(label(outcome.step, engine)
                              + " result shape: \(EvidenceExtractor.shape(of: result))")
                    buffered.append(outcome)
                    productive.insert(ObjectIdentifier(engine))
                    // "Usable" is the extractor's call, made inside the task: a 200
                    // with zero hits resolves fine, and treating it as an answer
                    // would leave the next round re-asking a barren query in new
                    // words — the exact waste `failedQueries` exists to stop.
                    if outcome.fruitful { fruitfulByStep[outcome.step, default: 0] += 1 }
                } else if let failure = outcome.failure {
                    // Buffered rather than appended: failures replay in (step,
                    // engine) order with the results, so the failure list is the
                    // same after every run of an identical turn instead of whichever
                    // engine happened to lose first.
                    trace.warn("\(label(outcome.step, engine)) failed on "
                               + "\(engine.backendName): \(failure)")
                    buffered.append(outcome)
                }
                // A step completes when its last pair does, whichever engine's that
                // was. An unknown step number cannot happen — outcomes only carry
                // indices this round planned — and is skipped rather than trapping.
                if let left = pairsLeft[outcome.step] {
                    pairsLeft[outcome.step] = left - 1
                    if left == 1 {
                        attempted += 1
                        update { $0.searchesCompleted = attempted }
                    }
                }
            }

            /// What the trace calls one (step, engine) pair — built once, in one
            /// place, so the stage label and the failure label cannot drift apart.
            func label(_ step: Int, _ engine: SearchBackend) -> String {
                asked.count > 1
                    ? "Search \(step + 1) via \(engine.backendName)"
                    : "Search \(step + 1)"
            }

            /// The shared body of both paths: run one pair, classify the outcome.
            /// A cancellation is not a failed search and still propagates. Fruitfulness
            /// is the extractor's call against the one result, and only deep turns pay
            /// for the walk — only their rounds read the list.
            func attempt(_ step: Int, _ engineIndex: Int,
                         _ stepArguments: [String: Any]) async throws -> Outcome {
                let engine = indexed[engineIndex].element
                do {
                    try Task.checkCancellation()
                    let label = asked.count > 1
                        ? "Search \(step + 1) via \(engine.backendName)"
                        : "Search \(step + 1)"
                    let result = try await trace.stage(label) {
                        try await engine.search(arguments: stepArguments)
                    }
                    return Outcome(step: step, engine: engineIndex, result: result,
                                   fruitful: mode == .deep
                                       && !EvidenceExtractor.sources(from: [result]).isEmpty,
                                   failure: nil)
                } catch is CancellationError {
                    throw ResearchError.cancelled
                } catch let error as ResearchError where error == .cancelled {
                    throw error
                } catch {
                    // One failed search must not lose the others, and in `deep` that
                    // now means the other engines and every earlier round too — a turn
                    // may have spent a dozen billed requests before reaching here.
                    // Narrowed to `ResearchError` this caught none of the failures the
                    // transport can raise on its own.
                    let reason = (error as? ResearchError)?.message ?? String(describing: error)
                    return Outcome(step: step, engine: engineIndex, result: nil,
                                   fruitful: false, failure: reason)
                }
            }

            // No engine to ask: nothing will run, and the progress label must still
            // count the plan off — a step only completes when its last pair answers,
            // and with no pairs that never happens on its own.
            if asked.isEmpty {
                attempted += planned.count
                update { $0.searchesCompleted = attempted }
                return asked
            }

            // Stateless engines: the whole round in flight at once. The fan-out is
            // bounded structurally: a round plans at most `maxSearches` steps, so at
            // most maxSearches × engines requests leave at once — a dozen HTTP calls
            // or short-lived CLI processes in any real configuration, which is what
            // the engines themselves tolerate under a single user key.
            if !stateless.isEmpty, !planned.isEmpty {
                try await withThrowingTaskGroup(of: Outcome.self) { group in
                    for (stepIndex, step) in planned.enumerated() {
                        for (engineIndex, _) in stateless {
                            group.addTask {
                                try await attempt(stepIndex, engineIndex, step.arguments)
                            }
                        }
                    }
                    for try await outcome in group {
                        apply(outcome, engine: indexed[outcome.engine].element)
                    }
                }
            }
            // Stateful engines: one session, one id sequence, as before.
            for (stepIndex, step) in planned.enumerated() {
                try Task.checkCancellation()
                for (engineIndex, _) in stateful {
                    let outcome = try await attempt(stepIndex, engineIndex, step.arguments)
                    apply(outcome, engine: indexed[outcome.engine].element)
                }
            }

            // Asked of every engine and nothing usable came back — outage or
            // barren index, the planner only needs the outcome. The query is the
            // model's own text, safe to hand back to it — the trace rule about not
            // logging results is about content, and this never reaches the log.
            // Deduped: a planner that re-asks a dead query anyway must not fill
            // the next round's context with the same line twice. Capped at the
            // digest's snippet budget: the list is re-injected into every later
            // round, and an unbounded model-written string would grow each one.
            // `asked` is non-empty here by the early return above, so a step with no
            // fruitfulness really was asked of a real engine and really got nothing.
            for (stepIndex, step) in planned.enumerated()
            where mode == .deep && fruitfulByStep[stepIndex, default: 0] == 0 {
                let query = String(step.displayQuery.prefix(200))
                if !failedQueries.contains(query) { failedQueries.append(query) }
            }
            let ordered = buffered.sorted { one, other in
                if one.step != other.step { return one.step < other.step }
                return one.engine < other.engine
            }
            rawResults.append(contentsOf: ordered.compactMap(\.result))
            searchFailures.append(contentsOf: ordered.compactMap(\.failure))

            // Nothing was asked, so nothing was proven unproductive. Without this an
            // empty plan — which a question carrying links can legitimately produce —
            // would report every engine as silent, and `deep` would skip the very rounds
            // that exist to ask what the first pass did not.
            if planned.isEmpty { return asked }
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
        //
        // `allSearches` accumulates every round's plan rather than living inside the
        // block: the answer payload's `searches_run` is built from it, and the answer
        // model is entitled to know about the searches that produced its evidence —
        // built from the first plan alone, the list described a fraction of what the
        // evidence block actually contains.
        //
        // `plannedReads` holds the texts of pages the rounds asked for by number. They
        // are keyed by source number rather than attached to a source list, because
        // `combined` rebuilds that list from raw results after every round — anything
        // attached mid-loop would be discarded by the next rebuild. Attached once,
        // after the last combine.
        //
        // `pageBudget` is the turn's whole page allowance, deep or not, spent as the
        // rounds ask for pages and topped up by nobody: the final fill afterwards
        // backstops what the rounds did not name, it does not get a second allowance.
        var allSearches = plan.searches
        var plannedReads: [Int: String] = [:]
        let evidenceLimit = mode == .deep ? ResearchContext.maxDeepEvidenceCharacters
                                          : ResearchContext.maxEvidenceCharacters
        // Clamped at zero: `prefix` traps on a negative count, and a turn whose links
        // spent the whole allowance has simply none left, which is different from
        // owing one.
        var pageBudget = max(0, (mode == .deep ? PageReaderFactory.maxDeepPages
                                               : PageReaderFactory.maxPages) - linkedAttempts)
        if mode == .deep, !engines.isEmpty, Self.maxDeepRounds > 1 {
            for round in 2...Self.maxDeepRounds {
                try Task.checkCancellation()
                // The reads attached: the budget check must count what they cost, and
                // the digest must mark them, or the planner asks for the same page again.
                let soFar = Self.applyingReads(plannedReads,
                                               to: Self.combined(linked: linked,
                                                                 results: rawResults))
                guard ResearchContext.evidence(from: soFar, limit: evidenceLimit).dropped == 0 else {
                    trace.log("Round \(round) not run: the evidence budget is already full")
                    break
                }

                update { $0.stage = .planning }
                var followExtra: [String: Any] = ["search_tool": search.toolDescriptor,
                                                  "found": Self.digest(of: soFar)]
                if !failedQueries.isEmpty { followExtra["failed_queries"] = failedQueries }
                // Stated even at zero: a planner that can see the reads are spent
                // stops asking for them, where an absent key leaves it guessing —
                // and guessing costs a round.
                followExtra["read_budget"] = pageBudget
                // The first plan's decomposition, so the round plans against the
                // sub-questions the evidence leaves open rather than re-deriving a
                // map of the question from snippets.
                if !plan.subquestions.isEmpty {
                    followExtra["subquestions"] = plan.subquestions
                }
                let followContext = ResearchContext.assemble(
                    question: question, history: history, today: today, extra: followExtra)
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

                // Read requests come before the empty-plan stop: "nothing left to
                // search, but page 7 is decisive and I have only its snippet" is a
                // legitimate end state, and the round's fetch is the only chance to
                // honour it.
                if !follow.readRequests.isEmpty {
                    if pageBudget > 0 {
                        // Reads applied, so `readableTargets` sees pages earlier
                        // rounds fetched as read: a repeated request for a page the
                        // turn already holds must not be re-fetched — and re-charged —
                        // in a slot a new page could have used. The digest's [read]
                        // mark asks the planner not to repeat itself; this is what
                        // enforces it when it does anyway.
                        let candidates = Self.applyingReads(
                            plannedReads,
                            to: Self.combined(linked: linked, results: rawResults))
                        let (texts, spent) = await readPlannedPages(
                            follow.readRequests, in: candidates,
                            settings: settings, budget: pageBudget)
                        pageBudget -= spent
                        // Empties are skipped rather than merged away: Dictionary.merge's
                        // combining closure only fires for keys that already exist, so
                        // an empty value for a NEW page would sail straight in — and a
                        // page recorded as read on a failed fetch is budget spent for
                        // nothing, with the digest marking it so no round retries it.
                        for (number, text) in texts where !text.isEmpty {
                            plannedReads[number] = text
                        }
                    } else {
                        // Said rather than silently skipped: the round still runs its
                        // searches — only its fetches are gone — and the trace is
                        // where the difference lands.
                        trace.log("Round asked for \(follow.readRequests.count) page(s); "
                                  + "the page budget is spent")
                    }
                }
                try Task.checkCancellation()

                // An empty plan is the documented way to stop, not a failure: a round with
                // nothing left worth asking should say so rather than fill its quota.
                guard !follow.searches.isEmpty else {
                    trace.log("Round \(round) found nothing left to ask; stopping")
                    break
                }

                allSearches += follow.searches
                // The reader sees every round's searches, not just the first plan's:
                // `searchesCompleted` counts against this list, and a list that stopped
                // growing would leave the progress label counting past its own total.
                update { $0.searches = allSearches }
                update { $0.stage = .searching }
                engines = try await runSearches(follow.searches, across: engines)
                if engines.isEmpty {
                    trace.warn("No search engine is still answering; stopping the rounds")
                    break
                }
            }
        }

        var harvested = Self.combined(linked: linked, results: rawResults)
        // The pages the rounds asked for, attached after the last rebuild of the list.
        // Keyed by the stable number the digest showed the planner — which is why the
        // numbering may not shift between rounds: a renumbered list would attach a
        // decisive page to the wrong source.
        harvested = Self.applyingReads(plannedReads, to: harvested)
        let plannedReadCount = plannedReads.values.filter { !$0.isEmpty }.count

        // 3b — read the pages behind the top sources, if the user asked for that.
        //
        // This is the backstop, not the primary mechanism: in a deep turn the rounds
        // have already spent the same allowance on pages they judged decisive, and what
        // is left fills in rank order. Before the budget, not after: what the model is
        // shown has to be decided with the page text in hand, or a page would be
        // fetched and then silently dropped. Still inside the searching stage — see
        // `ResearchTurn.runningProgressLabel` for why this does not get a
        // `ResearchStage` case of its own.
        // What the links already spent comes off the turn's page budget rather than
        // being added to it: the allowance is a statement about one turn's requests
        // and context, and it does not stop being true because the pages were chosen
        // by the user instead of by relevance.
        //
        // Spent by the *attempts*, not by the reads. A link that would not load still
        // sent a request and still reached a host, so charging only the successes would
        // let three dead links buy three more fetches — the ceiling saying one thing and
        // the turn doing another. `alreadyRead` stays the successes, because it answers a
        // different question: whether this turn has any page text at all, which is what
        // the `noPagesRead` notice is about.
        harvested = await readPages(harvested,
                                    settings: settings,
                                    budget: pageBudget,
                                    alreadyRead: linked.count + plannedReadCount)
        try Task.checkCancellation()

        // Trimmed to what fits the evidence budget *before* it becomes the turn's source
        // list. The model is only shown the kept prefix, so a turn that recorded the
        // full list would validate the answer's citations against sources the model
        // never saw, and would offer the reader a source list the answer could not have
        // used.
        let (evidence, droppedSources, withheldPageText) = ResearchContext.evidence(
            from: harvested, limit: evidenceLimit)
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
        let searchesRun: [[String: String]] = allSearches.map {
            ["purpose": $0.purpose, "query": $0.displayQuery]
        }
        var answerExtra: [String: Any] = [
            "reading": plan.reading,
            "searches_run": searchesRun,
            "evidence": evidence,
            "highest_source_number": evidence.compactMap { $0["number"] as? Int }.max() ?? 0,
        ]
        // The deep answer is structured by the first plan's decomposition; a quick
        // turn's is not, because a quick question rarely has five load-bearing parts
        // and headings for one part are scaffolding around a paragraph.
        let answerPrompt = mode == .deep && !plan.subquestions.isEmpty
            ? ResearchPrompts.answerDeep : ResearchPrompts.answer
        if mode == .deep, !plan.subquestions.isEmpty {
            answerExtra["subquestions"] = plan.subquestions
        }
        if !attachments.payload.isEmpty { answerExtra["attachments"] = attachments.payload }
        let answerContext = ResearchContext.assemble(
            question: question, history: history, today: today, extra: answerExtra)
        if answerContext.trimmed { update { $0.addNotice(.contextTrimmed) } }

        // A provider that dies mid-sentence has already streamed text into the turn, and
        // the next provider starts its answer from the beginning. Without the reset the
        // two would be concatenated into a paragraph neither model wrote — so the
        // fragment is discarded before the retry. The reader sees the answer restart,
        // which is honest, rather than a seam they cannot see.
        // Whether the provider that actually answered was shown the pictures. Recorded
        // inside the closure because the chain decides who answers: a fallback without
        // eyes is sent the turn without them rather than a request it would reject, and
        // the reader has to be told the difference.
        var sentImages = false
        let answerImages = attachments.images
        // A second payload for the case where the provider that answers has no eyes.
        //
        // Built here rather than inside the closure because the closure runs once per
        // attempt and this does not depend on which attempt it is. It matters more than
        // the reader's notice does: without it the model is asked "what is in the
        // top-left of the screenshot?" with no screenshot and *nothing saying one was
        // meant to be there*, which is the setup for a confidently invented answer. The
        // same `unavailable` entry a lost attachment gets, for the same reason — the
        // answer prompt's rule about an attachment that is not present needs something to
        // fire on.
        let withheldContext = answerImages.isEmpty ? nil : ResearchContext.assemble(
            question: question, history: history, today: today,
            extra: Self.namingImagesUnavailable(answerExtra, attachments))
        let answer = try await chain.perform("Answer", beforeRetry: { [weak self] in
            self?.update { $0.answer = "" }
        }) { chat in
            let images = chat.imagesWillBeSent ? answerImages : []
            let payload = images.isEmpty ? (withheldContext ?? answerContext).payload
                                         : answerContext.payload
            let text = try await chat.streamText(
                system: answerPrompt, payload: payload,
                withoutImages: images.isEmpty ? nil : withheldContext?.payload,
                label: "Answer", images: images
            ) { [weak self] chunk in
                self?.update { $0.answer += chunk }
            }
            // After the call, because a provider that rejected the image was retried
            // without it and the reader has to be told the answer saw no picture.
            sentImages = !images.isEmpty && !chat.withheldImages
            return text
        }
        // As in the plan stage: the payload that went is the one whose trimming the
        // reader has to be told about, and the withheld one carries more.
        if !sentImages, withheldContext?.trimmed == true {
            update { $0.addNotice(.contextTrimmed) }
        }
        if !answerImages.isEmpty, !sentImages { update { $0.addNotice(.imagesNotSent) } }
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
        try Task.checkCancellation()

        // 6 — revise, only when the check found something worth correcting.
        try await revise(answer: answer, findings: assessment.findings, evidence: evidence,
                         sources: sources, question: question, history: history,
                         today: today, reading: plan.reading, chain: chain)
    }

    /// Whether a verdict sends the answer back for correction.
    ///
    /// `contradicted` is a factual error in prose the reader has already read, and
    /// `mixed` is a claim stated more firmly than the sources will carry — both are the
    /// answer being wrong about the evidence in front of it.
    ///
    /// `insufficient` is not one, and that is the whole difference between a stage that
    /// runs occasionally and one that runs on nearly every turn. "The evidence does not
    /// settle this" is a normal, correct thing for an answer to contain — the answer
    /// prompt asks for exactly that hedge — so a finding of it is usually the check
    /// agreeing with the answer rather than catching it out. The reviser is still *shown*
    /// those findings, because a sentence it is already rewriting may need weakening on
    /// the same grounds; it just will not be woken for one.
    ///
    /// A switch rather than a set, so a sixth verdict cannot be added without someone
    /// deciding which side of this line it falls on.
    static func warrantsRevision(_ verdict: Verdict) -> Bool {
        switch verdict {
        case .contradicted, .mixed: return true
        case .supported, .insufficient, .opinion: return false
        }
    }

    /// Whether a finding is *shown* to the reviser, which is a wider set than the one
    /// that wakes it.
    ///
    /// A switch for the reason the one above is: `!= .supported && != .opinion` says the
    /// same thing today and would silently absorb a sixth verdict into "shown", which is
    /// a decision somebody should have to make rather than inherit. The two questions are
    /// separate — a claim can be worth mentioning to a rewrite already under way without
    /// being worth starting one for — so they are two switches rather than one.
    static func isShownToReviser(_ verdict: Verdict) -> Bool {
        switch verdict {
        case .contradicted, .mixed, .insufficient: return true
        case .supported, .opinion: return false
        }
    }

    /// The answer with a fence that wraps the *whole* of it removed.
    ///
    /// The revise prompt forbids fencing the answer and models do it anyway — it is the
    /// commonest way a "return the document and nothing else" instruction is misread. It
    /// matters more here than at the answer stage, which streams into view where a
    /// leading ``` is visible immediately: a revision is swapped in whole, and a fenced
    /// one would replace good prose with a wall of monospace. Worse, the citation check
    /// would pass it — a bracketed number inside a fence is code, not a citation, so a
    /// fenced revision validates as an answer that cites nothing at all.
    ///
    /// Only an *undecorated* opening fence is unwrapped: ``` or one labelled `markdown`
    /// or `md`. A fence naming a code language is a real code block, and an answer that
    /// is genuinely nothing but one — rare, but the reviser is told to preserve what it
    /// was given — must survive this untouched. An *unlabeled* fence is always read as
    /// decoration, even when what it wraps is code: the bare ``` wrap is the commonest
    /// thing this has to undo, and requiring a label to unwrap would give that up to
    /// protect a shape — an unlabeled whole-answer code block — that the un-citing guard
    /// downstream would refuse anyway.
    ///
    /// Two lines are enough, not three. A reply of nothing but an opening and closing
    /// fence unwraps to the empty string and is caught by the emptiness guard in
    /// `revise`; refusing to unwrap it left it non-empty, different from the draft, and
    /// carrying no citation for the validator to object to — so it cleared every guard
    /// and replaced a read answer with a bare fence. The `revise` guard rejects a reply
    /// made of nothing but backticks for the same reason, which covers the one-line
    /// spelling this cannot.
    static func unwrappingWholeAnswerFence(_ answer: String) -> String {
        // By `isNewline`, not by the character "\n". A Swift `Character` is a grapheme
        // cluster and CR-LF is *one* of them, so a CRLF reply never matched the "\n"
        // separator at all: the whole answer came back as a single line, `lines.count >=
        // 2` failed, and the one function whose job is catching a fenced answer switched
        // itself off for any provider or proxy that speaks CRLF. Trimming harder does not
        // reach this — there were no lines to trim.
        //
        // Trimmed first, so a trailing line terminator does not leave an empty last line
        // for the closer test to fail on. `revise` already hands this a trimmed string;
        // doing it here too means the function is correct whoever calls it, rather than
        // correct because of the order two lines happen to sit in.
        let lines = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count >= 2, let first = lines.first, let last = lines.last
        else { return answer }
        // A fence is a *run* of three or more backticks, not exactly three — and reading
        // only the three-tick spelling left the hole open exactly where it was widest.
        // A model reaches for the longer form when the thing it is wrapping contains its
        // own ``` block, which is the likeliest shape for a correction to arrive in and
        // the one reason it would think to fence the answer at all.
        // `whitespacesAndNewlines` rather than `whitespaces` as well, which the split
        // above already makes unnecessary for CR — belt and braces for any other line
        // terminator that reaches a line's edge without having split it.
        let opener = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let openingTicks = opener.prefix(while: { $0 == "`" }).count
        guard openingTicks >= 3 else { return answer }
        let label = opener.dropFirst(openingTicks)
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard label.isEmpty || label == "markdown" || label == "md" else { return answer }
        // The closer is backticks and nothing else, and at least as long as the opener.
        // A shorter run does not close the fence — it sits inside it, which is the whole
        // point of opening a longer one.
        let closer = last.trimmingCharacters(in: .whitespacesAndNewlines)
        let closingTicks = closer.prefix(while: { $0 == "`" }).count
        guard closingTicks >= openingTicks, closingTicks == closer.count
        else { return answer }
        return lines.dropFirst().dropLast().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rewrites the answer against the findings, when there are findings worth rewriting
    /// for.
    ///
    /// Ordered after the assessment rather than folded into it, which is the only order
    /// that keeps both halves honest: the check grades the answer that was actually
    /// written, and the correction is made against a check that has actually run. The
    /// cost is that the findings on screen describe the draft rather than the prose above
    /// them — so the draft is kept in `draftAnswer`, and a notice says which is which.
    ///
    /// Everything here fails soft. A revision that does not arrive, comes back empty, or
    /// breaks the citation rule leaves the turn exactly as the assessment left it: the
    /// draft on screen, the findings that grade it below, and a notice saying the
    /// correction did not land. The answer has already been streamed and read, and losing
    /// it to a failed rewrite is the worst outcome available here. Cancellation still
    /// propagates, because a Stop is a Stop.
    private func revise(answer: String,
                        findings: [Finding],
                        evidence: [[String: Any]],
                        sources: [Source],
                        question: String,
                        history: [ResearchTurn],
                        today: String,
                        reading: String,
                        chain: ModelChain) async throws {
        let revisable = findings.filter { Self.warrantsRevision($0.verdict) }
        guard !revisable.isEmpty else { return }

        // Every finding the check left unsettled, not only the ones that triggered this.
        // The trigger decides whether the call is worth making; once it is being made,
        // the reviser should see the whole of what the check was unsure about.
        let unsettled = findings
            .filter { Self.isShownToReviser($0.verdict) }
            .map { finding -> [String: Any] in
                ["claim": finding.claim,
                 "verdict": finding.verdict.rawValue,
                 "reasoning": finding.reasoning,
                 "sources": finding.sourceNumbers]
            }
        trace.log("Revising: \(revisable.count) claim(s) the evidence does not carry")
        // `trace.elapsed` counts from the start of the *run*, so the figure logged at
        // the end has to be a difference. Reporting it raw would say "revised the answer
        // in 47 seconds" about a turn that spent 45 of them searching — and how long this
        // stage costs is the number the decision to have it at all rests on.
        let began = trace.elapsed
        update { $0.isRevising = true }
        // Cleared on every path out, including the ones that keep the draft: a label
        // saying a request is outstanding must not outlive the request.
        defer { update { $0.isRevising = false } }

        let context = ResearchContext.assemble(
            question: question, history: history, today: today,
            extra: ["answer": answer, "evidence": evidence,
                    "reading": reading, "findings": unsettled])
        if context.trimmed { update { $0.addNotice(.contextTrimmed) } }

        let revised: String
        do {
            revised = try await chain.perform("Revise") { chat in
                // Streamed for the reason every long call here is — a provider that dies
                // halfway is retried — but into nothing. The draft stays on screen until
                // the whole correction has arrived and been checked, because text that
                // rewrites itself under a reader mid-paragraph is worse than text that
                // changes once.
                try await chat.streamText(system: ResearchPrompts.revise,
                                          payload: context.payload, label: "Revise") { _ in }
            }
        } catch {
            // Every error that is not a Stop, not only the ones this file knows how to
            // name. "Fails soft" was written above as a promise and matching on
            // `ResearchError` alone did not keep it: anything else — a transport error
            // that escaped wrapping, an encoding failure assembling the payload — would
            // propagate out of here and fail a turn whose answer had already been
            // streamed, validated, read and assessed. That is the outcome this whole
            // function is arranged to avoid, arriving through the one path that was not
            // covered.
            let stopped = Task.isCancelled
                || error is CancellationError
                || (error as? ResearchError) == ResearchError.cancelled
            guard !stopped else { throw error }
            // `safeLabel`, not the error's own description: an unknown error can carry a
            // URL with a query string or a path in it, and this trace is written to a
            // log the user may paste somewhere. A type name says enough to debug with.
            trace.warn("Revision unavailable: \(ResearchError.safeLabel(for: error))")
            update { $0.addNotice(.revisionUnavailable) }
            return
        }

        // The reply arrived; a Stop may have arrived with it. Everything below mutates
        // the turn, and the catch above only covers a cancellation thrown *by* the call.
        try Task.checkCancellation()
        // `corrected`, not `trimmed`: the two lines that matter in this function read
        // `turn.draftAnswer = answer` and `turn.answer = corrected`, and under the old
        // name a skimming reader had to work out which of the two was the rewrite — at
        // the one assignment where getting it backwards silently discards the correction.
        let corrected = Self.unwrappingWholeAnswerFence(
            revised.trimmingCharacters(in: .whitespacesAndNewlines))
        // Nothing in it, or nothing in it but fence. A reply of a lone ``` is not caught
        // by unwrapping — there is no closing line to pair it with — and would otherwise
        // read as a perfectly valid revision: non-empty, different from the draft, and
        // citing nothing for the validator to object to.
        guard corrected.contains(where: { !$0.isWhitespace && $0 != "`" }) else {
            // A reply with no content in it is a call that failed and happened to return.
            trace.warn("Revision unavailable: the reply was empty")
            update { $0.addNotice(.revisionUnavailable) }
            return
        }
        guard corrected != answer.trimmingCharacters(in: .whitespacesAndNewlines) else {
            // The reviser read the findings and judged that none of them warranted a
            // change, which is a real answer and not a failure — and not a revision
            // either. Nothing is said, because nothing happened.
            trace.log("Revision returned the answer unchanged")
            return
        }
        // The citation rule is not advice here. A correction that invents a source
        // number, or writes a URL the answer stage would have been refused, is a worse
        // answer than the one it replaces — and it would arrive *after* the validation
        // the reader's trust in these numbers rests on. So it is checked before it is
        // accepted, and dropped whole rather than swapped in and annotated.
        let validation = CitationValidator.validate(answer: corrected, sourceCount: sources.count)
        // Un-citing is the quiet half of the same failure. A reviser that hedges a claim
        // by dropping its `[n]` rather than weakening its words hands back prose that
        // reads as confident and rests on nothing — and every check above would pass it,
        // because there is no bad number to find. Measured against the draft, so an
        // answer that never cited anything is not held to a standard it never met.
        let draftCitedSomething = !CitationValidator
            .validate(answer: answer, sourceCount: sources.count)
            .citedSourceIndices.isEmpty
        let revisionCitedSomething = !validation.citedSourceIndices.isEmpty
        guard validation.outOfRangeCitations.isEmpty,
              validation.literalURLs.isEmpty,
              !draftCitedSomething || revisionCitedSomething
        else {
            // Which clause fired, because the three are different stories. Two are a
            // reviser breaking a rule it was given; the third is the un-citing guard,
            // which is the only one that can also refuse a *correct* rewrite — one that
            // weakened every flagged claim and legitimately dropped its numbers. It fails
            // soft either way, so the only way to know how often that happens is to say
            // which branch it was.
            let broken = !validation.outOfRangeCitations.isEmpty ? "a source number that does not exist"
                : !validation.literalURLs.isEmpty ? "a URL in the prose"
                : "no citation at all, where the draft had one"
            trace.warn("Revision discarded: \(broken)")
            update { $0.addNotice(.revisionUnavailable) }
            return
        }
        update { turn in
            turn.draftAnswer = answer
            turn.answer = corrected
            turn.addNotice(.answerRevised)
        }
        trace.log("Revised the answer in " + String(format: "%.1fs", trace.elapsed - began))
    }

    /// How much of a linked page the *planner* is shown. The answer sees the whole
    /// text; this is only enough for the planner to know what the page covers, which is
    /// what it needs to decide what the question still lacks.
    static let linkedExcerptCharacters = 1_500
    /// How much of a linked page becomes its entry in the source list. Long enough to
    /// recognise the page, short enough that three of them do not crowd the list.
    static let linkedSnippetCharacters = 300
    /// The most links one question is read from. The same ceiling as the pages behind
    /// search results, and for the same reason — each is a request and several thousand
    /// characters of the evidence budget.
    static var maxLinks: Int { PageReaderFactory.maxPages }

    /// The turn's sources: what the question linked to, then what the searches found.
    ///
    /// The links come first because the user chose them, and because
    /// `ResearchContext.evidence` keeps a prefix — so an evidence block that will not
    /// fit drops a search hit before it drops the page the question pointed at.
    ///
    /// A search hit for a URL the question already linked is dropped rather than
    /// numbered twice: `EvidenceExtractor` deduplicates within one call, but it never
    /// sees the linked sources, which did not come from a search result. The survivors
    /// are then renumbered, because a hole left by a dropped duplicate would show the
    /// model a numbering that skips — and a gap is an invitation to cite the number that
    /// is missing, which is the same reason `ResearchContext.evidence` drops a suffix
    /// rather than stepping over an entry that does not fit.
    ///
    /// **The numbering is append-only across rebuilds, and the deep rounds depend on
    /// it.** This function is called again after every round over the whole cumulative
    /// result list, and `plannedReads` keys fetched page text by number — a number that
    /// shifted between rebuilds would attach a decisive page to the wrong source, which
    /// is worse than dropping it. Append-only holds because every filter downstream of
    /// the numbering (dedupe by first occurrence, the per-domain cap, the pool cap)
    /// keeps earlier survivors when later results arrive: a new result can only add a
    /// tail, never reorder or displace what a previous round already numbered. Any new
    /// filter must preserve that property or key `plannedReads` by URL instead.
    static func combined(linked: [Source], results: [Any]) -> [Source] {
        guard !linked.isEmpty else { return EvidenceExtractor.sources(from: results) }
        // Compared by `canonicalKey`, not by the raw string. A URL pasted out of a
        // browser carries what the address bar added — a fragment, a trailing slash, a
        // `utm_` tag — and the search engine returns the canonical form without it. Byte
        // equality calls those two pages and numbers one document twice, which is the
        // exact thing this function exists to stop.
        let already = Set(linked.map { SourceHarvester.canonicalKey(for: $0.url) })
        let found = EvidenceExtractor.sources(from: results)
            .filter { !already.contains(SourceHarvester.canonicalKey(for: $0.url)) }
        // Numbered here rather than through `startingAt`, because the filter above can
        // drop an entry and the numbering has to be settled after that — two places
        // assigning numbers to one list is how a gap gets in.
        return linked + found.enumerated().map { offset, source -> Source in
            var renumbered = source
            renumbered.number = linked.count + 1 + offset
            return renumbered
        }
    }

    /// Attaches planner-requested page texts to a rebuilt source list, by number.
    ///
    /// The deep loop rebuilds the sources from raw results after every round, so reads
    /// are kept beside the list in a `[number: text]` map and applied where the list is
    /// consumed: the budget check (which must count what the reads cost), the digest
    /// (which must mark what is already read), and the final harvest. A number that no
    /// longer names a source — the extractor's cap dropped it — is ignored rather than
    /// resurrected.
    static func applyingReads(_ reads: [Int: String], to sources: [Source]) -> [Source] {
        guard !reads.isEmpty else { return sources }
        var applied = sources
        for index in applied.indices {
            guard let text = reads[applied[index].number], !text.isEmpty else { continue }
            applied[index].fullText = text
        }
        return applied
    }

    /// A name for a linked source: the host and path the user typed.
    ///
    /// Built from the URL rather than from the page, because this is the line the reader
    /// scans to see where a claim came from, and the address is the thing they will
    /// recognise — they pasted it. Taking it from the page's own `<title>` would also
    /// work, and every search hit's title arrives that way, but there is no reason to
    /// introduce fetched text into a field the URL already answers.
    static func linkTitle(for url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else {
            return ResearchContext.shorten(url, to: 120)
        }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = components.path
        return ResearchContext.shorten(path.isEmpty || path == "/" ? name : name + path, to: 120)
    }

    /// Reads the pages the question linked to, and turns the ones that answered into
    /// this turn's first sources.
    ///
    /// A link that could not be read does **not** become a source. A numbered entry with
    /// no text is a citation target the model cannot use and a line in the source list
    /// that claims the answer rests on a page nobody read; the honest report is a notice
    /// saying the link was not read, which is what this does. Same posture as the rest of
    /// page reading: never throws, because a page that will not load is not a failure of
    /// the research turn.
    ///
    /// - Returns: the pages that answered, and how many were **asked for**. The two are
    ///   different numbers and the caller needs both: the reads are the evidence, and the
    ///   attempts are what came out of the turn's page budget. A link that failed still
    ///   spent a request and still reached a host, so counting only the successes would
    ///   let a question full of dead links push the turn past a ceiling documented as
    ///   being about requests as well as context.
    ///
    /// A link-bearing turn deliberately pays two reader handshakes: this one before the
    /// plan, and `readPages`'s afterwards for the pages behind the search results. They
    /// are separated by the planning call, so holding a session open across it would mean
    /// keeping an MCP connection alive through the slowest stage of the turn to save one
    /// handshake — and `PageReaderFactory` hands back a reader, not a live session to
    /// pass around. The cost is one extra round trip on a turn that is already fetching
    /// pages.
    private func readLinkedPages(in question: String, settings: ProviderSettings)
        async -> (read: [Source], attempted: Int) {
        let links = SourceHarvester.links(inQuestion: question, limit: Self.maxLinks)
        guard !links.isEmpty else { return ([], 0) }
        // The privacy setting decides, even here. Reading is the one thing Vervellum does
        // that reaches a host the user did not configure, and a link in a question is
        // still that — so a user who turned it off is told their link was left rather
        // than having it fetched on their behalf.
        //
        // Asked before the count below, not after: with reading off, no link is read at
        // all, and adding "some links were past the limit" on top of that would offer a
        // reason that is not the reason.
        guard settings.pageReading != .off else {
            trace.log("Question carries \(links.count) link(s), but page reading is off")
            update { $0.addNotice(.linkReadingOff) }
            return ([], 0)
        }
        if SourceHarvester.linkCount(inQuestion: question) > links.count {
            trace.log("Question carries more than \(Self.maxLinks) links; "
                      + "reading the first \(links.count)")
            update { $0.addNotice(.linkNotRead) }
        }

        let reader: PageReading?
        do {
            reader = try PageReaderFactory.make(settings: settings, readerKey: environment.readerKey,
                                                trace: trace, transport: transport)
            try await reader?.connect()
        } catch {
            trace.warn("Link reading unavailable: \(ResearchError.safeLabel(for: error))")
            update { $0.addNotice(.linkNotRead) }
            return ([], 0)
        }
        guard let reader else {
            update { $0.addNotice(.linkNotRead) }
            return ([], 0)
        }

        // Numbered from one only to key the reader's result; the survivors are numbered
        // again below, so a link that did not answer leaves no hole.
        let asked = links.enumerated().map { offset, url in
            Source(number: offset + 1, url: url, title: Self.linkTitle(for: url), snippet: "")
        }
        // Counted twice over: `pagesAttempted` for the turn's record, `pagesInFlight`
        // for what is happening now. This read runs while the stage is still
        // `.planning`, so without the second the panel says "Planning searches" for as
        // long as three fetches take — see `ResearchTurn.pagesInFlight`.
        update {
            $0.pagesAttempted = asked.count
            $0.pagesInFlight = asked.count
        }
        let started = trace.elapsed
        let pages = await reader.read(asked)
        trace.log("Read \(links.count) linked page(s) via \(reader.readerName) in "
                  + String(format: "%.1fs", trace.elapsed - started))

        var sources: [Source] = []
        for source in asked {
            guard let text = pages[source.number], !text.isEmpty else { continue }
            var read = source
            read.number = sources.count + 1
            read.snippet = ResearchContext.shorten(text, to: Self.linkedSnippetCharacters)
            read.fullText = text
            sources.append(read)
        }
        // Zeroed here rather than the moment `read` returned, so that the one snapshot
        // carries both the end of the fetch and its result. Clearing it on its own
        // publishes a frame in which nothing is in flight and nothing has been read
        // yet — a flicker back to the bare stage label — and costs an extra publish to
        // do it.
        update {
            $0.pagesInFlight = 0
            $0.pagesRead = sources.count
        }
        trace.log("Linked pages read: \(sources.count) of \(asked.count)")
        if sources.count < asked.count { update { $0.addNotice(.linkNotRead) } }
        return (sources, asked.count)
    }

    /// Reads the pages behind the highest-ranked search results, when page reading is on.
    ///
    /// Best-effort throughout, and deliberately so. A reader that cannot be built (a
    /// missing key, an unusable endpoint), a handshake that fails, a page behind a
    /// consent wall — none of those fails the turn. They leave every source with its
    /// snippet, which is exactly the behaviour of the mode that is off, and the notice
    /// says so rather than the run collapsing over an enrichment.
    ///
    /// `budget` is what is left of the turn's page allowance after the question's own
    /// links and the deep rounds' requested reads; `alreadyRead` is how many pages the
    /// turn already has text for, and is what keeps the `noPagesRead` notice honest —
    /// "no page could be read" must not be said over a turn that read the page the user
    /// pasted, or one whose rounds read what they asked for.
    private func readPages(_ sources: [Source],
                           settings: ProviderSettings,
                           budget: Int,
                           alreadyRead: Int) async -> [Source] {
        // Said out loud, because the alternative is a turn whose sources all kept their
        // snippets with nothing anywhere to explain it. The links spending the whole
        // allowance is the one way that happens with reading switched on, and the notice
        // the reader does get is about the *links* — it says nothing about the pages
        // behind the search results also being left.
        if settings.pageReading != .off, budget <= 0, sources.contains(where: { !$0.wasRead }) {
            trace.log("Page budget already spent by the question's links; "
                      + "search-result pages left unread")
        }
        guard settings.pageReading != .off, !sources.isEmpty, budget > 0 else { return sources }

        // Which pages this will fetch, decided before the reader is built rather than
        // after. A turn whose links filled the budget — or a link-only turn, which an
        // empty plan now produces — has nothing unread left, and the MCP reader's
        // handshake is a real request: paying for one on a path that provably fetches
        // nothing costs a round trip and invents a failure surface, since a handshake
        // that fails would warn about reading this turn never intended to do.
        //
        // Skipping what is already read is also what stops a linked page being fetched
        // twice: the linked sources sit at the front of this list and arrive carrying
        // their text.
        //
        // And a search result is a URL nobody in this conversation typed. The question's
        // own links may point wherever the user pointed them, `http://localhost:3000`
        // included — that is the feature working. A URL that arrived from a search
        // engine has no such licence: fetching `http://192.168.1.1/admin` because a page
        // won a search slot would probe the user's own network and hand what it found to
        // the model provider as evidence. The address on the far side of a redirect is
        // held to the same rule inside the reader, which is the only other way one
        // arrives unasked.
        // One consequence worth naming: a question's own link that failed in the linked
        // pass (an empty text — a dev server that was briefly down) is unread, so it
        // would otherwise be retried here. If it is private, it no longer is. That is
        // the policy working rather than an oversight — this pass cannot tell the
        // question's links from the search results — and it costs a retry the linked
        // pass already had its chance at.
        let targets = Array(readableTargets(in: sources).prefix(max(0, budget)))
        guard !targets.isEmpty else {
            // Nothing survived the filter, so nothing will be fetched — and that is the
            // one turn where reading visibly did nothing. It gets the sentence a reader
            // that fetched and failed would get, rather than silence: before this pass
            // learned to refuse an address, these pages reached the reader and came back
            // empty, which is what raised the notice. Refusing earlier must not also
            // mean explaining less. `alreadyRead` keeps it honest — a turn that read the
            // page the user pasted is not a turn that read nothing.
            if alreadyRead == 0 { update { $0.addNotice(.noPagesRead) } }
            return sources
        }

        let (enriched, read) = await performReads(targets, in: sources, settings: settings)
        // One honesty rule for every failure shape — reader broken, fetches empty,
        // targets filtered out: "no page could be read" is said exactly when the turn
        // has no page text. A reader that could not be built used to raise this even
        // over a turn that had read the question's links, which was the one claim the
        // notice exists not to make.
        if read == 0, alreadyRead == 0 { update { $0.addNotice(.noPagesRead) } }
        return enriched
    }

    /// The sources a fetch is both permitted and meaningful for: unread, fetchable,
    /// and publicly routable. Shared by the rank-order fill and the deep rounds'
    /// by-number requests, so the two never drift on what may be fetched.
    ///
    /// A search result is a URL nobody in this conversation typed. The question's
    /// own links may point wherever the user pointed them, `http://localhost:3000`
    /// included — that is the feature working. A URL that arrived from a search
    /// engine has no such licence: fetching `http://192.168.1.1/admin` because a page
    /// won a search slot would probe the user's own network and hand what it found to
    /// the model provider as evidence. The address on the far side of a redirect is
    /// held to the same rule inside the reader, which is the only other way one
    /// arrives unasked.
    /// One consequence worth naming: a question's own link that failed in the linked
    /// pass (an empty text — a dev server that was briefly down) is unread, so it
    /// would otherwise be retried here. If it is private, it no longer is. That is
    /// the policy working rather than an oversight — this pass cannot tell the
    /// question's links from the search results — and it costs a retry the linked
    /// pass already had its chance at.
    private func readableTargets(in sources: [Source]) -> [Source] {
        sources.filter { source in
            guard !source.wasRead else { return false }
            // Two different skips, so the trace does not report a malformed URL as a
            // private one and send whoever reads it looking in the wrong place.
            guard let url = DirectPageReader.fetchableURL(source.url) else {
                trace.log("Page read skipped: not a fetchable address")
                return false
            }
            // The address itself stays out of the log, as in the reader's own refusal.
            guard DirectPageReader.isPubliclyRoutable(url) else {
                trace.log("Page read skipped: not a public address")
                return false
            }
            return true
        }
    }

    /// Reads the pages a deep round asked for by source number.
    ///
    /// Returns the texts keyed by source number rather than attaching them: the caller
    /// rebuilds the source list from raw results after every round, and anything
    /// attached here would be discarded by the next rebuild. `attempted` is what came
    /// out of the page budget — requests and context are spent whether or not the page
    /// answered, matching the rule the question's own links are charged by.
    private func readPlannedPages(_ numbers: [Int],
                                  in sources: [Source],
                                  settings: ProviderSettings,
                                  budget: Int) async -> (texts: [Int: String], attempted: Int) {
        // In the model's order, not the source list's: the request is a priority
        // list, and when the budget takes only some of it, the ones it named first
        // are the ones it wanted most.
        let requested = readableTargets(in: sources)
            .filter { numbers.contains($0.number) }
            .sorted { left, right in
                let leftIndex = numbers.firstIndex(of: left.number) ?? .max
                let rightIndex = numbers.firstIndex(of: right.number) ?? .max
                return leftIndex < rightIndex
            }
        let targets = Array(requested.prefix(max(0, budget)))
        guard !targets.isEmpty else { return ([:], 0) }
        trace.log("Round asked for \(numbers.count) page(s) by number; reading \(targets.count)")
        let (enriched, _) = await performReads(targets, in: sources, settings: settings)
        var texts: [Int: String] = [:]
        for source in enriched where targets.contains(where: { $0.number == source.number }) {
            if let text = source.fullText, !text.isEmpty { texts[source.number] = text }
        }
        return (texts, targets.count)
    }

    /// Fetches `targets` and attaches the texts to the sources they belong to. The
    /// shared core of every read after the question's own links: build the reader,
    /// account the attempt against the turn, attach what answered.
    ///
    /// Never throws and never raises a notice of its own. A reader that cannot be
    /// built or a page that will not load is a source that keeps its snippet — the
    /// caller decides what the turn should say about it, because the honest sentence
    /// depends on what the rest of the turn managed to read.
    private func performReads(_ targets: [Source],
                              in sources: [Source],
                              settings: ProviderSettings)
        async -> (sources: [Source], read: Int) {
        let reader: PageReading?
        do {
            reader = try PageReaderFactory.make(settings: settings, readerKey: environment.readerKey,
                                                trace: trace, transport: transport)
            try await reader?.connect()
        } catch {
            trace.warn("Page reading unavailable: \(ResearchError.safeLabel(for: error))")
            return (sources, 0)
        }
        guard let reader else { return (sources, 0) }

        update {
            $0.pagesAttempted += targets.count
            $0.pagesInFlight = targets.count
        }
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
        // One snapshot for the end of the fetch and its result, as above. The count
        // moves here, in the one place reads happen, so the rank-order fill and the
        // rounds' requested reads cannot drift on how a page is tallied.
        update {
            $0.pagesInFlight = 0
            $0.pagesRead += read
        }
        trace.log("Pages read: \(read) of \(targets.count)")
        return (enriched, read)
    }

    /// The `/direct` path: one streamed call, no search, no citations.
    private func answerDirectly(chain: ModelChain,
                                question: String,
                                history: [ResearchTurn],
                                today: String,
                                attachments: (payload: [[String: String]],
                                              images: [ChatCompletionsClient.ImagePart],
                                              imageNames: [String])) async throws {
        update { $0.stage = .answering }
        var directExtra: [String: Any] = [:]
        if !attachments.payload.isEmpty { directExtra["attachments"] = attachments.payload }
        let context = ResearchContext.assemble(question: question, history: history,
                                               today: today, extra: directExtra)
        if context.trimmed { update { $0.addNotice(.contextTrimmed) } }
        // The same second payload the research path builds, for the same reason: a
        // question about a picture, asked of a provider that cannot see it, must arrive
        // with the picture *named as unavailable* rather than with nothing at all.
        let withheldContext = attachments.images.isEmpty ? nil : ResearchContext.assemble(
            question: question, history: history, today: today,
            extra: Self.namingImagesUnavailable(directExtra, attachments))
        // Same reset as the research path's answer stage, for the same reason.
        var sentImages = false
        _ = try await chain.perform("Direct answer", beforeRetry: { [weak self] in
            self?.update { $0.answer = "" }
        }) { chat in
            let images = chat.imagesWillBeSent ? attachments.images : []
            let payload = images.isEmpty ? (withheldContext ?? context).payload
                                         : context.payload
            let text = try await chat.streamText(
                system: ResearchPrompts.direct, payload: payload,
                withoutImages: images.isEmpty ? nil : withheldContext?.payload,
                label: "Direct answer", images: images
            ) { [weak self] chunk in
                self?.update { $0.answer += chunk }
            }
            // After the call, as in the research path's answer: a rejected image was
            // retried without and must be reported as left out.
            sentImages = !images.isEmpty && !chat.withheldImages
            return text
        }
        // And here, for the same reason as the research path.
        if !sentImages, withheldContext?.trimmed == true {
            update { $0.addNotice(.contextTrimmed) }
        }
        if !attachments.images.isEmpty, !sentImages { update { $0.addNotice(.imagesNotSent) } }
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
