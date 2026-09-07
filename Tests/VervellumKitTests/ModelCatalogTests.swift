import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The model catalogue's pure parts: the address it asks, and the reply shapes it will
/// read.
final class ModelCatalogTests: XCTestCase {

    // MARK: The address

    /// The three shapes a user pastes as their chat endpoint, in reverse.
    func testDerivesTheListURLFromEveryEndpointShape() {
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/v1")?.absoluteString,
                       "https://api.example.com/v1/models")
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com")?.absoluteString,
                       "https://api.example.com/models")
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/api/paas/v4")?
            .absoluteString,
                       "https://api.example.com/api/paas/v4/models")
    }

    /// Appending to a full chat path would ask for `/chat/completions/models`, which is
    /// nothing — so the suffix comes off first.
    func testAFullChatPathBecomesItsSiblingModelsPath() {
        XCTAssertEqual(
            ProviderSettings.modelListURL(from: "https://api.example.com/v1/chat/completions")?
                .absoluteString,
            "https://api.example.com/v1/models")
    }

    func testTrailingSlashesAndQueriesAreDropped() {
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/v1/")?
            .absoluteString,
                       "https://api.example.com/v1/models")
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/v1?key=x#f")?
            .absoluteString,
                       "https://api.example.com/v1/models")
    }

    /// The same endpoint hygiene every other address gets.
    func testRejectsUnusableEndpoints() {
        XCTAssertNil(ProviderSettings.modelListURL(from: "http://api.example.com/v1"))
        XCTAssertNil(ProviderSettings.modelListURL(from: "https://user:pass@api.example.com/v1"))
        XCTAssertNil(ProviderSettings.modelListURL(from: ""))
        XCTAssertNil(ProviderSettings.modelListURL(from: "not a url"))
    }

    /// A local model server has no certificate, exactly like a local SearXNG instance.
    func testAllowsLoopbackWithoutTLS() {
        XCTAssertEqual(ProviderSettings.modelListURL(from: "http://localhost:11434/v1")?
            .absoluteString,
                       "http://localhost:11434/v1/models")
    }

    // MARK: The reply

    func testReadsTheOpenAIShape() {
        let body: [String: Any] = ["object": "list", "data": [
            ["id": "gpt-4o", "object": "model"],
            ["id": "gpt-4o-mini", "object": "model"],
        ]]
        XCTAssertEqual(ModelCatalog.parse(body), ["gpt-4o", "gpt-4o-mini"])
    }

    /// Servers in the wild put the array under `models`, fill it with bare strings, or
    /// name the field `name`. Reading all of them costs a few lines and saves a provider
    /// being unusable over a key nobody agreed on.
    func testReadsTheShapesOtherServersUse() {
        XCTAssertEqual(ModelCatalog.parse(["models": ["llama3", "mistral"]]), ["llama3", "mistral"])
        XCTAssertEqual(ModelCatalog.parse(["data": [["name": "phi-4"]]]), ["phi-4"])
        XCTAssertEqual(ModelCatalog.parse(["data": ["a-model"]]), ["a-model"])
    }

    /// `id` wins over `name` when a server sends both, because `id` is the field the
    /// completions call actually takes.
    func testPrefersTheIdentifierOverTheDisplayName() {
        XCTAssertEqual(ModelCatalog.parse(["data": [["id": "real-id", "name": "Friendly Name"]]]),
                       ["real-id"])
    }

    /// A list the user picks from should not depend on the order a gateway happened to
    /// enumerate its routing table in.
    func testSortsAndDeduplicates() {
        let body: [String: Any] = ["data": [["id": "zeta"], ["id": "Alpha"], ["id": "zeta"]]]
        XCTAssertEqual(ModelCatalog.parse(body), ["Alpha", "zeta"])
    }

    func testSkipsEntriesThatNameNothing() {
        let body: [String: Any] = ["data": [
            ["id": "  "], ["id": 7], ["object": "model"], "", "  ", ["id": "usable"],
        ]]
        XCTAssertEqual(ModelCatalog.parse(body), ["usable"])
    }

    /// A reply Vervellum cannot read is an empty list, and the client turns that into a
    /// failure that tells the user to keep typing rather than an empty picker that looks
    /// like a bug.
    func testAnUnreadableReplyYieldsNothing() {
        XCTAssertTrue(ModelCatalog.parse([:]).isEmpty)
        XCTAssertTrue(ModelCatalog.parse(["data": "not-an-array"]).isEmpty)
        XCTAssertTrue(ModelCatalog.parse(["error": ["message": "nope"]]).isEmpty)
    }
}
