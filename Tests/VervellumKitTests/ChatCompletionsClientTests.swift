import XCTest
import Foundation
#if canImport(FoundationNetworking)
// HTTPURLResponse lives in FoundationNetworking on Linux, and it is not re-exported.
import FoundationNetworking
#endif
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class ChatCompletionsClientTests: XCTestCase {

    // MARK: JSON recovery

    func testDecodesAPlainObject() {
        let object = ChatCompletionsClient.decodeJSONObject(from: #"{"a": 1}"#)
        XCTAssertEqual(object?["a"] as? Int, 1)
    }

    /// Models wrap JSON in a fence even when told not to.
    func testStripsAMarkdownFence() {
        let object = ChatCompletionsClient.decodeJSONObject(from: "```json\n{\"a\": 1}\n```")
        XCTAssertEqual(object?["a"] as? Int, 1)
        let bare = ChatCompletionsClient.decodeJSONObject(from: "```\n{\"b\": 2}\n```")
        XCTAssertEqual(bare?["b"] as? Int, 2)
    }

    /// And they prefix it with a sentence of commentary.
    func testRecoversAnObjectWrappedInProse() {
        let text = "Sure, here is the plan:\n{\"searches\": []}\nLet me know if that helps."
        XCTAssertNotNil(ChatCompletionsClient.decodeJSONObject(from: text)?["searches"])
    }

    /// A brace inside a string value must not end the scan early.
    func testBraceScanIgnoresBracesInsideStrings() {
        let text = #"prefix {"note": "a } brace", "ok": true} suffix"#
        let object = ChatCompletionsClient.decodeJSONObject(from: text)
        XCTAssertEqual(object?["ok"] as? Bool, true)
    }

    func testBraceScanHandlesEscapedQuotes() {
        let text = #"{"note": "he said \"}\" loudly", "ok": true}"#
        XCTAssertEqual(ChatCompletionsClient.decodeJSONObject(from: text)?["ok"] as? Bool, true)
    }

    func testReturnsNilForUnrecoverableText() {
        XCTAssertNil(ChatCompletionsClient.decodeJSONObject(from: "I cannot help with that."))
        XCTAssertNil(ChatCompletionsClient.decodeJSONObject(from: ""))
        XCTAssertNil(ChatCompletionsClient.decodeJSONObject(from: "{unclosed"))
    }

    /// A bare JSON array is not an object; the parsers all expect a keyed reply.
    func testReturnsNilForATopLevelArray() {
        XCTAssertNil(ChatCompletionsClient.decodeJSONObject(from: "[1, 2, 3]"))
    }

    func testOutermostObjectFindsTheFirstBalancedRun() {
        XCTAssertEqual(ChatCompletionsClient.outermostObject(in: "x {\"a\": {\"b\": 1}} y"),
                       "{\"a\": {\"b\": 1}}")
        XCTAssertNil(ChatCompletionsClient.outermostObject(in: "no braces here"))
    }

    /// A reasoning model served through a gateway that leaks its scratchpad puts a
    /// `<think>` block before the object — and that block often quotes the expected
    /// shape with literal ellipses, which is balanced and unparseable.
    func testStripsAReasoningBlockBeforeTheObject() {
        let text = "<think>I should return {\"reading\": ..., \"searches\": [...]} with two "
            + "queries.</think>\n{\"reading\": \"r\", \"searches\": []}"
        XCTAssertEqual(ChatCompletionsClient.decodeJSONObject(from: text)?["reading"] as? String, "r")
        let upper = "<THINK>\nbraces { everywhere }\n</THINK>{\"ok\": true}"
        XCTAssertEqual(ChatCompletionsClient.decodeJSONObject(from: upper)?["ok"] as? Bool, true)
    }

    /// Even without a tag, a preamble that quotes the schema must not win over the real
    /// object that follows it.
    func testSkipsAnUnparseableBalancedRunAndTakesTheNext() {
        let text = "The shape is {\"findings\": [...]} — here it is: {\"findings\": [], \"limitations\": \"\"}"
        XCTAssertNotNil(ChatCompletionsClient.decodeJSONObject(from: text)?["findings"])
    }

    // MARK: Request shape

    /// The two optional fields not every endpoint accepts, and nothing else, come and go
    /// together: a rejected request is retried without exactly these.
    func testOptionalParametersAreAddedOnlyWhenAsked() {
        let with = ChatCompletionsClient.requestBody(model: "m", system: "s", userContent: "u",
                                                     stream: false, optionalParameters: true)
        XCTAssertEqual(with["temperature"] as? Double, 0.2)
        XCTAssertEqual((with["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertEqual(with["stream"] as? Bool, false)

        let without = ChatCompletionsClient.requestBody(model: "m", system: "s", userContent: "u",
                                                        stream: false, optionalParameters: false)
        XCTAssertNil(without["temperature"])
        XCTAssertNil(without["response_format"])
        XCTAssertEqual(without["model"] as? String, "m")
        XCTAssertEqual((without["messages"] as? [[String: String]])?.count, 2)
    }

    /// JSON mode is a non-streaming affair; the streamed answer only ever carries the
    /// temperature.
    func testTheStreamedCallNeverAsksForJSONMode() {
        let streamed = ChatCompletionsClient.requestBody(model: "m", system: "s", userContent: "u",
                                                         stream: true, optionalParameters: true)
        XCTAssertEqual(streamed["temperature"] as? Double, 0.4)
        XCTAssertNil(streamed["response_format"])
        XCTAssertEqual(streamed["stream"] as? Bool, true)
    }

    /// The same inputs must produce the same prompt bytes.
    func testUserContentIsEncodedWithSortedKeys() {
        let payload: [String: Any] = ["question": "q", "evidence": [1], "today": "2026-09-06"]
        XCTAssertEqual(ChatCompletionsClient.encodeUserContent(payload),
                       #"{"evidence":[1],"question":"q","today":"2026-09-06"}"#)
    }

    func testOversizedFixedContextIsRejectedBeforeAnyRequest() {
        let oversized = String(repeating: "x", count: ResearchContext.maxCharacters)
        XCTAssertNil(ChatCompletionsClient.encodeUserContent(["answer": oversized, "question": "Q"]))
        XCTAssertNil(ChatCompletionsClient.encodeUserContent(["question": oversized]))
    }

    func testUnknownFinishReasonsCannotCompleteAnAnswer() {
        for reason in ["", "tool_calls", "function_call", "future_reason"] {
            XCTAssertThrowsError(try ChatCompletionsClient.checkFinishReason(reason))
        }
    }

    func testReasoningTagsInsideJSONStringsArePreserved() {
        let json = #"{"reading":"Explain <think>this text</think>","searches":[]}"#
        XCTAssertEqual(ChatCompletionsClient.decodeJSONObject(from: json)?["reading"] as? String,
                       "Explain <think>this text</think>")
    }

    // MARK: Response shaping

    func testExtractsTheMessageContent() throws {
        let response: [String: Any] = ["choices": [["message": ["content": "  hello  "], "finish_reason": "stop"]]]
        XCTAssertEqual(try ChatCompletionsClient.messageContent(from: response), "hello")
    }

    /// A provider that answers with its own error object instead of `choices` is the
    /// most common misconfiguration, and deserves a message naming the likely fix.
    func testMissingChoicesIsAConfigurationError() {
        let response: [String: Any] = ["error": ["message": "model not found"]]
        XCTAssertThrowsError(try ChatCompletionsClient.messageContent(from: response)) { error in
            XCTAssertTrue((error as? ResearchError)?.message.contains("Settings") ?? false)
        }
    }

    /// A truncated reply is worse than no reply: it parses as prose and fails
    /// validation with a confusing message.
    func testRejectsATruncatedReply() {
        XCTAssertThrowsError(try ChatCompletionsClient.checkFinishReason("length"))
        XCTAssertThrowsError(try ChatCompletionsClient.checkFinishReason("content_filter"))
        XCTAssertNoThrow(try ChatCompletionsClient.checkFinishReason("stop"))
        XCTAssertThrowsError(try ChatCompletionsClient.checkFinishReason(nil))
    }

    // MARK: SSE frames

    func testDecodesAFrameFromItsDataLines() {
        XCTAssertEqual(HTTPTransport.decodeFrame([#"{"a": 1}"#])?["a"] as? Int, 1)
    }

    /// The SSE spec joins a frame's multiple `data:` lines with newlines. Joining
    /// them any other way corrupts JSON that a provider chose to wrap.
    func testJoinsMultiLineFramesWithNewlines() {
        XCTAssertEqual(HTTPTransport.decodeFrame(["{\"a\":", "1}"])?["a"] as? Int, 1)
    }

    func testIgnoresAnEmptyOrUnparseableFrame() {
        XCTAssertNil(HTTPTransport.decodeFrame([]))
        XCTAssertNil(HTTPTransport.decodeFrame(["not json"]))
    }

    /// A plan or an assessment sends nothing until the model has finished, so the idle
    /// timeout that suits a stream would cut a slow local model off mid-generation.
    func testANonStreamingRequestGetsTheFullDeadline() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/v1/chat/completions"))
        let structured = try HTTPTransport.request(url: url, payload: ["stream": false], headers: [:],
                                                   acceptsEventStream: false)
        XCTAssertEqual(structured.timeoutInterval, HTTPTransport.deadline)
        let streamed = try HTTPTransport.request(url: url, payload: ["stream": true], headers: [:],
                                                 acceptsEventStream: true)
        XCTAssertEqual(streamed.timeoutInterval, HTTPTransport.idleTimeout)
        XCTAssertLessThan(HTTPTransport.idleTimeout, HTTPTransport.deadline)
    }

    func testDetectsAnEventStreamResponse() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let sse = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"]))
        XCTAssertTrue(HTTPTransport.isEventStream(sse))
        let json = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]))
        XCTAssertFalse(HTTPTransport.isEventStream(json))
    }

    // MARK: Attached images

    /// The regression that matters most here. Plenty of the OpenAI-compatible servers
    /// this app gets pointed at — a local llama.cpp, an older gateway — accept only a
    /// string for `content` and reject an array outright, so a turn with nothing attached
    /// has to send exactly the bytes it sent before images existed.
    func testAMessageWithNoImagesKeepsAPlainStringContent() throws {
        let body = ChatCompletionsClient.requestBody(model: "m", system: "s", userContent: "u",
                                                     stream: false, optionalParameters: false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["content"] as? String, "u")
    }

    /// With images the newer parts shape is used, text first: the question is what the
    /// pictures are *for*, and a model reading parts in order should have it before them.
    func testImagesBecomePartsWithTheTextFirst() throws {
        let images = [
            ChatCompletionsClient.ImagePart(mediaType: "image/png", base64: "AAAA"),
            ChatCompletionsClient.ImagePart(mediaType: "image/jpeg", base64: "BBBB"),
        ]
        let body = ChatCompletionsClient.requestBody(model: "m", system: "s", userContent: "u",
                                                     images: images, stream: true,
                                                     optionalParameters: false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "u")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual((parts[1]["image_url"] as? [String: Any])?["url"] as? String,
                       "data:image/png;base64,AAAA")
        XCTAssertEqual((parts[2]["image_url"] as? [String: Any])?["url"] as? String,
                       "data:image/jpeg;base64,BBBB")
    }

    /// The guarantee is the client's, not the caller's. `ModelProfile.sendsImages` exists
    /// because a text-only endpoint handed an `image_url` part answers 400 and the whole
    /// question fails — so the filter lives where every request is built, and a caller
    /// that hands over an image anyway cannot cost a turn.
    func testAProviderWithoutEyesIsNeverSentAnImageEvenIfOneIsHandedOver() async throws {
        let images = [ChatCompletionsClient.ImagePart(mediaType: "image/png", base64: "AAAA")]
        let transport = StubTransport { _ in .completion(json: [:]) }
        let client = ChatCompletionsClient(url: URL(string: "https://a.example/v1/chat/completions")!,
                                           model: "m", apiKey: nil, sendsImages: false,
                                           trace: ResearchTrace(sink: SilentLog()),
                                           transport: transport)

        _ = try await client.completeJSON(system: "s", payload: ["q": "?"], label: "Plan",
                                          images: images)
        let body = try XCTUnwrap(transport.calls.first?.body)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertNotNil(messages.last?["content"] as? String,
                        "an image reached a provider that was never configured for one")
    }

    /// And the same client with the flag on sends it, so the guard above is a filter
    /// rather than a wall.
    func testAProviderWithEyesIsSentTheImage() async throws {
        let images = [ChatCompletionsClient.ImagePart(mediaType: "image/png", base64: "AAAA")]
        let transport = StubTransport { _ in .completion(json: [:]) }
        let client = ChatCompletionsClient(url: URL(string: "https://a.example/v1/chat/completions")!,
                                           model: "m", apiKey: nil, sendsImages: true,
                                           trace: ResearchTrace(sink: SilentLog()),
                                           transport: transport)

        _ = try await client.completeJSON(system: "s", payload: ["q": "?"], label: "Plan",
                                          images: images)
        let body = try XCTUnwrap(transport.calls.first?.body)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
    }

    /// Inline rather than hosted. The alternative is uploading the user's screenshot
    /// somewhere to get a link for it, which is the opposite of what this app promises
    /// about where their data goes.
    func testAnImagePartIsADataURLAndNotALink() {
        let part = ChatCompletionsClient.ImagePart(mediaType: "image/webp", base64: "Zm8=")
        XCTAssertEqual(part.dataURL, "data:image/webp;base64,Zm8=")
        XCTAssertFalse(part.dataURL.hasPrefix("http"))
    }
}
