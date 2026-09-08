import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// `ResearchRunner.Environment` carries every configured provider's key for the length
/// of a turn, which makes it the single most expensive value in the app to print. The
/// rule used to be a note in its doc comment; these tests are the rule.
final class ResearchEnvironmentTests: XCTestCase {

    private func environment() -> (ResearchRunner.Environment, ModelProfile) {
        let profile = ModelProfile.new(name: "Alpha",
                                       endpoint: "https://alpha.example.com/v1",
                                       model: "alpha")
        let spare = ModelProfile.new(name: "Beta",
                                     endpoint: "https://beta.example.com/v1",
                                     model: "beta")
        let settings = ProviderSettings(modelProfiles: [profile, spare],
                                        selectedModelID: profile.id)
        return (ResearchRunner.Environment(settings: settings,
                                           modelKey: "sk-alpha-000000000000",
                                           searchKey: "sk-search-00000000000",
                                           readerKey: "sk-reader-00000000000",
                                           modelKeys: [profile.id: "sk-alpha-000000000000",
                                                       spare.id: "sk-beta-0000000000000"]),
                profile)
    }

    /// Interpolation, not just the debugger: `print(environment)` and `"\(environment)"`
    /// both take `description`, and a hurried log line during a failing turn is the way
    /// this value actually gets printed.
    func testPrintingAnEnvironmentPrintsNoKeys() {
        let (subject, _) = environment()
        for rendering in ["\(subject)", String(describing: subject), String(reflecting: subject)] {
            XCTAssertFalse(rendering.contains("sk-alpha-000000000000"), rendering)
            XCTAssertFalse(rendering.contains("sk-beta-0000000000000"), rendering)
            XCTAssertFalse(rendering.contains("sk-search-00000000000"), rendering)
            XCTAssertFalse(rendering.contains("sk-reader-00000000000"), rendering)
        }
    }

    /// Redacted is not the same as useless. Which providers had a key, and whether the
    /// search and reader ones were there at all, is what the question "why did this turn
    /// fail" actually needs.
    func testAnEnvironmentStillSaysWhichProvidersHadAKey() {
        let (subject, profile) = environment()
        let rendering = "\(subject)"
        XCTAssertTrue(rendering.contains(profile.id.uuidString), rendering)
        XCTAssertTrue(rendering.contains("searchKey: present"), rendering)
    }

    /// The absent case has to be distinguishable from the present one, or the rendering
    /// answers nothing — a local llama.cpp provider with no key is a supported setup.
    func testAnEnvironmentSaysWhenASecretIsAbsent() {
        let settings = ProviderSettings(modelProfiles: [], selectedModelID: nil)
        let subject = ResearchRunner.Environment(settings: settings,
                                                 modelKey: nil,
                                                 searchKey: nil,
                                                 readerKey: nil)
        XCTAssertTrue("\(subject)".contains("searchKey: absent"), "\(subject)")
        XCTAssertTrue("\(subject)".contains("modelKeys: []"), "\(subject)")
    }
}
