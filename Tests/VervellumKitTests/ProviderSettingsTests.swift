import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class ProviderSettingsTests: XCTestCase {

    // MARK: URL shaping

    /// Providers document their endpoint at three different levels of completeness,
    /// and users paste whichever their provider's docs show.
    func testAppendsChatCompletionsToAVersionedBase() {
        XCTAssertEqual(ProviderSettings.chatCompletionsURL(from: "https://api.example.com/v1")?.absoluteString,
                       "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(ProviderSettings.chatCompletionsURL(from: "https://api.example.com/v1/")?.absoluteString,
                       "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(ProviderSettings.chatCompletionsURL(from: "https://api.example.com/api/paas/v4")?.absoluteString,
                       "https://api.example.com/api/paas/v4/chat/completions")
    }

    func testAppendsChatCompletionsToABareHost() {
        XCTAssertEqual(ProviderSettings.chatCompletionsURL(from: "https://api.example.com")?.absoluteString,
                       "https://api.example.com/chat/completions")
    }

    func testPreservesAFullOrCustomPath() {
        XCTAssertEqual(
            ProviderSettings.chatCompletionsURL(from: "https://api.example.com/v1/chat/completions")?.absoluteString,
            "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(
            ProviderSettings.chatCompletionsURL(from: "https://gateway.example.com/llm/route")?.absoluteString,
            "https://gateway.example.com/llm/route")
    }

    // MARK: Endpoint hygiene

    func testRejectsPlainHTTPToARemoteHost() {
        XCTAssertNil(ProviderSettings.chatCompletionsURL(from: "http://api.example.com/v1"))
    }

    /// A local model server has no certificate; refusing HTTP outright would make
    /// Ollama and llama.cpp unusable for no security gain.
    func testAllowsHTTPOnLoopback() {
        XCTAssertNotNil(ProviderSettings.chatCompletionsURL(from: "http://localhost:11434/v1"))
        XCTAssertNotNil(ProviderSettings.chatCompletionsURL(from: "http://127.0.0.1:8080/v1"))
    }

    /// A credential in the URL would leak into logs and Referer headers. Keys belong
    /// in a header.
    func testRejectsURLsCarryingUserInfo() {
        XCTAssertNil(ProviderSettings.chatCompletionsURL(from: "https://secret@api.example.com/v1"))
        XCTAssertNil(ProviderSettings.chatCompletionsURL(from: "https://user:pass@api.example.com/v1"))
    }

    func testRejectsEmptyAndHostlessInput() {
        XCTAssertNil(ProviderSettings.chatCompletionsURL(from: ""))
        XCTAssertNil(ProviderSettings.chatCompletionsURL(from: "   "))
        XCTAssertNil(ProviderSettings.chatCompletionsURL(from: "https:/v1"))
    }

    // MARK: Readiness

    func testReportsEveryMissingPiece() {
        let problems = ProviderSettings(modelEndpoint: "", modelName: "")
            .problems(hasModelKey: false, hasSearchKey: false)
        XCTAssertEqual(problems.count, 3)
    }

    /// A local model server needs no key, so a missing model key must not block a run.
    func testAModelKeyIsOptional() {
        let settings = ProviderSettings(modelEndpoint: "https://api.example.com/v1", modelName: "m")
        XCTAssertTrue(settings.problems(hasModelKey: false, hasSearchKey: true).isEmpty)
    }

    func testASearchKeyIsRequired() {
        let settings = ProviderSettings(modelEndpoint: "https://api.example.com/v1", modelName: "m")
        XCTAssertEqual(settings.problems(hasModelKey: true, hasSearchKey: false).count, 1)
    }

    /// `/direct` never contacts the search server, so a broken search endpoint — or no
    /// search key at all — must not block the one mode that still works when search is
    /// misconfigured. That is exactly when someone reaches for it.
    func testDirectModeIgnoresTheSearchConfiguration() {
        let settings = ProviderSettings(modelEndpoint: "https://api.example.com/v1",
                                        modelName: "m",
                                        searchEndpoint: "not-a-url")
        XCTAssertTrue(settings.problems(hasModelKey: true, hasSearchKey: false,
                                        requiresSearch: false).isEmpty)
        XCTAssertFalse(settings.problems(hasModelKey: true, hasSearchKey: false).isEmpty)
    }

    /// A missing *model* endpoint still blocks direct mode: that one it does contact.
    func testDirectModeStillNeedsTheModelEndpoint() {
        let settings = ProviderSettings(modelEndpoint: "", modelName: "")
        XCTAssertEqual(settings.problems(hasModelKey: true, hasSearchKey: true,
                                         requiresSearch: false).count, 2)
    }

    func testRejectsANonHTTPSSearchEndpoint() {
        let settings = ProviderSettings(modelEndpoint: "https://api.example.com/v1",
                                        modelName: "m",
                                        searchEndpoint: "http://search.example.com/mcp")
        XCTAssertFalse(settings.problems(hasModelKey: true, hasSearchKey: true).isEmpty)
    }

    // MARK: Provider profiles

    /// The single-provider initializer is the migration path for a settings file that
    /// predates the list, so the profile it makes has to land on the account the old
    /// build's Keychain item is already under.
    func testTheSingleProviderInitializerKeepsTheLegacyAccount() {
        let settings = ProviderSettings(modelEndpoint: "https://api.example.com/v1", modelName: "m")
        XCTAssertEqual(settings.modelProfiles.count, 1)
        XCTAssertEqual(settings.modelProfiles.first?.keyAccount, SecretAccount.modelAPIKey.rawValue)
        XCTAssertEqual(settings.selectedModel?.model, "m")
    }

    /// A second provider gets a slot of its own, or one key would answer for both.
    func testAnAddedProviderGetsItsOwnSecretAccount() {
        let added = ModelProfile.new(name: "Local", endpoint: "http://localhost:11434/v1", model: "llama")
        XCTAssertNotEqual(added.keyAccount, SecretAccount.modelAPIKey.rawValue)
        XCTAssertTrue(added.keyAccount.hasPrefix(SecretAccount.modelAPIKey.rawValue + "."))
        XCTAssertEqual(added.secretAccount.rawValue, added.keyAccount)
    }

    /// A settings file that lost its selection must degrade to "the one at the top",
    /// not to "not configured".
    func testAnUnknownSelectionFallsBackToTheFirstProvider() {
        let first = ModelProfile.new(name: "First", endpoint: "https://a.example.com/v1", model: "a")
        let second = ModelProfile.new(name: "Second", endpoint: "https://b.example.com/v1", model: "b")
        let settings = ProviderSettings(modelProfiles: [first, second], selectedModelID: UUID())
        XCTAssertEqual(settings.selectedModel?.id, first.id)
        XCTAssertEqual(settings.modelName, "a")
    }

    func testSelectingByNameMatchesTheNameTheIdentifierAndAPrefix() {
        let fast = ModelProfile.new(name: "Fast", endpoint: "https://a.example.com/v1", model: "gpt-4o-mini")
        let big = ModelProfile.new(name: "Careful", endpoint: "https://b.example.com/v1", model: "gpt-4o")
        var settings = ProviderSettings(modelProfiles: [fast, big], selectedModelID: fast.id)

        XCTAssertTrue(settings.selectModel(named: "careful"))
        XCTAssertEqual(settings.selectedModel?.id, big.id)

        XCTAssertTrue(settings.selectModel(named: "gpt-4o-mini"))
        XCTAssertEqual(settings.selectedModel?.id, fast.id)

        XCTAssertTrue(settings.selectModel(named: "car"))
        XCTAssertEqual(settings.selectedModel?.id, big.id)
    }

    /// An exact match wins over a prefix, or "/model gpt-4o" would land on whichever
    /// longer identifier happened to be listed first.
    func testAnExactMatchBeatsAPrefix() {
        let mini = ModelProfile.new(name: "Mini", endpoint: "https://a.example.com/v1", model: "gpt-4o-mini")
        let full = ModelProfile.new(name: "Full", endpoint: "https://b.example.com/v1", model: "gpt-4o")
        var settings = ProviderSettings(modelProfiles: [mini, full], selectedModelID: mini.id)
        XCTAssertTrue(settings.selectModel(named: "gpt-4o"))
        XCTAssertEqual(settings.selectedModel?.id, full.id)
    }

    /// Nothing changes when nothing matches: researching with a model the user did not
    /// name is worse than telling them there is no such model.
    func testAnUnmatchedNameChangesNothing() {
        let only = ModelProfile.new(name: "Only", endpoint: "https://a.example.com/v1", model: "a")
        var settings = ProviderSettings(modelProfiles: [only], selectedModelID: only.id)
        XCTAssertFalse(settings.selectModel(named: "something else"))
        XCTAssertFalse(settings.selectModel(named: "   "))
        XCTAssertEqual(settings.selectedModel?.id, only.id)
    }

    /// The single-provider accessors are how the Linux front end and every older
    /// settings file still write. They must edit the selected profile in place rather
    /// than flattening the list.
    func testWritingThroughTheSingleProviderAccessorsEditsOnlyTheSelectedProfile() {
        let first = ModelProfile.new(name: "First", endpoint: "https://a.example.com/v1", model: "a")
        let second = ModelProfile.new(name: "Second", endpoint: "https://b.example.com/v1", model: "b")
        var settings = ProviderSettings(modelProfiles: [first, second], selectedModelID: second.id)

        settings.modelName = "changed"
        settings.modelEndpoint = "https://c.example.com/v1"

        XCTAssertEqual(settings.modelProfiles.count, 2)
        XCTAssertEqual(settings.modelProfiles[0].model, "a", "The unselected profile is untouched")
        XCTAssertEqual(settings.modelProfiles[1].model, "changed")
        XCTAssertEqual(settings.modelProfiles[1].endpoint, "https://c.example.com/v1")
        XCTAssertEqual(settings.modelProfiles[1].keyAccount, second.keyAccount,
                       "Editing a profile must not move its key")
    }

    func testWritingThroughTheAccessorsCreatesAProfileWhenTheListIsEmpty() {
        var settings = ProviderSettings(modelProfiles: [])
        settings.modelEndpoint = "https://api.example.com/v1"
        settings.modelName = "m"
        XCTAssertEqual(settings.modelProfiles.count, 1)
        XCTAssertEqual(settings.modelProfiles.first?.keyAccount, SecretAccount.modelAPIKey.rawValue)
        XCTAssertEqual(settings.selectedModel?.model, "m")
    }

    /// Only the selected provider is validated: a second one the user is halfway
    /// through configuring must not block a question asked with the first.
    func testValidationLooksOnlyAtTheSelectedProvider() {
        let good = ModelProfile.new(name: "Good", endpoint: "https://a.example.com/v1", model: "a")
        let halfDone = ModelProfile.new(name: "Half", endpoint: "", model: "")
        let settings = ProviderSettings(modelProfiles: [good, halfDone], selectedModelID: good.id)
        XCTAssertTrue(settings.problems(hasModelKey: true, hasSearchKey: true).isEmpty)
    }

    func testProfilesRoundTripThroughTheEncodedForm() throws {
        let profiles = [
            ModelProfile.new(name: "First", endpoint: "https://a.example.com/v1", model: "a"),
            ModelProfile.new(name: "", endpoint: "http://localhost:11434/v1", model: "llama"),
        ]
        let encoded = try XCTUnwrap(ProviderSettings.encodeModelProfiles(profiles))
        XCTAssertEqual(ProviderSettings.decodeModelProfiles(encoded), profiles)
    }

    /// A list that will not parse costs the extra profiles, never the ability to launch.
    func testAnUnreadableProfileListDecodesToNil() {
        XCTAssertNil(ProviderSettings.decodeModelProfiles("{ not json"))
        XCTAssertNil(ProviderSettings.decodeModelProfiles(""))
    }

    /// A field added later must not make an existing settings file unreadable — the
    /// recovery from that is a user re-pasting every endpoint they had configured.
    func testAProfileMissingFieldsStillDecodes() {
        let sparse = #"[{"endpoint":"https://a.example.com/v1","model":"a"}]"#
        let decoded = ProviderSettings.decodeModelProfiles(sparse)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.endpoint, "https://a.example.com/v1")
        XCTAssertFalse(decoded?.first?.keyAccount.isEmpty ?? true,
                       "A profile with no recorded account still gets one")
    }

    /// A profile is never listed as a blank row.
    func testDisplayNameFallsBackThroughTheModelToTheHost() {
        XCTAssertEqual(ModelProfile.new(name: "Named", endpoint: "https://a.example.com", model: "m")
            .displayName, "Named")
        XCTAssertEqual(ModelProfile.new(endpoint: "https://a.example.com", model: "m")
            .displayName, "m")
        XCTAssertEqual(ModelProfile.new(endpoint: "https://api.example.com/v1")
            .displayName, "api.example.com")
        XCTAssertEqual(ModelProfile.new().displayName, "Unnamed provider")
    }
}
