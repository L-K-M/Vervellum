import Dispatch
import Foundation

/// Finding a program on this machine and running it.
///
/// A seam, for the reason `HTTPTransporting` is one. Every other search backend talks
/// to a server, so a stubbed transport can drive a whole research turn in CI; the Kagi
/// backend talks to a program the user installed, and a test that had to install that
/// program would not run in CI at all. Behind this protocol, `KagiCLIClient` is as
/// testable as the HTTP clients — the argument list it builds, the environment it hands
/// over and the JSON it reads back are all assertable without a `kagi` binary existing.
///
/// The protocol is deliberately narrow: **one command, one set of arguments, one
/// environment, output back.** There is no shell, no working directory, no standard
/// input and no way to pass a string that a shell would re-split — see `CommandRunner`
/// for why that is the security property this whole file exists to hold.
protocol CommandRunning: AnyObject {

    /// The executable a command name or path refers to, or nil when there is none.
    ///
    /// Separate from `run` so a missing program is a *configuration* problem, reported
    /// while the provider settings are being validated, rather than a failure in the
    /// middle of a research turn the user is watching.
    func resolve(command: String) -> URL?

    /// Runs `executable` with exactly these arguments and exactly this environment.
    ///
    /// - Parameters:
    ///   - environment: the child's *whole* environment, not a set of additions to this
    ///     process's. See `CommandRunner.run` for why a third-party binary is handed
    ///     what it needs rather than everything Vervellum happens to be holding.
    ///   - limit: the most bytes of standard output to keep. A command that prints more
    ///     than this is stopped and the call fails, rather than a runaway program being
    ///     read into memory until something else breaks.
    ///   - timeout: how long the command may take before it is terminated.
    /// - Returns: the exit status and everything the command wrote to standard output.
    /// - Throws: `ResearchError` when the command could not be started, printed too
    ///   much, ran too long, or was cancelled. A command that ran and *failed* is not
    ///   an error here — it returns its non-zero status, and the caller decides.
    func run(executable: URL,
             arguments: [String],
             environment: [String: String],
             limit: Int,
             timeout: TimeInterval) async throws -> (status: Int32, output: Data)
}

/// Runs a program as a child process.
///
/// **Never through a shell.** `Process` is given an executable and an argument vector,
/// which the kernel passes to the child as separate strings — there is no parsing step
/// in between, so a quote, a semicolon or a backtick inside a search query is a quote, a
/// semicolon or a backtick. This matters more here than it would in a build script: the
/// query is written by a *model*, and in deep research that model has read pages found
/// by an earlier round. A page that could talk the planner into a well-chosen query
/// would, through `/bin/sh -c`, be talking it into a command. There is no code path in
/// this file that builds a command *string*, and there must never be one.
///
/// Three more bounds, none of them optional:
///
/// * **A minimal environment.** The child gets what the caller passes and nothing else.
///   A third-party binary inherits no model key, no reader key, and nothing else this
///   process happens to hold — see `KagiCLIClient.childEnvironment(apiKey:base:)` for
///   what a Kagi search actually needs.
/// * **Standard error goes nowhere.** It is never read, so a provider's own words can
///   never reach a log line or the panel, which is the rule the rest of the research
///   code follows for HTTP errors. It is attached to the null device rather than left
///   unset so that a chatty command cannot fill a pipe nobody is draining and block
///   forever.
/// * **Standard input is the null device**, so a command that decides to prompt reads
///   end-of-file and gives up instead of waiting for a terminal that is not there.
final class CommandRunner: CommandRunning {

    static let shared = CommandRunner()

    /// Concurrent on purpose. Reading a pipe blocks, and the timeout that has to fire
    /// *while* it blocks is scheduled on this same queue — on a serial one it would sit
    /// behind the read it exists to interrupt, and the timeout would never happen.
    private static let queue = DispatchQueue(label: "ch.lkmc.Vervellum.command",
                                             attributes: .concurrent)

    /// Read in chunks rather than to end-of-file: `readDataToEndOfFile` cannot notice
    /// that the output has grown past `limit` until it has already read all of it.
    private static let chunkSize = 64 * 1024

