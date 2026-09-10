#if os(Linux)
import Foundation
import CGtk

/// The Linux entry point.
///
/// Two modes, one pipeline:
///
/// * **`--ask "…"`** runs a research turn headlessly and prints the answer, its
///   verdicts and its sources. No GTK, no display, no session bus — which makes it the
///   thing to reach for on a server, in a script, and in CI, where it exercises the
///   entire shared core end to end.
/// * **No arguments** starts the panel: a GTK window that a desktop shortcut toggles.
///
/// Both are the *same* `ResearchRunner` the macOS app drives, so a fix to the pipeline
/// reaches every one of them.
public enum VervellumLinuxApp {

    /// The reverse-DNS identity, shared with the rest of the app. This one string is
    /// the D-Bus name, the `.desktop` basename and `StartupWMClass`, and all three break
    /// silently if they diverge: single-instance handling, the dock icon and desktop
    /// activation each key off it.
    static let applicationID = AppIdentity.bundleIdentifier

    public static func main() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "--help", "-h":
            printUsage()
            return 0
        case "--version":
            print("vervellum \(AppIdentity.version)")
            return 0
        case "--install-shortcut":
            return ShortcutInstaller.install() ? 0 : 1
        case "--ask":
            guard arguments.count > 1 else {
                FileHandle.standardError.write(Data("usage: vervellum --ask \"your question\"\n".utf8))
                return 2
            }
            return runHeadless(question: arguments.dropFirst().joined(separator: " "), mode: .research)
        case "--deep":
            guard arguments.count > 1 else {
                FileHandle.standardError.write(Data("usage: vervellum --deep \"your question\"\n".utf8))
                return 2
            }
            return runHeadless(question: arguments.dropFirst().joined(separator: " "), mode: .deep)
        case "--direct":
            guard arguments.count > 1 else {
                FileHandle.standardError.write(Data("usage: vervellum --direct \"your question\"\n".utf8))
                return 2
            }
            return runHeadless(question: arguments.dropFirst().joined(separator: " "), mode: .direct)
        case "--gapplication-service":
            // D-Bus activation passes this. GLib's own convention, and it must not be
            // treated as an unknown option: the session bus starts the app this way when
            // the keyboard shortcut fires and nothing is running yet.
            return runPanel(asService: true)
        case .some(let unknown) where unknown.hasPrefix("-"):
            FileHandle.standardError.write(Data("vervellum: unknown option \(unknown)\n".utf8))
            printUsage()
            return 2
        default:
            return runPanel(asService: false)
        }
    }

    private static func printUsage() {
        print("""
            vervellum — a hotkey-summoned research panel

            USAGE
              vervellum                    start the panel (or toggle a running one)
              vervellum --ask "question"    research a question and print the answer
              vervellum --deep "question"   research over several rounds, following up
                                            what the first pass missed
              vervellum --direct "question" answer without searching, badged as unsourced
              vervellum --install-shortcut  bind the summon shortcut in your desktop
              vervellum --version
              vervellum --help

            The panel is toggled by a desktop keyboard shortcut, which runs:
              gapplication action \(applicationID) toggle

            CONFIGURATION
              Settings live in ~/.config/vervellum/settings.json; threads in
              ~/.local/share/vervellum/threads.json (both honour the XDG variables).
              API keys go in your login keyring when one is available. They can also be
              supplied as VERVELLUM_MODEL_KEY and VERVELLUM_SEARCH_KEY, which is the
              right answer for a script or a container.
            """)
    }

    // MARK: Headless

    /// Runs one turn and prints it. Returns a shell-style exit code.
    private static func runHeadless(question: String, mode: ResearchRunner.Mode) -> Int32 {
        let environment = LinuxEnvironment()
        let settings = environment.preferences.providerSettings
        let problems = settings.problems(
            hasModelKey: environment.secrets.hasModelKey(for: settings),
            hasSearchKey: environment.secrets.hasSearchKey(for: settings),
            requiresSearch: mode.searches)
        guard problems.isEmpty else {
            FileHandle.standardError.write(Data(
                ("vervellum: not configured. " + problems.joined(separator: " ") + "\n").utf8))
            return 1
        }

        let runner = ResearchRunner(
            environment: .init(preferences: environment.preferences, secrets: environment.secrets),
            trace: ResearchTrace(sink: StandardErrorLog()),
            // A question typed as an argument carries nothing: there is no composer to
            // paste into and no turn on disk to inherit from. Stated rather than
            // defaulted, so a later change that gives the command line attachments has
            // to come through here.
            attachmentBytes: { _ in nil })
        var draft = ResearchTurn(question: question)
        draft.model = environment.preferences.providerSettings.modelName
        if mode == .direct { draft.notices = [.noEvidence] }
        // Immutable from here: the task's closure cannot capture a mutable variable.
        let turn = draft

        // A semaphore rather than an async `@main`: this process has no main loop to
        // give up, and the pipeline runs entirely on the cooperative pool.
        //
        // The results live in a class rather than in local `var`s because the task's
        // closure is concurrently-executing, and Swift does not allow such a closure to
        // mutate a captured variable — a captured *reference* it can.
        let output = Output()
        let finished = DispatchSemaphore(value: 0)

        Task {
            // No history: a one-shot command-line question is its own thread. Feeding
            // it the last GUI conversation would silently change the answer and cost
            // context the user did not ask to spend.
            output.turn = await runner.run(turn, mode: mode,
                                           history: []) { snapshot in
                // Progress goes to stderr so stdout stays a clean answer that can be
                // piped. Only stage *changes* are reported, or a streamed answer would
                // print a line per token.
                if snapshot.stage != output.lastStage {
                    output.lastStage = snapshot.stage
                    FileHandle.standardError.write(Data("… \(snapshot.stage.label)\n".utf8))
                }
            }
            finished.signal()
        }
        finished.wait()

        guard let result = output.turn else { return 1 }
        print(result.transcript)
        if let failure = result.failure {
            FileHandle.standardError.write(Data("vervellum: \(failure)\n".utf8))
            return 1
        }
        return 0
    }

    /// Somewhere for the headless run's task to put its results. See `runHeadless`.
    private final class Output {
        var turn: ResearchTurn?
        var lastStage: ResearchStage?
    }

    // MARK: Panel

    private static func runPanel(asService: Bool) -> Int32 {
        let application = gtk_application_new(applicationID, vv_app_default_flags())!
        let gapp = vv_gapp(application)

        if asService {
            // Started by the session bus rather than by a person. Without
            // `G_APPLICATION_IS_SERVICE`, GLib activates the application before entering
            // the main loop — so a cold shortcut press would show the panel *and then*
            // run the toggle action, hiding it again. The window should appear only when
            // something asks for it.
            g_application_set_flags(gapp, G_APPLICATION_IS_SERVICE)
        }

        // A stored reference: the panel must outlive the closure that creates it, and
        // GTK holds only a borrowed pointer to its window.
        var panel: LinuxPanel?
        func ensurePanel() -> LinuxPanel {
            if let panel { return panel }
            let created = LinuxPanel(application: application)
            panel = created
            return created
        }

        let toggle = g_simple_action_new("toggle", nil)!
        GTK.onActionActivated(UnsafeMutableRawPointer(toggle)) {
            // Builds the panel if it does not exist yet. When the session bus starts
            // Vervellum *because of* this action — which is what happens the first time
            // the shortcut is pressed after a reboot — GApplication invokes the action
            // without emitting "activate", so there is no window yet and a plain
            // `panel?.toggle()` would silently do nothing.
            ensurePanel().toggle()
        }
        g_action_map_add_action(vv_action_map(application), vv_action(toggle))

        let quit = g_simple_action_new("quit", nil)!
        GTK.onActionActivated(UnsafeMutableRawPointer(quit)) {
            g_application_quit(gapp)
        }
        g_action_map_add_action(vv_action_map(application), vv_action(quit))

        // The desktop entry's "Set Up Keyboard Shortcut" action. For a D-Bus-activatable
        // application GNOME does not run a desktop action's `Exec` line: it calls
        // `org.freedesktop.Application.ActivateAction` with the action's identifier, and
        // GApplication looks that name up here. The identifier in the `.desktop` file and
        // the name below must therefore match exactly — the same is true of "toggle".
        let installShortcut = g_simple_action_new("install-shortcut", nil)!
        GTK.onActionActivated(UnsafeMutableRawPointer(installShortcut)) {
            _ = ShortcutInstaller.install()
        }
        g_action_map_add_action(vv_action_map(application), vv_action(installShortcut))

        // Register explicitly and early, so the remote branch can bail out without ever
        // entering the main loop. This is the point at which the process learns whether
        // it is the primary instance.
        var error: UnsafeMutablePointer<GError>?
        guard g_application_register(gapp, nil, &error) != 0 else {
            let message = error.flatMap { $0.pointee.message.map { String(cString: $0) } }
                ?? "could not reach the session bus"
            FileHandle.standardError.write(Data("vervellum: \(message)\n".utf8))
            if let error { g_error_free(error) }
            return 1
        }

        if g_application_get_is_remote(gapp) != 0 {
            // A second invocation — which is what the keyboard shortcut produces. Hand
            // the action to the running instance and exit; the action is always
            // dispatched in the primary instance.
            g_action_group_activate_action(vv_action_group(application), "toggle", nil)
            if let connection = g_application_get_dbus_connection(gapp) {
                g_dbus_connection_flush_sync(connection, nil, nil)
            }
            return 0
        }

        GTK.onSignal(UnsafeMutableRawPointer(application), "activate") {
            ensurePanel().show()
        }

        // Without this a GApplication with no visible window exits, and a panel spends
        // most of its life with no window.
        g_application_hold(gapp)

        // The shortcut is installed on first run rather than from the package's
        // postinst: postinst runs as root with no user session bus and would write
        // root's dconf instead of the user's.
        ShortcutInstaller.installOnFirstRun(preferences: LinuxEnvironment.shared.preferences)

        return g_application_run(gapp, 0, nil)
    }
}
#endif
