import XCTest
@testable import Vervellum

final class AboutViewTests: XCTestCase {

    /// The About pane interpolates the version into a `Text`; an optional there prints
    /// `Optional("0.3.1")`, so the line must go through `versionText`, which reads the
    /// raw Info.plist value and never wraps it in Optional.
    func testVersionTextIsNeverAnOptionalDescription() {
        let text = AboutView.versionText(Bundle.main)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("Optional"), "version rendered as \(text)")
    }

    func testVersionTextFallsBackForABundleWithoutOne() {
        // A bundle with no CFBundleShortVersionString (the Linux executable's, or a
        // bare test host) must still produce a readable line, not "Optional(nil)".
        XCTAssertEqual(AboutView.versionText(Bundle(for: XCTestCase.self)),
                       Bundle(for: XCTestCase.self)
                           .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                           ?? "unknown")
    }
}
