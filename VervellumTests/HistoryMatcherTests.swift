import XCTest
@testable import Vervellum

final class HistoryMatcherTests: XCTestCase {
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
