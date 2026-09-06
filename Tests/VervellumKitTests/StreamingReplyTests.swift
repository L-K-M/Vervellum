import XCTest
import Foundation
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The rules for turning a streamed Chat Completions reply into an answer.
final class StreamingReplyTests: XCTestCase {

    private func delta(_ content: String, finish: String? = nil) -> [String: Any] {
        var choice: [String: Any] = ["delta": ["content": content]]
        if let finish { choice["finish_reason"] = finish }
        return ["choices": [choice]]
    }

    func testAccumulatesDeltasInOrder() throws {
        var reply = ChatCompletionsClient.StreamingReply()
        XCTAssertEqual(try reply.apply(delta("Hel")), "Hel")
        XCTAssertEqual(try reply.apply(delta("lo")), "lo")
        XCTAssertEqual(reply.text, "Hello")
        XCTAssertNil(reply.finishReason)
    }

    func testRecordsTheFinishReasonFromAnEmptyDelta() throws {
        var reply = ChatCompletionsClient.StreamingReply()
        _ = try reply.apply(delta("done"))
        XCTAssertNil(try reply.apply(["choices": [["delta": [String: Any](), "finish_reason": "stop"]]]))
        XCTAssertEqual(reply.finishReason, "stop")
        XCTAssertEqual(reply.text, "done")
    }

    /// A provider that fails mid-stream sends an `error` frame and closes the stream
    /// cleanly. Treating that frame as "not a delta" would return the fragment as a
    /// whole answer — the silently truncated outcome this app exists to prevent.
    func testAnErrorFrameFailsTheReply() throws {
        var reply = ChatCompletionsClient.StreamingReply()
        _ = try reply.apply(delta("Half an ans"))
        XCTAssertThrowsError(try reply.apply(["error": ["message": "upstream failed", "type": "server_error"]])) { error in
            XCTAssertEqual(error as? ResearchError, ResearchError.streamInterrupted)
        }
    }

    /// The provider's own words must never reach the user: the thrown error is one
    /// Vervellum wrote.
    func testTheErrorFrameTextIsNeverSurfaced() throws {
        var reply = ChatCompletionsClient.StreamingReply()
        let secret = "Bearer sk-live-should-not-appear"
        XCTAssertThrowsError(try reply.apply(["error": secret])) { error in
            XCTAssertFalse((error as? ResearchError)?.message.contains("sk-live") ?? true)
        }
    }

    /// Some gateways put `"error": null` on every ordinary frame.
    func testANullErrorFieldIsNotAnError() throws {
        var reply = ChatCompletionsClient.StreamingReply()
        XCTAssertEqual(try reply.apply(["error": NSNull(), "choices": [["delta": ["content": "ok"]]]]), "ok")
    }

    /// A gateway that ignored `stream: true` answers with one complete object.
    func testTakesAWholeResponseObject() throws {
        var reply = ChatCompletionsClient.StreamingReply()
        let whole: [String: Any] = ["choices": [["message": ["content": "  All at once  "], "finish_reason": "stop"]]]
        XCTAssertEqual(try reply.apply(whole), "All at once")
        XCTAssertEqual(reply.text, "All at once")
        XCTAssertEqual(reply.finishReason, "stop")
    }

    func testOnlyUsageFramesAreAcceptedAfterCompletion() throws {
        var reply = ChatCompletionsClient.StreamingReply()
        _ = try reply.apply(["choices": [["delta": [:], "finish_reason": "stop"]]])
        XCTAssertNil(try reply.apply(["choices": [], "usage": ["completion_tokens": 1]]))
        XCTAssertThrowsError(try reply.apply(["choices": [["delta": [:]]]]))
    }

    func testAClosingReasonCannotBeOverwrittenByLaterChoices() throws {
        var reply = ChatCompletionsClient.StreamingReply()
        _ = try reply.apply(["choices": [["delta": [:], "finish_reason": "length"]]])
        XCTAssertThrowsError(try reply.apply(["choices": [["delta": [:], "finish_reason": "stop"]]]))
        XCTAssertEqual(reply.finishReason, "length")
    }

    func testEveryNonNullErrorEnvelopeInterruptsTheReply() {
        for value: Any in [true, 42, ["error"]] {
            var reply = ChatCompletionsClient.StreamingReply()
            XCTAssertThrowsError(try reply.apply(["error": value]))
        }
    }

    func testAllowsUsageOnlyAndNullContentFrames() throws {
        var reply = ChatCompletionsClient.StreamingReply()
        XCTAssertNil(try reply.apply(["usage": ["completion_tokens": 1]]))
        XCTAssertNil(try reply.apply(["choices": [], "usage": ["completion_tokens": 1]]))
        XCTAssertNil(try reply.apply(["choices": [["delta": ["role": "assistant", "content": NSNull()]]]]))
        XCTAssertEqual(reply.text, "")
    }

    func testMalformedJSONShapesCannotDiscardAnswerData() {
        let events: [[String: Any]] = [
            [:], ["choices": "invalid"], ["choices": []], ["choices": [42]],
            ["choices": [["delta": "invalid"]]],
            ["choices": [["delta": ["content": 123]]]],
            ["choices": [["delta": ["content": ["text": "lost"]]]]],
            ["choices": [["delta": ["role": 123]]]],
            ["choices": [["delta": [:], "finish_reason": 123]]],
        ]
        for event in events {
            var reply = ChatCompletionsClient.StreamingReply()
            XCTAssertThrowsError(try reply.apply(event))
        }
    }
}

