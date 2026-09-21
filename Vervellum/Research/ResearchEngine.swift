import Foundation
import SwiftUI

/// The macOS front end's view model over the shared research pipeline.
///
/// Everything that decides *what* a research turn does — the four stages, the prompts,
/// the validation — lives in `ResearchRunner`, which knows nothing about AppKit,
/// SwiftUI or Combine and is compiled into the Linux build too. This class is the thin
/// part: it keeps one `ResearchSession` per open thread, publishes the session on
/// screen to SwiftUI, and marshals every session's progress onto the main queue.
///
/// Keeping the split here rather than one layer down is deliberate. `ObservableObject`
/// comes from Combine, which does not exist on Linux, so an engine that published
/// directly could not be shared at all. A view model per platform over one pipeline is
/// a few dozen lines of forwarding and keeps every rule in one place.
///
/// One session per thread, not one run for the panel: `/new` and `/history` detach the
/// session they leave rather than cancel it, so a question asked in one thread keeps
/// answering — and keeps persisting — while another thread is on screen. The engine
/// publishes only the active session; the map is what keeps the detached ones alive.
final class ResearchEngine: ObservableObject {

    typealias Mode = ResearchRunner.Mode
    typealias QueuedQuestion = ResearchSession.QueuedQuestion
    typealias AskOutcome = ResearchSession.AskOutcome
    static var maxQueued: Int { ResearchSession.maxQueued }

    /// The thread on screen — the active session's copy, republished as it mutates.
    @Published private(set) var thread: ResearchThread
    /// Whether the *visible* thread is researching. Composer affordances key off this;
    /// a run continuing on another thread does not say "busy" here.
    @Published private(set) var isRunning = false
    /// The visible session's waiting questions, oldest first.
    @Published private(set) var queue: [QueuedQuestion] = []
    /// Every thread with a run in flight, visible or not — what `HistoryView` badges.
    @Published private(set) var runningThreadIDs: Set<UUID> = []
    /// Whether any session is researching. The panel's "stay open on focus loss" check
    /// and the status item both mean *any* run — a detached one still counts.
    @Published private(set) var isBusy = false

    private let preferences: CorePreferences
    private let secrets: SecretStore
    private let logSink: LogSink
    private let makeRunner: (ResearchRunner.Environment, ResearchTrace,
                             @escaping (Attachment) -> Data?) -> ResearchRunning
    private let attachmentStore: AttachmentStore
    private let deliver: (@escaping () -> Void) -> Void
    private let after: (TimeInterval, @escaping () -> Void) -> Void

    /// Every open thread's session, running or idle, keyed by thread id. A detached
    /// session is retained here — nothing else holds it — so removing one is also how
    /// `discardSession` guarantees a deleted thread's run really ends.
    private var sessions: [UUID: ResearchSession] = [:]
    private var activeSession: ResearchSession

    /// Called whenever any session's thread changes, so the store can persist it.
    /// Detached sessions persist too — the run the user left is still producing the
    /// thread they will come back to.
    var onThreadChanged: ((ResearchThread) -> Void)?

    /// Called with the *visible* session's returned questions — after a Stop, or after
    /// a run that did not complete. The front end puts them back in the composer.
    ///
    /// A detached session's returned queue is deliberately dropped rather than saved
    /// for later: the questions were follow-ups to a conversation that is not on
    /// screen, and resurfacing them in a composer that is about a different thread is
    /// worse than losing them. The questions are gone either way once their thread's
    /// session is discarded.
    var onQueueReturned: (([QueuedQuestion]) -> Void)?

