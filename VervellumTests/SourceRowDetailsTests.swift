import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// A source row's details must be reachable without the pointer hovering — the
/// reason the hover-revealed summary was replaced by a button. The accessibility
/// tree of a hosted SwiftUI view is empty in a test process, so this drives the
/// real controls with local mouse events that never produce a hover, and checks
/// that the details button presents the source card while the row body still owns
/// the browser action.
@MainActor
final class SourceRowDetailsTests: XCTestCase {

    /// Counts activations of the action a click was meant to reach.
    private final class Counter {
        var value = 0
    }

    /// Fixed fixture: the details button is the row's trailing control, below the
    /// row's top edge. Recompute the point if the row layout changes.
    func testDetailsButtonPresentsTheCardWithoutOpeningThePage() throws {
        let opened = Counter()
        let (window, hosting) = host { opened.value += 1 }
        defer { window.close() }
        let details = NSPoint(x: hosting.frame.maxX - 11, y: hosting.frame.maxY - 15)
        XCTAssertTrue(hosting.frame.contains(details),
                      "the fixture point must land inside the hosted view")

        try click(at: details, in: window)
        let popover = try XCTUnwrap(waitForPopover(in: window),
                                    "the details button must present the source card")
        XCTAssertEqual(opened.value, 0, "Details must not activate the browser action")
        let contentWidth = try XCTUnwrap(popover.contentView?.frame.width)
        XCTAssertLessThanOrEqual(contentWidth, hosting.frame.width + 0.5,
                                 "the card narrows with the panel rather than overflowing it")
    }

    /// Splitting the row into two sibling buttons must not cost the browser action
    /// its hit area.
    func testTheRowBodyStillOpensTheSource() throws {
        let opened = Counter()
        let (window, hosting) = host { opened.value += 1 }
        defer { window.close() }
        let body = NSPoint(x: 60, y: hosting.frame.maxY - 15)

        try click(at: body, in: window)
        XCTAssertEqual(opened.value, 1,
                       "the row body must open the page; recompute the fixture if the layout changed")
        XCTAssertTrue(window.childWindows?.isEmpty != false,
                      "the browser action must not present the details card")
    }

    /// Moving the pointer across the row must not change its height: the summary
    /// that used to materialise under the hand is gone, so there is nothing left
    /// that could move the rows below.
    func testPointerMovementDoesNotChangeRowHeight() throws {
        let opened = Counter()
        let (window, hosting) = host { opened.value += 1 }
        defer { window.close() }
        settle()
        hosting.layoutSubtreeIfNeeded()
        let before = hosting.fittingSize.height

        for y in [hosting.frame.maxY - 15, hosting.frame.maxY - 30] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
                location: NSPoint(x: hosting.frame.midX, y: y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 0, pressure: 0))
            window.sendEvent(event)
        }
        settle()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.height, before,
                       "hover must never change a source row's geometry")
    }

    /// Hosts one row at the top of a real window at a narrow-panel width, with the
    /// browser action spied rather than allowed to reach `NSWorkspace`.
    private func host(onOpen: @escaping () -> Void) -> (NSWindow, NSView) {
        let source = Source(number: 2, url: "https://retrieved.example/page",
                            title: "Retrieved source",
                            snippet: "The summary the answer rested on.",
                            publishedAt: "Nov 2026")
        let hosting = NSHostingView(rootView: VStack(alignment: .leading) {
            SourceRow(source: source, isCited: true, onOpen: { _ in onOpen() })
            Spacer()
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        settle()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    /// Sends a local mouse-down/up pair at `point`, in window coordinates. These
    /// events do not move the pointer or send a hover event.
    private func click(at point: NSPoint, in window: NSWindow) throws {
        for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number,
                clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        settle()
    }

    /// The popover is a child window of the row's window, presented a run loop or
    /// two after the click.
    private func waitForPopover(in window: NSWindow) -> NSWindow? {
        var popover: NSWindow?
        for _ in 0..<12 where popover == nil {
            let tick = expectation(description: "Popover presented")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick.fulfill() }
            wait(for: [tick], timeout: 3)
            popover = window.childWindows?.first
        }
        return popover
    }

    private func settle() {
        let laidOut = expectation(description: "Event loop settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { laidOut.fulfill() }
        wait(for: [laidOut], timeout: 3)
    }
}
