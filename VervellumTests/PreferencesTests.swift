import XCTest
import Carbon.HIToolbox
import KeycapCore
@testable import Vervellum

final class PreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "VervellumPrefsTest-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        SuitePlistCleanup.removeSuite(suiteName, from: defaults)
        defaults = nil
        suiteName = nil
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

    /// A shortcut saved before Keycap stores a label the recorder no longer shows.
    /// The panel hint reads this binding through `Preferences`, so the stored JSON
    /// is seeded in a scratch suite and the hint must match the recorder's name.
    func testAnOldSavedShortcutHintMatchesTheRecorder() {
        let old = HotkeyBinding(keyCode: KeyCode.f5,
                                modifiers: UInt32(cmdKey | optionKey),
                                keyLabel: "Key \(KeyCode.f5)", enabled: true)
        defaults.set(old.jsonString, forKey: "summonHotkey")

        let stored = Preferences(defaults: defaults).summonHotkey
        XCTAssertEqual(stored, old)
        XCTAssertEqual(stored.displayString, stored.combo.displayString)
        XCTAssertEqual(stored.displayString, "⌥⌘F5")
    }

    /// The shared settings are exercised in `CorePreferencesTests`; this only checks
    /// that the macOS shell really forwards to them rather than keeping its own copy.
    func testAnEmptySearchEndpointRevertsToTheDefault() throws {
        let preferences = Preferences(defaults: defaults)
        var settings = preferences.providerSettings
        settings.modelEndpoint = "https://api.example.com/v1"
        settings.modelName = "m"
        settings.searchEndpoint = "   "
        try preferences.commitProviderSettings(settings, secrets: EphemeralSecretStore())
        XCTAssertEqual(preferences.providerSettings.searchEndpoint, ProviderSettings.defaultSearchEndpoint)
    }

    func testProviderSettingsRoundTrip() throws {
        let preferences = Preferences(defaults: defaults)
        var settings = preferences.providerSettings
        settings.modelEndpoint = "https://api.example.com/v1"
        settings.modelName = "some-model"
        settings.searchEndpoint = "https://search.example.com/mcp"
        try preferences.commitProviderSettings(settings, secrets: EphemeralSecretStore())
        XCTAssertEqual(Preferences(defaults: defaults).providerSettings, settings)
    }

    func testAProviderSelectionClearsStaleFixedKeysBeforePersistingItsMirror() throws {
        let preferences = Preferences(defaults: defaults)
        let first = ModelProfile.new(
            name: "First", endpoint: "https://first.example/v1", model: "first")
        let second = ModelProfile.new(
            name: "Second", endpoint: "https://second.example/v1", model: "second")
        let original = ProviderSettings(
            modelProfiles: [first, second], selectedModelID: first.id,
            searchProfiles: [])
        // Seed the unsafe state an older build could leave. Production macOS writes do
        // not expose this raw setter; the transaction below is the behavior under test.
        preferences.core.providerSettings = original
        let secrets = SelectionSecretStore([.modelAPIKey: "orphaned legacy key"])
        var edited = original
        edited.selectedModelID = second.id

        _ = try preferences.commitProviderSettings(edited, secrets: secrets)

        XCTAssertNil(secrets.value(for: .modelAPIKey))
        XCTAssertEqual(preferences.providerSettings.selectedModel?.id, second.id)
        XCTAssertTrue(secrets.operations.contains("delete:model-api-key"))
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
        for index in 0..<40 { store.save(thread("q\(index)")) }
        XCTAssertEqual(store.library.threads.count, 40)

        preferences.keptThreads = 25
        XCTAssertEqual(store.keptThreads, 25)
        // The number arriving is half the contract. An empty store would have asserted
        // the forwarding and nothing about what it is for — the pane promises the drop
        // takes effect now, so the list the pane is looking at has to have shrunk.
        XCTAssertEqual(store.library.threads.count, 25,
                       "the forwarded limit must prune, and the store's own view of the "
                       + "library must show it")
        // Which twenty-five, not just how many. A prune that kept the *oldest* would
        // satisfy the count above while throwing away the threads the setting exists to
        // keep. Deterministic without timestamps: `upsert` puts the newest first and
        // `prune` removes from the end, so position is the policy.
        XCTAssertEqual(store.library.threads.first?.title, "q39", "the newest is kept")
        XCTAssertFalse(store.library.threads.contains { $0.title == "q0" },
                       "the oldest is what goes")
    }

    private func thread(_ question: String) -> ResearchThread {
        var thread = ResearchThread()
        thread.turns = [ResearchTurn(question: question)]
        return thread
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
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VervellumPrefsTest-\(UUID().uuidString).json")
        // The retention test writes for real — forty threads at a zero debounce — so
        // without this every run leaves a file behind. `ThreadArchiveTests` tears its
        // directory down; this file had no equivalent.
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class SelectionSecretStore: SecretStore {
    private var values: [SecretAccount: String]
    private(set) var operations: [String] = []

    init(_ values: [SecretAccount: String]) { self.values = values }

    var backendDescription: String { "test store" }
    func value(for account: SecretAccount) -> String? { values[account] }

    func set(_ secret: String, for account: SecretAccount) throws {
        operations.append("set:\(account.rawValue)")
        values[account] = secret
    }

    func delete(_ account: SecretAccount) throws {
        operations.append("delete:\(account.rawValue)")
        values[account] = nil
    }
}
