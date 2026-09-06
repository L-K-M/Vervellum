import Foundation
import SwiftUI

/// The macOS front end's view model over the shared research pipeline.
///
/// Everything that decides *what* a research turn does — the four stages, the prompts,
/// the validation — lives in `ResearchRunner`, which knows nothing about AppKit,
/// SwiftUI or Combine and is compiled into the Linux build too. This class is the thin
/// part: it owns the thread, publishes changes to SwiftUI, and marshals the runner's
/// progress onto the main queue.
///
/// Keeping the split here rather than one layer down is deliberate. `ObservableObject`
/// comes from Combine, which does not exist on Linux, so an engine that published
/// directly could not be shared at all. A view model per platform over one pipeline is
/// a few dozen lines of forwarding and keeps every rule in one place.
final class ResearchEngine: ObservableObject {

    typealias Mode = ResearchRunner.Mode

    @Published private(set) var thread: ResearchThread
    @Published private(set) var isRunning = false

    private let preferences: CorePreferences
    private let secrets: SecretStore
    private let logSink: LogSink
    private var task: Task<Void, Never>?
    private var runningTurnID: UUID?

    /// Answer-only updates are coalesced to this rate during streaming.
    static let streamPublishInterval: TimeInterval = 0.1
    private var lastStreamPublish = Date.distantPast
    private var pendingSnapshot: ResearchTurn?
    private var streamFlushScheduled = false

    /// Called whenever the thread changes, so the store can persist it.
    var onThreadChanged: ((ResearchThread) -> Void)?

    init(thread: ResearchThread = ResearchThread(),
         preferences: CorePreferences,
         secrets: SecretStore,
         logSink: LogSink = OSLogSink()) {
        self.thread = thread
        self.preferences = preferences
        self.secrets = secrets
        self.logSink = logSink
    }

    // MARK: Thread control

    func replaceThread(with thread: ResearchThread) {
        cancel()
        self.thread = thread
    }

    func startNewThread() {
        cancel()
        thread = ResearchThread()
        publishChange()
    }

    /// Stops the running turn. The partial answer is kept: a half-written answer with
    /// its sources is often still useful, and discarding it would punish the user for
    /// changing their mind.
    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        if let id = runningTurnID {
            update(id) { turn in
                if !turn.stage.isTerminal {
                    turn.stage = .cancelled
                    turn.duration = Date().timeIntervalSince(turn.askedAt)
                }
            }
        }
        runningTurnID = nil
        pendingSnapshot = nil
        isRunning = false
        publishChange()
    }

    // MARK: Asking

    /// Appends a turn for `question` and starts researching it.
    func ask(_ question: String, mode: Mode = .research) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        var turn = ResearchTurn(question: trimmed)
        turn.model = preferences.providerSettings.modelName
        if mode == .direct { turn.notices = [.noEvidence] }
        thread.turns.append(turn)
        thread.updatedAt = Date()
        runningTurnID = turn.id
        isRunning = true
        publishChange()

        let id = turn.id
        // An immutable copy for the concurrent closure: capturing the mutable `turn`
        // would be a reference to a captured `var` in concurrently-executing code.
        let submitted = turn
        let history = thread.turns.filter { $0.id != id }
        let runner = ResearchRunner(
            environment: .init(preferences: preferences, secrets: secrets),
            trace: ResearchTrace(sink: logSink))

        task = Task { [weak self] in
            // The runner reports from whatever thread it is running on, so every
            // snapshot is hopped onto the main queue in order. `async` is FIFO, so the
            // streamed chunks arrive in the order they were produced.
            let finished = await runner.run(submitted, mode: mode, history: history) { snapshot in
                DispatchQueue.main.async { self?.apply(snapshot) }
            }
            // The same queue as the snapshots, not `MainActor.run`. Both land on the
            // main thread, but mixing the two mechanisms means the completion could be
            // scheduled ahead of snapshots already queued — and the final turn would
            // then be overwritten by an earlier, partial one.
            DispatchQueue.main.async { self?.finish(id, with: finished) }
        }
    }

    /// Re-runs one turn's question.
    ///
    /// Takes the turn's id rather than assuming the last one: a thread can hold several
    /// failed turns, and "retry" on the third of five must not silently delete the
    /// fifth. Only a turn that is still last is replaced in place; retrying an older one
    /// asks the question again at the end, where the answer belongs.
    func retry(_ id: UUID) {
        guard !isRunning, let turn = thread.turns.first(where: { $0.id == id }) else { return }
        let question = turn.question
        // Re-ask the way the user asked. A turn the *planner* decided needed no search
        // also carries the no-evidence notice, but should be researched again in full.
        let mode: Mode = turn.wasAskedDirectly ? .direct : .research
        if thread.turns.last?.id == id { thread.turns.removeLast() }
        ask(question, mode: mode)
    }

    // MARK: Turn mutation

    private func apply(_ snapshot: ResearchTurn) {
        guard let index = thread.turns.firstIndex(where: { $0.id == snapshot.id }) else { return }

        // A streamed answer publishes one snapshot per token, and each publish
        // re-renders the thread — re-parsing the whole answer's markdown on every
        // render, which is O(answer²) per turn. Coalesce updates that change only
        // the prose (or the running clock) to ~10 Hz; anything structural — a new
        // stage, sources, verdicts, a failure — publishes immediately, because those
        // are the moments the user is waiting on. The Linux front end does the same
        // split in `LinuxPanel.apply`.
        var previous = thread.turns[index]
        var incoming = snapshot
        previous.answer = ""
        previous.duration = nil
        incoming.answer = ""
        incoming.duration = nil
        let proseOnly = previous == incoming

        if proseOnly, !snapshot.stage.isTerminal,
           Date().timeIntervalSince(lastStreamPublish) < Self.streamPublishInterval {
            pendingSnapshot = snapshot
            scheduleStreamFlush()
            return
        }
        publish(snapshot, at: index)
    }

    private func publish(_ snapshot: ResearchTurn, at index: Int) {
        lastStreamPublish = Date()
        thread.turns[index] = snapshot
        thread.updatedAt = Date()
    }

    /// Trailing-edge flush for coalesced snapshots. The snapshot is dropped unless
    /// its turn is still the running one: `finish` publishes the terminal state
    /// itself, and applying a stale partial *after* it would visibly regress the
    /// answer to an earlier chunk.
    private func scheduleStreamFlush() {
        guard !streamFlushScheduled else { return }
        streamFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.streamPublishInterval) { [weak self] in
            guard let self else { return }
            self.streamFlushScheduled = false
            guard let pending = self.pendingSnapshot, pending.id == self.runningTurnID else { return }
            self.pendingSnapshot = nil
            self.apply(pending)
        }
    }

    private func update(_ id: UUID, _ body: (inout ResearchTurn) -> Void) {
        guard let index = thread.turns.firstIndex(where: { $0.id == id }) else { return }
        body(&thread.turns[index])
        thread.updatedAt = Date()
    }

    private func finish(_ id: UUID, with turn: ResearchTurn) {
        apply(turn)
        if runningTurnID == id {
            runningTurnID = nil
            isRunning = false
            task = nil
        }
        publishChange()
    }

    private func publishChange() {
        onThreadChanged?(thread)
    }
}
