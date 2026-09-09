import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The seam every outbound provider call passes through.
///
/// `HTTPTransport` is the only implementation that ships, and this protocol exists for
/// one reason: without it there is no way to run `ResearchRunner` — the type that holds
/// the pipeline the whole product is — through its stages in a test. Every client
/// already takes its transport as an injected parameter, so the runner could be handed a
/// stub the moment there was a type to hand it; there was not, and so `/deep-research`'s
/// round loop and the reading of a question's links both shipped covered only by unit
/// tests of the pure pieces around them.
///
/// The surface is deliberately the *whole* of what a client may do to the network, and
/// no more. Three requirements, because a client only ever needs three shapes:
///
/// * `sendJSON` — a request out, one JSON object back. Also the SSE case where a single
///   frame is the answer, which is how an MCP endpoint may reply.
/// * `fetch` — a request out, the response head and complete body back, **with the
///   status code unjudged**. Only the page reader uses it, and only for requests that
///   carry no credentials; see `HTTPTransport.fetch`.
/// * `streamJSONEvents` — a request out, its `data:` frames back in order. The streamed
///   answer.
///
/// Building the request stays on `HTTPTransport` as static work (`request(url:…)`,
/// `getRequest(url:…)`), because a `URLRequest` is a value and there is nothing to fake
/// about constructing one — a stub that built requests differently from the real
/// transport would be testing itself. What a test *may* fake is the answer.
///
/// `Sendable` because clients hold their transport across the `Task` boundaries a
/// streamed answer needs.
protocol HTTPTransporting: Sendable {

    /// Sends `request` and returns its response headers plus a decoded JSON object.
    ///
    /// The parameters carry no defaults, because a protocol requirement cannot have any.
    /// The extension below supplies the shorter form every caller actually writes.
    func sendJSON(_ request: URLRequest,
                  expectedID: Int?,
                  isNotification: Bool,
                  deadline: TimeInterval) async throws -> (headers: [String: String], body: [String: Any])

    /// Sends `request` and returns its response head and complete body, without judging
    /// the status code. Only for requests that carry no credentials.
    func fetch(_ request: URLRequest, limit: Int) async throws -> (HTTPURLResponse, Data)

    /// Sends `request` and yields each `data:` frame's decoded JSON object in order.
    func streamJSONEvents(_ request: URLRequest) -> AsyncThrowingStream<[String: Any], Error>
}

extension HTTPTransporting {

    /// The form every caller writes: a request, and at most one thing about it.
    ///
    /// A separate arity rather than defaulted arguments on the requirement itself, which
    /// Swift does not allow — and it must stay a *different* arity, because an extension
    /// method matching the requirement's signature would become its default
    /// implementation and call itself forever.
    func sendJSON(_ request: URLRequest,
                  expectedID: Int? = nil,
                  isNotification: Bool = false) async throws
        -> (headers: [String: String], body: [String: Any]) {
        try await sendJSON(request, expectedID: expectedID, isNotification: isNotification,
                           deadline: HTTPTransport.deadline)
    }

    /// A cheap GET, with its two bounds set from one number.
    ///
    /// `getRequest`'s `timeout` and `sendJSON`'s `deadline` are different clocks — one
    /// idle, one wall — and a caller that means "no longer than this" has to say both.
    /// Saying it once is the difference between a rule and a habit: a later cheap GET
    /// that set the timeout and forgot the deadline would keep the ten-minute wall clock
    /// while reading as though it had thirty seconds.
    ///
    /// On the protocol rather than on `HTTPTransport`, because it is pure composition
    /// over `sendJSON` and a request builder. A stub that re-implemented it could
    /// disagree with the real transport about which clocks a budget sets, which is
    /// exactly the kind of difference a test must not be able to introduce.
    func sendCheapJSON(url: URL,
                       headers: [String: String] = [:],
                       within budget: TimeInterval) async throws
        -> (headers: [String: String], body: [String: Any]) {
        try await sendJSON(HTTPTransport.getRequest(url: url, headers: headers, timeout: budget),
                           expectedID: nil, isNotification: false, deadline: budget)
    }
}