    init(thread: ResearchThread = ResearchThread(),
         preferences: CorePreferences,
         secrets: SecretStore,
         logSink: LogSink = OSLogSink(),
         attachmentStore: AttachmentStore = AttachmentStore(directory: ThreadStore.attachmentDirectory),
         makeRunner: @escaping (ResearchRunner.Environment, ResearchTrace,
                                @escaping (Attachment) -> Data?) -> ResearchRunning = {
             ResearchRunner(environment: $0, trace: $1, attachmentBytes: $2)
         },
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         }) {
        self.preferences = preferences
        self.secrets = secrets
        self.logSink = logSink
        self.attachmentStore = attachmentStore
        self.makeRunner = makeRunner
        self.deliver = deliver
        self.after = after
        let initial = thread
        let session = ResearchSession(thread: initial, preferences: preferences,
                                      secrets: secrets, logSink: logSink,
                                      attachmentStore: attachmentStore,
                                      makeRunner: makeRunner,
                                      deliver: deliver, after: after)
        self.thread = initial
        self.activeSession = session
        sessions[session.id] = session
        wire(session)
    }

    // MARK: Thread control

    /// Puts `thread` on screen. If a session is already live for it — a run detached
    /// and still working — that session is reactivated, not restarted: the panel picks
    /// the thread up mid-answer, with its queue and its snapshots intact.
    func replaceThread(with thread: ResearchThread) {
        if let live = sessions[thread.id] {
            activate(live)
            return
        }
        activate(makeSession(thread: thread))
    }

    /// Opens a fresh thread. The current session is detached, not stopped — a run in
    /// flight keeps going in the map, still reporting and still persisting, until the
    /// thread is deleted or the session finishes on its own.
    func startNewThread() {
        activate(makeSession(thread: ResearchThread()))
    }

    /// Deletes a thread's session entirely — the thread itself is being removed, so
    /// the run is cancelled *without* keeping its result and the session's callbacks
    /// are sealed. The archive's tombstone stops a late save; this stops the work.
    func discardSession(for id: UUID) {
        guard let session = sessions[id] else { return }
        session.discard()
        sessions.removeValue(forKey: id)
        // The deleted thread may be the one on screen. What replaces it is a fresh
        // session: the panel should land somewhere that exists.
        if activeSession === session {
            activate(makeSession(thread: ResearchThread()))
        }
        syncRunning()
    }

    /// `deleteAll`'s counterpart: every session ends and the panel starts over.
    func discardAllSessions() {
        for session in sessions.values { session.discard() }
        sessions.removeAll()
        activate(makeSession(thread: ResearchThread()))
        syncRunning()
    }

    // MARK: Asking

    @discardableResult
    func ask(_ question: String, mode: Mode? = nil,
             attachments: [PendingAttachment] = []) -> AskOutcome {
        activeSession.ask(question, mode: mode, attachments: attachments)
    }

    func retry(_ id: UUID) {
        activeSession.retry(id)
    }

    /// Stops the visible thread's running turn. A detached thread's run is unaffected —
    /// Stop means stop *this* conversation's work.
    func cancel() {
        activeSession.cancel()
    }

    func removeQueued(_ id: UUID) {
        activeSession.removeQueued(id)
    }

    /// Make every session's latest displayed progress durable before dismissal or
    /// termination — a detached run's coalesced snapshot is its thread's too.
    func flushProgress() {
        for session in sessions.values { session.flushProgress() }
    }

    // MARK: Sessions

    private func makeSession(thread: ResearchThread) -> ResearchSession {
        let session = ResearchSession(thread: thread, preferences: preferences,
                                      secrets: secrets, logSink: logSink,
                                      attachmentStore: attachmentStore,
                                      makeRunner: makeRunner,
                                      deliver: deliver, after: after)
        wire(session)
        return session
    }

    /// Puts a session on screen and republishes its current state: reactivating a live
    /// session shows the thread as it actually is, mid-run, not the copy that was
    /// persisted when it was left.
    private func activate(_ session: ResearchSession) {
        sessions[session.id] = session
        activeSession = session
        thread = session.thread
        queue = session.queue
        isRunning = session.isRunning
        syncRunning()
    }

    private func wire(_ session: ResearchSession) {
        session.onChange = { [weak self] session in
            guard let self else { return }
            if session === self.activeSession {
                self.thread = session.thread
                self.queue = session.queue
                if self.isRunning != session.isRunning {
                    self.isRunning = session.isRunning
                }
            }
            // Persisted whether or not the session is on screen — the archive upserts
            // by thread id, so a detached run writes its own thread and no other.
            self.onThreadChanged?(session.persistableThread)
            self.syncRunning()
        }
        session.onRunningChange = { [weak self] _ in
            self?.syncRunning()
        }
        session.onQueueReturned = { [weak self] session, questions in
            guard let self, session === self.activeSession else { return }
            self.onQueueReturned?(questions)
        }
    }

    /// Recomputes the derived running state from the map. Called from every session
    /// callback rather than diffed against one task, so a detached run starting or
    /// finishing lands here the same way the visible one does.
    private func syncRunning() {
        let running = Set(sessions.values.filter(\.isRunning).map(\.id))
        if runningThreadIDs != running { runningThreadIDs = running }
        if isBusy != !running.isEmpty { isBusy = !running.isEmpty }
        if isRunning != activeSession.isRunning { isRunning = activeSession.isRunning }
    }
}
