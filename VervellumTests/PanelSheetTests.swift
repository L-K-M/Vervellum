import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// A sheet takes key status from the panel it belongs to. With dismiss-on-focus-loss
/// on, that must not read as the user having left.
@MainActor
final class PanelSheetTests: XCTestCase {

    private struct Asking: View {
        /// One per test: an earlier test's panel is still listening while it fades.
        let ask: Notification.Name
        var onDelete: () -> Void = {}
        @State private var showsHistory = true
        @State private var asks = false

        var body: some View {
            // As in the panel: History, which owns the dialog, closes as the panel hides.
            ZStack {
                if showsHistory {
                    Color.clear
                        .confirmationDialog("Delete this thread?", isPresented: $asks) {
                            Button("Delete", role: .destructive, action: onDelete)
                        }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ask)) { _ in asks = true }
            .onReceive(NotificationCenter.default.publisher(for: .vervellumPanelWillHide)) { _ in
                showsHistory = false
            }
        }
    }

    func testAConfirmationDoesNotDismissThePanel() throws {
        let suite = "VervellumPanelSheetTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { SuitePlistCleanup.removeSuite(suite, from: defaults) }
        let preferences = Preferences(defaults: defaults)
        preferences.dismissOnFocusLoss = true
        let ask = Notification.Name(suite)
        let controller = PanelController(preferences: preferences) { AnyView(Asking(ask: ask)) }
        let windowsBefore = NSApp.windows
        controller.show()
        defer { controller.hide(restoringActivation: false) }
        settle()
        guard controller.isOpen else { return XCTFail("the panel must open") }
        let panel = try XCTUnwrap(panel(openedSince: windowsBefore))

        NotificationCenter.default.post(name: ask, object: nil)
        for _ in 0..<20 where panel.attachedSheet == nil { settle() }
        let sheet = try XCTUnwrap(panel.attachedSheet, "the confirmation must appear")
        defer { if panel.attachedSheet === sheet { panel.endSheet(sheet) } }
        // Posted as well as observed: a test host is not always given key status.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        settle()
        XCTAssertTrue(controller.isOpen, "the panel's own confirmation dismissed it")
    }

    func testDismissingThePanelCancelsItsConfirmation() throws {
        let suite = "VervellumPanelSheetTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { SuitePlistCleanup.removeSuite(suite, from: defaults) }
        let ask = Notification.Name(suite)
        var deletes = 0
        let controller = PanelController(preferences: Preferences(defaults: defaults)) {
            AnyView(Asking(ask: ask, onDelete: { deletes += 1 }))
        }
        let windowsBefore = NSApp.windows
        controller.show()
        settle()
        let panel = try XCTUnwrap(panel(openedSince: windowsBefore))
        NotificationCenter.default.post(name: ask, object: nil)
        for _ in 0..<20 where panel.attachedSheet == nil { settle() }
        XCTAssertNotNil(panel.attachedSheet, "the confirmation must appear")

        controller.hide(restoringActivation: false)
        for _ in 0..<20 where panel.attachedSheet != nil { settle() }
        XCTAssertFalse(controller.isOpen)
        XCTAssertNil(panel.attachedSheet, "a hidden panel must not keep a question waiting")
        XCTAssertEqual(deletes, 0, "dismissing the panel must not answer Delete")
        for _ in 0..<20 where panel.isVisible { settle() }
        XCTAssertFalse(panel.isVisible, "the panel must still leave the screen")
    }

    /// The window this test opened, not one an earlier test is still fading out.
    private func panel(openedSince windows: [NSWindow]) -> NSWindow? {
        NSApp.windows.first { window in
            window is ResearchPanel && !windows.contains { $0 === window }
        }
    }

    private func settle() {
        let settled = expectation(description: "Panel event loop settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }
}
