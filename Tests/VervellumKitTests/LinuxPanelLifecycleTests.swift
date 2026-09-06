#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import VervellumKit

final class LinuxPanelLifecycleTests: XCTestCase {

    func testNativeCloseKeepsThePanelAvailableForTheShortcut() throws {
        guard gtk_init_check() != 0 else {
            if ProcessInfo.processInfo.environment["VERVELLUM_REQUIRE_DISPLAY"] == "1" {
                XCTFail("The GTK smoke test requires a working display.")
                return
            }
            throw XCTSkip("Requires a GTK display, such as Xvfb.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VervellumPanelTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = LinuxEnvironment(
            settingsFile: directory.appendingPathComponent("settings.json"),
            threadsFile: directory.appendingPathComponent("threads.json"),
            secrets: EphemeralSecretStore())
        let application = try XCTUnwrap(gtk_application_new(nil, G_APPLICATION_NON_UNIQUE))
        defer { g_object_unref(application) }
        guard g_application_register(vv_gapp(application), nil, nil) != 0 else {
            XCTFail("Could not register the isolated test application.")
            return
        }

        let panel = LinuxPanel(application: application, environment: environment)
        panel.show()
        let window = try XCTUnwrap(gtk_application_get_active_window(application))
        // Hold the object through the failing baseline's destruction, so this test
        // detects lost application ownership instead of dereferencing freed memory.
        _ = g_object_ref(window)
        defer {
            gtk_window_destroy(window)
            g_object_unref(window)
        }

        gtk_window_close(window)
        XCTAssertEqual(gtk_window_get_application(window), application)
        guard gtk_window_get_application(window) == application else { return }

        panel.toggle()
        XCTAssertEqual(gtk_application_get_active_window(application), window)
        gtk_window_close(window)
        XCTAssertEqual(gtk_window_get_application(window), application)
        panel.toggle()
        XCTAssertEqual(gtk_application_get_active_window(application), window)
    }
}
#endif
