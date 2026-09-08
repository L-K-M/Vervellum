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
            XCTAssertTrue(error is ResearchError, "got \(error)")
        }
        XCTAssertTrue(lines.isEmpty, "the guard runs before the chunk does")
    }

    /// Both readers used to divide the budget by 60 and write "minutes", which reads as
    /// "did not finish within 0 minutes" for every budget shorter than one — and the
    /// model list's is thirty seconds.
    func testTheOverdueMessageIsSpelledInTheUnitTheBudgetIsIn() {
        XCTAssertTrue(HTTPTransport.tookTooLong(30).message.contains("30 seconds"),
                      HTTPTransport.tookTooLong(30).message)
        XCTAssertTrue(HTTPTransport.tookTooLong(HTTPTransport.deadline).message
            .contains("10 minutes"), HTTPTransport.tookTooLong(HTTPTransport.deadline).message)
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
