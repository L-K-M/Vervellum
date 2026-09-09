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
        case plan, deepPlan, answer, assess
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
}
