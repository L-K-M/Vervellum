import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The settings both platforms share, tested against an in-memory store so the suite
/// never touches a real user's preferences on either.
final class CorePreferencesTests: XCTestCase {

    private func preferences(_ initial: [String: Any] = [:]) -> CorePreferences {
        CorePreferences(store: MemorySettingsStore(initial))
    }

    func testDefaultsForAnEmptyStore() {
        let settings = preferences()
        XCTAssertTrue(settings.historyEnabled)
        XCTAssertTrue(settings.showProcessTrail)
        XCTAssertTrue(settings.submitOnReturn)
        XCTAssertEqual(settings.textScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(settings.providerSettings.searchEndpoint, ProviderSettings.defaultSearchEndpoint)
    }

    /// On by design: a false positive costs a re-typed word, a false negative sends a
    /// live credential to a third party.
    func testRedactionIsOnByDefault() {
        XCTAssertTrue(preferences().redactSecrets)
    }

    func testRoundTripsThroughTheStore() {
        let store = MemorySettingsStore()
        let settings = CorePreferences(store: store)
        settings.textScale = 1.25
        settings.submitOnReturn = false
        settings.redactSecrets = false
        settings.providerSettings = ProviderSettings(modelEndpoint: "https://api.example.com/v1",
                                                     modelName: "some-model",
                                                     searchEndpoint: "https://search.example.com/mcp")

        let reloaded = CorePreferences(store: store)
        XCTAssertEqual(reloaded.textScale, 1.25, accuracy: 0.001)
        XCTAssertFalse(reloaded.submitOnReturn)
        XCTAssertFalse(reloaded.redactSecrets)
        XCTAssertEqual(reloaded.providerSettings.modelName, "some-model")
    }

    /// Clamping on *read* is what makes a corrupted settings file survivable without a
    /// reset — the alternative is an app the user has to delete a file to recover.
    func testClampsCorruptedValuesOnRead() {
        XCTAssertEqual(preferences(["textScale": 99.0]).textScale, 1.4, accuracy: 0.001)
        XCTAssertEqual(preferences(["textScale": 0.0]).textScale, 0.85, accuracy: 0.001)
        XCTAssertEqual(preferences(["textScale": Double.nan]).textScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(preferences(["textScale": Double.infinity]).textScale, 1.0, accuracy: 0.001)
    }

    func testClampsOnWrite() {
        let settings = preferences()
        settings.textScale = -5
        XCTAssertEqual(settings.textScale, 0.85, accuracy: 0.001)
    }

    /// An emptied search endpoint reverts to the documented default rather than leaving
    /// the app with no search at all.
    func testAnEmptySearchEndpointRevertsToTheDefault() {
        let settings = preferences()
        settings.providerSettings = ProviderSettings(modelEndpoint: "https://api.example.com/v1",
                                                     modelName: "m",
                                                     searchEndpoint: "   ")
        XCTAssertEqual(settings.providerSettings.searchEndpoint, ProviderSettings.defaultSearchEndpoint)
    }

    func testChangesAreAnnounced() {
        let settings = preferences()
        var announcements = 0
        settings.onChange = { announcements += 1 }
        settings.textScale = 1.1
        settings.historyEnabled = false
        settings.providerSettings = ProviderSettings(modelEndpoint: "https://a.example.com/v1",
                                                     modelName: "m")
        XCTAssertEqual(announcements, 3)
    }

    // MARK: Provider profiles

    /// The upgrade path. A settings file written before providers were a list has only
    /// `modelEndpoint` and `modelName`, and must become one profile on the account that
    /// build's Keychain item is already under — or the user re-pastes their key.
    func testASettingsFileWithoutAListMigratesToOneProfileOnTheLegacyAccount() {
        let settings = preferences(["modelEndpoint": "https://api.example.com/v1",
                                    "modelName": "legacy-model"]).providerSettings
        XCTAssertEqual(settings.modelProfiles.count, 1)
        XCTAssertEqual(settings.modelProfiles.first?.keyAccount, SecretAccount.modelAPIKey.rawValue)
        XCTAssertEqual(settings.modelName, "legacy-model")
        XCTAssertEqual(settings.modelEndpoint, "https://api.example.com/v1")
    }

    func testAStoredListIsAuthoritativeAndKeepsItsSelection() {
        let store = MemorySettingsStore()
        let settings = CorePreferences(store: store)
        let first = ModelProfile.new(name: "First", endpoint: "https://a.example.com/v1", model: "a")
        let second = ModelProfile.new(name: "Second", endpoint: "https://b.example.com/v1", model: "b")
        settings.providerSettings = ProviderSettings(modelProfiles: [first, second],
                                                     selectedModelID: second.id)

        let reloaded = CorePreferences(store: store).providerSettings
        XCTAssertEqual(reloaded.modelProfiles.map(\.name), ["First", "Second"])
        XCTAssertEqual(reloaded.selectedModel?.id, second.id)
        XCTAssertEqual(reloaded.modelName, "b")
    }

    /// The single-provider keys are mirrored so the Linux settings file stays readable
    /// and a downgraded build still finds an endpoint — and it must be the *selected*
    /// provider's, not the first in a list that build cannot see.
    func testTheSelectedProviderIsMirroredIntoTheSingleProviderKeys() {
        let store = MemorySettingsStore()
        let settings = CorePreferences(store: store)
        let first = ModelProfile.new(name: "First", endpoint: "https://a.example.com/v1", model: "a")
        let second = ModelProfile.new(name: "Second", endpoint: "https://b.example.com/v1", model: "b")
        settings.providerSettings = ProviderSettings(modelProfiles: [first, second],
                                                     selectedModelID: second.id)

        XCTAssertEqual(store.string(for: "modelEndpoint"), "https://b.example.com/v1")
        XCTAssertEqual(store.string(for: "modelName"), "b")
    }

    /// Losing the extra profiles is bad; refusing to launch over them is worse.
    func testAnUnreadableProviderListFallsBackToTheSingleProviderKeys() {
        let settings = preferences(["modelProviders": "{ not json",
                                    "modelEndpoint": "https://api.example.com/v1",
                                    "modelName": "fallback"]).providerSettings
        XCTAssertEqual(settings.modelProfiles.count, 1)
        XCTAssertEqual(settings.modelName, "fallback")
    }

    /// The memo behind `providerSettings` must not outlive a write, or Settings would
    /// save a new provider and the panel would keep asking with the old one.
    func testAWriteIsVisibleToTheNextRead() {
        let settings = preferences()
        let added = ModelProfile.new(name: "Added", endpoint: "https://a.example.com/v1", model: "a")
        XCTAssertNotEqual(settings.providerSettings.modelName, "a")
        settings.providerSettings = ProviderSettings(modelProfiles: [added], selectedModelID: added.id)
        XCTAssertEqual(settings.providerSettings.modelName, "a")
        XCTAssertEqual(settings.providerSettings.selectedModel?.name, "Added")
    }

    /// The search half migrates on its own: a settings file can have a model list and
    /// no search list, because the two arrived in different releases.
    func testTheSearchHalfMigratesIndependentlyOfTheModelHalf() {
        let store = MemorySettingsStore(["searchEndpoint": "https://search.example.com/mcp"])
        let model = ModelProfile.new(name: "Only", endpoint: "https://a.example.com/v1", model: "a")
        store.setString(ProviderSettings.encodeModelProfiles([model]), for: "modelProviders")

        let settings = CorePreferences(store: store).providerSettings
        XCTAssertEqual(settings.modelProfiles.count, 1)
        XCTAssertEqual(settings.searchProfiles.count, 1)
        XCTAssertEqual(settings.searchEndpoint, "https://search.example.com/mcp")
        XCTAssertEqual(settings.searchKind, .mcp)
    }

    /// A hand-edited Linux settings file is the only way to reach SearXNG there, so the
    /// scalar `searchProvider` key has to be honoured on the no-list path.
    func testAHandEditedSearchProviderKindIsHonouredWithoutAList() {
        let settings = preferences(["searchEndpoint": "https://searx.example.org",
                                    "searchProvider": "searxng"]).providerSettings
        XCTAssertEqual(settings.searchKind, .searxng)
        XCTAssertEqual(settings.searchEndpoint, "https://searx.example.org")
    }

    func testSearchProvidersRoundTripAndMirrorTheSelectedOne() {
        let store = MemorySettingsStore()
        let settings = CorePreferences(store: store)
        let hosted = SearchProfile.new(name: "z.ai", kind: .mcp,
                                       endpoint: ProviderSettings.defaultSearchEndpoint)
        let mine = SearchProfile.new(name: "Mine", kind: .searxng,
                                     endpoint: "https://searx.example.org")
        var value = ProviderSettings(modelEndpoint: "https://a.example.com/v1", modelName: "m")
        value.searchProfiles = [hosted, mine]
        value.selectedSearchID = mine.id
        settings.providerSettings = value

        XCTAssertEqual(store.string(for: "searchEndpoint"), "https://searx.example.org")
        XCTAssertEqual(store.string(for: "searchProvider"), "searxng")

        let reloaded = CorePreferences(store: store).providerSettings
        XCTAssertEqual(reloaded.searchProfiles.map(\.name), ["z.ai", "Mine"])
        XCTAssertEqual(reloaded.selectedSearch?.id, mine.id)
        XCTAssertEqual(reloaded.searchKind, .searxng)
    }

    /// The file store must survive a number that round-tripped as an integer, which is
    /// what happens to `1.0` in a hand-edited settings file — and what JSON gives back
    /// for `1`. Tested against the real file store, because the in-memory one does no
    /// coercion and the assertion would pass vacuously through the default instead.
    func testTheFileStoreReadsAnIntegerAsADouble() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VervellumSettingsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("settings.json")
        try #"{"textScale": 1, "historyEnabled": false}"#.write(to: file, atomically: true, encoding: .utf8)

        let store = JSONFileSettingsStore(url: file)
        XCTAssertEqual(store.double(for: "textScale"), 1.0)
        XCTAssertEqual(CorePreferences(store: store).textScale, 1.0, accuracy: 0.001)
        XCTAssertFalse(CorePreferences(store: store).historyEnabled)
    }

    func testTheFileStorePersistsAcrossInstances() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VervellumSettingsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("settings.json")
        CorePreferences(store: JSONFileSettingsStore(url: file)).textScale = 1.3
        XCTAssertEqual(CorePreferences(store: JSONFileSettingsStore(url: file)).textScale,
                       1.3, accuracy: 0.001)
    }

