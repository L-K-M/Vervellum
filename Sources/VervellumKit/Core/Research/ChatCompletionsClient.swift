import Foundation

/// Talks to an OpenAI-compatible Chat Completions endpoint.
///
/// Vervellum needs two different shapes from the same endpoint, and they are kept
/// separate on purpose:
///
/// * `completeJSON` — a **non-streaming** call whose whole reply must parse as one
///   JSON object. Used for the search plan and the claim assessment, where a
///   half-formed reply is worthless and strict validation is the point.
/// * `streamText` — a **streaming** call whose deltas are handed to the UI as they
///   arrive. Used for the prose answer, where the first token mattering within a
///   second is worth more than structure.
///
/// The endpoint is untrusted: it is whatever URL the user pasted. So the JSON path
/// re-parses defensively and every failure becomes a `ResearchError` naming the
/// likely fix, rather than a decoding trace the user cannot act on.
///
/// ## Optional request parameters
///
/// Two parameters improve the calls but are not universally accepted: a low
/// `temperature` (OpenAI's reasoning models reject any value but their default with
/// HTTP 400) and `response_format: json_object` for the two structured stages (some
/// gateways return 400 for a field they do not know). A rejected parameter must never
/// make a model unusable, so on the first HTTP 400 for a request that carried them the
/// call is retried once without them — safe, because a 400 arrives before any streamed
/// content — and the outcome is remembered for the rest of the turn. That memory is
/// why this is a class: a runner builds one client per turn and makes three calls
/// through it, and paying the rejected request three times would be silly.
final class ChatCompletionsClient {

    let url: URL
    let model: String
    let apiKey: String?
    let trace: ResearchTrace
    let transport: HTTPTransport

    /// Whether the endpoint has, so far, accepted the optional parameters.
    private var sendsOptionalParameters = true

    init(url: URL, model: String, apiKey: String?, trace: ResearchTrace, transport: HTTPTransport = .shared) {
        self.url = url
        self.model = model
        self.apiKey = apiKey
        self.trace = trace
        self.transport = transport
    }

    private var headers: [String: String] {
        guard let apiKey, !apiKey.isEmpty else { return [:] }
        return ["Authorization": "Bearer " + apiKey]
    }

    // MARK: Structured call

    /// Sends `system` plus a JSON-encoded `payload` and decodes the reply as a JSON
    /// object.
    func completeJSON(system: String, payload: Any, label: String) async throws -> [String: Any] {
        guard let userContent = Self.encodeUserContent(payload)
        else { throw ResearchError.invalidContext }

        let response = try await withOptionalParameters(label: label) { optional in
            let body = Self.requestBody(model: self.model, system: system, userContent: userContent,
                                        stream: false, optionalParameters: optional)
            // `"stream": false` above, so do not advertise SSE — see HTTPTransport.request.
            let request = try HTTPTransport.request(url: self.url, payload: body, headers: self.headers,
                                                    acceptsEventStream: false)
            return try await self.trace.stage(label) {
                try await self.transport.sendJSON(request)
            }.body
        }
        let text = try Self.messageContent(from: response)
        guard let object = Self.decodeJSONObject(from: text) else {
            throw ResearchError("The model did not return the requested JSON. "
                                + "Try again, or choose a model that follows JSON instructions.")
        }
        return object
    }

    // MARK: Streaming call

