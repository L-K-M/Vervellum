#if os(Linux)
import Foundation

/// Registers the summon shortcut with the desktop environment.
///
/// Vervellum does **not** grab the key itself on Linux, and cannot. The three
/// candidates all fail on the target:
///
/// * The `org.freedesktop.portal.GlobalShortcuts` portal has no GNOME backend before
///   GNOME 48, so it is simply absent on Ubuntu 24.04 LTS.
/// * `XGrabKey` works only in a real X11 session, and recent Mutter no longer honours
///   XWayland-side global grabs at all — the grab fires only when the window is already
///   focused, which defeats the purpose.
/// * A compositor-level grab needs a protocol Wayland does not expose to clients.
///
/// What does work everywhere, on X11 and Wayland alike, is asking the desktop to run a
/// command on a key press. The compositor owns the grab, so it fires over full-screen
/// windows too. The command is
/// `gapplication action ch.lkmc.Vervellum toggle`, which routes to the already-running
/// instance over D-Bus — and starts it, via the desktop entry, if it is not running.
///
/// This runs at first launch, not from the package's `postinst`: `postinst` runs as
/// root with no user session bus, and would write root's dconf rather than the user's.
enum ShortcutInstaller {

    static let defaultAccelerator = "<Control><Alt><Super>space"
    private static let installedKey = "shortcutInstalled"

    private static let listSchema = "org.gnome.settings-daemon.plugins.media-keys"
    private static let itemSchema = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
    private static let basePath = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
    private static let bindingName = "Vervellum"

    /// Installs once, then records that it did.
    ///
    /// Only once: re-binding on every launch would silently undo a shortcut the user
    /// had deliberately changed, which is worse than not offering the convenience.
    static func installOnFirstRun(preferences: CorePreferences) {
        guard !(preferences.rawBool(installedKey) ?? false) else { return }
        // Recorded only on success. Marking it done after a failure — because this is
        // not a GNOME session, or gsettings is missing — would mean the shortcut is
        // never installed even after the user moves to a desktop where it would work.
        guard install() else { return }
        preferences.setRawBool(true, installedKey)
    }

    /// Adds or updates the binding. Returns false when this is not a GNOME session.
    @discardableResult
    static func install(accelerator: String = defaultAccelerator) -> Bool {
        guard gsettingsPath != nil else {
            report("gsettings was not found — bind the shortcut yourself, to: \(command)")
            return false
        }
        guard let schemas = run(["list-schemas"]), schemas.contains(listSchema) else {
            report("this is not a GNOME session — bind the shortcut yourself, to: \(command)")
            return false
        }

        // A *failed* read must abort, never fall back to an empty list. Treating a
        // failure as "there are no bindings" and then writing would erase every custom
        // keybinding the user has, in every other application.
        guard let list = run(["get", listSchema, "custom-keybindings"]) else {
            report("could not read the existing shortcuts — nothing was changed")
            return false
        }
        let slot = existingSlot(in: list) ?? claimSlot(in: list)

        _ = run(["set", "\(itemSchema):\(slot)", "name", bindingName])
        _ = run(["set", "\(itemSchema):\(slot)", "command", command])
        _ = run(["set", "\(itemSchema):\(slot)", "binding", accelerator])
        report("bound \(accelerator) to Vervellum")
        return true
    }

    static var command: String { "gapplication action \(VervellumLinuxApp.applicationID) toggle" }

    // MARK: Slot bookkeeping

    /// The slot Vervellum already owns, found by name rather than by position.
    ///
    /// Matching on the name is what makes re-running this a no-op instead of leaking a
    /// fresh `customN` entry on every launch.
    private static func existingSlot(in list: String) -> String? {
        paths(in: list).first { path in
            run(["get", "\(itemSchema):\(path)", "name"]) == "'\(bindingName)'"
        }
    }

    /// The lowest unused slot, appended to the list.
    private static func claimSlot(in list: String) -> String {
        let existing = Set(paths(in: list))
        var index = 0
        var path = "\(basePath)/custom0/"
        while existing.contains(path) {
            index += 1
            path = "\(basePath)/custom\(index)/"
        }
        _ = run(["set", listSchema, "custom-keybindings", encode(paths(in: list) + [path])])
        return path
    }

    /// The dconf paths in a GVariant array as `gsettings get` prints it.
    ///
    /// An empty list prints `@as []`, not `[]` — appending to that string naively
    /// produces `@as [, 'x']`, which is not valid GVariant and is rejected on write.
    /// Parsing the quoted paths out sidesteps the whole question.
    static func paths(in list: String) -> [String] {
        var found: [String] = []
        var current: String?
        for character in list {
            if character == "'" {
                if let value = current { found.append(value); current = nil } else { current = "" }
            } else if current != nil {
                current?.append(character)
            }
        }
        return found
    }

    static func encode(_ paths: [String]) -> String {
        paths.isEmpty ? "@as []" : "[" + paths.map { "'\($0)'" }.joined(separator: ", ") + "]"
    }

    // MARK: Running gsettings

    private static let gsettingsPath: String? = {
        ["/usr/bin/gsettings", "/bin/gsettings", "/usr/local/bin/gsettings"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private static func run(_ arguments: [String]) -> String? {
        guard let gsettingsPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gsettingsPath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // The null device, not a Pipe that nobody reads: an undrained pipe fills at
        // 64 KB and the child then blocks on it forever, which would hang
        // `waitUntilExit`. gsettings is terse, but the cost of being wrong is a hang on
        // every launch.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("vervellum: \(message)\n".utf8))
    }
}
#endif
