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

    // MARK: Response shaping

    func testExtractsTheMessageContent() throws {
        let response: [String: Any] = ["choices": [["message": ["content": "  hello  "]]]]
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
        XCTAssertNoThrow(try ChatCompletionsClient.checkFinishReason(nil))
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
}
