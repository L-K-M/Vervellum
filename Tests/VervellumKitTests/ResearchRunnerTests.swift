import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// `ResearchRunner` driven end to end over a scripted transport.
///
/// Everything else about the pipeline was already testable — the parsers, the context
/// budget, the citation rules, the numbering — and every one of those is a *piece*. What
/// no test could reach was the order the pieces run in and what each stage is actually
/// sent, which is where the two most recent features live: a question's links are read
/// before the planner so that the plan can be informed by them, and the pages they
/// produce become the turn's first numbered sources. Both of those are claims about
/// sequence, and a unit test of a pure function cannot make them.
///
/// The transport is the only thing faked. Requests are built, search arguments validated
/// against the advertised schema, replies parsed and evidence assembled by the real code
/// — see `StubTransport` for why the seam is there and not higher up.
final class ResearchRunnerTests: XCTestCase {

    // MARK: Fixtures

    private static let modelEndpoint = "https://model.test/v1"
    private static let modelURL = "https://model.test/v1/chat/completions"
    private static let searchEndpoint = "https://search.test"

    private func settings(pageReading: PageReadingMode = .direct,
                          searchKind: SearchProviderKind = .searxng,
                          searchEndpoint: String = ResearchRunnerTests.searchEndpoint,
                          sendsImages: Bool = false) -> ProviderSettings {
        var settings = ProviderSettings(modelEndpoint: Self.modelEndpoint,
                                        modelName: "test-model",
                                        searchEndpoint: searchEndpoint,
                                        searchKind: searchKind,
                                        pageReading: pageReading)
        // Without a profile to stamp, `sendsImages` would be a silently ignored
        // argument and every image test would run on the default configuration.
        XCTAssertFalse(settings.modelProfiles.isEmpty,
                       "no model profile to configure; sendsImages would do nothing")
        for index in settings.modelProfiles.indices {
            settings.modelProfiles[index].sendsImages = sendsImages
        }
        return settings
    }

    private func environment(pageReading: PageReadingMode = .direct,
                             searchKind: SearchProviderKind = .searxng,
                             searchEndpoint: String = ResearchRunnerTests.searchEndpoint,
                             sendsImages: Bool = false)
        -> ResearchRunner.Environment {
        ResearchRunner.Environment(settings: settings(pageReading: pageReading,
                                                      searchKind: searchKind,
                                                      searchEndpoint: searchEndpoint,
                                                      sendsImages: sendsImages),
                                   modelKey: "model-key", searchKey: nil)
    }

    private func run(_ question: String,
                     mode: ResearchRunner.Mode = .research,
                     pageReading: PageReadingMode = .direct,
                     searchKind: SearchProviderKind = .searxng,
                     searchEndpoint: String = ResearchRunnerTests.searchEndpoint,
                     transport: StubTransport,
                     commandRunner: StubCommandRunner = StubCommandRunner { _ in .unrouted },
                     sendsImages: Bool = false,
                     attachments: [Attachment] = [],
                     attachmentBytes: @escaping (Attachment) -> Data? = { _ in nil })
        async -> ResearchTurn {
        let runner = ResearchRunner(environment: environment(pageReading: pageReading,
                                                             searchKind: searchKind,
                                                             searchEndpoint: searchEndpoint,
                                                             sendsImages: sendsImages),
                                    trace: ResearchTrace(sink: SilentLog()),
                                    transport: transport,
                                    commandRunner: commandRunner,
                                    attachmentBytes: attachmentBytes)
        var turn = ResearchTurn(question: question)
        turn.attachments = attachments
        return await runner.run(turn, mode: mode, history: [], onUpdate: { _ in })
    }

    /// The stage a chat-completions request belongs to, read off its system prompt.
    ///
    /// The stages share one endpoint, so the prompt is what tells them apart — which is
    /// also a small guard on the prompts themselves: a stage that stopped sending the
    /// prompt it is named for would stop being routed here.
    private enum Stage {
        case plan, deepPlan, answer, assess, revise
    }

    private static func stage(of call: StubTransport.Call) -> Stage? {
        guard let prompt = call.systemPrompt else { return nil }
        // The deep round is tested first even though the two phrases do not currently
        // overlap: they are two spellings of the same job, and a later round's prompt
        // that borrowed a clause from the first would be classified as round one and fed
        // round one's reply — which surfaces as a wrong search count several assertions
        // away from the cause.
        if prompt.contains("TASK: this is round") { return .deepPlan }
        if prompt.contains("TASK: plan the web searches") { return .plan }
        if prompt.contains("TASK: answer the user's question using the numbered evidence") {
            return .answer
        }
        if prompt.contains("TASK: assess the material claims") { return .assess }
        // Answered before this one and by a longer phrase, because both stages talk
        // about "the answer": the revision prompt repeats the citation rule "exactly as
        // it was for the answer", and a looser answer test would swallow it and feed the
        // revision the answer's script.
        if prompt.contains("TASK: correct an answer you are given") { return .revise }
        return nil
    }

    private static func plan(_ query: String,
                            purpose: String = "settle the question") -> [String: Any] {
        let search: [String: Any] = ["purpose": purpose, "arguments": ["q": query]]
        return ["reading": "The question asks about a documented fact.", "searches": [search]]
    }

    private static func searxng(_ hits: [(url: String, title: String)]) -> [String: Any] {
        ["results": hits.map { ["url": $0.url, "title": $0.title, "content": "A summary of \($0.title)."] }]
    }

    private static let assessment: [String: Any] = {
        let finding: [String: Any] = [
            "claim": "The page says what the answer says it says.",
            "verdict": "supported",
            "reasoning": "The page text states it directly.",
            "sources": [1],
        ]
        return [
            "findings": [finding],
            "limitations": "Only one page was consulted.",
            "followups": ["What does the other side say?"],
        ]
    }()

    /// An assessment with one finding of the given verdict, for the revision tests.
    private static func assessment(verdict: String,
                                   claim: String = "Parallax is measured in arcseconds.",
                                   sources: [Int] = [1],
                                   alongside: [(verdict: String, claim: String)] = [])
        -> [String: Any] {
        func finding(_ verdict: String, _ claim: String) -> [String: Any] {
            [
                "claim": claim,
                "verdict": verdict,
                "reasoning": "What the evidence does and does not carry.",
                "sources": sources,
            ]
        }
        // `alongside` exists so a fixture can carry a second verdict. Every one of these
        // used to hold exactly one finding, which meant `isShownToReviser` was only ever
        // asked what it returns and never what it *does*.
        return ["findings": [finding(verdict, claim)] + alongside.map { finding($0.verdict, $0.claim) },
                "limitations": "", "followups": []]
    }

    // MARK: A whole turn

