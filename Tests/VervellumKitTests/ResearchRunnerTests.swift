import XCTest
@testable import VervellumKit

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

    private func settings(pageReading: PageReadingMode = .direct) -> ProviderSettings {
        ProviderSettings(modelEndpoint: Self.modelEndpoint,
                         modelName: "test-model",
                         searchEndpoint: Self.searchEndpoint,
                         searchKind: .searxng,
                         pageReading: pageReading)
    }

    private func environment(pageReading: PageReadingMode = .direct) -> ResearchRunner.Environment {
        ResearchRunner.Environment(settings: settings(pageReading: pageReading),
                                   modelKey: "model-key", searchKey: nil)
    }

    private func run(_ question: String,
                     mode: ResearchRunner.Mode = .research,
                     pageReading: PageReadingMode = .direct,
                     transport: StubTransport) async -> ResearchTurn {
        let runner = ResearchRunner(environment: environment(pageReading: pageReading),
                                    trace: ResearchTrace(sink: SilentLog()),
                                    transport: transport)
        return await runner.run(ResearchTurn(question: question), mode: mode,
                                history: [], onUpdate: { _ in })
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
        if prompt.contains("TASK: plan the web searches") { return .plan }
        if prompt.contains("TASK: this is round") { return .deepPlan }
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
                    guard call.systemPrompt?.contains("round 2 of") == true else {
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
    }
}
