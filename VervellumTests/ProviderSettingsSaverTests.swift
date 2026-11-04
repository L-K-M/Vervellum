import XCTest
@testable import Vervellum

final class ProviderSettingsSaverTests: XCTestCase {

    private final class RecordingSecrets: SecretStore {
        enum Failure: Error { case refused }

        var events: [String] = []
        var values: [SecretAccount: String] = [:]
        var setAttempts: [SecretAccount: Int] = [:]
        var failingSet: SecretAccount?
        var failingSetAttempts: [SecretAccount: Set<Int>] = [:]
        var failingDelete: SecretAccount?

        var backendDescription: String { "test store" }
        func value(for account: SecretAccount) -> String? { values[account] }

        func set(_ secret: String, for account: SecretAccount) throws {
            events.append("set:\(account.rawValue)")
            let attempt = setAttempts[account, default: 0] + 1
            setAttempts[account] = attempt
            if account == failingSet || failingSetAttempts[account]?.contains(attempt) == true {
                throw Failure.refused
            }
            values[account] = secret
        }

        func delete(_ account: SecretAccount) throws {
            events.append("delete:\(account.rawValue)")
            if account == failingDelete { throw Failure.refused }
            values[account] = nil
        }
    }

    func testASecretWriteFailureDoesNotPersistSettingsOrDeleteOldAccounts() {
        let secrets = RecordingSecrets()
        secrets.values[.modelAPIKey] = "old-model"
        secrets.failingSet = .searchAPIKey
        let settings = ProviderSettings(modelEndpoint: "https://new.example/v1", modelName: "new")
        var persisted = false

        XCTAssertThrowsError(try ProviderSettingsSaver.commit(
            settings: settings,
            writes: [(.modelAPIKey, "model"), (.searchAPIKey, "search")],
            deleting: [.readerAPIKey],
            secrets: secrets,
            persist: { _ in persisted = true }))

        XCTAssertFalse(persisted)
        XCTAssertEqual(secrets.values[.modelAPIKey], "old-model")
        XCTAssertEqual(secrets.events,
                       ["set:model-api-key", "set:search-api-key", "set:model-api-key"])
    }

    func testRollbackFailureIsReportedExplicitly() {
        let secrets = RecordingSecrets()
        secrets.values[.modelAPIKey] = "old-model"
        secrets.failingSet = .searchAPIKey
        secrets.failingSetAttempts[.modelAPIKey] = [2]
        let settings = ProviderSettings(modelEndpoint: "https://new.example/v1", modelName: "new")

        XCTAssertThrowsError(try ProviderSettingsSaver.commit(
            settings: settings,
            writes: [(.modelAPIKey, "model"), (.searchAPIKey, "search")],
            deleting: [],
            secrets: secrets,
            persist: { _ in XCTFail("Settings must not be persisted") })) { error in
                guard case ProviderSettingsSaver.CommitError.rollbackFailed = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
    }

    func testSettingsPersistBeforeDestructiveCleanupAndFailedDeletesRemainPending() throws {
        let secrets = RecordingSecrets()
        secrets.failingDelete = .readerAPIKey
        let settings = ProviderSettings(modelEndpoint: "https://new.example/v1", modelName: "new")

        let pending = try ProviderSettingsSaver.commit(
            settings: settings,
            writes: [(.modelAPIKey, "model")],
            deleting: [.searchAPIKey, .readerAPIKey],
            secrets: secrets,
            persist: { _ in secrets.events.append("persist") })

        XCTAssertEqual(secrets.events, [
            "set:model-api-key", "persist", "delete:search-api-key", "delete:reader-api-key",
        ])
        XCTAssertEqual(pending, [.readerAPIKey])
    }
}
