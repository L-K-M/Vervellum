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

    /// A question typed while a turn was still running.
    struct QueuedQuestion: Identifiable, Equatable {
        let id: UUID
        var question: String
        var mode: Mode

        init(id: UUID = UUID(), question: String, mode: Mode) {
            self.id = id
            self.question = question
            self.mode = mode
        }
    }

    /// What `ask` did with a question, so the caller knows whether to clear the
    /// composer. Returned rather than re-derived from `isRunning`, which by the time
    /// the caller could read it has already changed.
    enum AskOutcome: Equatable {
        /// Research started immediately.
        case started
        /// A turn was already running; this one waits for it.
        case queued
        /// The queue is full. Nothing was recorded — the caller keeps the text.
        case queueFull
        /// Nothing but whitespace.
        case ignored
    }

    @Published private(set) var thread: ResearchThread
    @Published private(set) var isRunning = false

    /// Questions asked while a turn was running, oldest first. Each starts on its own
    /// as the thread frees up.
    ///
    /// A queue rather than a second concurrent run: two runs against one thread would
    /// each be answered without the other's evidence, and the second would land in the
    /// transcript above conversation it had never seen. It is bounded because a queue
    /// with no visible end is a way to spend a provider's quota by accident.
    @Published private(set) var queue: [QueuedQuestion] = []

    /// The most questions that may wait at once.
    static let maxQueued = 3

    private let preferences: CorePreferences
    private let secrets: SecretStore
    private let logSink: LogSink
    private let makeRunner: (ResearchRunner.Environment, ResearchTrace) -> ResearchRunning
    private let deliver: (@escaping () -> Void) -> Void
    private var task: Task<Void, Never>?
    private var runningTurnID: UUID?

    /// Rate-limits the streamed snapshots before they republish the thread. See
    /// `SnapshotCoalescer` for the rule; optional because it can only be built in
    /// `init` (its publish closure needs `self`), and every use is a `?.` rather than
    /// an implicit unwrap.
    private var coalescer: SnapshotCoalescer?

    /// Called whenever the thread changes, so the store can persist it.
    var onThreadChanged: ((ResearchThread) -> Void)?

    /// Called with questions that were waiting and will not now be asked — after a Stop,
    /// or after a run that did not complete. The front end puts them back in the composer.
    ///
    /// Typed text is the one thing here the user cannot recover, so it is never simply
    /// dropped. Running the queue anyway would be worse: after a Stop it would ignore the
    /// Stop, and after a failure it would fire the rest of the queue at a provider that
    /// had just refused, spending a request per question to collect the same error again.
    var onQueueReturned: (([String]) -> Void)?

    init(thread: ResearchThread = ResearchThread(),
         preferences: CorePreferences,
         secrets: SecretStore,
         logSink: LogSink = OSLogSink(),
         makeRunner: @escaping (ResearchRunner.Environment, ResearchTrace) -> ResearchRunning = {
             // Nothing can be attached on this front end yet; the composer comes in a
             // later change, and this is the line it will come through.
             ResearchRunner(environment: $0, trace: $1, attachmentBytes: { _ in nil })
         },
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         }) {
        self.thread = thread
        self.preferences = preferences
        self.secrets = secrets
        self.logSink = logSink
        self.makeRunner = makeRunner
        self.deliver = deliver
        coalescer = SnapshotCoalescer(
            after: after,
            publish: { [weak self] turn in self?.applyNow(turn) })
    }

    // MARK: Thread control

    func replaceThread(with thread: ResearchThread) {
        // Queued questions are dropped rather than handed back: they were follow-ups to
        // a conversation being put away, and pasting them into the composer over a
        // thread they were not about is worse than losing them.
        stopRunningTurn(returningQueue: false)
        self.thread = thread
    }

    func startNewThread() {
        stopRunningTurn(returningQueue: false)
        thread = ResearchThread()
        publishChange()
    }

    /// Stops the running turn. The partial answer is kept: a half-written answer with
    /// its sources is often still useful, and discarding it would punish the user for
    /// changing their mind.
    ///
    /// Stop means stop *everything that was asked for*, so anything still queued is
    /// cancelled too — and handed back to the composer rather than thrown away.
    func cancel() {
        stopRunningTurn(returningQueue: true)
    }

    /// Drops one waiting question. The composer keeps whatever is in it: this is the
    /// user removing a chip, not a Stop.
    func removeQueued(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    private func stopRunningTurn(returningQueue: Bool) {
        let pending = queue
        if !pending.isEmpty { queue.removeAll() }
        if returningQueue, !pending.isEmpty { onQueueReturned?(pending.map(\.question)) }

        guard let task else { return }
        coalescer?.flush()
        coalescer?.discardPending()
        task.cancel()
        self.task = nil
        if let id = runningTurnID {
            update(id) { turn in
                if !turn.stage.isTerminal {
                    turn.stage = .cancelled
                    turn.duration = Date().timeIntervalSince(turn.askedAt)
                    turn.applyCitationValidation(sourceCount: turn.sources.count)
                }
            }
        }
        runningTurnID = nil
        isRunning = false
        publishChange()
    }

    // MARK: Asking

    /// Researches `question`, or queues it when a turn is already running.
    ///
    /// The composer stays live during a run precisely so a follow-up or a clarification
    /// can be typed while the answer is still arriving — which is when it occurs to you —
    /// and this is where that text goes.
    @discardableResult
    func ask(_ question: String, mode: Mode = .research) -> AskOutcome {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        guard !isRunning else {
            guard queue.count < Self.maxQueued else { return .queueFull }
            queue.append(QueuedQuestion(question: trimmed, mode: mode))
            return .queued
        }
        start(trimmed, mode: mode)
        return .started
    }

    /// Appends a turn for an already-trimmed question and starts researching it.
    private func start(_ trimmed: String, mode: Mode) {
        // Re-checked rather than assumed: `retry` reaches here with a stored question,
        // and a turn with an empty one would be researched, persisted and sent as
        // history to every later turn in the thread.
        guard !trimmed.isEmpty else { return }
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
        let runner = makeRunner(.init(preferences: preferences, secrets: secrets),
                                ResearchTrace(sink: logSink))

        let deliver = self.deliver
        task = Task { [weak self] in
            // The runner reports from whatever thread it is running on, so every
            // snapshot is hopped onto the main queue in order. `async` is FIFO, so the
            // streamed chunks arrive in the order they were produced.
            let finished = await runner.run(submitted, mode: mode, history: history) { snapshot in
                deliver { self?.apply(snapshot) }
            }
            // The same queue as the snapshots, not `MainActor.run`. Both land on the
            // main thread, but mixing the two mechanisms means the completion could be
            // scheduled ahead of snapshots already queued — and the final turn would
            // then be overwritten by an earlier, partial one.
            deliver { self?.finish(id, with: finished) }
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
        // `start`, not `ask`: the guard above has already established nothing is running,
        // and a retry that landed in the queue behind other questions would rewrite a
        // turn the user was looking at some time later, out of order.
        start(question.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode)
    }

    // MARK: Turn mutation

    /// A snapshot from the running turn. Runs on the main queue (see `ask`), which is
    /// the queue the coalescer is documented to live on.
    private func apply(_ snapshot: ResearchTurn) {
        guard snapshot.id == runningTurnID else { return }
        coalescer?.receive(snapshot)
    }

    /// Publishes a snapshot directly — the coalescer's flush path and `finish`'s final
    /// turn both land here.
    private func applyNow(_ snapshot: ResearchTurn) {
        guard snapshot.id == runningTurnID,
              let index = thread.turns.firstIndex(where: { $0.id == snapshot.id }) else { return }
        thread.turns[index] = snapshot
        thread.updatedAt = Date()
        // Published here rather than only at ask/finish so the debounced archive keeps
        // receiving the growing answer: a crash mid-stream used to lose everything the
        // run had produced so far, because nothing called save between the two.
        publishChange()
    }

    private func update(_ id: UUID, _ body: (inout ResearchTurn) -> Void) {
        guard let index = thread.turns.firstIndex(where: { $0.id == id }) else { return }
        body(&thread.turns[index])
        thread.updatedAt = Date()
    }

    private func finish(_ id: UUID, with turn: ResearchTurn) {
        // A cancelled run cannot overwrite Stop or discard a newer run's pending work.
        guard runningTurnID == id else { return }
        // The finished turn is the whole truth; any coalesced snapshot still waiting is
        // older by definition, and a scheduled flush firing after this would otherwise
        // repaint the turn as mid-answer.
        coalescer?.discardPending()
        applyNow(turn)
        runningTurnID = nil
        isRunning = false
        task = nil
        publishChange()
        startNextQueued(after: turn)
    }

    /// Starts the next waiting question, or hands the queue back.
    ///
    /// Only a turn that *completed* pulls the next one. A failed turn usually means a
    /// provider, a key or a quota — conditions the next question would meet unchanged —
    /// so the queue goes back to the composer, where the user can fix the setting and
    /// press Return, instead of collecting the same error once per queued question.
    private func startNextQueued(after finished: ResearchTurn) {
        guard !queue.isEmpty else { return }
        guard finished.stage == .complete else {
            let pending = queue
            queue.removeAll()
            onQueueReturned?(pending.map(\.question))
            return
        }
        let next = queue.removeFirst()
        start(next.question, mode: next.mode)
    }

    /// Make the latest displayed progress durable before dismissal or termination.
    func flushProgress() {
        coalescer?.flush()
    }

    private func publishChange() {
        onThreadChanged?(thread)
    }
}
