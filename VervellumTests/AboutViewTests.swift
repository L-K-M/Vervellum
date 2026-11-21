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
        // Canary: fail loudly and specifically if platform behavior ever changes and
        // Bundle() stops being plist-free.
        XCTAssertNil(Bundle().object(forInfoDictionaryKey: "CFBundleShortVersionString"),
                     "Bundle() unexpectedly has a CFBundleShortVersionString; the fallback path is no longer exercised")
        XCTAssertEqual(AboutView.versionText(Bundle()), "unknown")
        XCTAssertEqual(AboutView.versionLine(Bundle()), "Version unknown")
    }

    func testVersionTextFallsBackForAnEmptyVersionString() {
        // A bundle that ships CFBundleShortVersionString = "" must read as "unknown",
        // not render "Version " with nothing after it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AboutViewTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? (["CFBundleShortVersionString": ""] as NSDictionary)
            .write(to: dir.appendingPathComponent("Info.plist"), atomically: true)
        guard let bundle = Bundle(path: dir.path) else {
            XCTFail("could not load the fixture bundle")
            return
        }
        XCTAssertEqual(AboutView.versionText(bundle), "unknown")
    }
}
