import XCTest
@testable import Vervellum

final class HistoryMatcherTests: XCTestCase {
    func testCancelledQueryStopsBeforeMatchingAnotherThread() async {
        let worker = HistoryMatcher(needle: "answer")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.matches(in: ThreadLibrary(threads: [ResearchThread()]))
        }
        do {
            _ = try await task.value
            XCTFail("A superseded query should release its worker")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSameQueryTracksEditedAndRemovedThreads() async throws {
        let search = HistoryMatcher(needle: "needle")
        var thread = ResearchThread()
        thread.turns = [ResearchTurn(question: "Unrelated")]
        var match = try await search.matches(in: ThreadLibrary(threads: [thread]))
        XCTAssertTrue(match.isEmpty)
        thread.turns[0].answer = "Needle in the answer"
        match = try await search.matches(in: ThreadLibrary(threads: [thread]))
        XCTAssertEqual(match, [thread.id])
        match = try await search.matches(in: ThreadLibrary())
        XCTAssertTrue(match.isEmpty)
    }
}
