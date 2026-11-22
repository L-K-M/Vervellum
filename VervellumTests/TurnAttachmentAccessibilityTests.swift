import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// An attachment row reads as one element; the button beside it stays its own.
@MainActor
final class TurnAttachmentAccessibilityTests: XCTestCase {

    /// SwiftUI builds its accessibility tree only while a client is asking for it.
    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    override func setUp() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
    }

    override func tearDown() async throws {
        NSApp.accessibilitySetValue(false, forAttribute: Self.enhancedUI)
    }

    func testThePreviewButtonIsReachableBesideTheAttachment() throws {
        var turn = ResearchTurn(question: "What is in the file?")
        turn.stage = .complete
        let attachment = Attachment(kind: .text, name: "notes.txt", mediaType: "text/plain", byteCount: 5)
        turn.attachments = [attachment]
        var requested: [UUID] = []
        let view = TurnView(turn: turn, showsProcessTrail: false,
                            palette: PanelTheme.palette,
                            onRetry: {}, onAskFollowup: { _ in },
                            attachmentData: { requested.append($0.id); return Data("hello".utf8) })
        let window = host(view)
        defer { window.close() }

        let elements = descendants(of: try XCTUnwrap(window.contentView))
        XCTAssertNotNil(elements.first { label(of: $0) == "Attached file: notes.txt" },
                        "the row must still be named as an attachment")
        let button = try XCTUnwrap(elements.first { label(of: $0) == "Show attachment notes.txt" },
                                   "the preview button must not be folded into the row")
        _ = button.perform(#selector(NSAccessibilityProtocol.accessibilityPerformPress))
        settle()
        XCTAssertEqual(requested, [attachment.id])
    }

    /// Merged into one element, a long preview's text could be neither walked nor selected.
    func testThePreviewKeepsItsTextAsItsOwnElement() throws {
        let attachment = Attachment(kind: .text, name: "notes.txt", mediaType: "text/plain", byteCount: 5)
        let window = host(AttachmentPreview(attachment: attachment, data: Data("hello".utf8)))
        defer { window.close() }

        let spoken = descendants(of: try XCTUnwrap(window.contentView)).compactMap { text(of: $0) }
        XCTAssertTrue(spoken.contains("hello"), "found \(spoken)")
    }

    private func host(_ view: some View) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        settle()
        return window
    }

    private func text(of element: NSObject) -> String? {
        label(of: element).flatMap { $0.isEmpty ? nil : $0 }
            ?? read(#selector(NSAccessibilityProtocol.accessibilityValue), from: element) as? String
    }

    private func label(of element: NSObject) -> String? {
        read(#selector(NSAccessibilityProtocol.accessibilityLabel), from: element) as? String
    }

    /// By selector: SwiftUI's elements answer these without declaring the protocol.
    private func read(_ selector: Selector, from element: NSObject) -> Any? {
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private func descendants(of element: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 40, let children = read(#selector(NSAccessibilityProtocol.accessibilityChildren),
                                              from: element) as? [Any]
        else { return [element] }
        return [element] + children.compactMap { $0 as? NSObject }
            .flatMap { descendants(of: $0, depth: depth + 1) }
    }

    private func settle() {
        let settled = expectation(description: "Attachment row settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }
}
