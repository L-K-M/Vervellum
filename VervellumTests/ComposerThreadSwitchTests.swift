import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

final class ComposerThreadSwitchTests: XCTestCase {

    func testOpeningHistoryKeepsDraftAndAttachmentsTogether() throws {
        if Thread.isMainThread {
            try exerciseThreadSwitch()
        } else {
            try DispatchQueue.main.sync { try exerciseThreadSwitch() }
        }
    }

    private func exerciseThreadSwitch() throws {
        let suite = "VervellumThreadSwitchTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            SuitePlistCleanup.removeSuite(suite, from: defaults)
            try? FileManager.default.removeItem(at: directory)
        }

        let preferences = Preferences(defaults: defaults)
        preferences.core.providerSettings = ProviderSettings(modelProfiles: [], searchProfiles: [])
        let store = ThreadStore(fileURL: directory.appendingPathComponent("threads.json"),
                                debounce: 0)
        var archived = ResearchThread()
        archived.turns = [ResearchTurn(question: "Archived question")]
        store.save(archived)
        store.flush()

        let runner = RecordingRunner()
        let engine = ResearchEngine(preferences: preferences.core,
                                    secrets: EphemeralSecretStore(),
                                    logSink: SilentLog(),
                                    attachmentStore: store.attachmentStore,
                                    makeRunner: { _, _, _ in runner })
        let hosting = NSHostingView(rootView: PanelRootView(
            engine: engine, store: store, preferences: preferences,
            onOpenSettings: {}, onClose: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(hosting)

        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + Data(repeating: 7, count: 8)
        let pending = try PendingAttachment.make(from: bytes, name: "context.png").get()
        NotificationCenter.default.post(name: .vervellumSeedComposer, object: nil,
                                        userInfo: ["text": "Draft question",
                                                   "attachments": [pending]])
        settle(hosting)
        XCTAssertEqual(composer(in: hosting)?.string, "Draft question")

        NotificationCenter.default.post(name: .vervellumPanelCommand, object: nil,
                                        userInfo: ["command": PanelCommand.toggleHistory.rawValue])
        settle(hosting)
        clickFirstHistoryRow(in: hosting, window: window)
        settle(hosting)

        XCTAssertEqual(engine.thread.id, archived.id)
        guard composer(in: hosting)?.string == "Draft question" else {
            XCTFail("opening history must not silently discard typed text")
            return
        }

        NotificationCenter.default.post(name: .vervellumPanelCommand, object: nil,
                                        userInfo: ["command": PanelCommand.submit.rawValue])
        for _ in 0..<20 where runner.capturedTurn == nil {
            settle(hosting)
        }
        let turn = try XCTUnwrap(runner.capturedTurn)
        XCTAssertEqual(turn.question, "Draft question")
        XCTAssertEqual(turn.attachments.map(\.name), ["context.png"],
                       "the attachment and the words it belongs to must move together")
    }

    private func settle(_ hosting: NSView) {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
    }

    private func composer(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap(composer).first
    }

    private func clickFirstHistoryRow(in hosting: NSView, window: NSWindow) {
        // Center of the first row in this fixed-size hosted panel. The assertion on the
        // selected thread immediately after the click keeps layout drift from becoming
        // a false positive; update this alongside the history header/row geometry.
        let rowCenter = NSPoint(x: 100, y: 76)
        let y = hosting.isFlipped ? rowCenter.y : hosting.bounds.maxY - rowCenter.y
        let local = NSPoint(x: rowCenter.x, y: y)
        let location = hosting.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
            if let event { window.sendEvent(event) }
        }
    }

    private final class RecordingRunner: ResearchRunning {
        private let lock = NSLock()
        private var turn: ResearchTurn?

        var capturedTurn: ResearchTurn? {
            lock.withLock { turn }
        }

        func run(_ turn: ResearchTurn, mode: ResearchRunner.Mode,
                 history: [ResearchTurn],
                 onUpdate: @escaping (ResearchTurn) -> Void) async -> ResearchTurn {
            lock.withLock { self.turn = turn }
            var completed = turn
            completed.stage = .complete
            return completed
        }
    }
}
