import Foundation

/// Where a research run's diagnostics go.
///
/// A seam rather than a direct dependency because `os.Logger` is Apple-only, and the
/// pipeline this logs is shared with Linux. It is deliberately the narrowest possible
/// protocol: the rule about *what* may be logged (stage names, durations, counts and
/// sizes — never a prompt, a search result, a key, or a provider's error text) lives in
/// `ResearchTrace`, so a new platform cannot weaken it by supplying a chattier sink.
protocol LogSink {
    /// Implementations must tolerate concurrent `write` calls: the search fan-out
    /// runs several backends at once, and each may log from its own task. A sink
    /// with mutable state must serialise it itself.
    func write(_ level: LogLevel, _ message: String)
}

enum LogLevel {
    case info
    case warning
}

/// The default sink: one line per event on standard error.
///
/// Standard error rather than standard output so a future `--json` mode can own stdout,
/// and unbuffered so a crash does not swallow the last thing that happened. Locked
/// rather than relying on POSIX write atomicity, because concurrent search tasks may
/// interleave and a torn line is a line nobody can read.
struct StandardErrorLog: LogSink {
    private let lock = NSLock()

    func write(_ level: LogLevel, _ message: String) {
        let prefix = level == .warning ? "warning" : "info"
        let line = Data("vervellum \(prefix): \(message)\n".utf8)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(line)
    }
}

/// Discards everything. Used by tests, so a suite does not spray a thousand lines.
struct SilentLog: LogSink {
    func write(_ level: LogLevel, _ message: String) {}
}
