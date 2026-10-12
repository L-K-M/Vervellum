import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// Exercises the hosted transcript, including AppKit text and SwiftUI scrolling. A
/// model-only test cannot detect a view graph that keeps the main run loop occupied.
final class TranscriptLayoutTests: XCTestCase {

    func testCompletedCitedAnswersRemainReadableAfterAShortFollowupAndResize() throws {
        // XCTest can invoke a synchronous test off the main thread. AppKit still owns
        // its usual thread, and the waits below let its real run loop perform layout.
        if Thread.isMainThread {
            try exerciseTranscript()
        } else {
            try DispatchQueue.main.sync { try exerciseTranscript() }
        }
    }

    private func exerciseTranscript() throws {
        let suite = "VervellumTranscriptTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = Preferences(defaults: defaults)
        // PanelRootView's onAppear asks its own KeychainStore about the selected
        // providers. With neither selected, both lookups return before reading a key.
        // The injected runner needs no provider, so this is a complete isolated panel.
        preferences.providerSettings = ProviderSettings(modelProfiles: [], searchProfiles: [])
        let store = ThreadStore(fileURL: directory.appendingPathComponent("threads.json"))
        let started = expectation(description: "Follow-up runner started")
        let runner = ManualRunner(onStart: started.fulfill)
        defer { runner.finish() }
        var thread = ResearchThread()
        thread.turns = [citedTurn(number: 1), citedTurn(number: 2)]
        let engine = ResearchEngine(thread: thread, preferences: preferences.core,
                                    secrets: EphemeralSecretStore(), logSink: SilentLog(),
                                    attachmentStore: store.attachmentStore,
                                    makeRunner: { _, _, _ in runner })
        let hosting = NSHostingView(rootView: PanelRootView(
            engine: engine, store: store, preferences: preferences,
            onOpenSettings: {}, onClose: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }

        heartbeat("Initial transcript layout")
        let scroll = try XCTUnwrap(descendants(of: NSScrollView.self, in: hosting).first)
        try settle(scroll)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height,
                             scroll.contentView.bounds.height,
                             "The fixture must require scrolling to its older answers")

        XCTAssertEqual(engine.ask("Short follow-up question", mode: .direct), .started)
        wait(for: [started], timeout: 3)
        for answer in ["Follow-up", "Follow-up response", "Follow-up response remains readable."] {
            runner.emit(answer)
            heartbeat("Streamed follow-up layout")
        }
        let completed = expectation(description: "Completed follow-up published")
        engine.onThreadChanged = { changed in
            store.save(changed)
            if changed.turns.last?.stage == .complete {
                completed.fulfill()
            }
        }
        runner.finish()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(engine.thread.turns.count, 3)
        XCTAssertTrue(engine.thread.turns.last?.notices.contains(.noEvidence) == true)

        // Scroll in both directions and rewrap at different widths. This crosses the
        // visibility boundary between large cited rows and the short completed row,
        // where lazy layout can keep invalidating the hosted text views indefinitely.
        for width in [CGFloat(420), CGFloat(620), CGFloat(480)] {
            window.setContentSize(NSSize(width: width, height: 540))
            try settle(scroll)
            scrollToEnd(scroll, bottom: false)
            try settle(scroll)
            try assertVisible("Earlier research question 1", in: hosting, scroll: scroll)
            scrollToEnd(scroll, bottom: true)
            try settle(scroll)
            try assertVisible("Follow-up response remains readable.", in: hosting, scroll: scroll)
        }
        XCTAssertFalse(engine.isRunning)
        store.flush()
    }

    /// A queue callback proves that layout returned control to AppKit. The outer
    /// Xcode per-test timeout also catches a flush that never returns to this waiter.
    private func heartbeat(_ description: String) {
        let beat = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { beat.fulfill() }
        wait(for: [beat], timeout: 3)
    }

