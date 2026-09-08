import XCTest
@testable import Vervellum

final class PreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "VervellumPrefsTest-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsAreReturnedForAnEmptyStore() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.panelSide, Preferences.Default.panelSide)
        XCTAssertEqual(preferences.panelWidth, Preferences.Default.panelWidth)
        XCTAssertEqual(preferences.summonHotkey, HotkeyBinding.defaultSummon)
        XCTAssertTrue(preferences.historyEnabled)
    }

    /// Dismiss-on-focus-loss is off by design: a research run takes tens of seconds
    /// and the answer is meant to be read while working.
    func testDismissOnFocusLossIsOffByDefault() {
        XCTAssertFalse(Preferences(defaults: defaults).dismissOnFocusLoss)
    }

    func testRoundTripsEveryStoredValue() {
        let preferences = Preferences(defaults: defaults)
        preferences.panelSide = .leading
        preferences.panelWidth = 520
        preferences.textScale = 1.2
        preferences.submitOnReturn = false
        preferences.showProcessTrail = false
        preferences.dismissOnFocusLoss = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.panelSide, .leading)
        XCTAssertEqual(reloaded.panelWidth, 520)
        XCTAssertEqual(reloaded.textScale, 1.2, accuracy: 0.001)
        XCTAssertFalse(reloaded.submitOnReturn)
        XCTAssertFalse(reloaded.showProcessTrail)
        XCTAssertTrue(reloaded.dismissOnFocusLoss)
    }

    /// Clamping on *read* is what makes a corrupted preferences file survivable: a
    /// zero-width panel is one the user can neither see nor fix.
    func testClampsCorruptedNumbersOnRead() {
        defaults.set(0.0, forKey: "panelWidth")
        XCTAssertEqual(Preferences(defaults: defaults).panelWidth, PanelPlacement.minimumWidth)

        defaults.set(99_999.0, forKey: "panelWidth")
        XCTAssertEqual(Preferences(defaults: defaults).panelWidth, PanelPlacement.maximumWidth)

        defaults.set(Double.nan, forKey: "textScale")
        XCTAssertEqual(Preferences(defaults: defaults).textScale, CorePreferences.Default.textScale, accuracy: 0.001)

        defaults.set(Double.infinity, forKey: "panelHeight")
        XCTAssertEqual(Preferences(defaults: defaults).panelHeight, Preferences.Default.panelHeight)
    }

    func testClampsOnWriteToo() {
        let preferences = Preferences(defaults: defaults)
        preferences.panelWidth = -100
        XCTAssertEqual(preferences.panelWidth, PanelPlacement.minimumWidth)
        preferences.textScale = 99
        XCTAssertEqual(preferences.textScale, 1.4, accuracy: 0.001)
    }

    func testFallsBackWhenTheStoredValueIsGarbage() {
        defaults.set("sideways", forKey: "panelSide")
        XCTAssertEqual(Preferences(defaults: defaults).panelSide, Preferences.Default.panelSide)

        defaults.set("not json", forKey: "summonHotkey")
        XCTAssertEqual(Preferences(defaults: defaults).summonHotkey, HotkeyBinding.defaultSummon)
    }

    /// The shared settings are exercised in `CorePreferencesTests`; this only checks
    /// that the macOS shell really forwards to them rather than keeping its own copy.
    func testAnEmptySearchEndpointRevertsToTheDefault() {
        let preferences = Preferences(defaults: defaults)
        preferences.providerSettings = ProviderSettings(modelEndpoint: "https://api.example.com/v1",
                                                        modelName: "m",
                                                        searchEndpoint: "   ")
        XCTAssertEqual(preferences.providerSettings.searchEndpoint, ProviderSettings.defaultSearchEndpoint)
    }

    func testProviderSettingsRoundTrip() {
        let preferences = Preferences(defaults: defaults)
        let settings = ProviderSettings(modelEndpoint: "https://api.example.com/v1",
                                        modelName: "some-model",
                                        searchEndpoint: "https://search.example.com/mcp")
        preferences.providerSettings = settings
        XCTAssertEqual(Preferences(defaults: defaults).providerSettings, settings)
    }

    // MARK: Change notification

    /// `onChanged` is what re-places an open panel, so it has to fire for the settings
    /// the panel's geometry is built from — including the ones that live in
    /// `CorePreferences` and reach here through its own callback.
    func testEveryKindOfSettingAnnouncesItsChange() {
        let preferences = Preferences(defaults: defaults)
        var announcements = 0
        preferences.onChanged = { announcements += 1 }

        preferences.panelWidth = 500          // a macOS-only number
        preferences.panelSide = .leading      // a macOS-only string
        preferences.dismissOnFocusLoss = true // a macOS-only flag
        preferences.textScale = 1.2           // a shared setting, via CorePreferences

        XCTAssertEqual(announcements, 4)
    }

    /// The whole reason `onChanged` exists rather than `objectWillChange`: a subscriber
    /// has to be able to read the value it was told about. `objectWillChange` fires
    /// before the write and would hand back the old width, which would place the panel
    /// one drag-step behind the slider forever.
    func testTheChangeIsAlreadyStoredWhenItIsAnnounced() {
        let preferences = Preferences(defaults: defaults)
        var widthWhenAnnounced: CGFloat?
        // Weakly, or the closure and the object it is stored on would retain each other.
        preferences.onChanged = { [weak preferences] in widthWhenAnnounced = preferences?.panelWidth }
        preferences.panelWidth = 512
        XCTAssertEqual(widthWhenAnnounced, 512)
    }

    /// The retention picker's rows and the range the archive clamps into are separate
    /// constants, and the picker's own doc comment claims they agree. A row outside the
    /// range would be stored as something else the moment it was chosen, so the control
    /// would show one number while the archive applied another.
    func testEveryOfferedThreadLimitIsInsideTheRangeTheArchiveAccepts() {
        XCTAssertFalse(GeneralView.threadLimits.isEmpty)
        for limit in GeneralView.threadLimits {
            XCTAssertTrue(ThreadLibrary.keptThreadsRange.contains(limit),
                          "\(limit) is offered but would be clamped to something else")
        }
    }

    /// The settings pane writes only the preference and relies on the composition root
    /// to forward it. What this pins is the half that can break silently: that the write
    /// fires `onChanged` *after* the new value is readable, so a forwarder reading
    /// `preferences.keptThreads` from inside the callback sees 25 rather than the old
    /// limit. The forwarder here stands in for `AppDelegate`'s.
    func testChangingTheLimitPreferenceReachesTheStore() {
        let preferences = Preferences(defaults: defaults)
        let store = ThreadStore(fileURL: temporaryThreadsURL(), historyEnabled: true,
                                keptThreads: preferences.keptThreads, debounce: 0)
        preferences.onChanged = { [weak preferences] in
            guard let preferences else { return }
            store.keptThreads = preferences.keptThreads
        }
        XCTAssertNotEqual(preferences.keptThreads, 25,
                          "the starting value must differ, or the assertion below passes "
                          + "whether or not anything was forwarded")
        preferences.keptThreads = 25
        XCTAssertEqual(store.keptThreads, 25)
    }

    /// The default-versus-floor distinction rests entirely on an absent key reading as
    /// nil rather than zero, and this is the store that ships. `UserDefaults`'s own
    /// `double(forKey:)` answers `0` for a missing key, which would clamp a fresh
    /// install to ten threads and prune its history at the first write — so the store
    /// reads through `object(forKey:)` instead, and that is what this pins.
    func testTheShippingStoreReadsAnAbsentNumberAsNilNotZero() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertNil(store.double(for: "keptThreads"))
        XCTAssertEqual(Preferences(defaults: defaults).keptThreads, 200)
    }

    private func temporaryThreadsURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VervellumPrefsTest-\(UUID().uuidString).json")
    }
}
