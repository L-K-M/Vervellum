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

    private func environment() -> (ResearchRunner.Environment, ModelProfile, ModelProfile) {
        // A key in the endpoint's *query*, which is where gateways that take one put it
        // and where a person pastes one. The URL validator refuses credentials in a URL's
        // userinfo, which is a different part of the address — so nothing upstream stops
        // this, and printing `settings` whole would have carried it into the log.
        let profile = ModelProfile.new(name: "Alpha",
                                       endpoint: "https://alpha.example.com/v1?api-key=sk-in-url-0000",
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
                profile, spare)
    }

    /// Interpolation, not just the debugger: `print(environment)` and `"\(environment)"`
    /// both take `description`, and a hurried log line during a failing turn is the way
    /// this value actually gets printed.
    func testPrintingAnEnvironmentPrintsNoKeys() {
        let (subject, _, _) = environment()
        for rendering in ["\(subject)", String(describing: subject), String(reflecting: subject)] {
            // The messages say what went wrong without repeating the rendering. A test
            // whose job is keeping key material out of logs must not be the thing that
            // writes it to CI's, and these fixtures will not stay synthetic forever.
            XCTAssertFalse(rendering.contains("sk-alpha-000000000000"), "the model key leaked")
            XCTAssertFalse(rendering.contains("sk-beta-0000000000000"), "the spare's key leaked")
            XCTAssertFalse(rendering.contains("sk-search-00000000000"), "the search key leaked")
            XCTAssertFalse(rendering.contains("sk-reader-00000000000"), "the reader key leaked")
            // The catch-all, which the four above are not: a rendering that showed the
            // first eight characters of a key, or the endpoint the key was pasted into,
            // would satisfy every one of them. Nothing legitimate here contains "sk-".
            XCTAssertFalse(rendering.contains("sk-"), "key material leaked")
        }
    }

    /// Reflection, which is the way neither description above is consulted. `dump()`
    /// walks the stored properties, and a debugger, a crash reporter and most structured
    /// loggers reach a value the same way — so redacting `description` alone would have
    /// moved this hole rather than closed it.
    func testReflectingOverAnEnvironmentReflectsNoKeys() {
        let (subject, _, _) = environment()
        var dumped = ""
        dump(subject, to: &dumped)
        // Same catch-all as above, and the same reason for not echoing what failed.
        XCTAssertFalse(dumped.contains("sk-"), "reflection leaked key material")
        XCTAssertTrue(dumped.contains("modelKey: present"),
                      "and it still says what the redacted description says")
    }

    /// Redacted is not the same as useless. Which providers had a key, and whether the
    /// search and reader ones were there at all, is what the question "why did this turn
    /// fail" actually needs.
    func testAnEnvironmentStillSaysWhichProvidersHadAKey() {
        let (subject, profile, spare) = environment()
        let rendering = "\(subject)"
        // The debug rendering too. The leak test covers three ways of printing this
        // value and the usefulness tests covered one, so `debugDescription` could have
        // drifted into redacted-but-useless — which is the rendering `debugPrint` and a
        // debugger's quick-look both reach for — with nothing failing.
        XCTAssertTrue(String(reflecting: subject).contains("modelKey: present"),
                      "the debug rendering says less than the plain one")
        XCTAssertTrue(rendering.contains(profile.id.uuidString), "the selection is not named")
        // The spare too. Naming only the selected one would satisfy a rendering that
        // reported a bare count and never said which providers the map covers — which is
        // the question this is for, since the chain may reach any of them.
        XCTAssertTrue(rendering.contains(spare.id.uuidString), "the spare is not named")
        // All three, not just the one: a rendering that hard-coded "present" for the
        // search key and dropped the others would have passed on `searchKey` alone.
        XCTAssertTrue(rendering.contains("modelKey: present"), "modelKey is not reported")
        XCTAssertTrue(rendering.contains("searchKey: present"), "searchKey is not reported")
        XCTAssertTrue(rendering.contains("readerKey: present"), "readerKey is not reported")
        XCTAssertTrue(rendering.contains("model: alpha"), "the model is not named")
        // The switch as well as the count: with fallback off `providers` reads 1 whatever
        // is configured, so the count alone cannot answer "why was my spare not tried".
        XCTAssertTrue(rendering.contains("fallback: true"), "the fallback switch is not reported")
    }

    /// The absent case has to be distinguishable from the present one, or the rendering
    /// answers nothing — a local llama.cpp provider with no key is a supported setup.
    func testAnEnvironmentSaysWhenASecretIsAbsent() {
        let settings = ProviderSettings(modelProfiles: [], selectedModelID: nil)
        let subject = ResearchRunner.Environment(settings: settings,
                                                 modelKey: nil,
                                                 searchKey: nil,
                                                 readerKey: nil)
        XCTAssertTrue("\(subject)".contains("modelKey: absent"), "modelKey is not reported")
        XCTAssertTrue("\(subject)".contains("searchKey: absent"), "searchKey is not reported")
        XCTAssertTrue("\(subject)".contains("readerKey: absent"), "readerKey is not reported")
        XCTAssertTrue("\(subject)".contains("modelKeys: []"), "an empty map is not reported")
    }
}
