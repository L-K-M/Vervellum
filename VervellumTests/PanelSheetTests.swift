import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// A sheet takes key status from the panel it belongs to. With dismiss-on-focus-loss
/// on, that must not read as the user having left.
@MainActor
final class PanelSheetTests: XCTestCase {

    private struct Asking: View {
        @State private var asks = false

        var body: some View {
            Color.clear
                .confirmationDialog("Delete this thread?", isPresented: $asks) {
                    Button("Delete", role: .destructive) {}
                }
                .onReceive(NotificationCenter.default.publisher(for: Self.ask)) { _ in asks = true }
        }

        static let ask = Notification.Name("PanelSheetTests.ask")
    }

    func testAConfirmationDoesNotDismissThePanel() throws {
        let suite = "VervellumPanelSheetTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { SuitePlistCleanup.removeSuite(suite, from: defaults) }
        let preferences = Preferences(defaults: defaults)
        preferences.dismissOnFocusLoss = true
        let controller = PanelController(preferences: preferences) { AnyView(Asking()) }
        controller.show()
        defer { controller.hide(restoringActivation: false) }
        settle()
        guard controller.isOpen else { return XCTFail("the panel must open") }
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is ResearchPanel && $0.isVisible && $0.alphaValue > 0 })

        NotificationCenter.default.post(name: Asking.ask, object: nil)
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
        let controller = PanelController(preferences: Preferences(defaults: defaults)) { AnyView(Asking()) }
        controller.show()
        settle()
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is ResearchPanel && $0.isVisible && $0.alphaValue > 0 })
        NotificationCenter.default.post(name: Asking.ask, object: nil)
        for _ in 0..<20 where panel.attachedSheet == nil { settle() }
        XCTAssertNotNil(panel.attachedSheet, "the confirmation must appear")

        controller.hide(restoringActivation: false)
        for _ in 0..<20 where panel.attachedSheet != nil { settle() }
        XCTAssertFalse(controller.isOpen)
        XCTAssertNil(panel.attachedSheet, "a hidden panel must not keep a question waiting")
    }

    private func settle() {
        let settled = expectation(description: "Panel event loop settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }
}
