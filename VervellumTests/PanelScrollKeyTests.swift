import AppKit
import KeycapKit
import XCTest
@testable import Vervellum

/// Command-Up and Command-Down belong to the text being edited, and to the thread
/// only when there is none.
@MainActor
final class PanelScrollKeyTests: XCTestCase {

    func testCommandArrowsStayWithTextBeingEdited() throws {
        let (panel, editor) = makePanel(text: "first line\nsecond line")
        defer { panel.close() }
        for key in [UInt32(KeyCode.upArrow), UInt32(KeyCode.downArrow)] {
            editor.setSelectedRange(NSRange(location: 14, length: 0))
            let posted = try commands(sending: key, to: panel)
            XCTAssertTrue(posted.isEmpty, "the shortcut took the caret's key")
        }
        editor.setSelectedRange(NSRange(location: 14, length: 0))
        let event = try arrow(KeyCode.upArrow, in: panel)
        if !panel.performKeyEquivalent(with: event) { editor.keyDown(with: event) }
        XCTAssertEqual(editor.selectedRange().location, 0, "Command-Up must reach the start of the draft")
    }

    func testCommandArrowsScrollTheThreadFromAnEmptyComposer() throws {
        let (panel, _) = makePanel(text: "")
        defer { panel.close() }
        XCTAssertEqual(try commands(sending: KeyCode.upArrow, to: panel), [.scrollToTop])
        XCTAssertEqual(try commands(sending: KeyCode.downArrow, to: panel), [.scrollToBottom])
    }

    func testCommandArrowsScrollPastReadOnlyText() throws {
        let (panel, editor) = makePanel(text: "An answer")
        defer { panel.close() }
        editor.isEditable = false
        XCTAssertEqual(try commands(sending: KeyCode.upArrow, to: panel), [.scrollToTop])
    }

    private func makePanel(text: String) -> (ResearchPanel, NSTextView) {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        editor.string = text
        let panel = ResearchPanel(content: editor)
        panel.makeFirstResponder(editor)
        return (panel, editor)
    }

    private func commands(sending key: UInt32, to panel: ResearchPanel) throws -> [PanelCommand] {
        var posted: [PanelCommand] = []
        let observer = NotificationCenter.default.addObserver(forName: .vervellumPanelCommand,
                                                              object: nil, queue: nil) { note in
            if let raw = note.userInfo?["command"] as? String, let command = PanelCommand(rawValue: raw) {
                posted.append(command)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = panel.performKeyEquivalent(with: try arrow(key, in: panel))
        return posted
    }

    private func arrow(_ key: UInt32, in panel: NSWindow) throws -> NSEvent {
        let function = key == KeyCode.upArrow ? NSUpArrowFunctionKey : NSDownArrowFunctionKey
        let characters = String(try XCTUnwrap(UnicodeScalar(UInt32(function))))
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(key)))
    }
}
