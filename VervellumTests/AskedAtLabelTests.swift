import XCTest
@testable import Vervellum

final class AskedAtLabelTests: XCTestCase {

    /// The label is an age. A bare duration beside an answer reads as how long the
    /// research took.
    @MainActor
    func testTheLabelSaysHowLongAgoRatherThanADuration() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 86_400
        for (age, expected) in [(30.0, "just now"), (7_200.0, "2h ago"), (23 * day, "3w ago")] {
            XCTAssertEqual(AskedAtLabel.text(for: now.addingTimeInterval(-age), now: now), expected)
        }
    }
}