    /// How long a child gets to honour the signal that asks it to stop, before this call
    /// stops waiting for it.
    ///
    /// `Process.terminate()` sends `SIGTERM`, which is a *request*: a program is entitled
    /// to catch it, and a wedged one cannot answer at all. There is no `SIGKILL` from
    /// here — that needs `kill(2)` from a platform module, and nothing under `Core/` may
    /// import one — so the deadline is enforced on this side of the pipe instead. When
    /// the grace period passes, the caller is given its error and the turn moves on,
    /// whatever the child is doing.
    ///
    /// The cost is real and bounded: one dispatch thread stays parked on a read that will
    /// never end, for as long as that child lives. A hung search that ends the turn with
    /// an error beats one that never ends at all — without this, a child that ignored
    /// `SIGTERM` left the continuation unresumed and the research turn simply stopped,
    /// with nothing on screen to say why.
    static let terminationGrace: TimeInterval = 2

    // MARK: Resolving

    /// Where a bare command name is looked for, after `PATH`.
    ///
    /// This list is not redundant with `PATH`, and leaving it out would make the feature
    /// look broken to most of the people using it. A macOS menu-bar agent is launched by
    /// `launchd`, not by a shell, so it inherits `/usr/bin:/bin:/usr/sbin:/sbin` — a
    /// `PATH` that contains none of the places a CLI installs itself. The user's own
    /// shell finds `kagi` instantly and the app does not, which reads as a bug in the
    /// app rather than as the environment difference it is.
    ///
    /// Absolute paths only, and a fixed list: a relative directory in `PATH` means the
    /// program found depends on the working directory, which is not something a
    /// background app should be resolving executables against.
    static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        return path + [
            "/opt/homebrew/bin",                 // Homebrew, Apple silicon
            "/usr/local/bin",                    // Homebrew, Intel; and the usual manual install
            "/home/linuxbrew/.linuxbrew/bin",
            home + "/.local/bin",                // the install script's default
            home + "/.cargo/bin",                // cargo install
            home + "/.bun/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    func resolve(command: String) -> URL? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A path the user wrote is taken as a path, tilde and all, and is not searched
        // for anywhere else. Someone who types `/opt/kagi/bin/kagi` means that file.
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            let expanded = trimmed.hasPrefix("~/")
                ? NSHomeDirectory() + String(trimmed.dropFirst(1))
                : trimmed
            return Self.executableFile(at: expanded)
        }
        // Anything else with a slash in it is relative to this process's working
        // directory — the very dependence the fixed list above refuses to have, and a
        // background app's working directory is whatever it was launched with. Two
        // grammars are documented, a bare name and an absolute path; `./kagi` is neither,
        // and saying so at the settings screen beats resolving it against `/`.
        if trimmed.contains("/") { return nil }

