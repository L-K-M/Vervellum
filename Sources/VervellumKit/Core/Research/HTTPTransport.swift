import Foundation
#if canImport(FoundationNetworking)
// Linux splits URLSession out of Foundation into its own module. Guarded on
// `canImport` rather than `os(Linux)` because the split applies to every non-Darwin
// platform, and the module is not re-exported by Foundation.
import FoundationNetworking
#endif

/// The single outbound HTTP path for every provider call, on every platform.
///
/// Everything Vervellum sends carries an API key, so the transport is built around
/// three defensive rules rather than convenience:
///
/// 1. **Redirects are never followed.** `URLSession` re-sends headers — including
///    `Authorization` — to a redirect target by default. A provider (or anything that
///    can answer for its hostname) could therefore harvest the key with a single
///    `302`. The delegate refuses every redirect. Refusing does *not* fail the task:
///    it completes successfully carrying the 3xx response, so the status code is
///    checked explicitly as well.
/// 2. **Responses are capped.** A hostile or malfunctioning endpoint must not be able
///    to stream gigabytes into the app.
/// 3. **Provider errors never escape verbatim.** Every underlying error is caught and
///    replaced with a `ResearchError` Vervellum wrote, because provider messages have
///    been observed echoing request URLs and credentials.
///
/// ## Why the delegate API rather than `bytes(for:)`
///
/// The obvious way to stream a response is `URLSession.bytes(for:)`, and on macOS it
/// works. It does not exist on Linux at all: `URLSession.AsyncBytes` is absent from
/// swift-corelibs-foundation, so the convenient version would be a compile error
/// there, not a slow path.
///
/// Rather than keep two implementations — one of which would only ever be exercised on
/// the platform with less test coverage — both use `URLSessionDataDelegate`, which is
/// the older and more widely supported API. The streaming body is republished as an
/// `AsyncThrowingStream` of chunks so callers still read it with `for try await`.
///
/// The task must be created with `dataTask(with:)` and **no completion handler**: any
/// completion-handler form switches the session's drain mode to in-memory and buffers
/// the whole body before returning a single blob, which for a streamed answer means
/// the user watches a spinner until the last token.
final class HTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// Hard ceiling on a single buffered response body.
    static let maxResponseBytes = 2_000_000
    /// Hard ceiling on a streamed response, which is allowed to be larger because a
    /// long answer arrives token by token.
    static let maxStreamBytes = 8_000_000

    static let shared = HTTPTransport()

    /// The longest a single request may take, end to end.
    ///
    /// Separate from the session's timeout because that one is an *idle* timeout on
    /// Linux — FoundationNetworking rebuilds its timer on every chunk received — so a
    /// server sending a keep-alive comment every few seconds could hold a request open
    /// forever without ever tripping it.
    static let deadline: TimeInterval = 600

    /// How long a request may go without a byte arriving before it is abandoned.
    ///
    /// An *idle* timeout on both platforms — Darwin documents it as the wait for
    /// additional data, and FoundationNetworking rebuilds its timer on every chunk —
    /// which is what a streamed answer wants: a token a second keeps it alive, and a
    /// stall ends it. A non-streaming call is the opposite case. A plan or an
    /// assessment sends nothing until the model has finished generating, so "idle"
    /// there is the whole generation, and a local model working through a large
    /// evidence block takes minutes. Those requests get `deadline` instead; see
    /// `request(url:payload:headers:acceptsEventStream:)`.
    static let idleTimeout: TimeInterval = 120

    // MARK: Session

    /// Built once in `init`, not lazily. `lazy` is not atomic, so two threads reaching
    /// it together could each build a session — and `taskIdentifier`, which keys the
    /// exchange registry, is only unique *within* a session.
    private var session: URLSession!

    override init() {
        super.init()
        session = Self.makeSession(delegate: self)
    }

    private static func makeSession(delegate: URLSessionDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // The idle timeout, overridden per request for non-streaming calls.
        // `timeoutIntervalForResource` is deliberately not set — it is stored but never
        // read by FoundationNetworking, so relying on it would be a timeout that
        // silently does nothing.
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // Nothing here should be served from a cache: a stale plan or stale search
        // results would be indistinguishable from fresh ones.
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil

        // A *serial* delegate queue. Callbacks mutate the per-task registry, and a
        // concurrent queue would let a completion overtake the chunk before it.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "\(AppIdentity.bundleIdentifier).transport"
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    /// Everything in flight, keyed by task identifier.
    ///
    /// A session-level delegate is used rather than a per-task one because
    /// `URLSessionTask.delegate` is not dependable across platforms, so routing by
    /// identifier is the portable answer.
    private var exchanges: [Int: Exchange] = [:]
    private let lock = NSLock()

    /// One in-flight request's state.
    private final class Exchange {
        var head: CheckedContinuation<HTTPURLResponse, Error>?
        var body: AsyncThrowingStream<Data, Error>.Continuation?
        var response: HTTPURLResponse?
        /// Held so the request can be stopped when the caller abandons the body, and so
        /// the producer can be cut off if it outruns the cap.
        weak var task: URLSessionTask?
        var bytesYielded = 0
        var limit = HTTPTransport.maxStreamBytes
        /// Set by the cancellation handler. Read under the lock by `open`, which may
        /// not have registered its continuation yet when cancellation arrives.
        var cancelled = false
    }

    // MARK: Requests

    /// Builds a POST carrying `payload` as JSON plus `headers`.
    ///
    /// `acceptsEventStream` is not a convenience. A gateway is entitled to
    /// content-negotiate on `Accept`, so advertising `text/event-stream` on a call that
    /// sent `"stream": false` invites a stream back — and the buffered reader would then
    /// hand the caller the first partial delta as though it were the whole reply,
    /// failing later with a message blaming the user's endpoint. Only the MCP calls
    /// (which genuinely may answer either way) and the streamed answer ask for it.
    static func request(url: URL,
                        payload: [String: Any],
                        headers: [String: String],
                        acceptsEventStream: Bool) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A call that does not stream is silent until the model has finished, so the
        // idle timeout would cut it off after two minutes of ordinary generation and
        // blame the connection. It gets the end-to-end budget instead; the streamed
        // and MCP calls keep the idle timeout, where a stall really is a failure.
        // FoundationNetworking honours a per-request interval too, once it is set.
        request.timeoutInterval = acceptsEventStream ? idleTimeout : deadline
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(acceptsEventStream ? "application/json, text/event-stream" : "application/json",
                         forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { throw ResearchError("Vervellum could not encode the request.") }
        request.httpBody = body
        return request
    }

    /// The wall-clock message, spelled in whatever unit the budget is actually in.
    ///
    /// Both readers used to divide by 60 and hard-code "minutes", which was right while
    /// every budget was the ten-minute `deadline` and reads as "did not finish within 0
    /// minutes" for anything shorter than one.
    static func tookTooLong(_ budget: TimeInterval) -> ResearchError {
        // Floored, and the unit chosen from the floored value. Three ways to get this
        // subtly wrong, all of which it has been: the message hard-coded "minutes"
        // because the only budget was ten of them, so generalising the number alone
        // turned "0 minutes" into "1 minutes"; choosing the unit from the raw budget
        // reported 59.6 seconds as "60 seconds" while 60 said "1 minute"; and rounding
        // to nearest then claimed a 59.6-second budget "did not finish within 1 minute",
        // which is a sentence about a wait that never happened. This message is the
        // reader's record of what the app did, so it may understate and never overstate.
        //
        // The floor at 1 is prose, not arithmetic: no caller passes a budget under a
        // second, and "did not finish within 0 seconds" is the nonsense the first bug
        // above produced.
        let seconds = Swift.max(1, Int(budget.rounded(.down)))
        let spelled: String
        if seconds < 60 {
            spelled = seconds == 1 ? "1 second" : "\(seconds) seconds"
        } else {
            let minutes = seconds / 60
            spelled = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return ResearchError("The provider's response did not finish within \(spelled).")
    }

    /// Builds a GET expecting JSON back.
    ///
    /// Separate from the POST builder rather than a parameter on it: a GET has no body
    /// to encode and cannot be an SSE call, and every caller of the POST builder passes
    /// a payload. `timeout` defaults to the ten-minute `deadline`, which is sized for a
    /// local model working through an evidence block; a GET that fetches a small JSON
    /// document has nothing to think about and a caller that knows its request is cheap
    /// passes its own.
    ///
    /// It buys less than it looks like, and this used to claim otherwise. Whatever goes
    /// into `URLRequest.timeoutInterval` is an *idle* timeout — URLSession restarts it
    /// on every byte — so it bounds the silences, not the exchange. A caller that means
    /// "not longer than this" passes the same number to `sendJSON`'s `deadline`, which
    /// is the wall clock.
    static func getRequest(url: URL,
                           headers: [String: String] = [:],
                           timeout: TimeInterval = deadline) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Sends `request` and returns its response headers plus a decoded JSON object.
    ///
    /// Handles both transports an MCP endpoint may pick: a plain JSON body, or an SSE
    /// stream whose frames are scanned for the one bearing `expectedID`. A notification
    /// (a JSON-RPC message with no `id`) legitimately gets an empty `202`/`204`, which
    /// is reported as an empty object rather than an error.
    ///
    /// `deadline` is the wall clock on reading the body, and it is separate from the
    /// request's own `timeoutInterval` because that one is an *idle* timeout: it is
    /// rebuilt every time a byte arrives, so a server trickling one byte every 29
    /// seconds satisfies a 30-second `timeoutInterval` forever. A caller that means "do
    /// not make someone wait longer than this" has to say both, and only this one is a
    /// bound on the whole exchange.
    func sendJSON(_ request: URLRequest,
                  expectedID: Int? = nil,
                  isNotification: Bool = false,
                  deadline: TimeInterval = HTTPTransport.deadline) async throws -> (headers: [String: String], body: [String: Any]) {
        let (http, body) = try await open(request, limit: Self.maxResponseBytes)
        let headers = Self.headerDictionary(http)

        if isNotification && (http.statusCode == 202 || http.statusCode == 204) {
            return (headers, [:])
        }
        try Self.checkStatus(http)

        if Self.isEventStream(http) {
            // A notification carries no `id`, so nothing in this stream can be its
            // answer — but the request advertised `text/event-stream`, so a gateway is
            // entitled to open one anyway. Reading it would either block until the
            // request timer expires (a server may hold the stream open for later
            // server-to-client messages) or, since `matches` accepts anything when there
            // is no `expectedID`, mistake an unrelated progress frame for the
            // acknowledgement. Abandon the stream and report the empty ack.
            if isNotification { return (headers, [:]) }
            guard let event = try await firstMatchingEvent(in: body, expectedID: expectedID,
                                                          deadline: deadline) else {
                throw ResearchError("The search stream ended before returning a result.")
            }
            return (headers, event)
        }

        let data = try await collect(body, limit: Self.maxResponseBytes, deadline: deadline)
        if isNotification && data.isEmpty { return (headers, [:]) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResearchError.invalidResponse
        }
        return (headers, object)
    }

    /// A cheap GET, with its two bounds set from one number.
    ///
    /// `getRequest`'s `timeout` and `sendJSON`'s `deadline` are different clocks — one
    /// idle, one wall — and a caller that means "no longer than this" has to say both.
    /// Saying it once is the difference between a rule and a habit: a later cheap GET
    /// that set the timeout and forgot the deadline would keep the ten-minute wall clock
    /// while reading as though it had thirty seconds.
    func sendCheapJSON(url: URL,
                       headers: [String: String] = [:],
                       within budget: TimeInterval) async throws
        -> (headers: [String: String], body: [String: Any]) {
        try await sendJSON(Self.getRequest(url: url, headers: headers, timeout: budget),
                           deadline: budget)
    }

    /// Sends `request` and returns its response head and complete body, **without**
    /// judging the status code.
    ///
    /// Every other entry point turns a non-2xx into a `ResearchError`, which is right
    /// for a provider call. The page reader needs the 3xx itself: `HTTPTransport` still
    /// refuses every automatic redirect, because `URLSession` would re-send headers to
    /// the new host, and the reader instead starts a *fresh* credential-free request at
    /// the `Location`. That keeps the rule's actual reason — a credential must never
    /// reach a host the user did not configure — while letting `http → https` resolve.
    ///
    /// Only for requests that carry no credentials. Nothing else may use it.
    func fetch(_ request: URLRequest, limit: Int) async throws -> (HTTPURLResponse, Data) {
        let (http, body) = try await open(request, limit: limit)
        let data = try await collect(body, limit: limit)
        return (http, data)
    }

    /// Sends `request` and yields each `data:` frame's decoded JSON object in order,
    /// stopping at the `[DONE]` sentinel. Used for the streaming answer.
    func streamJSONEvents(_ request: URLRequest) -> AsyncThrowingStream<[String: Any], Error> {
        // Generic arguments spelled out: `AsyncThrowingStream` has no default for
        // `Failure`, and its trailing-closure initializer is constrained to
        // `Failure == Error`. Buffering stays unbounded — dropping a delta would
        // silently corrupt the answer, which is worse than holding it in memory.
        AsyncThrowingStream<[String: Any], Error> { continuation in
            let task = Task {
                do {
                    let (http, body) = try await self.open(request, limit: Self.maxStreamBytes)
                    try Self.checkStatus(http)
                    guard Self.isEventStream(http) else {
                        // Some gateways ignore `"stream": true` and answer with one JSON
                        // body. Forward it as a single event so the caller's accumulation
                        // logic works unchanged.
                        let data = try await self.collect(body, limit: Self.maxResponseBytes)
                        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            continuation.yield(object)
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: ResearchError.invalidResponse)
                        }
                        return
                    }

                    var assembler = SSEFrameAssembler()
                    var finished = false
                    try await Self.readLines(from: body, limit: Self.maxStreamBytes) { line in
                        try Task.checkCancellation()
                        let step = try assembler.consume(line)
                        if let object = step.frame { continuation.yield(object) }
                        if step.done {
                            finished = true
                            return false
                        }
                        return true
                    }
                    // A stream that ends without a trailing blank line still has a frame.
                    if !finished, let object = try assembler.flush() { continuation.yield(object) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ResearchError.cancelled)
                } catch let error as ResearchError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: Self.sanitized(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Opening a request

    /// Starts `request` and waits for its response head, returning the head plus a
    /// stream of body chunks.
    ///
    /// Cancelling the calling task cancels the URL task, which is what stops a
    /// half-streamed answer from continuing to bill the provider after the user has
    /// pressed Stop.
    private func open(_ request: URLRequest,
                      limit: Int) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let exchange = Exchange()
        let task = session.dataTask(with: request)
        exchange.task = task
        exchange.limit = limit

        // The build closure runs synchronously, so the continuation is in place before
        // the task is resumed and no chunk can arrive with nowhere to go.
        let identifier = task.taskIdentifier
        let bodyStream = AsyncThrowingStream<Data, Error> { continuation in
            exchange.body = continuation
            // Abandoning the stream — which `sendJSON` does deliberately for a
            // notification answered with an event stream — must stop the request.
            // Without this the transfer runs to completion in the background, billing
            // the provider and leaving the exchange in the registry forever.
            //
            // `self` is captured strongly on purpose. A `[weak self]` here is a captured
            // *var*, and reading one from this `@Sendable` closure is diagnosed; the
            // transport is a process-lifetime singleton, and the reference is released
            // the moment the stream terminates.
            continuation.onTermination = { _ in
                task.cancel()
                self.forget(identifier)
            }
        }

        register(exchange, for: identifier)

        do {
            let http = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                    // Register the continuation *before* resuming. The delegate queue is
                    // a different thread, so a response that arrives the instant the task
                    // starts must already have somewhere to go.
                    self.lock.lock()
                    // The cancellation handler runs *immediately* when the calling task
                    // is already cancelled — that is, before this closure. `failHead`
                    // then finds no continuation to fail, the URL task is never resumed,
                    // no completion callback is coming, and a continuation registered
                    // here would wait forever. Refuse to start instead.
                    guard !exchange.cancelled else {
                        self.lock.unlock()
                        continuation.resume(throwing: ResearchError.cancelled)
                        return
                    }
                    exchange.head = continuation
                    self.lock.unlock()
                    task.resume()
                }
            } onCancel: {
                self.lock.lock()
                exchange.cancelled = true
                self.lock.unlock()
                task.cancel()
                // Belt and braces. Cancelling a task that has not been resumed does not
                // reliably produce a `didCompleteWithError` on every platform, and a
                // head continuation nobody resumes is a hang with no diagnostic.
                self.failHead(identifier, with: ResearchError.cancelled)
            }
            return (http, bodyStream)
        } catch {
            forget(identifier)
            exchange.body?.finish()
            throw Self.sanitized(error)
        }
    }

    /// Adds an exchange to the registry.
    ///
    /// A synchronous helper rather than three lines inline in `open`: `NSLock.lock()` is
    /// flagged when called directly from an `async` function — a suspension while holding
    /// it would deadlock the cooperative pool — and the compiler cannot see that nothing
    /// suspends between the lock and the unlock. Inside a synchronous function it can.
    private func register(_ exchange: Exchange, for identifier: Int) {
        lock.lock()
        exchanges[identifier] = exchange
        lock.unlock()
    }

    /// Resumes a still-waiting head continuation with an error, once.
    private func failHead(_ identifier: Int, with error: Error) {
        lock.lock()
        let head = exchanges[identifier]?.head
        exchanges[identifier]?.head = nil
        lock.unlock()
        head?.resume(throwing: error)
    }

    private func forget(_ identifier: Int) {
        lock.lock()
        exchanges[identifier] = nil
        lock.unlock()
    }

    // MARK: Reading

    /// Accumulates a whole body, refusing to grow past `limit`.
    private func collect(_ body: AsyncThrowingStream<Data, Error>,
                         limit: Int,
                         deadline: TimeInterval = HTTPTransport.deadline) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        let started = Date()
        do {
            for try await chunk in body {
                // The session's timeout is an idle timeout on Linux, so a server
                // trickling one byte at a time would never trip it. This one is wall
                // clock.
                guard Date().timeIntervalSince(started) <= deadline else {
                    throw Self.tookTooLong(deadline)
                }
                data.append(chunk)
                if data.count > limit { throw ResearchError.responseTooLarge }
            }
        } catch let error as ResearchError {
            throw error
        } catch is CancellationError {
            throw ResearchError.cancelled
        } catch {
            throw Self.sanitized(error)
        }
        return data
    }

    /// Scans an SSE stream for the frame whose `id` matches the JSON-RPC request. Any
    /// other frame belongs to a different in-flight call and is skipped.
    private func firstMatchingEvent(in body: AsyncThrowingStream<Data, Error>,
                                    expectedID: Int?,
                                    deadline: TimeInterval = HTTPTransport.deadline) async throws -> [String: Any]? {
        var assembler = SSEFrameAssembler()
        var found: [String: Any]?
        do {
            try await Self.readLines(from: body, limit: Self.maxResponseBytes,
                                     deadline: deadline) { line in
                let step = try assembler.consume(line)
                if let object = step.frame, Self.matches(object, expectedID: expectedID) {
                    found = object
                    return false
                }
                return !step.done
            }
        } catch let error as ResearchError {
            throw error
        } catch is CancellationError {
            throw ResearchError.cancelled
        } catch {
            throw Self.sanitized(error)
        }
        if let found { return found }
        if let object = try assembler.flush(), Self.matches(object, expectedID: expectedID) {
            return object
        }
        return nil
    }

    /// Splits a stream of chunks into lines, **including empty ones**, invoking `handle`
    /// for each and stopping when it returns false.
    ///
    /// Empty lines are the whole point: in Server-Sent Events a blank line is what
    /// dispatches an event. Any line reader that skips them — which is exactly what
    /// `AsyncLineSequence` does, since it only yields when its buffer is non-empty —
    /// silently merges every frame in the stream into one.
    ///
    /// Chunk boundaries fall wherever the network put them, so a line can span two
    /// chunks and a chunk can hold many lines. Both cases are handled by buffering.
    ///
    /// The SSE grammar allows three line terminators — LF, CRLF and a lone CR — and
    /// says a single leading byte-order mark is ignored. All three terminators are
    /// accepted, because a gateway that emits one of the rarer two would otherwise
    /// deliver its whole body as a single "line" at close, which decodes as nothing.
    static func readLines(from body: AsyncThrowingStream<Data, Error>,
                          limit: Int,
                          deadline: TimeInterval = HTTPTransport.deadline,
                          handle: (String) throws -> Bool) async throws {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(4096)
        var consumed = 0
        var followsCarriageReturn = false
        var isFirstLine = true
        let started = Date()

        func emitLine() throws -> Bool {
            var line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            if isFirstLine {
                isFirstLine = false
                if line.hasPrefix(SSELine.byteOrderMark) { line.removeFirst() }
            }
            return try handle(line)
        }

        for try await chunk in body {
            // A wall-clock deadline as well as a size cap. The session's timeout is an
            // *idle* timeout on Linux, rebuilt on every chunk, so a server emitting a
            // keep-alive comment every few seconds would hold the read open indefinitely
            // without ever tripping it.
            guard Date().timeIntervalSince(started) <= deadline else {
                throw HTTPTransport.tookTooLong(deadline)
            }
            consumed += chunk.count
            guard consumed <= limit else { throw ResearchError.responseTooLarge }

            // Visit each byte once and keep only the unfinished line. Prefix removal
            // per newline repeatedly copied the rest of a large chunk.
            for byte in chunk {
                if followsCarriageReturn, byte == SSELine.lineFeed {
                    followsCarriageReturn = false
                    continue
                }
                followsCarriageReturn = byte == SSELine.carriageReturn

                // SSE permits CR, LF, and CRLF, even across separate chunks.
                if byte == SSELine.carriageReturn || byte == SSELine.lineFeed {
                    guard try emitLine() else { return }
                } else {
                    buffer.append(byte)
                }
            }
        }
        // A final line with no trailing newline is still a line.
        if !buffer.isEmpty { _ = try emitLine() }
    }

    private enum SSELine {
        static let carriageReturn: UInt8 = 0x0D
        static let lineFeed: UInt8 = 0x0A
        static let byteOrderMark = "\u{FEFF}"
    }

    /// Whether an SSE frame is the response being waited for.
    ///
    /// A frame carrying a different `id` belongs to another in-flight call and is
    /// skipped. `expectedID` is nil only for callers that never advertised
    /// `text/event-stream` and for the notification path, which returns before the
    /// stream is read — so in practice this is never asked to match blind.
    private static func matches(_ object: [String: Any], expectedID: Int?) -> Bool {
        guard let expectedID else { return true }
        return (object["id"] as? Int) == expectedID
    }

    /// Joins a frame's `data:` lines with newlines (per the SSE spec) and decodes it.
    static func decodeFrame(_ payload: [String]) -> [String: Any]? {
        guard !payload.isEmpty else { return nil }
        let joined = payload.joined(separator: "\n")
        guard let data = joined.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Turns a sequence of SSE lines into decoded frames.
    ///
    /// A value type with no I/O, so the framing rules can be unit-tested with plain
    /// strings. Two rules beyond the spec's blank-line dispatch:
    ///
    /// * `data: [DONE]` ends the stream — but it flushes the `data:` lines gathered
    ///   before it first. A gateway that puts the last delta and the sentinel in one
    ///   event block would otherwise lose that delta, and it is typically the one
    ///   carrying `finish_reason`.
    /// * Comment lines (`:` keep-alives) and fields other than `data:` are ignored.
    struct SSEFrameAssembler {
        private var payload: [String] = []

        /// Feeds one line. Returns the frame that line completed, if any, and whether
        /// the stream has announced its end.
        mutating func consume(_ line: String) throws -> (frame: [String: Any]?, done: Bool) {
            if line.isEmpty { return (try flush(), false) }
            if line.hasPrefix(":") { return (nil, false) }
            guard line.hasPrefix("data:") else { return (nil, false) }
            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if value == "[DONE]" { return (try flush(), true) }
            payload.append(value)
            return (nil, false)
        }

        /// Decodes and clears whatever has been gathered — the frame a blank line
        /// dispatches, or the one a stream ends on without a trailing blank line.
        mutating func flush() throws -> [String: Any]? {
            defer { payload.removeAll(keepingCapacity: true) }
            guard !payload.isEmpty else { return nil }
            // Dropping a malformed delta would silently remove part of the answer.
            guard let frame = HTTPTransport.decodeFrame(payload) else {
                throw ResearchError.invalidResponse
            }
            return frame
        }
    }

    // MARK: Response checks

    private static func checkStatus(_ http: HTTPURLResponse) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 404 {
            throw ResearchError(
                "The provider returned HTTP 404. Check the endpoint path and model name in "
                + "the provider settings — the server did not recognise the requested resource.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ResearchError.rejectedCredential(http.statusCode)
        }
        if http.statusCode == 429 {
            throw ResearchError("The provider is rate-limiting Vervellum (HTTP 429). Wait a moment and retry.")
        }
        if http.statusCode == 400 {
            throw ResearchError.badRequest
        }
        if (300..<400).contains(http.statusCode) {
            // Refusing a redirect does not fail the task — `URLSession` completes it
            // successfully with the 3xx response — so this branch is the only thing that
            // turns a blocked redirect into an error the caller can see.
            throw ResearchError(
                "The provider redirected the request (HTTP \(http.statusCode)). Vervellum never "
                + "follows a redirect, because that would resend the API key to another host. "
                + "Check the endpoint URL in the provider settings.")
        }
        throw ResearchError.providerStatus(http.statusCode)
    }

    static func isEventStream(_ http: HTTPURLResponse) -> Bool {
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        return contentType.lowercased().contains("text/event-stream")
    }

    private static func headerDictionary(_ http: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String { headers[name] = text }
        }
        return headers
    }

    /// Maps a transport failure onto one of Vervellum's own messages. The original
    /// error is deliberately discarded rather than wrapped.
    private static func sanitized(_ error: Error) -> ResearchError {
        if let error = error as? ResearchError { return error }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return .cancelled }
        // Named separately: "connection failed" invites a retry that will hit the
        // same wall, when the remedy is a faster model or a shorter question.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut { return .timedOut }
        return .connectionFailed
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Always allow: on Linux the disposition is read and discarded (libcurl cannot
        // be paused the way FoundationNetworking drives it), so a `.cancel` here would
        // be a silent no-op. A bad status is handled by the caller instead.
        completionHandler(.allow)

        guard let http = response as? HTTPURLResponse else { return }
        lock.lock()
        guard let exchange = exchanges[dataTask.taskIdentifier] else { lock.unlock(); return }
        exchange.response = http
        let head = exchange.head
        exchange.head = nil
        lock.unlock()
        head?.resume(returning: http)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let exchange = exchanges[dataTask.taskIdentifier] else { lock.unlock(); return }
        exchange.bytesYielded += data.count
        let overLimit = exchange.bytesYielded > exchange.limit
        lock.unlock()

        // Enforced here, at the producer, not only where the bytes are consumed. The
        // body stream's buffer is unbounded — dropping a delta would corrupt an answer —
        // so a hostile endpoint could otherwise bury a slow reader in memory long before
        // the reader's own check ran.
        guard !overLimit else {
            dataTask.cancel()
            exchange.body?.finish(throwing: ResearchError.responseTooLarge)
            return
        }
        exchange.body?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let exchange = exchanges.removeValue(forKey: task.taskIdentifier)
        let head = exchange?.head
        exchange?.head = nil
        lock.unlock()
        guard let exchange else { return }

        // A task that fails before any response leaves the head continuation waiting;
        // resuming it with the error is the only thing that unblocks `open`.
        if let head {
            head.resume(throwing: error ?? ResearchError.connectionFailed)
            exchange.body?.finish()
            return
        }
        if let error {
            exchange.body?.finish(throwing: Self.sanitized(error))
        } else {
            exchange.body?.finish()
        }
    }

    /// Refuses every redirect. See rule 1 in the type's documentation.
    ///
    /// The completion-handler form, not the `async` one: swift-corelibs-foundation
    /// declares only this shape, and the async overloads exist on Darwin purely as
    /// Objective-C-generated variants.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
