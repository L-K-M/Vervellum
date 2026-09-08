import Foundation

/// The settings both front ends share, with their defaults, keys and clamping in one
/// place.
///
/// Platform-specific settings deliberately stay out: the macOS panel's edge, width and
/// dismissal behaviour, its global shortcuts and its login item have no Linux
/// equivalent (a GNOME Wayland compositor will not let an application place its own
/// window, and the shortcut is registered with the desktop environment rather than
/// grabbed by the app). Each platform's own preferences type owns those and forwards
/// the shared ones here, so a change to a shared default reaches both.
///
/// Numeric values are clamped **on read as well as on write**, so a settings file
/// corrupted by a crash, an interrupted sync, or a hand edit cannot produce a state the
/// user can neither see nor fix.
final class CorePreferences {

    /// Invoked after any change, so a platform can republish it — `objectWillChange` on
    /// macOS, a redraw on Linux.
    var onChange: (() -> Void)?

    private let store: SettingsStore

    /// The last assembled provider configuration.
    ///
    /// Assembling it now means decoding a JSON provider list, and the panel reads it on
    /// every SwiftUI render — which during a streamed answer is many times a second.
    /// This instance is the only thing that writes those keys, so the memo is invalidated
    /// by its own setter and by nothing else.
    private var cachedProviderSettings: ProviderSettings?

    init(store: SettingsStore) {
        self.store = store
    }

    // MARK: Defaults

    enum Default {
        static let modelEndpoint = ""
        static let modelName = ""
        static let searchEndpoint = ProviderSettings.defaultSearchEndpoint
        /// Pages behind the top sources are fetched and read.
        ///
        /// On, because a citation to a page nobody read is the weakest link in the whole
        /// chain — the app's own source rows say "search summary, not the full page" for
        /// exactly that reason. It is also the setting that changes *who Vervellum talks
        /// to*, so it is named in `PRIVACY.md` and switchable in one control; `.off` is
        /// what every build before it did.
        static let pageReading = PageReadingMode.direct
        static let readerEndpoint = ProviderSettings.defaultReaderEndpoint
        static let historyEnabled = true
        /// How many past threads are kept. See `ThreadLibrary.defaultKeptThreads`.
        static let keptThreads = ThreadLibrary.defaultKeptThreads
        /// The search-plan and sources trail above each answer.
        static let showProcessTrail = true
        /// Return submits; Shift-Return inserts a newline. The inverse suits people who
        /// write long multi-paragraph questions.
        static let submitOnReturn = true
        /// On. A false positive costs a re-typed word; a false negative sends a live
        /// credential to a third party.
        static let redactSecrets = true
        static let textScale = 1.0
    }

    enum Key {
        /// The selected provider's endpoint and model, kept as plain strings.
        ///
        /// These are the *only* provider keys a pre-profiles build ever wrote, and they
        /// are still both the fallback this one migrates from and a mirror it maintains:
        /// they are what `~/.config/vervellum/settings.json` documents for hand editing,
        /// and what a build downgraded onto the same file would look for.
        static let modelEndpoint = "modelEndpoint"
        static let modelName = "modelName"
        /// The full provider list, JSON-encoded. Authoritative when present.
        static let modelProviders = "modelProviders"
        static let selectedModelProvider = "selectedModelProvider"
        /// The selected search provider's endpoint, and — for a backend that is not an
        /// MCP server — which protocol it speaks. Mirrored like the model keys are.
        static let searchEndpoint = "searchEndpoint"
        static let searchProvider = "searchProvider"
        /// The full search-provider list, JSON-encoded. Authoritative when present.
        static let searchProviders = "searchProviders"
        static let selectedSearchProvider = "selectedSearchProvider"
        /// How much of each source is read, and where a reader service lives.
        static let pageReading = "pageReading"
        static let readerEndpoint = "readerEndpoint"
        static let historyEnabled = "historyEnabled"
        static let keptThreads = "keptThreads"
        static let showProcessTrail = "showProcessTrail"
        static let submitOnReturn = "submitOnReturn"
        static let redactSecrets = "redactSecrets"
        static let textScale = "textScale"
    }