    /// A settings file that will not parse must not stop the app launching.
    func testAnUnreadableFileReadsAsEmpty() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VervellumSettingsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("settings.json")
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CorePreferences(store: JSONFileSettingsStore(url: file)).textScale,
                       1.0, accuracy: 0.001)
    }

    // MARK: The theme

    /// The setter used to hand `encode`'s optional straight to the store, and a nil there
    /// clears the key — so a palette that would not encode replaced the stored theme with
    /// the default. Nothing can be made to fail encoding any more, which is the fix; what
    /// is left to check here is that the ordinary path writes something the next launch
    /// reads back as the same theme.
    func testAThemeSurvivesBeingStoredAndReadBack() {
        // Every preset, not one: Solarized states neither `fontDesign` nor `cornerScale`,
        // so it was the round trip least able to notice a field that stopped encoding.
        // Terminal carries `.monospaced` and a zero scale, Paper `.serif`, Bubblegum 1.8.
        for preset in PanelPalette.presets {
            let store = MemorySettingsStore()
            CorePreferences(store: store).panelPalette = preset
            XCTAssertEqual(CorePreferences(store: store).panelPalette, preset,
                           "\(preset.name) did not survive a round trip through the store")
        }
    }

    /// Losing a theme is a bad afternoon; refusing to launch is worse.
    func testAStoredThemeThatWillNotParseReadsAsEmber() {
        // The key by name rather than by literal: a rename would otherwise leave this
        // test seeding a key nothing reads, and it would still pass.
        XCTAssertEqual(preferences([CorePreferences.Key.panelPalette: "{ not json"]).panelPalette,
                       .ember)
    }
}
