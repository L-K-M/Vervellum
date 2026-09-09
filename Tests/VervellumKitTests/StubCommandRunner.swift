import Foundation
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// A scripted `CommandRunning`, so the Kagi backend can be driven without a `kagi`
/// binary on the machine.
///
/// The counterpart to `StubTransport`, and honest in the same two ways. It answers a
/// **call** — a resolved executable and an argument vector — rather than a method, so the
/// real client builds the vector, checks the model's values and parses the output; and it
/// **records** every call, because the argument vector is the thing worth asserting. Half
/// of what `KagiCLIClient` promises is about what does *not* end up in that vector.
///
/// An unrouted command fails loudly rather than returning empty output: a search
/// answered with nothing looks, from inside the runner, exactly like a provider that
/// found nothing, and the test would then fail somewhere else naming the wrong thing.
final class StubCommandRunner: CommandRunning, @unchecked Sendable {

    /// One command the client ran.
    ///
    /// Checked `Sendable`, unlike `StubTransport.Call`: every property here is an
    /// immutable value the compiler can already prove sendable, so there is nothing to
    /// promise on its behalf — and a field added later that breaks that gets an error
    /// rather than a silent pass.
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let limit: Int
        let timeout: TimeInterval

        /// The command line as a shell would *display* it — for assertions and failure
        /// messages only. Nothing in Vervellum ever builds this string to run it.
        var line: String { ([executable.path] + arguments).joined(separator: " ") }
    }

    /// What a command is answered with.
    ///
    /// Checked `Sendable` like `Call`, and for the same reason: `ResearchError` is a
    /// struct holding one `String`, so every payload here is already provably sendable
    /// and there is nothing to promise on the compiler's behalf.
    enum Reply: Sendable {
        /// It ran and printed this on standard output.
        case output(status: Int32, text: String)
        /// It could not be run at all — the shape of a timeout, a cancellation, or a
        /// program that would not start.
        case failure(ResearchError)
        /// Nothing in the script recognises this command.
        case unrouted
    }

    private let executable: URL?
    private let route: @Sendable (Call) -> Reply
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var resolveRequests: [String] = []

    /// - Parameters:
    ///   - executable: what `resolve` answers with, or nil to stand in for a machine
    ///     where the tool is not installed.
    ///   - route: answers a command, or `.unrouted` if the script has no answer.
    init(executable: URL? = URL(fileURLWithPath: "/opt/test/bin/kagi"),
         _ route: @escaping @Sendable (Call) -> Reply) {
        self.executable = executable
        self.route = route
    }

    /// Every command run, in order.
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Every command name `resolve` was asked about, in order.
    var resolved: [String] {
        lock.lock()
        defer { lock.unlock() }
        return resolveRequests
    }

    // MARK: CommandRunning

    func resolve(command: String) -> URL? {
        lock.lock()
        resolveRequests.append(command)
        lock.unlock()
        return executable
    }

    func run(executable: URL,
             arguments: [String],
             environment: [String: String],
             limit: Int,
             timeout: TimeInterval) async throws -> (status: Int32, output: Data) {
        let call = Call(executable: executable, arguments: arguments,
                        environment: environment, limit: limit, timeout: timeout)
        lock.lock()
        recorded.append(call)
        lock.unlock()

        switch route(call) {
        case .output(let status, let text):
            return (status, Data(text.utf8))
        case .failure(let error):
            throw error
        case .unrouted:
            throw ResearchError("StubCommandRunner: nothing routes `\(call.line)`.")
        }
    }
}

// MARK: Building replies

extension StubCommandRunner.Reply {

    /// A `kagi search --format json` reply, in the shape the tool documents:
    /// `{"data":[{"t":0,"rank":1,"title":…,"url":…,"snippet":…,"published":…}]}`.
    static func kagiResults(_ hits: [(url: String, title: String)]) -> StubCommandRunner.Reply {
        let data = hits.enumerated().map { offset, hit in
            [
                "t": 0,
                "rank": offset + 1,
                "title": hit.title,
                "url": hit.url,
                "snippet": "A summary of \(hit.title).",
                "published": NSNull(),
            ] as [String: Any]
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: ["data": data]),
              let text = String(data: encoded, encoding: .utf8) else {
            preconditionFailure("StubCommandRunner: this fixture is not encodable as JSON.")
        }
        return .output(status: 0, text: text)
    }
}