        for directory in Self.searchDirectories {
            if let url = Self.executableFile(at: directory + "/" + trimmed) { return url }
        }
        return nil
    }

    /// The file at `path` if it is a program, or nil.
    ///
    /// The directory check is not pedantry: `isExecutableFile` is true of most
    /// directories, because that is what their execute bit means. Without it a command of
    /// `/tmp` passes configuration and fails much later as "could not start the search
    /// command", which sends whoever reads that looking in the wrong place.
    static func executableFile(at path: String) -> URL? {
        var isDirectory: ObjCBool = false
        let manager = FileManager.default
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              manager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    // MARK: Running

    func run(executable: URL,
             arguments: [String],
             environment: [String: String],
             limit: Int,
             timeout: TimeInterval) async throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        // Pinned rather than inherited, so where the child writes anything of its own
        // does not depend on the directory Vervellum happened to be launched from.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let control = Control(process: process) { reason in
            switch reason {
            case .timedOut:
                return ResearchError(
                    "The search command did not finish within \(Int(timeout)) seconds.")
            case .tooMuchOutput:
                return ResearchError(
                    "The search command printed more than \(limit / 1024) KB.")
            case .cancelled:
                return ResearchError.cancelled
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                control.attach(continuation)
                Self.queue.async {
                    let launched: Bool
                    do {
                        launched = try control.start()
                    } catch {
                        // The name is not in the message: it came from the settings, and
                        // the settings screen is where it can be fixed.
                        control.finish(throwing: ResearchError(
                            "Vervellum could not start the search command. Check the "
                            + "command in the provider settings."))
                        return
                    }
                    // Cancelled in the gap before the launch. Returning here rather than
                    // falling through matters: with no child holding the pipe's write
                    // end, the read below would block on a pipe that will never close.
                    guard launched else {
                        control.finish(throwing: ResearchError.cancelled)
                        return
                    }

                    let deadline = DispatchWorkItem { control.stop(because: .timedOut) }
                    Self.queue.asyncAfter(deadline: .now() + timeout, execute: deadline)

                    // Blocking here is safe exactly as far as `Control.stop` is: this ends
                    // when the child exits, and a child that will not exit is answered by
                    // the grace timer rather than by this thread — see `terminationGrace`.
                    let handle = pipe.fileHandleForReading
                    var output = Data()
                    while true {
                        let chunk = handle.readData(ofLength: Self.chunkSize)
                        if chunk.isEmpty { break }
                        output.append(chunk)
                        if output.count > limit {
                            control.stop(because: .tooMuchOutput)
                            break
                        }
                    }
                    process.waitUntilExit()
                    deadline.cancel()
                    try? handle.close()

                    guard let reason = control.reason else {
                        control.finish(returning: (process.terminationStatus, output))
                        return
                    }
                    // The deadline and a natural exit can land in the same moment, and
                    // `DispatchWorkItem.cancel()` cannot stop one that has already begun —
                    // so a search that finished can be sitting here labelled a timeout,
                    // with its results in hand. A child that exited by itself has an
                    // answer worth having, so it reports its own status. Only `.timedOut`
                    // is forgiven this way: `.tooMuchOutput` is decided by what *this*
                    // side read rather than by how the child died, and stays an error
                    // however it ended.
                    if reason == .timedOut, process.terminationReason == .exit {
                        control.finish(returning: (process.terminationStatus, output))
                        return
                    }
                    control.finish(throwing: control.failure(reason))
                }
            }
        } onCancel: {
            control.stop(because: .cancelled)
        }
    }

    /// The one piece of shared state, and the reason it is a type rather than a few
    /// captured variables: it is written from a timer, from a cancellation handler and
    /// from the reading thread, any of them can arrive first, and exactly one of them may
    /// resume the caller.
    private final class Control: @unchecked Sendable {

        enum Reason { case timedOut, tooMuchOutput, cancelled }

        /// How a stop reason is worded. Held here so `stop` can answer the caller from a
        /// timer without knowing what the timeout or the limit was.
        let failure: (Reason) -> Error

        private let process: Process
        private let lock = NSLock()
        private var running = false
        private var stopped: Reason?
        private var continuation: CheckedContinuation<(status: Int32, output: Data), Error>?

        init(process: Process, failure: @escaping (Reason) -> Error) {
            self.process = process
            self.failure = failure
        }

        var reason: Reason? {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func attach(_ continuation: CheckedContinuation<(status: Int32, output: Data), Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        /// Resumes the caller, once. Every later attempt is a no-op, which is what lets
        /// the grace timer and the reading thread both be free to end the call without
        /// either having to know whether the other got there first.
        func finish(returning value: (status: Int32, output: Data)) {
            take()?.resume(returning: value)
        }

        func finish(throwing error: Error) {
            take()?.resume(throwing: error)
        }

        private func take() -> CheckedContinuation<(status: Int32, output: Data), Error>? {
            lock.lock()
            defer { lock.unlock() }
            let pending = continuation
            continuation = nil
            return pending
        }

        /// Starts the process unless something already asked for it to stop, and says
        /// which happened. A task cancelled in the moment between the call and the
        /// launch must not leave a child running with nobody waiting for it — and the
        /// caller has to know that no child exists, because a great deal of what it does
        /// next assumes one is holding the other end of a pipe.
        func start() throws -> Bool {
            lock.lock()
            if stopped != nil {
                lock.unlock()
                return false
            }
            lock.unlock()
            try process.run()
            lock.lock()
            let cancelledDuringLaunch = stopped
            running = true
            lock.unlock()
            if let cancelledDuringLaunch { signal(because: cancelledDuringLaunch) }
            return true
        }

        /// Records why the command is being stopped and stops it. The first reason wins:
        /// a timeout that fires while a cancellation is already tearing the process down
        /// should not relabel what happened.
        func stop(because reason: Reason) {
            lock.lock()
            guard stopped == nil else {
                lock.unlock()
                return
            }
            stopped = reason
            let live = running
            lock.unlock()
            if live { signal(because: reason) }
        }

        /// Asks the child to stop, and makes sure the caller is answered whether or not it
        /// agrees to. See `CommandRunner.terminationGrace`.
        private func signal(because reason: Reason) {
            process.terminate()
            CommandRunner.queue.asyncAfter(
                deadline: .now() + CommandRunner.terminationGrace
            ) { [weak self] in
                guard let self else { return }
                self.finish(throwing: self.failure(reason))
            }
        }
    }
}