    /// Streams a prose reply, invoking `onDelta` for each chunk, and returns the full
    /// accumulated text.
    ///
    /// `onDelta` is called on whichever thread the stream is being consumed on, and is
    /// deliberately *not* `@MainActor`. Marshalling belongs to the caller because the
    /// platforms answer it differently: on macOS the main actor is the main dispatch
    /// queue, but a GTK application runs a GLib main loop instead, so a `MainActor` hop
    /// there would never execute and the answer would never appear.
    func streamText(system: String,
                    payload: Any,
                    label: String,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        guard let userContent = Self.encodeUserContent(payload)
        else { throw ResearchError.invalidContext }

        trace.log("\(label) started")
        let began = Date()
        // The retry is safe here too: a 400 is delivered as the response head, before
        // the first frame, so no delta has reached the caller when it is thrown.
        let reply = try await withOptionalParameters(label: label) { optional in
            let body = Self.requestBody(model: self.model, system: system, userContent: userContent,
                                        stream: true, optionalParameters: optional)
            let request = try HTTPTransport.request(url: self.url, payload: body, headers: self.headers,
                                                    acceptsEventStream: true)
            var reply = StreamingReply()
            do {
                for try await event in self.transport.streamJSONEvents(request) {
                    try Task.checkCancellation()
                    if let chunk = try reply.apply(event) { onDelta(chunk) }
                }
            } catch let error as ResearchError {
                self.trace.warn(String(format: "%@ failed after %.2fs: %@", label,
                                       Date().timeIntervalSince(began), error.message))
                throw error
            } catch is CancellationError {
                throw ResearchError.cancelled
            } catch {
                throw ResearchError.connectionFailed
            }
            return reply
        }

        // Checked again *after* the loop, not only inside it. Cancelling the consuming
        // task while it is suspended in `next()` terminates the stream rather than
        // failing it: the iterator returns nil, the loop above exits normally, and the
        // in-loop check never runs because no element was delivered. Without this line
        // the fragment streamed so far would be returned — and recorded — as a whole
        // answer.
        try Task.checkCancellation()

        try Self.checkFinishReason(reply.finishReason)
        guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchError("The model returned an empty answer. Try again or choose another model.")
        }
        trace.log(String(format: "%@ completed in %.2fs, %d characters", label,
                         Date().timeIntervalSince(began), reply.text.count))
        return reply.text
    }

    /// Accumulates a streamed Chat Completions reply, one SSE event at a time.
    ///
    /// A value type with no I/O so the event rules can be unit-tested. The rule that
    /// matters most: a provider that fails mid-stream does not fail the connection —
    /// it sends one frame carrying an `error` object instead of a delta and then closes
    /// the stream cleanly, usually without `[DONE]`. Skipping that frame as "not a
    /// delta" would return the text streamed so far as if it were the whole answer, which
    /// is the silently truncated, confidently wrong outcome this app exists to prevent.
    struct StreamingReply {
        private(set) var text = ""
        private(set) var finishReason: String?

        /// Applies one event and returns the text it contributed, if any.
        mutating func apply(_ event: [String: Any]) throws -> String? {
            // The provider's own message is discarded, never surfaced: gateway errors
            // have been seen echoing request data and credentials.
            if let error = event["error"], !(error is NSNull) {
                throw ResearchError.streamInterrupted
            }
            guard let choices = event["choices"] as? [[String: Any]],
                  let first = choices.first else { return nil }
            if let reason = first["finish_reason"] as? String { finishReason = reason }
            // Whole-response fallback must retain its finish reason and validation errors.
            if first["message"] != nil {
                guard text.isEmpty else { throw ResearchError.invalidResponse }
                let whole = try ChatCompletionsClient.messageContent(from: event)
                text = whole
                return whole
            }
            guard let delta = first["delta"] as? [String: Any],
                  let chunk = delta["content"] as? String, !chunk.isEmpty else { return nil }
            text += chunk
            return chunk
        }
    }

    // MARK: Request shaping

    /// Runs `attempt` with the optional parameters, and once more without them if the
    /// provider answered HTTP 400 — see the type's documentation.
    private func withOptionalParameters<T>(label: String,
                                           _ attempt: (_ optional: Bool) async throws -> T) async throws -> T {
        guard sendsOptionalParameters else { return try await attempt(false) }
        do {
            return try await attempt(true)
        } catch let error as ResearchError where error == .badRequest {
            sendsOptionalParameters = false
            trace.log("\(label): the provider rejected the request; retrying without optional parameters")
            return try await attempt(false)
        }
    }

    /// The request body for one call.
    ///
    /// `optionalParameters` adds the two fields not every endpoint accepts: a low
    /// temperature — these calls are extraction and adjudication, not composition, and
    /// sampling variance there shows up as flaky validation — and, for the non-streaming
    /// JSON stages, `response_format: json_object`, which stops a model wrapping the
    /// object in a fence or a sentence of commentary at the source. The word "JSON"
    /// that OpenAI requires in the prompt when that mode is on is in `ResearchPrompts`.
    static func requestBody(model: String,
                            system: String,
                            userContent: String,
                            stream: Bool,
                            optionalParameters: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
        ]
        if optionalParameters {
            body["temperature"] = stream ? 0.4 : 0.2
            if !stream { body["response_format"] = ["type": "json_object"] }
        }
        return body
    }

    /// The user message: the context payload as JSON text.
    ///
    /// Keys are sorted so the same inputs produce the same bytes. Unsorted, the
    /// question's position relative to a 70 KB evidence block would depend on Swift's
    /// per-process hash seed, which made two runs of one question send different prompts,
    /// defeated deterministic replay when diagnosing a bad answer, and defeated any
    /// prefix caching a provider offers across retries. Sorted, `evidence` precedes
    /// `question`, which is also where long-context guidance says the query belongs.
    static func encodeUserContent(_ payload: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              encoded.count <= ResearchContext.maxCharacters
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    // MARK: Response shaping

    /// The assistant message text from a non-streaming Chat Completions response.
    static func messageContent(from response: [String: Any]) throws -> String {
        guard let choices = response["choices"] as? [[String: Any]], let first = choices.first else {
            // A provider that returns its own error object instead of `choices` is the
            // single most common misconfiguration (wrong path, wrong model name).
            throw ResearchError("The model endpoint did not return a completion. "
                                + "Check the endpoint path and model name in Settings ▸ Providers.")
        }
        try checkFinishReason(first["finish_reason"] as? String)
        guard let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ResearchError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func checkFinishReason(_ reason: String?) throws {
        switch reason {
        case "length":
            throw ResearchError("The model's reply was cut off by its output limit. "
                                + "Try a shorter question or a model with a larger output limit.")
        case "content_filter":
            throw ResearchError("The model's provider filtered the reply. Try rephrasing the question.")
        case "stop":
            return
        default:
            throw ResearchError.streamInterrupted
        }
    }

    /// Decodes a JSON object from a model reply, tolerating the three things models do
    /// even when told not to: wrapping the object in a ```json fence, prefixing it with
    /// a sentence of commentary, and — for a reasoning model served through a gateway
    /// that leaks its scratchpad — preceding it with a `<think>` block.
    static func decodeJSONObject(from text: String) -> [String: Any]? {
        // Parse valid JSON before recovery so literal reasoning tags remain data.
        if let object = parseObject(text) { return object }
        var candidate = stripReasoning(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            candidate = stripFence(candidate)
        }
        if let object = parseObject(candidate) { return object }
        // Fall back to the brace-balanced runs, in order, until one parses. The *first*
        // run is not enough on its own: a preamble that quotes the expected shape —
        // `{"reading": ..., "searches": [...]}` with literal ellipses — is balanced and
        // unparseable, and the real object follows it.
        var from = candidate.startIndex
        while let range = objectRange(in: candidate, from: from) {
            if let object = parseObject(String(candidate[range])) { return object }
            from = range.upperBound
        }
        return nil
    }

    private static func parseObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Removes `<think>…</think>` and `<reasoning>…</reasoning>` blocks, which some
    /// OpenAI-compatible servers pass through in the content rather than in a
    /// separate field. Only the JSON stages are affected: the streamed answer shows
    /// whatever the model wrote.
    static func stripReasoning(_ text: String) -> String {
        guard let regex = reasoningBlock else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static let reasoningBlock = try? NSRegularExpression(
        pattern: #"(?is)^\s*<(think|reasoning)>.*?</\1>\s*"#)

    /// Removes a surrounding ``` fence.
    ///
    /// Handles the one-line form — ```` ```json {"a": 1} ``` ```` — separately, because
    /// dropping "the first line" there discards the entire object and leaves nothing to
    /// parse. Models produce that shape often enough for a short reply.
    private static func stripFence(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        if lines.count == 1 {
            var single = Substring(text)
            single = single.drop(while: { $0 == "`" })
            while let last = single.last, last == "`" { single = single.dropLast() }
            // Drop an info string such as `json` that is now leading the content.
            let trimmed = single.trimmingCharacters(in: .whitespaces)
            if let brace = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) {
                return String(trimmed[brace...])
            }
            return trimmed
        }
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The substring from the first `{` to its matching `}`, ignoring braces inside
    /// string literals so a brace in prose content cannot end the scan early.
    static func outermostObject(in text: String) -> String? {
        objectRange(in: text, from: text.startIndex).map { String(text[$0]) }
    }

    /// The range of the first brace-balanced run at or after `from`.
    static func objectRange(in text: String, from: String.Index) -> Range<String.Index>? {
        guard let start = text[from...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return start..<text.index(after: index) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
