import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// A scripted `HTTPTransporting`, so a whole research turn can be run without a network.
///
/// This is the thing `ResearchRunner` was missing. Every client already took its
/// transport as a parameter, but the parameter's type was the concrete `HTTPTransport`,
/// so the pipeline — the plan call, the searches, the page reads, the streamed answer
/// and the assessment, in that order and with what each one was actually sent — could
/// only be exercised against real endpoints. It therefore was not exercised at all.
///
/// Two decisions keep the double honest:
///
/// * It answers **requests**, not method calls. A test says what a URL returns, and the
///   real client code builds the `URLRequest`, chooses the headers, validates the search
///   arguments against the schema and parses the reply. A double that intercepted
///   `SearchBackend` or `ChatCompletionsClient` instead would skip exactly the code
///   most likely to be wrong.
/// * It **records** every request in order, with its decoded body. Ordering is a real
///   property of this pipeline — a question's links must be read *before* the planner
///   is asked, or the plan cannot be informed by them — and the recording is how a test
///   can say so.
///
/// An unrouted request fails loudly rather than returning an empty object: a stage
/// answering `{}` looks, from inside the runner, exactly like a provider that returned
/// nothing useful, and the resulting test failure would name the wrong thing.
final class StubTransport: HTTPTransporting, @unchecked Sendable {

    /// One request the runner made.
    ///
    /// `@unchecked Sendable` because it crosses the `@Sendable` routing closure while
    /// carrying an `Any`-typed dictionary the compiler cannot prove sendable. The claim
    /// is honest rather than a silencer: every property is a `let`, the value is built
    /// under the lock and never mutated afterwards, and the dictionary holds only what
    /// `JSONSerialization` produces. The package pins Swift 5 language mode on both
    /// platforms deliberately (see `Package.swift`), so this is a trap disarmed early
    /// rather than an error today.
    struct Call: @unchecked Sendable {
        enum Kind: String { case json, stream, fetch }

        let kind: Kind
        let url: URL
        let method: String
        /// The request's own idle timeout, so a caller that must pass a shorter one than
        /// the transport's generation-sized default can be held to it.
        let timeout: TimeInterval
        /// The wall clock on reading the body, for a `sendJSON`. A caller that means "not
        /// longer than this" has to set both — they are different clocks — so a test that
        /// checked only `timeout` would pin half the promise. Nil for a stream or a fetch,
        /// neither of which takes one.
        let deadline: TimeInterval?
        /// The decoded JSON body, for a POST that carried one.
        let body: [String: Any]?

        /// The system prompt of a chat-completions call, which is what identifies the
        /// stage: `ResearchPrompts.plan`, `.answer` and `.assess` are the three.
        var systemPrompt: String? { message(role: "system") }
        /// The user turn of a chat-completions call — the JSON context the stage was
        /// given, as text.
        var userContent: String? { message(role: "user") }

        private func message(role: String) -> String? {
            guard let messages = body?["messages"] as? [[String: Any]] else { return nil }
            return messages.first { $0["role"] as? String == role }?["content"] as? String
        }
    }

    /// What a request is answered with. `@unchecked Sendable` for the reason `Call` is.
    enum Reply: @unchecked Sendable {
        /// A decoded JSON object, as `sendJSON` returns it.
        case json([String: Any])
        /// SSE frames, in order, as `streamJSONEvents` yields them.
        case events([[String: Any]])
        /// A page, as `fetch` returns it: a status, headers, and a body.
        case page(status: Int, headers: [String: String], text: String)
        /// A failure raised the way the real transport raises one.
        case failure(ResearchError)
        /// Nothing in the script recognises this request. Reported as a failure naming
        /// the request, rather than as an empty reply that would look — from inside the
        /// runner — like a provider that simply had nothing to say.
        case unrouted
    }

    private let route: @Sendable (Call) -> Reply
    private let lock = NSLock()
    private var recorded: [Call] = []

    /// - Parameter route: answers a request, or `.unrouted` if the script has no answer.
    init(_ route: @escaping @Sendable (Call) -> Reply) {
        self.route = route
    }

    /// Every request made, in order.
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The requests, as `kind url` lines — enough to assert the shape of a whole turn.
    var trail: [String] {
        calls.map { "\($0.kind.rawValue) \($0.url.absoluteString)" }
    }

    // MARK: HTTPTransporting

    func sendJSON(_ request: URLRequest,
                  expectedID: Int?,
                  isNotification: Bool,
                  deadline: TimeInterval) async throws -> (headers: [String: String], body: [String: Any]) {
        switch try answer(to: request, kind: .json, deadline: deadline) {
        case .json(let object):
            return ([:], object)
        case .events(let frames):
            // The MCP transport genuinely may answer a JSON-RPC call with a single SSE
            // frame, and `HTTPTransport.sendJSON` returns that frame as the body.
            //
            // An empty script is a routing mistake, not an empty answer: a `[:]` body
            // here reaches the runner as a provider that said nothing useful, and the
            // test then fails several stages later naming the wrong thing.
            guard let frame = frames.first else {
                throw ResearchError("StubTransport: sendJSON was answered with an empty "
                                    + "stream script.")
            }
            return ([:], frame)
        case .page, .failure, .unrouted:
            throw ResearchError("StubTransport: sendJSON was answered with a non-JSON reply.")
        }
    }