    /// Allow asynchronous layout to finish, then require the scroll geometry to stay
    /// fixed across two more run-loop turns. No assertion depends on a frame rate.
    private func settle(_ scroll: NSScrollView) throws {
        var previous: NSRect?
        var stable = 0
        for _ in 0..<24 {
            heartbeat("Transcript layout yielded")
            let frame = try XCTUnwrap(scroll.documentView).frame
            XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
            XCTAssertGreaterThan(frame.height, 0)
            if let previous,
               abs(frame.width - previous.width) < 0.5,
               abs(frame.height - previous.height) < 0.5 {
                stable += 1
                if stable == 2 { return }
            } else {
                stable = 0
            }
            previous = frame
        }
        XCTFail("Transcript geometry did not settle after layout and scrolling")
    }

    private func scrollToEnd(_ scroll: NSScrollView, bottom: Bool) {
        guard let document = scroll.documentView else { return }
        let end = max(0, document.frame.height - scroll.contentView.bounds.height)
        let y = (bottom == document.isFlipped) ? end : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func assertVisible(_ text: String, in hosting: NSView,
                               scroll: NSScrollView) throws {
        let view = try XCTUnwrap(descendants(of: NSTextView.self, in: hosting)
            .first { $0.string.contains(text) }, "Transcript text was not rendered: \(text)")
        XCTAssertGreaterThan(view.frame.height, 0, "A measured answer must actually be drawn")
        let rect = view.convert(view.bounds, to: scroll.contentView)
        XCTAssertTrue(rect.intersects(scroll.contentView.bounds),
                      "Scrolling must leave the requested answer visible")
        // The visible text must also remain selectable. This reads the selected
        // storage directly so the test never changes the user's pasteboard.
        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertTrue(view.isSelectable)
        let range = (storage.string as NSString).range(of: text)
        guard range.location != NSNotFound else {
            XCTFail("The visible text disappeared from its drawing storage")
            return
        }
        view.setSelectedRange(range)
        XCTAssertEqual(storage.attributedSubstring(from: view.selectedRange()).string, text)
        XCTAssertNotNil(view.layoutManager)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func citedTurn(number: Int) -> ResearchTurn {
        var turn = ResearchTurn(question: "Earlier research question \(number)")
        turn.stage = .complete
        turn.sources = [Source(number: 1, url: "https://retrieved.example/source",
                               title: "Retrieved source", snippet: "Evidence summary")]
        turn.answer = (1...24).map { paragraph in
            "Evidence paragraph \(number).\(paragraph) explains the retrieved finding. "
                + "The detail is long enough to wrap at the panel's normal width, and "
                + "the completed answer keeps its original source citation [1]."
        }.joined(separator: "\n\n")
        return turn
    }

    /// Runs the same engine/session delivery path as production, with the model and
    /// network replaced by explicit snapshots. One parked continuation at a time.
    private final class ManualRunner: ResearchRunning {
        private let lock = NSLock()
        private let onStart: () -> Void
        private var turn: ResearchTurn?
        private var update: ((ResearchTurn) -> Void)?
        private var continuation: CheckedContinuation<ResearchTurn, Never>?

        init(onStart: @escaping () -> Void) { self.onStart = onStart }

        func run(_ turn: ResearchTurn, mode: ResearchRunner.Mode, history: [ResearchTurn],
                 onUpdate: @escaping (ResearchTurn) -> Void) async -> ResearchTurn {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.turn = turn
                update = onUpdate
                self.continuation = continuation
                lock.unlock()
                onStart()
            }
        }

        func emit(_ answer: String) {
            lock.lock()
            guard var snapshot = turn, let update else { lock.unlock(); return }
            snapshot.stage = .answering
            snapshot.answer = answer
            turn = snapshot
            lock.unlock()
            update(snapshot)
        }

        func finish() {
            lock.lock()
            let completion = continuation
            continuation = nil
            var snapshot = turn ?? ResearchTurn(question: "")
            lock.unlock()
            snapshot.stage = .complete
            completion?.resume(returning: snapshot)
        }
    }
}