/// Server-Sent Events framing, independent of the network.
final class SSEFrameAssemblerTests: XCTestCase {

    func testMalformedDataCannotDisappearBeforeAValidFinish() throws {
        var assembler = HTTPTransport.SSEFrameAssembler()
        _ = try assembler.consume("data: {broken")
        XCTAssertThrowsError(try assembler.flush())
    }

    func testABlankLineDispatchesTheFrame() throws {
        var assembler = HTTPTransport.SSEFrameAssembler()
        XCTAssertNil(try assembler.consume(#"data: {"a": 1}"#).frame)
        let step = try assembler.consume("")
        XCTAssertEqual(step.frame?["a"] as? Int, 1)
        XCTAssertFalse(step.done)
    }

    /// The bug this guards against: a `[DONE]` that follows the last delta without a
    /// blank line between them used to drop that delta — typically the one carrying
    /// `finish_reason`.
    func testTheDoneSentinelFlushesThePendingFrameFirst() throws {
        var assembler = HTTPTransport.SSEFrameAssembler()
        _ = try assembler.consume(#"data: {"last": true}"#)
        let step = try assembler.consume("data: [DONE]")
        XCTAssertEqual(step.frame?["last"] as? Bool, true)
        XCTAssertTrue(step.done)
    }

    func testTheDoneSentinelAloneIsJustDone() throws {
        var assembler = HTTPTransport.SSEFrameAssembler()
        let step = try assembler.consume("data: [DONE]")
        XCTAssertNil(step.frame)
        XCTAssertTrue(step.done)
    }

    func testCommentsAndOtherFieldsAreIgnored() throws {
        var assembler = HTTPTransport.SSEFrameAssembler()
        XCTAssertNil(try assembler.consume(": keep-alive").frame)
        XCTAssertNil(try assembler.consume("event: message").frame)
        XCTAssertNil(try assembler.consume("id: 7").frame)
        _ = try assembler.consume(#"data: {"b": 2}"#)
        XCTAssertEqual(try assembler.consume("").frame?["b"] as? Int, 2)
    }

    /// A stream that ends without a trailing blank line still has a frame.
    func testFlushReturnsAFrameLeftAtTheEndOfTheStream() throws {
        var assembler = HTTPTransport.SSEFrameAssembler()
        _ = try assembler.consume(#"data: {"c":"#)
        _ = try assembler.consume("data: 3}")
        XCTAssertEqual(try assembler.flush()?["c"] as? Int, 3)
        XCTAssertNil(try assembler.flush(), "flushing clears the pending lines")
    }
}

/// Splitting a byte stream into SSE lines, whatever the terminator and the chunking.
final class ReadLinesTests: XCTestCase {

    private func stream(_ chunks: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
            continuation.finish()
        }
    }

    private func lines(_ chunks: [String]) async throws -> [String] {
        var collected: [String] = []
        try await HTTPTransport.readLines(from: stream(chunks), limit: 1_000_000) { line in
            collected.append(line)
            return true
        }
        return collected
    }

    func testSplitsOnLFIncludingEmptyLines() async throws {
        let result = try await lines(["data: a\n\ndata: b\n"])
        XCTAssertEqual(result, ["data: a", "", "data: b"])
    }

    func testALineCanSpanChunks() async throws {
        let result = try await lines(["data: {\"a\":", " 1}\n\n"])
        XCTAssertEqual(result, ["data: {\"a\": 1}", ""])
    }

    func testAFinalLineWithoutATerminatorIsStillALine() async throws {
        let result = try await lines(["data: tail"])
        XCTAssertEqual(result, ["data: tail"])
    }

    func testCRLFIsOneTerminator() async throws {
        let result = try await lines(["a\r\n\r\nb\r\n"])
        XCTAssertEqual(result, ["a", "", "b"])
    }

    /// The CR of a CRLF pair may be the last byte of one chunk and the LF the first of
    /// the next. Dispatching at the CR would insert a spurious empty line — an event
    /// boundary — when the LF arrived.
    func testCRLFSplitAcrossChunksIsStillOneTerminator() async throws {
        let result = try await lines(["a\r", "\nb\r\n"])
        XCTAssertEqual(result, ["a", "b"])
    }

    /// The SSE grammar allows a lone CR as a terminator.
    func testCROnlyIsATerminator() async throws {
        let result = try await lines(["a\r\rb\r"])
        XCTAssertEqual(result, ["a", "", "b"])
    }

    /// A single leading byte-order mark is ignored, even when it arrives on its own.
    func testALeadingBOMIsStripped() async throws {
        let whole = try await lines(["\u{FEFF}data: x\n"])
        XCTAssertEqual(whole, ["data: x"])
        let split = try await lines(["\u{FEFF}", "data: y\n"])
        XCTAssertEqual(split, ["data: y"])
    }

    func testHandlerCanStopTheRead() async throws {
        var seen: [String] = []
        try await HTTPTransport.readLines(from: stream(["one\ntwo\nthree\n"]), limit: 1_000) { line in
            seen.append(line)
            return line != "two"
        }
        XCTAssertEqual(seen, ["one", "two"])
    }

    func testRefusesABodyOverTheLimit() async {
        do {
            try await HTTPTransport.readLines(from: stream(["0123456789"]), limit: 5) { _ in true }
            XCTFail("expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? ResearchError, ResearchError.responseTooLarge)
        }
    }
}