    /// Body-text scale for the thread. The panel is narrow and often sits on a display
    /// the user is not sitting square to; one slider beats guessing a good size.
    static let textScaleRange: ClosedRange<Double> = 0.85...1.4

    // MARK: Providers

    /// The provider configuration, assembled from the list when there is one and from
    /// the single-provider keys when there is not.
    ///
    /// The fallback is the migration: a settings file written before model providers
    /// were a list has only `modelEndpoint` and `modelName`, and
    /// `ProviderSettings.init(modelEndpoint:modelName:searchEndpoint:)` turns those into
    /// one profile on the `model-api-key` account — which is precisely where that
    /// build's Keychain item already is, so an existing user upgrades without re-pasting
    /// anything. It is also the path the Linux front end stays on, since it never writes
    /// a list; hand-editing `settings.json` therefore keeps working there.
    ///
    /// A list that will not parse falls back the same way rather than throwing: losing
    /// the extra profiles is bad, and refusing to launch over them is worse.
    var providerSettings: ProviderSettings {
        get {
            if let cachedProviderSettings { return cachedProviderSettings }
            let assembled = readProviderSettings()
            cachedProviderSettings = assembled
            return assembled
        }
        set {
            // Normalised first, so the stored list and the mirrored keys cannot disagree
            // about an endpoint the rules rewrote. See `ProviderSettings.normalized()`.
            let settings = newValue.normalized()

            store.setString(ProviderSettings.encodeModelProfiles(settings.modelProfiles),
                            for: Key.modelProviders)
            store.setString(settings.selectedModel?.id.uuidString, for: Key.selectedModelProvider)
            store.setString(ProviderSettings.encodeSearchProfiles(settings.searchProfiles),
                            for: Key.searchProviders)
            store.setString(settings.selectedSearch?.id.uuidString, for: Key.selectedSearchProvider)

            // The single-provider keys are mirrored, not merely left behind: they are what
            // the Linux settings file documents, and what an older build downgraded onto
            // the same file reads. Writing the *selected* profile into them means such a
            // build finds the provider the user was last using rather than the first one
            // in a list it cannot see.
            store.setString(settings.modelEndpoint, for: Key.modelEndpoint)
            store.setString(settings.modelName, for: Key.modelName)
            store.setString(settings.searchEndpoint, for: Key.searchEndpoint)
            store.setString(settings.searchKind.rawValue, for: Key.searchProvider)
            store.setString(settings.pageReading.rawValue, for: Key.pageReading)
            store.setString(settings.readerEndpoint, for: Key.readerEndpoint)

            cachedProviderSettings = settings
            onChange?()
        }
    }

    private func readProviderSettings() -> ProviderSettings {
        // Assembled half by half: a settings file can have a model list and no search
        // list (an upgrade in between), and each half migrates on its own.
        var settings = ProviderSettings(
            modelEndpoint: store.string(for: Key.modelEndpoint) ?? Default.modelEndpoint,
            modelName: store.string(for: Key.modelName) ?? Default.modelName,
            searchEndpoint: store.string(for: Key.searchEndpoint) ?? Default.searchEndpoint,
            searchKind: store.string(for: Key.searchProvider)
                .flatMap { SearchProviderKind(rawValue: $0) } ?? .mcp,
            pageReading: store.string(for: Key.pageReading)
                .flatMap { PageReadingMode(rawValue: $0) } ?? Default.pageReading,
            readerEndpoint: store.string(for: Key.readerEndpoint) ?? Default.readerEndpoint)

        if let encoded = store.string(for: Key.modelProviders),
           let profiles = ProviderSettings.decodeModelProfiles(encoded),
           !profiles.isEmpty {
            settings.modelProfiles = profiles
            settings.selectedModelID = store.string(for: Key.selectedModelProvider)
                .flatMap { UUID(uuidString: $0) }
        }
        if let encoded = store.string(for: Key.searchProviders),
           let profiles = ProviderSettings.decodeSearchProfiles(encoded),
           !profiles.isEmpty {
            settings.searchProfiles = profiles
            settings.selectedSearchID = store.string(for: Key.selectedSearchProvider)
                .flatMap { UUID(uuidString: $0) }
        }
        return settings
    }

