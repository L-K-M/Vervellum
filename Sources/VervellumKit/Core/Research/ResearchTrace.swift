import Foundation

/// Per-run logging with a short shared identifier.
///
/// A research run fans out into a plan call, several searches, a streamed answer and an
/// assessment, all of which can interleave with another run the user started in a second
/// thread. Without a per-run tag the log is unreadable, so every line carries the same
/// eight-character id — the same idea as a request id in a server log.
///
/// What is logged is deliberately narrow: stage names, durations, counts and sizes.
/// Never a prompt, never a search result, never a key, and never a provider's own error
/// text. That keeps the log shareable in a bug report, which is the only reason it
/// exists. The rule lives here rather than in the sink so a new platform cannot weaken
/// it by supplying a chattier backend.
final class ResearchTrace {

    let id: String
    private let sink: LogSink
    /// Monotonic uptime rather than a wall-clock `Date`: a system clock adjustment
    /// mid-turn would otherwise make a stage duration negative or inflated, and the
    /// `%.1f` format would print it without complaint.
    private let started: TimeInterval

    init(id: String? = nil, sink: LogSink = StandardErrorLog()) {
        self.id = id ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        self.sink = sink
        self.started = Self.now()
    }

    func log(_ message: String) {
        sink.write(.info, "[\(id)] \(message)")
    }

    func warn(_ message: String) {
        sink.write(.warning, "[\(id)] \(message)")
    }

    /// Times `work`, logging its start, duration, and — on failure — a safe label for
    /// the error. A non-`ResearchError` is logged by *type name only*, because its
    /// description may contain the request URL or an authorization header.
    func stage<T>(_ label: String, _ work: () async throws -> T) async throws -> T {
        let began = Self.now()
        log("\(label) started")
        do {
            let value = try await work()
            log(String(format: "%@ completed in %.2fs", label, Self.now() - began))
            return value
        } catch {
            warn(String(format: "%@ failed after %.2fs: %@", label,
                        Self.now() - began, ResearchError.safeLabel(for: error)))
            throw error
        }
    }

    /// Seconds since the run began, for a final summary line.
    var elapsed: TimeInterval { Self.now() - started }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
