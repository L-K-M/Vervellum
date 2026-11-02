import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

@MainActor
final class HistoryAccessibilityTests: XCTestCase {
    func testDeleteIsAccessibleWithoutPointerHover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(fileURL: directory.appendingPathComponent("threads.json"))
        var thread = ResearchThread()
        var turn = ResearchTurn(question: "A research question")
        turn.stage = .complete
        thread.turns = [turn]
        store.save(thread)
        store.flush()

        let hosting = NSHostingView(rootView: HistoryView(store: store,
            onOpen: { _ in }, onDelete: { _ in }, onClose: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }

        let laidOut = expectation(description: "History laid out")
        DispatchQueue.main.async { laidOut.fulfill() }
        wait(for: [laidOut], timeout: 3)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertTrue(labels(in: hosting).contains("Delete thread: A research question"))
    }

    private func labels(in element: Any) -> [String] {
        guard let accessible = element as? NSAccessibility else { return [] }
        let own = accessible.accessibilityLabel().map { [$0] } ?? []
        return own + (accessible.accessibilityChildren() ?? []).flatMap { labels(in: $0) }
    }
}