    // MARK: Behaviour

    var historyEnabled: Bool {
        get { store.bool(for: Key.historyEnabled) ?? Default.historyEnabled }
        set { store.setBool(newValue, for: Key.historyEnabled); onChange?() }
    }

    var showProcessTrail: Bool {
        get { store.bool(for: Key.showProcessTrail) ?? Default.showProcessTrail }
        set { store.setBool(newValue, for: Key.showProcessTrail); onChange?() }
    }

    var submitOnReturn: Bool {
        get { store.bool(for: Key.submitOnReturn) ?? Default.submitOnReturn }
        set { store.setBool(newValue, for: Key.submitOnReturn); onChange?() }
    }

    /// Whether text captured from another application is scanned for credentials before
    /// it reaches the composer. See `SecretRedactor`.
    var redactSecrets: Bool {
        get { store.bool(for: Key.redactSecrets) ?? Default.redactSecrets }
        set { store.setBool(newValue, for: Key.redactSecrets); onChange?() }
    }

    /// How many past threads are kept on disk.
    ///
    /// Stored as a double because that is the only number `SettingsStore` carries, and
    /// clamped on read as well as on write like every other bound value here: a
    /// settings file left holding a zero by a crash or a hand edit must not be able to
    /// erase the history.
    ///
    /// Which is why a non-positive value falls back to the default rather than being
    /// clamped. Clamping honoured the letter of that promise and broke its spirit: zero
    /// became ten, and ten of two thousand kept threads is not meaningfully better than
    /// none. A zero or a negative is not a setting anything can have produced, so it
    /// says the file is damaged, and the answer to damage is the default rather than the
    /// smallest legal setting.
    ///
    /// Only those. A positive number under the floor — a `7` from an older build or a
    /// hand edit that meant it — is still clamped up to ten, because it reads as a
    /// setting rather than as damage. This paragraph used to say "below the floor" and
    /// describe the `7` case as damage too, which is not what the code does and not
    /// what `testAStoredLimitOutsideTheRangeIsClamped` pins.
    var keptThreads: Int {
        get {
            let range = ThreadLibrary.keptThreadsRange
            guard let stored = store.double(for: Key.keptThreads), stored > 0 else {
                return Default.keptThreads
            }
            let bounded = Self.clamped(stored,
                                       Double(Default.keptThreads),
                                       Double(range.lowerBound)...Double(range.upperBound))
            return Int(bounded.rounded())
        }
        set {
            let range = ThreadLibrary.keptThreadsRange
            let bounded = min(max(newValue, range.lowerBound), range.upperBound)
            store.setDouble(Double(bounded), for: Key.keptThreads)
            onChange?()
        }
    }

    var textScale: Double {
        get { Self.clamped(store.double(for: Key.textScale), Default.textScale, Self.textScaleRange) }
        set {
            store.setDouble(Self.clamp(newValue, Self.textScaleRange), for: Key.textScale)
            onChange?()
        }
    }

    // MARK: Platform escape hatch

    /// Reads a flag that has no shared meaning — a platform's own bookkeeping.
    ///
    /// Deliberately unglamorous and deliberately narrow. Every setting a user can see
    /// belongs above, where its default and clamping are shared; this exists so a
    /// platform does not have to stand up a second settings file for one boolean, such
    /// as "the desktop shortcut has been installed once".
    func rawBool(_ key: String) -> Bool? { store.bool(for: key) }

    func setRawBool(_ value: Bool, _ key: String) {
        store.setBool(value, for: key)
        onChange?()
    }

    // MARK: Clamping

    /// Substitutes the default for a missing, non-finite, or out-of-range value.
    /// Clamping on *read* is what makes a corrupted settings file survivable without a
    /// reset — the alternative is an app the user has to delete a plist to recover.
    static func clamped(_ stored: Double?, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
        guard let stored, stored.isFinite else { return fallback }
        return clamp(stored, range)
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
