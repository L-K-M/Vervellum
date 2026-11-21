import XCTest
@testable import Vervellum

final class AboutViewTests: XCTestCase {

    /// The About pane renders the whole line through `versionLine`; an optional
    /// interpolated in the view prints `Optional(...)`, so the rendered line must
    /// never contain that.
    func testVersionLineIsNeverAnOptionalDescription() {
        let line = AboutView.versionLine(.main)
        XCTAssertFalse(line.contains("Optional"), "version line rendered as \(line)")
        XCTAssertTrue(line.hasPrefix("Version "), "line rendered as \(line)")
        XCTAssertGreaterThan(line.count, "Version ".count, "line rendered as \(line)")
    }

    func testVersionTextFallsBackForABundleWithoutOne() {
        // `Bundle()` is an uninitialized bundle with no Info.plist, so this exercises
        // the fallback path deterministically — not the test host's own plist.
        XCTAssertEqual(AboutView.versionText(Bundle()), "unknown")
        XCTAssertEqual(AboutView.versionLine(Bundle()), "Version unknown")
    }
}
