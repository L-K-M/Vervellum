import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// "Edit & re-ask" gives back the question as it was asked, files included.
@MainActor
final class EditAndReaskTests: XCTestCase {

    /// SwiftUI builds its accessibility tree only while a client is asking for it.
    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    override func setUp() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
    }

    override func tearDown() async throws {
        NSApp.accessibilitySetValue(false, forAttribute: Self.enhancedUI)
    }

    func testEditingBringsTheAttachmentBack() throws {
        let result = try editAndSubmit(storingBytes: true)
        XCTAssertEqual(result.turn.question, "What is in the file?")
        XCTAssertEqual(result.turn.attachments.map(\.name), ["notes.txt"])
        XCTAssertNotEqual(result.turn.attachments.first?.id, result.original.id,
                          "the edited question carries its own copy")
    }

    func testEditingSaysWhenAnAttachmentIsGone() throws {
        let result = try editAndSubmit(storingBytes: false)
        XCTAssertEqual(result.turn.question, "What is in the file?")
        XCTAssertTrue(result.turn.attachments.isEmpty)
        XCTAssertTrue(result.shown.contains { $0.contains("could not be brought back") },
                      "found \(result.shown)")
    }

    private func editAndSubmit(storingBytes: Bool) throws
        -> (turn: ResearchTurn, original: Attachment, shown: [String]) {
        let suite = "VervellumEditAndReaskTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            SuitePlistCleanup.removeSuite(suite, from: defaults)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = Preferences(defaults: defaults)
        preferences.core.providerSettings = ProviderSettings(modelProfiles: [], searchProfiles: [])
        let store = ThreadStore(fileURL: directory.appendingPathComponent("threads.json"), debounce: 0)

        let pending = try PendingAttachment.make(from: Data("hello".utf8), name: "notes.txt").get()
        var asked = ResearchTurn(question: "What is in the file?")
        asked.stage = .complete
        asked.answer = "A greeting."
        asked.attachments = [pending.attachment]
        if storingBytes { try store.attachmentStore.write(pending.data, for: pending.attachment) }
        var thread = ResearchThread()
        thread.turns = [asked]

        let runner = RecordingRunner()
        let engine = ResearchEngine(thread: thread, preferences: preferences.core,
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
        settle()

        let edit = try XCTUnwrap(descendants(of: hosting).first { text(of: $0)?.contains("Edit & re-ask") == true },
                                 "the turn must offer Edit & re-ask")
        _ = edit.perform(#selector(NSAccessibilityProtocol.accessibilityPerformPress))
        settle()
        let shown = descendants(of: hosting).compactMap { text(of: $0) }

        NotificationCenter.default.post(name: .vervellumPanelCommand, object: nil,
                                        userInfo: ["command": PanelCommand.submit.rawValue])
        for _ in 0..<20 where runner.capturedTurn == nil { settle() }
        return (try XCTUnwrap(runner.capturedTurn, "the edited question must be asked"),
                pending.attachment, shown)
    }

    private func text(of element: NSObject) -> String? {
        for selector in [#selector(NSAccessibilityProtocol.accessibilityLabel),
                         #selector(NSAccessibilityProtocol.accessibilityTitle),
                         #selector(NSAccessibilityProtocol.accessibilityValue)] {
            if let text = read(selector, from: element) as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// By selector: SwiftUI's elements answer these without declaring the protocol.
    private func read(_ selector: Selector, from element: NSObject) -> Any? {
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private func descendants(of element: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 60, let children = read(#selector(NSAccessibilityProtocol.accessibilityChildren),
                                              from: element) as? [Any]
        else { return [element] }
        return [element] + children.compactMap { $0 as? NSObject }
            .flatMap { descendants(of: $0, depth: depth + 1) }
    }

    private func settle() {
        let settled = expectation(description: "Composer settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }

    private final class RecordingRunner: ResearchRunning {
        private let lock = NSLock()
        private var turn: ResearchTurn?

        var capturedTurn: ResearchTurn? { lock.withLock { turn } }

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
