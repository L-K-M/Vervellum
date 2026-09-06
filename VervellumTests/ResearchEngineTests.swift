import XCTest
@testable import Vervellum

final class ResearchEngineTests: XCTestCase {
    func testLateCompletionCannotOverwriteStop() {
        let engine = ResearchEngine(preferences: CorePreferences(store: MemorySettingsStore()),
                                    secrets: EphemeralSecretStore())
        // Missing configuration fails locally; no credentials or network are used.
        engine.ask("Question")
        engine.cancel()
        XCTAssertEqual(engine.thread.turns.last?.stage, .cancelled)

        let drained = expectation(description: "Queued runner callbacks drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertFalse(engine.isRunning)
            XCTAssertEqual(engine.thread.turns.last?.stage, .cancelled)
            drained.fulfill()
        }
        wait(for: [drained], timeout: 3)
    }
}
