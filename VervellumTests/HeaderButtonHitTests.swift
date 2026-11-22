import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// Clicks a real header button. The padding arithmetic was right while the clickable
/// area was only the glyph's own pixels, so arithmetic alone cannot cover this.
@MainActor
final class HeaderButtonHitTests: XCTestCase {

    private static let windowSize = NSSize(width: 120, height: 80)

    func testTheWholeExpandedFrameTakesAClick() throws {
        var hits = 0
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HeaderButton(symbol: "xmark", help: "Close") { hits += 1 }
            .frame(width: Self.windowSize.width, height: Self.windowSize.height))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle()

        // The button is centred; 11.5 pt is just inside a 26 pt target and 15.5 just outside.
        let center = NSPoint(x: Self.windowSize.width / 2, y: Self.windowSize.height / 2)
        for (dx, dy) in [(0, 0), (-11.5, 0), (11.5, 0), (0, -11.5), (0, 11.5), (-11.5, 11.5), (11.5, -11.5)] {
            let before = hits
            try click(NSPoint(x: center.x + dx, y: center.y + dy), in: window)
            XCTAssertEqual(hits, before + 1, "no click at offset \(dx), \(dy)")
        }
        let before = hits
        try click(NSPoint(x: center.x + 15.5, y: center.y), in: window)
        XCTAssertEqual(hits, before, "the target must not reach past its frame")
    }

    private func click(_ point: NSPoint, in window: NSWindow) throws {
        for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number,
                clickCount: 1, pressure: 1)))
        }
        settle()
    }

    private func settle() {
        let settled = expectation(description: "Header event loop settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }
}
