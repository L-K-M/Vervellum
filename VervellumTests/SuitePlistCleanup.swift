import Foundation

/// Removes a `UserDefaults(suiteName:)` test suite completely.
///
/// `removePersistentDomain(forName:)` alone is not enough: it unregisters the
/// domain but leaves the suite's plist in ~/Library/Preferences, so every test
/// run used to add one more permanent `Vervellum*Test-*` domain — hundreds of
/// junk entries in `defaults domains` after a year of runs. Deleting the file
/// after unregistering is what makes a suite actually gone.
enum SuitePlistCleanup {

    static func removeSuite(_ name: String, from defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: name)
        let plist = NSHomeDirectory() + "/Library/Preferences/\(name).plist"
        try? FileManager.default.removeItem(atPath: plist)
    }
}