    func testAResearchTurnRunsItsStagesInOrder() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .json where call.url.absoluteString.hasPrefix(Self.modelURL):
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("stellar parallax"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .json where call.url.path == "/search":
                return .json(Self.searxng([(url: "https://a.example/one", title: "One"),
                                           (url: "https://b.example/two", title: "Two")]))
            case .fetch:
                return .html("<p>The page text for \(call.url.path).</p>")
            case .stream:
                return .stream(["Parallax is measured in arcseconds [1]. ",
                                "A second source agrees [2]."])
            default:
                return .unrouted
            }
        }

        let turn = await run("How is stellar parallax measured?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.reading, "The question asks about a documented fact.")
        XCTAssertEqual(turn.searches.count, 1)
        XCTAssertEqual(turn.sources.map(\.number), [1, 2])
        XCTAssertEqual(turn.sources.map(\.url), ["https://a.example/one", "https://b.example/two"])
        XCTAssertEqual(turn.pagesAttempted, 2)
        XCTAssertEqual(turn.pagesRead, 2)
        XCTAssertTrue(turn.sources.allSatisfy(\.wasRead))
        XCTAssertEqual(turn.answer,
                       "Parallax is measured in arcseconds [1]. A second source agrees [2].")
        XCTAssertEqual(turn.findings.count, 1)
        XCTAssertEqual(turn.limitations, "Only one page was consulted.")
        XCTAssertEqual(turn.followups, ["What does the other side say?"])
        XCTAssertTrue(turn.notices.isEmpty, "unexpected notices: \(turn.notices)")

        // The order the stages actually ran in. The two page reads are concurrent — one
        // task group, deliberately, because they are unrelated hosts — so they are
        // asserted as a set between the search and the answer.
        let calls = transport.calls
        guard calls.count == 6 else {
            return XCTFail("expected six requests, got \(transport.trail)")
        }
        XCTAssertEqual(Self.stage(of: calls[0]), .plan)
        XCTAssertEqual(calls[1].url.path, "/search")
        XCTAssertEqual(Set(calls[2...3].map { $0.url.absoluteString }),
                       ["https://a.example/one", "https://b.example/two"])
        XCTAssertTrue(calls[2...3].allSatisfy { $0.kind == .fetch })
        XCTAssertEqual(Self.stage(of: calls[4]), .answer)
        XCTAssertEqual(calls[4].kind, .stream)
        XCTAssertEqual(Self.stage(of: calls[5]), .assess)
    }

    // MARK: Kagi

    /// The one search backend that is a program rather than a server, run end to end.
    ///
    /// Worth a whole-turn test rather than only a unit one because the interesting claims
    /// are about the *seam*: that the planner's query reaches an argument vector rather
    /// than a URL, that no search request goes out over HTTP at all, and that the rest of
    /// the pipeline — numbering, page reading, citation — cannot tell the difference.
    func testAKagiTurnSearchesByRunningTheCommand() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .json where call.url.absoluteString.hasPrefix(Self.modelURL):
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("stellar parallax"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .fetch:
                return .html("<p>The page text for \(call.url.path).</p>")
            case .stream:
                return .stream(["Parallax is measured in arcseconds [1]."])
            default:
                return .unrouted
            }
        }
        let commands = StubCommandRunner { call in
            guard call.arguments.first == "search" else { return .unrouted }
            return .kagiResults([(url: "https://a.example/one", title: "One")])
        }

        let turn = await run("How is stellar parallax measured?",
                             searchKind: .kagiCLI, searchEndpoint: "kagi",
                             transport: transport, commandRunner: commands)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.sources.map(\.url), ["https://a.example/one"])
        XCTAssertEqual(turn.sources.map(\.number), [1])
        XCTAssertTrue(turn.sources.allSatisfy(\.wasRead), "the page behind a Kagi hit was not read")
        XCTAssertEqual(turn.answer, "Parallax is measured in arcseconds [1].")

        // The command was found by the name the settings hold, and run once with the
        // planner's query as a positional argument after the separator.
        XCTAssertEqual(commands.resolved, ["kagi"])
        XCTAssertEqual(commands.calls.map(\.arguments),
                       [["search", "--format", "json", "--", "stellar parallax"]])
        // The key never travels in the vector, where `ps` would show it, and nothing this
        // process holds travels in the environment either.
        let environment = try XCTUnwrap(commands.calls.first?.environment)
        XCTAssertTrue(Set(environment.keys).isSubset(of: Set(KagiCLIClient.passedThrough)),
                      "unexpected subprocess environment: \(environment.keys)")
        // And nothing went looking for a search server: the only requests are the model's
        // three stages and the page fetch.
        XCTAssertEqual(transport.trail.filter { $0.contains("/search") }, [])
        XCTAssertEqual(transport.calls.count, 4, transport.trail.description)
    }

    /// A tool that is not installed is a configuration problem, and it is reported before
    /// the turn's first billable call rather than as a search that failed a minute in.
    func testAMissingKagiToolFailsTheTurnBeforeTheModelIsAsked() async throws {
        let transport = StubTransport { _ in .unrouted }
        let commands = StubCommandRunner(executable: nil) { _ in .unrouted }

        let turn = await run("How is stellar parallax measured?",
                             searchKind: .kagiCLI, searchEndpoint: "kagi",
                             transport: transport, commandRunner: commands)

        XCTAssertEqual(turn.stage, .failed)
        XCTAssertTrue(transport.calls.isEmpty,
                      "the model was asked to plan a turn that could not search: "
                      + transport.trail.description)
        XCTAssertTrue(commands.calls.isEmpty)
        // Pins *why* it failed. Without this the test passes for any pre-flight failure
        // at all, including one that has nothing to do with the tool being missing.
        XCTAssertEqual(commands.resolved, ["kagi"])
    }

    /// The other failure, and the one that costs money: the tool is installed, the
    /// planner has been paid for, and the search itself fails. The turn fails rather than
    /// answering from nothing, and the reason survives to the turn where the user reads
    /// it — a rate limit named as one beats "research failed".
    func testAKagiCommandThatFailsAfterPlanningFailsTheTurn() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .json where call.url.absoluteString.hasPrefix(Self.modelURL):
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("stellar parallax"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .stream:
                return .stream(["An answer that should never be written."])
            default:
                return .unrouted
            }
        }
        let commands = StubCommandRunner { _ in
            .output(status: 1, text: "kagi: rate limited")
        }

        let turn = await run("How is stellar parallax measured?",
                             searchKind: .kagiCLI, searchEndpoint: "kagi",
                             transport: transport, commandRunner: commands)

        XCTAssertEqual(turn.stage, .failed)
        let failure = try XCTUnwrap(turn.failure)
        XCTAssertTrue(failure.contains("exited with status 1"), failure)
        // And the tool's own words are not what the user is shown.
        XCTAssertFalse(failure.contains("rate limited"), failure)
    }

    // MARK: Address space

    /// A search result is a URL nobody in this conversation typed, so it does not get to
    /// point the reader at the user's own network. The source stays — it is still a
    /// result, and it keeps its snippet like any page that could not be read — but the
    /// request is never made, which is the difference between a page Vervellum declined
    /// to read and a probe of a home router whose response text goes to the model
    /// provider as evidence.
    func testASearchResultOnAPrivateAddressIsNeverFetched() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .json where call.url.absoluteString.hasPrefix(Self.modelURL):
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("router admin page"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .json where call.url.path == "/search":
                return .json(Self.searxng([(url: "https://a.example/one", title: "One"),
                                           (url: "http://192.168.1.1/admin", title: "Router")]))
            case .fetch:
                return .html("<p>The page text for \(call.url.path).</p>")
            case .stream:
                return .stream(["The public page says so [1]."])
            default:
                return .unrouted
            }
        }

        let turn = await run("What does my router's admin page say?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.sources.map(\.url),
                       ["https://a.example/one", "http://192.168.1.1/admin"],
                       "the result should still be a source, just an unread one")
        XCTAssertEqual(turn.pagesAttempted, 1)
        XCTAssertEqual(turn.pagesRead, 1)
        XCTAssertEqual(turn.sources.map(\.wasRead), [true, false])
        // "Keeps its snippet" is the promise above, so it is asserted rather than
        // assumed: an unread source that arrived with nothing would be a result the
        // answer cannot use at all, which is a different outcome from not reading it.
        XCTAssertEqual(turn.sources.last?.title, "Router")
        XCTAssertFalse(turn.sources.last?.snippet.isEmpty ?? true)
        XCTAssertEqual(transport.calls.filter { $0.kind == .fetch }.map { $0.url.absoluteString },
                       ["https://a.example/one"],
                       "only the public page may be fetched, and a private address never "
                       + "requested at all")
    }

    /// And the turn where the filter takes everything: a search that returned only
    /// addresses Vervellum will not fetch. Refusing earlier than the reader must not
    /// also mean explaining less — before the filter existed these pages were fetched,
    /// came back empty and raised the notice, so a turn that now refuses them without a
    /// word would be the one turn where reading visibly did nothing and nothing said so.
    func testATurnWhoseResultsAreAllPrivateSaysNoPageWasRead() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .json where call.url.absoluteString.hasPrefix(Self.modelURL):
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("router admin page"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .json where call.url.path == "/search":
                return .json(Self.searxng([(url: "http://192.168.1.1/admin", title: "Router")]))
            case .stream:
                return .stream(["The snippet is all there is [1]."])
            default:
                return .unrouted
            }
        }

        let turn = await run("What does my router's admin page say?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertTrue(turn.notices.contains(.noPagesRead), "notices: \(turn.notices)")
        // The other half of the same contract: a refused result is still a source, kept
        // with its snippet, exactly as it is on the turn where only some were refused.
        // Dropping them here would leave the answer's `[1]` pointing at nothing.
        XCTAssertEqual(turn.sources.map(\.url), ["http://192.168.1.1/admin"])
        XCTAssertFalse(turn.sources.first?.snippet.isEmpty ?? true)
        XCTAssertEqual(turn.pagesAttempted, 0)
        XCTAssertEqual(turn.pagesRead, 0)
        XCTAssertTrue(transport.calls.allSatisfy { $0.kind != .fetch },
                      "nothing may be fetched: \(transport.trail)")
    }

    // MARK: Attachments

    private static let image = Attachment(kind: .image, name: "shot.png",
                                          mediaType: "image/png", byteCount: 4)

    /// A `/direct` turn with an image, on a provider configured to be shown one: the
    /// picture reaches the request as an inline data URL beside the question's text.
    func testAnAttachedImageIsSentToAProviderThatTakesOne() async throws {
        let transport = StubTransport { call in
            call.kind == .stream ? .stream(["It is a screenshot of a stack trace."]) : .unrouted
        }

        let turn = await run("What is this?", mode: .direct, transport: transport,
                             sendsImages: true, attachments: [Self.image],
                             attachmentBytes: { _ in Data([0x89, 0x50, 0x4E, 0x47]) })

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertFalse(turn.notices.contains(.imagesNotSent))

        let body = try XCTUnwrap(transport.calls.first?.body)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        // Exactly two: the question and the picture. Endpoint-only checks would let a
        // duplicated text part or a stray empty one through, and a provider charges for
        // every part.
        XCTAssertEqual(parts.count, 2, "unexpected parts: \(parts)")
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        // The question itself, not just a text part: an image that arrived in place of
        // the words would be the most visible bug this feature could have.
        let text = try XCTUnwrap(parts.first?["text"] as? String)
        XCTAssertTrue(text.contains("What is this?"), text)
        // And the picture's *name*, which was the asymmetry worth closing: a withheld
        // image was announced by name while a delivered one arrived as anonymous
        // pixels. A question is written about files the way the user sees them, and a
        // model handed four pictures in order with no names can resolve none of them.
        XCTAssertTrue(text.contains("shot.png"), text)
        XCTAssertTrue(text.contains("\"sent\""), text)
        // Never both. `sent` and `unavailable` are opposite answers about one file, and
        // the withheld payload replaces the first with the second rather than adding to
        // it — see the merges in `ResearchRunner`.
        XCTAssertFalse(text.contains("unavailable"), text)
        // The part's `type` as well as its payload: a part carrying the right data URL
        // under a missing or misspelled type passes every other assertion here and is
        // refused by the provider, which is a failure that arrives in production rather
        // than in this suite.
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
        XCTAssertEqual((parts.last?["image_url"] as? [String: Any])?["url"] as? String,
                       "data:image/png;base64,iVBORw==")
    }

    /// The same turn on a provider nobody said has eyes. The question still gets an
    /// answer — a request carrying an image part would have been rejected outright — and
    /// the turn says the picture was left out, because an answer that ignores it with
    /// nothing explaining why reads as a model that looked and did not understand.
    func testAnImageIsWithheldFromAProviderThatCannotSeeAndTheTurnSaysSo() async throws {
        let transport = StubTransport { call in
            call.kind == .stream ? .stream(["I cannot see the attachment."]) : .unrouted
        }

        let turn = await run("What is this?", mode: .direct, transport: transport,
                             sendsImages: false, attachments: [Self.image],
                             attachmentBytes: { _ in Data([0x89, 0x50, 0x4E, 0x47]) })

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertTrue(turn.notices.contains(.imagesNotSent), "notices: \(turn.notices)")

        // And the request is the shape it was before this feature existed.
        let body = try XCTUnwrap(transport.calls.first?.body)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertNotNil(messages.last?["content"] as? String,
                        "an image-less request must still send a plain string")
        // The whole request, not only the last message: an image part placed anywhere
        // else — the system message, an extra message appended later — is the placement
        // failure the client-level test scans for, and the comment above claims the
        // shape of the request rather than the shape of one message in it.
        let whole = String(decoding: try JSONSerialization.data(withJSONObject: body),
                           as: UTF8.self)
        XCTAssertFalse(whole.contains("image_url"),
                       "an image reached a provider that cannot see")
        // Named, and named once. The picture is announced as unavailable so the model
        // can say what it could not see — and *only* as unavailable, because the sent
        // marker it would otherwise carry is the opposite answer about the same file.
        //
        // Asked of the user content rather than of `whole`: the system prompt explains
        // both markers by name, so a whole-body search finds the words in the
        // instructions and proves nothing about the payload.
        let content = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(content.contains("shot.png"), content)
        XCTAssertTrue(content.contains("unavailable"), content)
        XCTAssertFalse(content.contains("\"sent\""), content)
    }

    /// An attached text file is inlined into the payload, so a model with no eyes at all
    /// can still read it — and the provider's image flag has nothing to do with it.
    func testAnAttachedTextFileIsInlinedForAnyProvider() async throws {
        let transport = StubTransport { call in
            call.kind == .stream ? .stream(["The log shows a timeout."]) : .unrouted
        }
        let note = Attachment(kind: .text, name: "log.txt", mediaType: "text/plain", byteCount: 12)

        let turn = await run("What failed?", mode: .direct, transport: transport,
                             sendsImages: false, attachments: [note],
                             attachmentBytes: { _ in Data("read timeout".utf8) })

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertFalse(turn.notices.contains(.imagesNotSent), "a text file is not an image")
        let content = try XCTUnwrap(transport.calls.first?.userContent)
        XCTAssertTrue(content.contains("read timeout"), content)
        XCTAssertTrue(content.contains("log.txt"), content)
    }

    /// Bytes that are gone — a library copied without its attachments folder — are not a
    /// failed turn. The question is still a question.
    func testAnAttachmentWhoseBytesAreGoneDoesNotFailTheTurn() async throws {
        let transport = StubTransport { call in
            call.kind == .stream ? .stream(["Answering from the words alone."]) : .unrouted
        }

        let turn = await run("What is this?", mode: .direct, transport: transport,
                             sendsImages: true, attachments: [Self.image],
                             attachmentBytes: { _ in nil })

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        // And it is said out loud. An answer that ignores the picture with nothing
        // explaining why is the thing the notices exist to prevent — the bytes being
        // gone is a different reason from the provider having no eyes, so it is a
        // different notice.
        XCTAssertTrue(turn.notices.contains(.attachmentMissing), "notices: \(turn.notices)")
        XCTAssertFalse(turn.notices.contains(.imagesNotSent),
                       "no setting would have made this one arrive")
        let body = try XCTUnwrap(transport.calls.first?.body)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertNotNil(messages.last?["content"] as? String)
        // And the model is told which file it is not seeing, so it can say so instead of
        // answering as though nothing had been attached.
        let content = try XCTUnwrap(transport.calls.first?.userContent)
        XCTAssertTrue(content.contains("shot.png"), content)
        XCTAssertTrue(content.contains("unavailable"), content)
    }

    /// Zero bytes are no more readable than bytes that are gone, and an empty `data:`
    /// URL is a thing no provider can use. `Attachment.make` refuses an empty file, so
    /// this is storage that was truncated rather than anything a user chose.
    func testAnEmptyAttachmentIsReportedAsMissing() async throws {
        let transport = StubTransport { call in
            call.kind == .stream ? .stream(["Answering from the words alone."]) : .unrouted
        }

        let turn = await run("What is this?", mode: .direct, transport: transport,
                             sendsImages: true, attachments: [Self.image],
                             attachmentBytes: { _ in Data() })

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertTrue(turn.notices.contains(.attachmentMissing), "notices: \(turn.notices)")
        // And not `.imagesNotSent`, which `sendsImages: true` here makes the point of:
        // the picture is absent because its bytes are unreadable, not because a setting
        // withheld it — and that notice tells the reader to go and flip the setting.
        XCTAssertFalse(turn.notices.contains(.imagesNotSent),
                       "no setting would have made this one arrive")
        let body = try XCTUnwrap(transport.calls.first?.body)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertNotNil(messages.last?["content"] as? String,
                        "an empty image must not become an empty image part")
    }

    /// A picture and a log on the same question. The image rides only because this
    /// provider has eyes; the log would have been inlined either way, and both reach the
    /// same request.
    func testAnImageAndATextFileTravelTogether() async throws {
        let transport = StubTransport { call in
            call.kind == .stream ? .stream(["The trace shows a timeout."]) : .unrouted
        }
        let log = Attachment(kind: .text, name: "log.txt", mediaType: "text/plain", byteCount: 12)

        let turn = await run("What failed?", mode: .direct, transport: transport,
                             sendsImages: true, attachments: [Self.image, log],
                             attachmentBytes: { attachment in
                                 attachment.kind == .image
                                     ? Data([0x89, 0x50, 0x4E, 0x47])
                                     : Data("read timeout".utf8)
                             })

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertFalse(turn.notices.contains(.attachmentMissing), "notices: \(turn.notices)")
        XCTAssertFalse(turn.notices.contains(.imagesNotSent), "notices: \(turn.notices)")
        let call = try XCTUnwrap(transport.calls.first)
        let messages = try XCTUnwrap(call.body?["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2, "unexpected parts: \(parts)")
        // The text file rides inside the question payload, which is the text part.
        let text = try XCTUnwrap(parts.first?["text"] as? String)
        XCTAssertTrue(text.contains("What failed?"), text)
        XCTAssertTrue(text.contains("read timeout"), text)
        XCTAssertTrue(text.contains("log.txt"), text)
        // The part's `type` as well as its payload: a part carrying the right data URL
        // under a missing or misspelled type passes every other assertion here and is
        // refused by the provider, which is a failure that arrives in production rather
        // than in this suite.
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
        XCTAssertEqual((parts.last?["image_url"] as? [String: Any])?["url"] as? String,
                       "data:image/png;base64,iVBORw==")
    }

    // MARK: Links in the question

    func testAQuestionsLinksAreReadBeforeThePlannerIsAsked() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .fetch where call.url.absoluteString == "https://linked.example/paper":
                return .html("<p>The paper reports a 12 percent improvement.</p>")
            case .fetch:
                return .html("<p>A page a search turned up.</p>")
            case .json where call.url.path == "/search":
                return .json(Self.searxng([(url: "https://other.example/review", title: "A review")]))
            case .json:
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("independent review of the paper"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .stream:
                return .stream(["The paper claims 12 percent [1], and a review agrees [2]."])
            }
        }

        let turn = await run("Is https://linked.example/paper sound?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")

        // The claim this feature rests on: the page is read *before* the plan exists, so
        // the plan can be written against what it says rather than against its address.
        let calls = transport.calls
        XCTAssertEqual(calls.first?.kind, .fetch)
        XCTAssertEqual(calls.first?.url.absoluteString, "https://linked.example/paper")
        let firstPlan = try XCTUnwrap(calls.firstIndex { Self.stage(of: $0) == .plan })
        XCTAssertEqual(firstPlan, 1, "the planner must be asked after the link has been read")

        // And that the planner was actually shown it.
        let planPayload = try XCTUnwrap(calls[firstPlan].userContent)
        XCTAssertTrue(planPayload.contains("linked_pages"), planPayload)
        XCTAssertTrue(planPayload.contains("12 percent improvement"), planPayload)

        // The linked page is the turn's first numbered source, ahead of what the search
        // found, and it is marked as read rather than as a search summary.
        XCTAssertEqual(turn.sources.map(\.url),
                       ["https://linked.example/paper", "https://other.example/review"])
        XCTAssertEqual(turn.sources.map(\.number), [1, 2])
        XCTAssertEqual(turn.sources.first?.wasRead, true)
        XCTAssertTrue(turn.notices.isEmpty, "unexpected notices: \(turn.notices)")
    }

    func testASearchHitForALinkedPageIsNotNumberedTwice() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .fetch:
                return .html("<p>Text for \(call.url.path).</p>")
            case .json where call.url.path == "/search":
                // The search returns the very page the question linked to, plus one more.
                return .json(Self.searxng([(url: "https://linked.example/paper", title: "The paper"),
                                           (url: "https://other.example/review", title: "A review")]))
            case .json:
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("the paper"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .stream:
                return .stream(["It holds up [1]."])
            }
        }

        let turn = await run("What about https://linked.example/paper ?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.sources.map(\.url),
                       ["https://linked.example/paper", "https://other.example/review"],
                       "the duplicate must be dropped, not numbered twice")
        // Contiguous from one: a gap in the numbering is an invitation to cite the
        // number that is missing.
        XCTAssertEqual(turn.sources.map(\.number), [1, 2])
        // And the page is read once, not twice. Numbering it once while fetching it
        // again would pass every assertion above while spending a second request and
        // letting source 1's text disagree with the copy the second read returned.
        XCTAssertEqual(transport.calls.filter {
            $0.kind == .fetch && $0.url.absoluteString == "https://linked.example/paper"
        }.count, 1, "the linked page is reused, not re-fetched as a search hit")
    }

    /// The dedupe compares pages, not strings. A browser hands over the fragment it was
    /// scrolled to; the search engine returns the canonical address. Byte equality calls
    /// those two sources and shows the model one document twice.
    func testASearchHitUnderAVariantAddressIsNotNumberedTwice() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .fetch:
                return .html("<p>Text for \(call.url.path).</p>")
            case .json where call.url.path == "/search":
                return .json(Self.searxng([(url: "https://www.linked.example/paper/",
                                            title: "The paper"),
                                           (url: "https://other.example/review",
                                            title: "A review")]))
            case .json:
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("the paper"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .stream:
                return .stream(["It holds up [1]."])
            }
        }

        let turn = await run("What about https://linked.example/paper#results ?",
                             transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.sources.map(\.url),
                       ["https://linked.example/paper#results",
                        "https://other.example/review"],
                       "a fragment, a www. and a trailing slash are not a second page")
        XCTAssertEqual(turn.sources.map(\.number), [1, 2])
        // The fold has to hold at read time as well as at numbering time. Canonicalising
        // only for the numbering would still spend a second request and let source 1's
        // text disagree with the copy that came back under the other address.
        XCTAssertEqual(transport.calls.filter {
            $0.kind == .fetch && $0.url.absoluteString == "https://www.linked.example/paper/"
        }.count, 0, "the search hit reuses the linked page's read")
    }

    func testPageReadingOffLeavesALinkUnreadAndSaysSo() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .json where call.url.path == "/search":
                return .json(Self.searxng([(url: "https://other.example/review", title: "A review")]))
            case .json:
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("the paper"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .stream:
                return .stream(["A review says so [1]."])
            case .fetch:
                return .unrouted  // Nothing may be fetched; an attempt fails the test loudly.
            }
        }

        let turn = await run("What about https://linked.example/paper ?",
                             pageReading: .off, transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertTrue(turn.notices.contains(.linkReadingOff), "\(turn.notices)")
        XCTAssertFalse(transport.calls.contains { $0.kind == .fetch },
                       "reading off means nothing is fetched, pasted link or not")
        XCTAssertFalse(turn.sources.contains { $0.url == "https://linked.example/paper" },
                       "an unread link must not become a numbered source")
        XCTAssertEqual(turn.pagesRead, 0)
    }

    func testALinkThatCouldNotBeReadDoesNotBecomeASource() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .fetch where call.url.absoluteString == "https://linked.example/paper":
                return .page(status: 404, headers: [:], text: "not found")
            case .fetch:
                return .html("<p>A page a search turned up.</p>")
            case .json where call.url.path == "/search":
                return .json(Self.searxng([(url: "https://other.example/review", title: "A review")]))
            case .json:
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("the paper"))
                case .assess: return .completion(json: Self.assessment)
                default: return .unrouted
                }
            case .stream:
                return .stream(["A review says so [1]."])
            }
        }

        let turn = await run("What about https://linked.example/paper ?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertTrue(turn.notices.contains(.linkNotRead), "\(turn.notices)")
        // A numbered entry with no text is a citation target the model cannot use, and a
        // line claiming the answer rests on a page nobody read.
        XCTAssertFalse(turn.sources.contains { $0.url == "https://linked.example/paper" })
        XCTAssertEqual(turn.sources.map(\.url), ["https://other.example/review"])
        // And the planner is not promised a key the payload does not carry. The prompt
        // says linked pages "have already been read for you"; over a turn where every
        // read failed that is a false premise, and a model asked to plan against pages
        // that are not there will explain their absence or invent them.
        let plan = try XCTUnwrap(transport.calls.first { Self.stage(of: $0) == .plan })
        let planPayload = try XCTUnwrap(plan.userContent)
        let planPrompt = try XCTUnwrap(plan.systemPrompt)
        XCTAssertFalse(planPayload.contains("linked_pages"), planPayload)
        XCTAssertFalse(planPrompt.contains("already been read"), "the prompt promised a "
                       + "key the payload does not carry")
    }

    // MARK: Deep research

    func testDeepResearchPlansAndRunsASecondRound() async throws {
        let transport = StubTransport { call in
            switch call.kind {
            case .fetch:
                return .html("<p>Text for \(call.url.path).</p>")
            case .json where call.url.path == "/search":
                let query = URLComponents(url: call.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "q" }?.value ?? ""
                return .json(Self.searxng([(url: "https://\(query.prefix(5)).example/hit",
                                            title: "Hit for \(query)")]))
            case .json:
                switch Self.stage(of: call) {
                case .plan:
                    return .completion(json: Self.plan("first", purpose: "the opening question"))
                case .deepPlan:
                    // Round two asks for the gap the first round could not have known
                    // about; round three finds nothing left and stops by returning none.
                    // Anchored on the template `stage(of:)` already keys off — "TASK:
                    // this is round <n>" — rather than on the "of" that happens to follow
                    // the number. A cosmetic rewording would otherwise hand round two the
                    // stop reply and fail two assertions away from the cause.
                    guard call.systemPrompt?.contains("this is round 2") == true else {
                        let nothingLeft: [String: Any] = ["reading": "Nothing is missing.",
                                                          "searches": [Any]()]
                        return .completion(json: nothingLeft)
                    }
                    return .completion(json: Self.plan("second", purpose: "the gap round one left"))
                case .assess:
                    return .completion(json: Self.assessment)
                default:
                    return .unrouted
                }
            case .stream:
                return .stream(["Both rounds agree [1]."])
            }
        }

        let turn = await run("What is still unsettled?", mode: .deep, transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        // Every round's searches are on the turn, not just the first plan's: the progress
        // label counts against this list.
        XCTAssertEqual(turn.searches.map(\.purpose),
                       ["the opening question", "the gap round one left"])
        XCTAssertEqual(turn.searchesCompleted, 2)

        let searches = transport.calls.filter { $0.url.path == "/search" }
        XCTAssertEqual(searches.count, 2)
        let plans = transport.calls.filter { Self.stage(of: $0) == .deepPlan }
        XCTAssertEqual(plans.count, 2, "round two plans, round three asks and is told to stop")
        // A later round can only plan against the gap if it is shown what the earlier
        // ones found. Without this the whole feature could stop forwarding the digest and
        // every assertion above would still pass.
        // Titles and snippets, which is what `digest` puts under "found" — deliberately
        // not the URLs, because this call chooses queries and cites nothing.
        let roundTwo = try XCTUnwrap(plans.first?.userContent)
        XCTAssertTrue(roundTwo.contains("Hit for first"), roundTwo)
    }

    // MARK: Revision

    /// Everything the revision stage needs, with the answer and the revision scripted
    /// separately so a test can say what each one returns.
    ///
    /// The verdict is passed as a string rather than a built assessment, so the route
    /// closure captures nothing that is not `Sendable` — the same reason every other
    /// fixture here is reached through `Self.` instead of captured.
    private func revisionTransport(verdict: String,
                                   claim: String = "Parallax is measured in arcseconds.",
                                   alongside: [(verdict: String, claim: String)] = [],
                                   answer: [String],
                                   revision: StubTransport.Reply?) -> StubTransport {
        StubTransport { call in
            switch call.kind {
            case .json where call.url.absoluteString.hasPrefix(Self.modelURL):
                switch Self.stage(of: call) {
                case .plan: return .completion(json: Self.plan("stellar parallax"))
                case .assess:
                    return .completion(json: Self.assessment(verdict: verdict, claim: claim,
                                                            alongside: alongside))
                default: return .unrouted
                }
            case .json where call.url.path == "/search":
                return .json(Self.searxng([(url: "https://a.example/one", title: "One")]))
            case .fetch:
                return .html("<p>The page text.</p>")
            case .stream:
                switch Self.stage(of: call) {
                case .answer: return .stream(answer)
                case .revise: return revision ?? .unrouted
                default: return .unrouted
                }
            default:
                return .unrouted
            }
        }
    }

    /// The whole point of the stage: a claim the evidence contradicts does not stay on
    /// screen. The draft is kept because the findings below it grade the draft — a table
    /// saying "contradicted" over prose that no longer makes the claim reads as broken.
    func testAContradictedClaimIsRewrittenAndTheDraftIsKept() async throws {
        let transport = revisionTransport(
            verdict: "contradicted",
            answer: ["Parallax is measured in degrees [1]."],
            revision: .stream(["Parallax is measured in arcseconds [1]."]))

        let turn = await run("How is stellar parallax measured?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.answer, "Parallax is measured in arcseconds [1].")
        XCTAssertEqual(turn.draftAnswer, "Parallax is measured in degrees [1].")
        XCTAssertTrue(turn.notices.contains(.answerRevised), "\(turn.notices)")
        XCTAssertFalse(turn.isRevising, "the label outlived the request")
        // The findings outlive the rewrite they caused, which is the whole reason the
        // draft is kept: they grade the draft, and a table with nothing in it under a
        // notice saying the answer was corrected explains nothing.
        XCTAssertEqual(turn.findings.count, 1,
                       "the grading table should outlive the rewrite it caused")

        // What the reviser was actually sent, because a stage that ran on the wrong
        // material would pass every assertion above.
        let revise = try XCTUnwrap(transport.calls.first { Self.stage(of: $0) == .revise })
        let sent = try XCTUnwrap(revise.userContent)
        XCTAssertTrue(sent.contains("Parallax is measured in degrees"), sent)
        // The finding's own claim, not the verdict word — the revise prompt explains
        // what "contradicted" means, so matching that alone would pass on the template
        // even if the findings payload had been dropped entirely.
        XCTAssertTrue(sent.contains("Parallax is measured in arcseconds."), sent)
        XCTAssertTrue(sent.contains("contradicted"), sent)
    }

    /// `mixed` is the other verdict that sends an answer back, and nothing else here
    /// pins that a valid rewrite under it is *accepted*: the citation test proves only
    /// that it triggers an attempt. A change that gated the stage on `contradicted`
    /// alone would pass every other test in this section.
    func testAMixedVerdictIsRevisedAndKeepsItsDraft() async throws {
        let transport = revisionTransport(
            verdict: "mixed",
            claim: "The answer gives the unit as degrees.",
            answer: ["Parallax is measured in degrees [1]."],
            revision: .stream(["Parallax is measured in arcseconds [1]."]))

        let turn = await run("How is stellar parallax measured?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.answer, "Parallax is measured in arcseconds [1].")
        XCTAssertEqual(turn.draftAnswer, "Parallax is measured in degrees [1].")
        XCTAssertTrue(turn.notices.contains(.answerRevised), "\(turn.notices)")
    }

    /// The mirror, and the reason the claim above is true in both directions. Without it
    /// a *new* verdict that warrants a revision would land in neither loop: this one
    /// filters it out, and the named tests above only ever say "contradicted" and
    /// "mixed". A gate that drifted from `warrantsRevision` for that verdict would fail
    /// nothing.
    func testEveryVerdictThatWarrantsRevisionSendsTheAnswerBack() async throws {
        let sentBack = Verdict.allCases
            .filter { ResearchRunner.warrantsRevision($0) }
            .map(\.rawValue)
        XCTAssertFalse(sentBack.isEmpty, "nothing warrants a revision any more")

        for verdict in sentBack {
            let transport = revisionTransport(
                verdict: verdict,
                answer: ["Parallax is measured in degrees [1]."],
                revision: .stream(["Parallax is measured in arcseconds [1]."]))

            let turn = await run("How is stellar parallax measured?", transport: transport)

            XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
            XCTAssertTrue(transport.calls.contains { Self.stage(of: $0) == .revise },
                          "\(verdict) never sent the answer back")
            XCTAssertEqual(turn.draftAnswer, "Parallax is measured in degrees [1].", verdict)
            // And that the rewrite was *taken*, not merely asked for. This loop is the
            // only cover a sixth verdict would have, and a runner that woke the stage,
            // kept the draft and then discarded every result would have passed it while
            // leaving the contradicted prose on screen.
            XCTAssertEqual(turn.answer, "Parallax is measured in arcseconds [1].", verdict)
            XCTAssertTrue(turn.notices.contains(.answerRevised),
                          "\(verdict) rewrote the answer without saying so")
        }
    }

    /// What the reviser is shown, as opposed to what wakes it.
    ///
    /// `isShownToReviser` had its return value pinned and its effect not. Every fixture
    /// in this section carried exactly one finding, so a runner that woke on
    /// `contradicted` and then poured the whole findings array into the prompt would
    /// have passed all of them — the predicate would have been dead code with a green
    /// suite beside it. An `insufficient` claim rides along; a `supported` one has
    /// nothing to correct and must not be offered as though it did.
    func testOnlyTheFindingsWorthShowingReachTheReviser() async throws {
        let transport = revisionTransport(
            verdict: "contradicted",
            alongside: [("insufficient", "The distance is under ten parsecs."),
                        ("supported", "Parallax is an angle.")],
            answer: ["Parallax is measured in degrees [1]."],
            revision: .stream(["Parallax is measured in arcseconds [1]."]))

        let turn = await run("How is stellar parallax measured?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        let revise = try XCTUnwrap(transport.calls.first { Self.stage(of: $0) == .revise })
        let sent = try XCTUnwrap(revise.userContent)
        XCTAssertTrue(sent.contains("The distance is under ten parsecs."),
                      "an unsettled claim rides along: \(sent)")
        XCTAssertFalse(sent.contains("Parallax is an angle."),
                       "a supported claim has nothing to correct: \(sent)")
    }

    /// The two switches, read directly. One decides whether a finding *wakes* the stage,
    /// the other whether it is *shown* to a rewrite already under way — and the whole
    /// reason they are switches rather than set membership is that a sixth verdict has to
    /// be decided about twice. This is what notices if one of them quietly grows a
    /// `default`.
    func testWhichVerdictsWakeTheReviserAndWhichAreMerelyShownToIt() {
        // As sets: which verdicts are in each answer is the contract, and the order
        // `allCases` happens to list them in is not. Compared as arrays, renaming or
        // reordering a case in `Verdict` — a change with no behaviour in it — turned this
        // red as though a switch had grown a `default`. A sixth verdict still breaks it,
        // which is the property worth keeping.
        XCTAssertEqual(Set(Verdict.allCases.filter(ResearchRunner.warrantsRevision)),
                       [.contradicted, .mixed])
        XCTAssertEqual(Set(Verdict.allCases.filter(ResearchRunner.isShownToReviser)),
                       [.contradicted, .mixed, .insufficient])
    }

    /// A reviser that fences the whole answer would otherwise replace good prose with a
    /// wall of monospace — and the citation check would pass it, because a bracketed
    /// number inside a fence is code rather than a citation.
    func testAWholeAnswerWrappedInAFenceIsUnwrapped() {
        let fenced = "```markdown\nParallax is measured in arcseconds [1].\n```"
        XCTAssertEqual(ResearchRunner.unwrappingWholeAnswerFence(fenced),
                       "Parallax is measured in arcseconds [1].")
        XCTAssertEqual(ResearchRunner.unwrappingWholeAnswerFence("```\nOne\nTwo\n```"),
                       "One\nTwo")
        XCTAssertEqual(ResearchRunner.unwrappingWholeAnswerFence("```md\nText [1].\n```"),
                       "Text [1].", "`md` is the other spelling of a prose wrapper")

        // A fence naming a *code* language — unlike the `markdown` wrapper the first
        // assertion unwraps — is a real code block, and an answer that is nothing but one
        // has to survive: the reviser is told to return what it was given where the
        // findings name nothing.
        let code = "```swift\nlet x = 1\n```"
        XCTAssertEqual(ResearchRunner.unwrappingWholeAnswerFence(code), code)
        // And a fence that closes in the middle is not a wrapper at all.
        let partial = "Text.\n```\nlet x = 1\n```\nMore text."
        XCTAssertEqual(ResearchRunner.unwrappingWholeAnswerFence(partial), partial)

        // A fence with nothing between its halves unwraps to nothing, which is what
        // hands it to the emptiness guard. Left alone it was non-empty, different from
        // the draft, and cited nothing for the validator to object to — so it cleared
        // every check and replaced a read answer with two rows of backticks.
        XCTAssertEqual(ResearchRunner.unwrappingWholeAnswerFence("```\n```"), "")

        // Four backticks, which is what a model reaches for when the prose it is
        // wrapping has its own three-tick block in it — the likeliest shape of all for a
        // correction, and the one a three-tick-only reading let straight through.
        XCTAssertEqual(
            ResearchRunner.unwrappingWholeAnswerFence(
                "````markdown\nText [1].\n\n```swift\nlet x = 1\n```\n````"),
            "Text [1].\n\n```swift\nlet x = 1\n```",
            "the inner block is content, not fence")
        // A closer shorter than its opener does not close anything — it sits inside the
        // fence, which is the whole reason for opening a longer one.
        XCTAssertEqual(ResearchRunner.unwrappingWholeAnswerFence("````\nText.\n```"),
                       "````\nText.\n```")

        // CRLF, which switched the whole function off — and not for the reason it
        // looked like. A Swift `Character` is a grapheme cluster and CR-LF is one of
        // them, so splitting on the character "\n" never matched a CRLF break at all:
        // the answer arrived as a single line and the two-line guard turned the function
        // into a no-op. Splitting by `isNewline` is what fixes it; no amount of trimming
        // would have.
        XCTAssertEqual(
            ResearchRunner.unwrappingWholeAnswerFence("```markdown\r\nText [1].\r\n```"),
            "Text [1].")
        // A lone trailing CR after the closing fence is still just a line terminator.
        XCTAssertEqual(
            ResearchRunner.unwrappingWholeAnswerFence("```\r\nText [1].\r\n```\r\n"),
            "Text [1].")
        let crlfCode = "```swift\r\nlet x = 1\r\n```"
        XCTAssertEqual(ResearchRunner.unwrappingWholeAnswerFence(crlfCode), crlfCode,
                       "a code fence survives, CRLF or not")
    }

    /// The unwrapper is pinned above; this pins that the revision path still calls it.
    /// A disconnected call site would either drop a wall of monospace on the reader or
    /// discard a good rewrite, and every other test in this section would stay green —
    /// the fenced replies they use are degenerate ones that fail the emptiness guard
    /// whether they were unwrapped or not.
    func testAFencedValidRevisionIsUnwrappedAndAccepted() async {
        let transport = revisionTransport(
            verdict: "contradicted",
            answer: ["Parallax is measured in degrees [1]."],
            revision: .stream(["```markdown\nParallax is measured in arcseconds [1].\n```"]))

        let turn = await run("How is stellar parallax measured?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.answer, "Parallax is measured in arcseconds [1].")
        XCTAssertEqual(turn.draftAnswer, "Parallax is measured in degrees [1].")
        XCTAssertTrue(turn.notices.contains(.answerRevised), "\(turn.notices)")
    }

    /// The one-line spelling of the same degenerate reply, which unwrapping cannot see —
    /// there is no closing line to pair the opening one with — so the guard that catches
    /// it is the one asking whether anything but backticks came back.
    func testAReplyOfNothingButFenceIsNotARevision() async throws {
        let transport = revisionTransport(
            verdict: "contradicted",
            answer: ["Parallax is measured in degrees [1]."],
            revision: .stream(["```"]))

        let turn = await run("How is stellar parallax measured?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.answer, "Parallax is measured in degrees [1].")
        XCTAssertNil(turn.draftAnswer)
        XCTAssertTrue(turn.notices.contains(.revisionUnavailable), "\(turn.notices)")
    }

    /// Dropping every citation is the quiet half of breaking the citation rule: the prose
    /// still reads as confident and now rests on nothing, and no check above this one has
    /// a bad number to catch.
    func testARevisionThatStripsEveryCitationIsDiscarded() async throws {
        let transport = revisionTransport(
            verdict: "mixed",
            answer: ["Parallax is measured in degrees [1]."],
            revision: .stream(["Parallax is measured in arcseconds, though sources vary."]))

        let turn = await run("How is stellar parallax measured?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.answer, "Parallax is measured in degrees [1].")
        XCTAssertNil(turn.draftAnswer)
        XCTAssertTrue(turn.notices.contains(.revisionUnavailable), "\(turn.notices)")
    }

    /// The common case, and the one that decides whether this stage costs a call on
    /// every turn. A `supported` finding is the check agreeing with the answer, and an
    /// `insufficient` one is usually the check agreeing with a hedge the answer prompt
    /// asked for — neither is the answer being wrong about its evidence.
    func testAnAnswerTheCheckDidNotFaultIsNeverSentBackForRevision() async throws {
        // Derived from the runner's own rule rather than listed here, so a sixth verdict
        // is covered the day it is added: whichever side of `warrantsRevision` it lands
        // on, this loop or its mirror above takes it, and it cannot fall between them.
        let accepted = Verdict.allCases
            .filter { !ResearchRunner.warrantsRevision($0) }
            .map(\.rawValue)
        // A derived loop can pass by running nothing. If every verdict came to warrant a
        // revision, the filter would empty and this test would go green while checking
        // the opposite of what it is named for.
        XCTAssertFalse(accepted.isEmpty, "no verdict is left that does not warrant a revision")
        for verdict in accepted {
            let transport = revisionTransport(
                verdict: verdict,
                answer: ["Parallax is measured in arcseconds [1]."],
                revision: nil)

            let turn = await run("How is stellar parallax measured?", transport: transport)

            XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
            XCTAssertNil(turn.draftAnswer, "\(verdict) sent the answer back for rewriting")
            XCTAssertTrue(transport.calls.allSatisfy { Self.stage(of: $0) != .revise },
                          "\(verdict) spent a model call")
            XCTAssertFalse(turn.notices.contains(.answerRevised),
                           "\(verdict) announced a revision")
        }
    }

    /// A correction that breaks the citation rule is worse than the answer it replaces,
    /// and it arrives *after* the validation the reader's trust in these numbers rests
    /// on. So it is checked before it is accepted, and dropped whole.
    func testARevisionThatBreaksTheCitationRuleIsDiscarded() async throws {
        for bad in ["Parallax is measured in arcseconds [7].",
                    "Parallax is measured in arcseconds, see https://a.example/one."] {
            let transport = revisionTransport(
                verdict: "mixed",
                answer: ["Parallax is measured in degrees [1]."],
                revision: .stream([bad]))

            let turn = await run("How is stellar parallax measured?", transport: transport)

            XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
            XCTAssertEqual(turn.answer, "Parallax is measured in degrees [1].",
                           "\(bad): a revision that broke the rule reached the screen")
            XCTAssertNil(turn.draftAnswer, "\(bad): the discarded revision replaced the draft")
            XCTAssertTrue(turn.notices.contains(.revisionUnavailable), "\(turn.notices)")
            XCTAssertFalse(turn.notices.contains(.answerRevised))
            // And the answer keeps the notices its own validation earned, rather than
            // the discarded revision's.
            XCTAssertFalse(turn.notices.contains(.invalidCitation), "\(turn.notices)")
            XCTAssertFalse(turn.notices.contains(.literalURL), "\(turn.notices)")
        }
    }

    /// The reviser reading the findings and judging that none of them warrants a change
    /// is a real answer, not a failure — and not a revision either. Nothing is said,
    /// because nothing happened.
    func testARevisionThatChangesNothingIsNotAnnouncedAsOne() async throws {
        let transport = revisionTransport(
            verdict: "mixed",
            answer: ["Parallax is measured in arcseconds [1]."],
            revision: .stream(["Parallax is measured in arcseconds [1].\n"]))

        let turn = await run("How is stellar parallax measured?", transport: transport)

        XCTAssertEqual(turn.stage, .complete, turn.failure ?? "no failure recorded")
        XCTAssertEqual(turn.answer, "Parallax is measured in arcseconds [1].")
        XCTAssertNil(turn.draftAnswer)
        XCTAssertFalse(turn.notices.contains(.answerRevised), "\(turn.notices)")
        XCTAssertFalse(turn.notices.contains(.revisionUnavailable), "\(turn.notices)")
    }

    /// The answer has been streamed, validated and read by the time this stage runs.
    /// Losing it to a rewrite that never arrived is the worst outcome available here, so
    /// a failed revision leaves the turn exactly as the assessment left it — and says so.
    func testAFailedRevisionKeepsTheAnswerAndSaysTheCorrectionDidNotLand() async throws {
        let transport = revisionTransport(
            verdict: "contradicted",
            answer: ["Parallax is measured in degrees [1]."],
            revision: .failure(ResearchError("the provider gave up")))

        let turn = await run("How is stellar parallax measured?", transport: transport)

        XCTAssertEqual(turn.stage, .complete,
                       "a failed revision must not fail the turn: "
                        + (turn.failure ?? "no failure recorded"))
        XCTAssertEqual(turn.answer, "Parallax is measured in degrees [1].")
        XCTAssertNil(turn.draftAnswer)
        XCTAssertTrue(turn.notices.contains(.revisionUnavailable), "\(turn.notices)")
        XCTAssertFalse(turn.isRevising)
        // The findings are still there: the check ran, and what it found is the reason
        // the reader is being told the correction is missing.
        XCTAssertEqual(turn.findings.count, 1)
    }
}
