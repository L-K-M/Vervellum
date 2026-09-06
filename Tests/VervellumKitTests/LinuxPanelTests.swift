#if os(Linux)
import XCTest
@testable import VervellumKit

final class LinuxPanelTests: XCTestCase {

    /// The shared text-scale preference reaches the GTK thread through one CSS rule.
    func testTheStylesheetScalesTheThread() {
        XCTAssertTrue(LinuxPanel.stylesheet(textScale: 1.0).contains(".thread { font-size: 1.00em; }"))
        XCTAssertTrue(LinuxPanel.stylesheet(textScale: 1.25).contains(".thread { font-size: 1.25em; }"))
        // The rest of the sheet survives the scaling rule.
        XCTAssertTrue(LinuxPanel.stylesheet(textScale: 1.0).contains(".composer {"))
    }
}
#endif
