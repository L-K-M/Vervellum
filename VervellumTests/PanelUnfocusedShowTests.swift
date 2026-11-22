import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

/// A panel shown without focus has never had the user in it.
@MainActor
final class PanelUnfocusedShowTests: XCTestCase {

    func testTheFirstSummonFocusesAnUnfocusedPanelInsteadOfHidingIt() throws {
        let controller = try makeController(frontmost: { nil })
        defer { controller.hide(restoringActivation: false) }
        controller.show(takingFocus: false)
        XCTAssertTrue(controller.isOpen)

        controller.toggle()
        XCTAssertTrue(controller.isOpen, "the first summon hid the panel it was meant to focus")
    }

    func testPromotionRestoresTheAppThatWasFrontmostThen() throws {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
        try XCTSkipIf(apps.count < 2, "needs two other running applications")
        var front = apps[0]
        let controller = try makeController(frontmost: { front })
        defer { controller.hide(restoringActivation: false) }
        controller.show(takingFocus: false)

        front = apps[1]
        controller.toggle()
        XCTAssertEqual(controller.applicationToRestore?.processIdentifier, apps[1].processIdentifier,
                       "closing would hand focus back to the app from launch time")
    }

    /// The status menu's summon goes through `show()` rather than the hotkey's toggle.
    func testShowingAgainRefreshesTheRestoreTargetToo() throws {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
        try XCTSkipIf(apps.count < 2, "needs two other running applications")
        var front = apps[0]
        let controller = try makeController(frontmost: { front })
        defer { controller.hide(restoringActivation: false) }
        controller.show(takingFocus: false)

        front = apps[1]
        controller.show()
        XCTAssertEqual(controller.applicationToRestore?.processIdentifier, apps[1].processIdentifier)
    }

    /// Settings opened from the status menu never focuses the panel, so nothing
    /// promotes it before Settings asks where to hand focus back.
    func testSettingsFromTheStatusMenuRestoresTheAppThatIsFrontmostNow() throws {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
        try XCTSkipIf(apps.count < 2, "needs two other running applications")
        var front = apps[0]
        let controller = try makeController(frontmost: { front })
        defer { controller.hide(restoringActivation: false) }
        controller.show(takingFocus: false)

        front = apps[1]
        XCTAssertEqual(controller.applicationToRestore?.processIdentifier, apps[1].processIdentifier)
    }

    private func makeController(frontmost: @escaping () -> NSRunningApplication?) throws -> PanelController {
        let suite = "VervellumUnfocusedPanelTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { SuitePlistCleanup.removeSuite(suite, from: defaults) }
        return PanelController(preferences: Preferences(defaults: defaults),
                               frontmostApplication: frontmost) { AnyView(Color.clear) }
    }
}
