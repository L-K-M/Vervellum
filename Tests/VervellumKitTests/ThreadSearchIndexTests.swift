import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class ThreadSearchIndexTests: XCTestCase {

    private func makeLibrary() -> ThreadLibrary {
        var first = ResearchThread()
        var turn = ResearchTurn(question: "Why is the sky blue?")
        turn.answer = "Rayleigh scattering, mostly."
        turn.stage = .complete
        first.turns = [turn]

        var second = ResearchThread()
        var other = ResearchTurn(question: "Best pizza in Naples?")
        other.answer = "L'Antica Pizzeria da Michele comes up often."
        other.stage = .complete
        second.turns = [other]

        var library = ThreadLibrary()
        library.upsert(first)
        library.upsert(second)
        return library
    }

    func testEmptyQueryReturnsEverythingNewestFirst() {
        let library = makeLibrary()
        let index = ThreadSearchIndex(library: library)
        XCTAssertEqual(index.search("  ", in: library).map(\.id),
                       library.search("  ").map(\.id))
        XCTAssertEqual(index.search("", in: library).count, 2)
    }

    func testMatchesTheSameThreadsAsTheLibrarySearch() {
        let library = makeLibrary()
        let index = ThreadSearchIndex(library: library)
        for query in ["sky", "RAYLEIGH", "pizza", "naples", "michele", "absent"] {
            XCTAssertEqual(index.search(query, in: library).map(\.id),
                           library.search(query).map(\.id),
                           "query: \(query)")
        }
    }

    /// The title is derived from the first question, so a title-shaped query must
    /// match even when the question list is what carries the text.
    func testMatchesOnQuestionAndAnswerText() {
        let library = makeLibrary()
        let index = ThreadSearchIndex(library: library)
        XCTAssertEqual(index.search("scattering", in: library).count, 1)
        XCTAssertEqual(index.search("sky", in: library).count, 1)
    }
}
