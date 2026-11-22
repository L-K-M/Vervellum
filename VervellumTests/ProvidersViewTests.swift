import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

final class ProvidersViewTests: XCTestCase {

    func testClearIsCancelledWhenSettingsClosesWithoutSave() throws {
        if Thread.isMainThread {
            try exercisePendingClear()
        } else {
            try DispatchQueue.main.sync { try exercisePendingClear() }
        }
    }

    private func exercisePendingClear() throws {
        let suite = "VervellumProvidersViewTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { SuitePlistCleanup.removeSuite(suite, from: defaults) }
        let preferences = Preferences(defaults: defaults)
        let id = UUID()
        let account = SecretAccount.derived(from: .modelAPIKey, for: id)
        preferences.core.providerSettings = ProviderSettings(
            modelProfiles: [ModelProfile(
                id: id, name: "Test", endpoint: "https://model.example/v1",
                model: "test-model", keyAccount: account.rawValue)],
            selectedModelID: id,
            searchProfiles: [])
        let secrets = RecordingProvidersSecretStore([account: "stored key"])

        let first = host(preferences: preferences, secrets: secrets)
        defer { first.window.close() }
        settle(first.hosting)
        let field = try XCTUnwrap(secureField(in: first.hosting))
        let storedWidth = field.bounds.width

        clickClear(beside: field, in: first.hosting, window: first.window)
        settle(first.hosting)

        XCTAssertGreaterThan(field.bounds.width, storedWidth + 20,
                             "Clear should become a pending form edit and hide its button")
        XCTAssertTrue(secrets.mutations.isEmpty,
                      "closing an unsaved form must not have touched the Keychain")
        XCTAssertEqual(secrets.value(for: account), "stored key")

        first.window.close()
        let reopened = host(preferences: preferences, secrets: secrets)
        defer { reopened.window.close() }
        settle(reopened.hosting)
        let reopenedField = try XCTUnwrap(secureField(in: reopened.hosting))

        XCTAssertEqual(reopenedField.bounds.width, storedWidth, accuracy: 1,
                       "a fresh Settings view must rediscover the still-stored key")
        XCTAssertTrue(secrets.mutations.isEmpty)
    }

    private func host(preferences: Preferences, secrets: SecretStore)
        -> (window: NSWindow, hosting: NSHostingView<ProvidersView>) {
        let hosting = NSHostingView(rootView: ProvidersView(
            preferences: preferences, keychain: secrets))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return (window, hosting)
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
    }

    private func secureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap(secureField).first
    }

    private func clickClear(beside field: NSSecureTextField,
                            in hosting: NSView,
                            window: NSWindow) {
        let fieldRect = field.convert(field.bounds, to: hosting)
        let point = NSPoint(x: fieldRect.maxX + 36, y: fieldRect.midY)
        let location = hosting.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
            if let event { window.sendEvent(event) }
        }
    }
}

private final class RecordingProvidersSecretStore: SecretStore {
    private var values: [SecretAccount: String]
    private(set) var mutations: [String] = []

    init(_ values: [SecretAccount: String]) { self.values = values }

    var backendDescription: String { "test store" }
    func value(for account: SecretAccount) -> String? { values[account] }

    func set(_ secret: String, for account: SecretAccount) throws {
        mutations.append("set:\(account.rawValue)")
        values[account] = secret
    }

    func delete(_ account: SecretAccount) throws {
        mutations.append("delete:\(account.rawValue)")
        values[account] = nil
    }
}
