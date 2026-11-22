import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// The composer's ↑/↓ walk through a thread's earlier questions.
///
/// The walk has to survive the draft change that puts a question on screen, and must
/// not survive an edit. Both directions are pinned here, because the failure is silent:
/// a reader corrects a recalled question, presses ↑, and the correction is gone.
@MainActor
final class ComposerRecallTests: XCTestCase {

    private func makePanel(with thread: ResearchThread,
                           store: ThreadStore,
                           preferences: Preferences) -> (NSView, NSWindow, ResearchEngine) {
        let engine = ResearchEngine(thread: thread,
                                    preferences: preferences.core,
                                    secrets: EphemeralSecretStore(),
                                    logSink: SilentLog(),
                                    attachmentStore: store.attachmentStore,
                                    makeRunner: { _, _, _ in NoopRunner() })
        let hosting = NSHostingView(rootView: PanelRootView(
            engine: engine, store: store, preferences: preferences,
            secrets: EphemeralSecretStore(),
            onOpenSettings: {}, onClose: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return (hosting, window, engine)
    }

    private func makeThread() -> ResearchThread {
        var thread = ResearchThread()
        var first = ResearchTurn(question: "First question")
        first.stage = .complete
        var second = ResearchTurn(question: "Second question")
        second.stage = .complete
        thread.turns = [first, second]
        return thread
    }

    private func makePreferencesAndStore() throws -> (Preferences, ThreadStore, UserDefaults, String) {
        let suite = "VervellumRecallTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let preferences = Preferences(defaults: defaults)
        preferences.core.providerSettings = ProviderSettings(modelProfiles: [], searchProfiles: [])
        let store = ThreadStore(fileURL: directory.appendingPathComponent("threads.json"),
                                debounce: 0)
        return (preferences, store, defaults, suite)
    }

    func testEditingARecalledQuestionEndsTheWalk() throws {
        let (preferences, store, defaults, suite) = try makePreferencesAndStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true))
        }
        let thread = makeThread()
        store.save(thread)
        store.flush()
        let (hosting, window, _) = makePanel(with: thread, store: store, preferences: preferences)
        defer { window.close() }
        settle(hosting)

        guard let composer = composer(in: hosting) else { return XCTFail("no composer") }
        XCTAssertTrue(pressArrow(up: true, in: composer))
        settle(hosting)
        XCTAssertEqual(composer.string, "Second question")

        // The edit. The walk must end here, so the next ↑ leaves the correction alone.
        let end = (composer.string as NSString).length
        composer.insertText(" edited", replacementRange: NSRange(location: end, length: 0))
        settle(hosting)
        XCTAssertEqual(composer.string, "Second question edited")

        _ = pressArrow(up: true, in: composer)
        settle(hosting)
        XCTAssertEqual(composer.string, "Second question edited",
                       "an edited recalled question must not be replaced by the next ↑")
    }

    /// The other half: without an edit, the walk still moves. A fix that ended the
    /// walk on every draft change would pass the test above and break the feature.
    func testAPlainWalkStillMovesThroughTheThread() throws {
        let (preferences, store, defaults, suite) = try makePreferencesAndStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true))
        }
        let thread = makeThread()
        store.save(thread)
        store.flush()
        let (hosting, window, _) = makePanel(with: thread, store: store, preferences: preferences)
        defer { window.close() }
        settle(hosting)

        guard let composer = composer(in: hosting) else { return XCTFail("no composer") }
        XCTAssertTrue(pressArrow(up: true, in: composer))
        settle(hosting)
        XCTAssertEqual(composer.string, "Second question")
        XCTAssertTrue(pressArrow(up: true, in: composer))
        settle(hosting)
        XCTAssertEqual(composer.string, "First question")
        XCTAssertTrue(pressArrow(up: false, in: composer))
        settle(hosting)
        XCTAssertEqual(composer.string, "Second question")
    }

    /// Drives the composer's own arrow-key handler, which is where ↑/↓ reach the recall
    /// walk. Going through the coordinator directly is the same call AppKit makes.
    private func pressArrow(up: Bool, in composer: NSTextView) -> Bool {
        guard let coordinator = composer.delegate as? ComposerView.Coordinator else { return false }
        let selector = up ? #selector(NSResponder.moveUp(_:)) : #selector(NSResponder.moveDown(_:))
        return coordinator.textView(composer, doCommandBy: selector)
    }

    private func settle(_ hosting: NSView) {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
    }

    private func composer(in view: NSView) -> NSTextView? {
        // The delegate check is what distinguishes the composer from the answer's
        // selectable text views, which are also editable-looking `NSTextView`s.
        if let text = view as? NSTextView,
           text.isEditable, text.delegate is ComposerView.Coordinator { return text }
        return view.subviews.lazy.compactMap(composer).first
    }

    private final class NoopRunner: ResearchRunning {
        func run(_ turn: ResearchTurn, mode: ResearchRunner.Mode,
                 history: [ResearchTurn],
                 onUpdate: @escaping (ResearchTurn) -> Void) async -> ResearchTurn { turn }
    }
}
