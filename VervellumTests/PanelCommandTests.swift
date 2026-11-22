import XCTest
@testable import Vervellum

final class PanelCommandTests: XCTestCase {

    /// Every command the panel window can post round-trips through its raw value, which
    /// is the notification contract `PanelRootView` switches on.
    func testEveryCommandRawValueRoundTrips() {
        for command in PanelCommand.allCases {
            XCTAssertEqual(PanelCommand(rawValue: command.rawValue), command)
        }
    }

    /// The scroll commands exist so ⌘↑/⌘↓ can reach the thread's scroll view; pinning
    /// their raw values keeps a rename from silently unhooking `ResearchPanel`'s posts.
    func testScrollCommandRawValues() {
        XCTAssertEqual(PanelCommand.scrollToTop.rawValue, "scrollToTop")
        XCTAssertEqual(PanelCommand.scrollToBottom.rawValue, "scrollToBottom")
    }
}
