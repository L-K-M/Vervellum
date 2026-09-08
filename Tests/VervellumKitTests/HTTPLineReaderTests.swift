import Foundation
import XCTest
#if canImport(VervellumKit)
@testable import VervellumKit
#else
@testable import Vervellum
#endif

final class HTTPLineReaderTests: XCTestCase {

    func testEverySSELineEndingPreservesEmptyLinesAcrossChunkBoundaries() async throws {
        for newline in ["\n", "\r\n", "\r"] {
            let data = Data("data: café 🦊\(newline)\(newline)data: next\(newline)\(newline)".utf8)
            for split in 0...data.count {
                let lines = try await read([Data(data.prefix(split)), Data(data.dropFirst(split))])
                XCTAssertEqual(lines, ["data: café 🦊", "", "data: next", ""], "split \(split)")
            }
        }
    }

    func testOneByteChunksHandleMixedEndingsAndUTF8() async throws {
        let data = Data("a\r\nb\rc\n\r\nd 🦊".utf8)
        let lines = try await read(data.map { Data([$0]) })
        XCTAssertEqual(lines, ["a", "b", "c", "", "d 🦊"])
    }

    func testStripsOnlyTheLeadingUTF8BOM() async throws {
        let data = Data("\u{FEFF}data: first\r\rdata: \u{FEFF}second\r\r".utf8)
        let lines = try await read(data.map { Data([$0]) })
        XCTAssertEqual(lines, ["data: first", "", "data: \u{FEFF}second", ""])
    }

    func testTrailingCRDispatchesALineButDoesNotInventAnExtraOne() async throws {
        let lines = try await read([Data("one\rtwo\r".utf8)])
        XCTAssertEqual(lines, ["one", "two"])
    }

    func testKeepsTheFinalUnterminatedLine() async throws {
        let lines = try await read([Data("one\nlast".utf8)])
        XCTAssertEqual(lines, ["one", "last"])
    }

    func testEmptyStreamHasNoLines() async throws {
        let lines = try await read([])
        XCTAssertEqual(lines, [])
    }

    func testStopsWithoutDeliveringLaterLines() async throws {
        var lines: [String] = []
        try await HTTPTransport.readLines(from: stream([Data("first\r\nsecond\r\n".utf8)]),
                                          limit: HTTPTransport.maxStreamBytes) { line in
            lines.append(line)
            return false
        }
        XCTAssertEqual(lines, ["first"])
    }

    /// The wall clock is the caller's budget now, not the transport's ten-minute
    /// default. `URLRequest.timeoutInterval` cannot express "no longer than this": it
    /// restarts on every byte, so a host trickling one byte just under the limit
    /// satisfies it forever — which is why a caller that means a bound has to say this
    /// one too. Checked before the chunk is consumed, so a spent budget delivers
    /// nothing rather than one more line.
    func testAReadWithNoBudgetLeftStopsBeforeDeliveringALine() async {
        var lines: [String] = []
        do {
            try await HTTPTransport.readLines(from: stream([Data("first\n".utf8)]),
                                              limit: HTTPTransport.maxStreamBytes,
                                              deadline: -1) { line in
                lines.append(line)
                return true
            }
            XCTFail("Expected the spent budget to stop the read")
        } catch {
            // The budget's own error, not merely *a* `ResearchError` — the size cap and
            // the handler both throw those, so the weaker assertion passed for a guard
            // that had stopped being about the deadline at all.
            XCTAssertEqual(error as? ResearchError, HTTPTransport.tookTooLong(-1),
                           "expected the deadline's error, got \(error)")
        }
        XCTAssertTrue(lines.isEmpty, "the guard runs before the chunk does")
    }