    func fetch(_ request: URLRequest, limit: Int) async throws -> (HTTPURLResponse, Data) {
        guard case .page(let status, let headers, let text) = try answer(to: request, kind: .fetch) else {
            throw ResearchError("StubTransport: fetch was answered with a non-page reply.")
        }
        let url = request.url ?? URL(string: "https://example.invalid/")!
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw ResearchError("StubTransport: could not build a response.")
        }
        return (response, Data(text.utf8))
    }

    func streamJSONEvents(_ request: URLRequest) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream<[String: Any], Error> { continuation in
            do {
                guard case .events(let frames) = try answer(to: request, kind: .stream) else {
                    throw ResearchError("StubTransport: a stream was answered with a non-stream reply.")
                }
                for frame in frames { continuation.yield(frame) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: Routing

    private func answer(to request: URLRequest, kind: Call.Kind,
                        deadline: TimeInterval? = nil) throws -> Reply {
        let url = request.url ?? URL(string: "https://example.invalid/")!
        var body: [String: Any]?
        if let data = request.httpBody {
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let call = Call(kind: kind, url: url, method: request.httpMethod ?? "GET",
                        timeout: request.timeoutInterval, deadline: deadline, body: body)
        lock.lock()
        recorded.append(call)
        lock.unlock()

        let reply = route(call)
        if case .unrouted = reply {
            throw ResearchError("StubTransport: nothing routes \(kind.rawValue) \(url.absoluteString).")
        }
        if case .failure(let error) = reply { throw error }
        return reply
    }
}

// MARK: Building replies

extension StubTransport.Reply {

    /// A chat-completions reply carrying `text` as the assistant's whole message, which
    /// is what `ChatCompletionsClient.completeJSON` reads.
    ///
    /// Carries `finish_reason` for the same reason the streamed form does:
    /// `messageContent(from:)` checks it before it looks at the content, and a reply
    /// without one is an interrupted reply. A fixture that omitted it would fail every
    /// stage with "the model's reply ended without a valid completion" — which is the
    /// rule working, not the rule being in the way.
    static func completion(_ text: String) -> StubTransport.Reply {
        let choice: [String: Any] = ["message": ["role": "assistant", "content": text],
                                     "finish_reason": "stop"]
        return .json(["choices": [choice]])
    }

    /// The same, for a call whose reply is parsed as JSON.
    ///
    /// A fixture `JSONSerialization` cannot encode — a `Date`, a `UUID`, anything that is
    /// not a JSON value — stops the run naming itself. Falling back to "{}" would hand
    /// the runner a model that answered with an empty object, and the test would then
    /// fail a stage later complaining about the model rather than about the fixture.
    static func completion(json object: [String: Any]) -> StubTransport.Reply {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("StubTransport: this fixture is not encodable as JSON: \(object)")
        }
        return .completion(text)
    }

    /// A streamed answer, one delta per chunk, as an OpenAI-shaped SSE stream.
    ///
    /// Closed with a `finish_reason` frame, because a stream that just stops is not a
    /// finished answer: `ChatCompletionsClient.checkFinishReason` treats a missing reason
    /// as an interrupted stream, which is the rule that stops a truncated reply being
    /// recorded as a whole one.
    static func stream(_ chunks: [String]) -> StubTransport.Reply {
        var frames: [[String: Any]] = chunks.map { ["choices": [["delta": ["content": $0]]]] }
        let stop: [String: Any] = ["delta": [String: Any](), "finish_reason": "stop"]
        frames.append(["choices": [stop]])
        return .events(frames)
    }

    /// A readable HTML page.
    ///
    /// Padded past `HTMLTextExtractor.minimumUsefulCharacters`. Below that the reader
    /// treats whatever came back as navigation or a consent wall and drops it — so a
    /// one-sentence fixture would quietly exercise the *unreadable* page path while
    /// looking like it tested a successful read.
    static func html(_ body: String) -> StubTransport.Reply {
        let filler = "<p>This paragraph is here only so the extracted text clears the "
            + "reader's minimum useful length, which one short sentence does not.</p>"
        // Padded against the constant rather than by a filler sentence sized to today's
        // value of it. A fixed pad clears the bar by luck: raise
        // `minimumUsefulCharacters`, or pass a shorter `body`, and the fixture silently
        // becomes an *unreadable* page while the test that depends on a successful read
        // goes on passing. Twice the minimum absorbs the tags, which count here and do
        // not survive extraction.
        var padded = body
        while padded.count < HTMLTextExtractor.minimumUsefulCharacters * 2 {
            padded += filler
        }
        return .page(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"],
                     text: "<html><body>\(padded)</body></html>")
    }
}
