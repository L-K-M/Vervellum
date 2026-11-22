import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// The delete action in a history row must work without the pointer hovering it.
///
/// The trash used to appear only while the row was hovered, so keyboard and VoiceOver
/// users had no way to delete a thread. The accessibility tree of a hosted SwiftUI view
/// is empty in a test process, so this drives the real control with local mouse events
/// that never produce a hover, and checks the click reaches Delete and not Open.
@MainActor
final class HistoryAccessibilityTests: XCTestCase {
    func testDeleteWorksWithoutPointerHover() throws {
        // Fixed fixture: trailing action in the first row, below the search field.
        let counts = try click(at: NSPoint(x: 380, y: 190), answering: "Delete")
        XCTAssertEqual(counts.deleted, 1,
                       "the click must reach Delete; recompute the fixture if the row layout changed")
        XCTAssertEqual(counts.opened, 0, "Delete must not activate Open")
    }

    func testCancellingTheConfirmationKeepsTheThread() throws {
        let counts = try click(at: NSPoint(x: 380, y: 190), answering: "Cancel")
        XCTAssertEqual(counts.deleted, 0, "Cancel must not delete")
        XCTAssertEqual(counts.opened, 0, "Cancel must not activate Open")
    }

    /// Splitting the row into two sibling buttons must not cost Open its hit area.
    func testTheRowBodyStillOpensTheThread() throws {
        let counts = try click(at: NSPoint(x: 40, y: 190))
        XCTAssertEqual(counts.opened, 1,
                       "the row body must open the thread; recompute the fixture if the layout changed")
        XCTAssertEqual(counts.deleted, 0, "Open must not delete")
    }

    /// Hosts one archived thread in a real window and sends a local mouse-down/up pair
    /// at `point`. These events do not move the pointer or send a hover event.
    ///
    /// With an `answer`, the click must raise the confirmation, must not have acted
    /// yet, and the named button of that confirmation is then pressed.
    private func click(at point: NSPoint,
                       answering answer: String? = nil) throws -> (opened: Int, deleted: Int) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(fileURL: directory.appendingPathComponent("threads.json"))
        var thread = ResearchThread()
        var turn = ResearchTurn(question: "A research question")
        turn.stage = .complete
        thread.turns = [turn]
        store.save(thread)
        store.flush()
        var deleted = 0
        var opened = 0
        let hosting = NSHostingView(rootView: HistoryView(store: store,
            onOpen: { _ in opened += 1 }, onDelete: { _ in deleted += 1 }, onClose: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(hosting.frame.contains(point),
                      "the fixture point must land inside the hosted view, not the window chrome")

        for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number,
                clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        settle()
        if let answer {
            let sheet = try XCTUnwrap(waitForSheet(on: window), "Delete must ask first")
            XCTAssertEqual(deleted, 0, "nothing is deleted until the confirmation is answered")
            try XCTUnwrap(button(titled: answer, in: sheet.contentView),
                          "the confirmation has no \(answer) button").performClick(nil)
            for _ in 0..<20 where window.attachedSheet != nil { settle() }
            XCTAssertNil(window.attachedSheet, "answering must dismiss the confirmation")
            settle()
        }
        return (opened, deleted)
    }

    private func waitForSheet(on window: NSWindow) -> NSWindow? {
        for _ in 0..<20 where window.attachedSheet == nil { settle() }
        return window.attachedSheet
    }

    private func button(titled title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(titled: title, in: $0) }.first
    }

    private func settle() {
        let laidOut = expectation(description: "History event loop settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { laidOut.fulfill() }
        wait(for: [laidOut], timeout: 3)
    }
}