    /// The budget is re-read between chunks, not once on the way in. A host that trickles
    /// keeps every individual wait short, so a check hoisted out of the loop would bound
    /// nothing at all — and the `-1` test above cannot tell the difference, because a
    /// budget spent before the first chunk fails either way.
    ///
    /// Five seconds of sleep against a one-second budget. The two clocks start in
    /// different places — the sleep from when the stream is built, the budget from when
    /// `readLines` is entered — so the headroom is the gap minus the budget, and at two
    /// seconds that was one second of tolerance for a cooperative pool that has not got
    /// round to this task yet. Four is not a proof either, but it is past what a loaded
    /// CI runner does between two adjacent statements. The green path does not pay for
    /// it: the read is expected to throw at one second and never waits for the chunk.
    func testABudgetThatRunsOutBetweenChunksStopsBeforeTheNextLine() async {
        var lines: [String] = []
        let trickle = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("first\n".utf8))
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continuation.yield(Data("second\n".utf8))
                continuation.finish()
            }
        }
        do {
            try await HTTPTransport.readLines(from: trickle,
                                              limit: HTTPTransport.maxStreamBytes,
                                              deadline: 1) { line in
                lines.append(line)
                return true
            }
            XCTFail("Expected the spent budget to stop the read")
        } catch {
            XCTAssertEqual(error as? ResearchError, HTTPTransport.tookTooLong(1),
                           "expected the deadline's error, got \(error)")
        }
        XCTAssertEqual(lines, ["first"], "the second line arrived after the budget was gone")
    }

    /// Both readers used to divide the budget by 60 and write "minutes", which reads as
    /// "did not finish within 0 minutes" for every budget shorter than one — and the
    /// model list's is thirty seconds.
    func testTheOverdueMessageIsSpelledInTheUnitTheBudgetIsIn() {
        let halfMinute = HTTPTransport.tookTooLong(30).message
        XCTAssertTrue(halfMinute.contains("30 seconds"), halfMinute)
        // The constant, pinned separately: feeding `deadline` in and expecting "10
        // minutes" out made this test a silent second home for that number, so raising
        // it would have failed here as a wording regression rather than as itself.
        XCTAssertEqual(HTTPTransport.deadline, 600, "the ten-minute default")
        let tenMinutes = HTTPTransport.tookTooLong(HTTPTransport.deadline).message
        XCTAssertTrue(tenMinutes.contains("10 minutes"), tenMinutes)
        // Floored rather than rounded to nearest, and the unit taken from the floored
        // value. The message is the reader's record of what the app did, so it may
        // understate the wait and never overstate it: 59.6 seconds reads as "59 seconds",
        // and the "1 minute" that rounding produced describes a wait nobody had.
        // Choosing the unit from the raw budget was the first version of the same bug and
        // reported it as "60 seconds".
        let almostAMinute = HTTPTransport.tookTooLong(59.6).message
        XCTAssertTrue(almostAMinute.contains("59 seconds"), almostAMinute)
        XCTAssertFalse(almostAMinute.contains("minute"),
                       "a 59.6-second budget must not be reported as a minute")
        // Both sides of the unit switch, and both singulars. No budget in the app is one
        // of either today, which is exactly why the wording would rot unnoticed.
        let oneMinute = HTTPTransport.tookTooLong(60).message
        XCTAssertTrue(oneMinute.contains("1 minute."), oneMinute)
        let oneSecond = HTTPTransport.tookTooLong(1).message
        XCTAssertTrue(oneSecond.contains("1 second."), oneSecond)
        // The floor under the floor. No caller passes a budget below a second, and
        // flooring one would otherwise write the "0 seconds" this helper exists to avoid
        // — a negative budget, which the deadline tests do pass, read "-1 seconds".
        for tiny in [0.4, 0.0, -1.0] {
            XCTAssertTrue(HTTPTransport.tookTooLong(tiny).message.contains("1 second."),
                          "\(tiny): \(HTTPTransport.tookTooLong(tiny).message)")
        }
    }

    func testPropagatesHandlerErrors() async {
        do {
            try await HTTPTransport.readLines(from: stream([Data("line\n".utf8)]),
                                              limit: HTTPTransport.maxStreamBytes) { _ in
                throw ResearchError.cancelled
            }
            XCTFail("Expected the handler error")
        } catch {
            XCTAssertEqual(error as? ResearchError, .cancelled)
        }
    }

    func testPropagatesAnUpstreamCancellation() async {
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("first\n".utf8))
            continuation.finish(throwing: ResearchError.cancelled)
        }
        var lines: [String] = []
        do {
            try await HTTPTransport.readLines(from: body, limit: HTTPTransport.maxStreamBytes) { line in
                lines.append(line)
                return true
            }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? ResearchError, .cancelled)
        }
        XCTAssertEqual(lines, ["first"])
    }

    func testByteLimitIncludesTerminatorsAndBOM() async throws {
        let data = Data("\u{FEFF}é\r\n".utf8)
        let lines = try await read([data], limit: data.count)
        XCTAssertEqual(lines, ["é"])

        do {
            _ = try await read(data.map { Data([$0]) }, limit: data.count - 1)
            XCTFail("Expected the byte cap")
        } catch {
            XCTAssertEqual(error as? ResearchError, .responseTooLarge)
        }
    }

    // Many tiny lines and a fragmented long line exercise both former rescan paths.
    func testLargeInputsAreLossless() async throws {
        let lineCount = 50_000
        let lines = try await read([Data(String(repeating: "x\n", count: lineCount).utf8)])
        XCTAssertEqual(lines.count, lineCount)
        XCTAssertTrue(lines.allSatisfy { $0 == "x" })

        let chunk = Data(repeating: 0x61, count: 1_024)
        let chunks = Array(repeating: chunk, count: 256)
        let longLine = try await read(chunks)
        XCTAssertEqual(longLine, [String(repeating: "a", count: chunk.count * chunks.count)])
    }

    private func read(_ chunks: [Data], limit: Int = HTTPTransport.maxStreamBytes) async throws -> [String] {
        var lines: [String] = []
        try await HTTPTransport.readLines(from: stream(chunks), limit: limit) { line in
            lines.append(line)
            return true
        }
        return lines
    }

    private func stream(_ chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}
