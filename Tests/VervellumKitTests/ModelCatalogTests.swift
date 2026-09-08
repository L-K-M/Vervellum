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
        // The shape a provider's own documentation is usually copied in, and the one that
        // exercises the strip-slashes / strip-suffix / strip-slashes ordering rather than
        // either half of it alone.
        XCTAssertEqual(
            ProviderSettings.modelListURL(from: "https://api.example.com/v1/chat/completions/")?
                .absoluteString,
            "https://api.example.com/v1/models")
    }

    /// The model-list URL is itself a plausible paste — it is the line a provider's
    /// documentation prints — so appending must be idempotent rather than producing
    /// `/v1/models/models`, which no provider serves.
    func testAPastedModelsPathIsUsedAsIs() {
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/v1/models")?
            .absoluteString,
                       "https://api.example.com/v1/models")
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/v1/models/")?
            .absoluteString,
                       "https://api.example.com/v1/models")
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/models")?
            .absoluteString,
                       "https://api.example.com/models")
    }

    /// Only a whole path component counts: a path merely *ending* in the letters is a
    /// different resource, and still needs its own `/models` sibling.
    func testAPathThatOnlyEndsInTheLettersStillGetsItsOwnSuffix() {
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/v1/mymodels")?
            .absoluteString,
                       "https://api.example.com/v1/mymodels/models")
    }

    /// Azure's deployment-scoped route is the one shape whose model list is not its own
    /// sibling: every deployment is listed at `/openai/models`. `chatCompletionsURL`
    /// takes the deployment path as a custom route and leaves it alone, so without this
    /// the address that answers questions 404s the moment the reader asks for a list.
    func testAnAzureDeploymentPathListsAtTheAccountRoute() {
        XCTAssertEqual(
            ProviderSettings.modelListURL(
                from: "https://r.openai.azure.com/openai/deployments/gpt-4o/chat/completions"
                    + "?api-version=2024-02")?.absoluteString,
            "https://r.openai.azure.com/openai/models?api-version=2024-02")
        // Azure's newer v1 surface needs no folding — its sibling route is the real one.
        XCTAssertEqual(
            ProviderSettings.modelListURL(
                from: "https://r.openai.azure.com/openai/v1/chat/completions?api-version=2024-02")?
                .absoluteString,
            "https://r.openai.azure.com/openai/v1/models?api-version=2024-02")
    }

    /// Only a bare deployment name is folded away. Anything deeper under `deployments/`
    /// is somebody else's routing scheme, and guessing at it would be worse than
    /// appending beside it.
    func testADeeperDeploymentPathIsLeftAlone() {
        XCTAssertEqual(
            ProviderSettings.modelListURL(
                from: "https://gateway.example.com/openai/deployments/team/gpt-4o")?
                .absoluteString,
            "https://gateway.example.com/openai/deployments/team/gpt-4o/models")
    }

    func testTrailingSlashesAreDroppedAndTheFragmentWithThem() {
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/v1/")?
            .absoluteString,
                       "https://api.example.com/v1/models")
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/v1#f")?
            .absoluteString,
                       "https://api.example.com/v1/models")
    }

    /// The query is not the fragment: `chatCompletionsURL` carries it, so this must too,
    /// or a provider that answers questions reports no models. Azure's OpenAI-compatible
    /// surface requires `?api-version=` on every call.
    func testTheQueryIsCarriedOntoTheListURL() {
        XCTAssertEqual(
            ProviderSettings.modelListURL(from: "https://api.example.com/v1?api-version=2024-02")?
                .absoluteString,
            "https://api.example.com/v1/models?api-version=2024-02")
        // And from the full chat path, which is the shape Azure's docs actually print.
        XCTAssertEqual(
            ProviderSettings.modelListURL(
                from: "https://api.example.com/v1/chat/completions?api-version=2024-02")?
                .absoluteString,
            "https://api.example.com/v1/models?api-version=2024-02")
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

    /// The key has to reach the request, and as the same scheme chat uses.
    func testTheKeyIsSentAsABearerTokenLikeChat() throws {
        let url = try XCTUnwrap(ProviderSettings.modelListURL(from: "https://api.example.com/v1"))
        let request = HTTPTransport.getRequest(url: url, headers: ["Authorization": "Bearer k"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(request.httpMethod, "GET")
        // And nothing is attached when there is no key: a local server that takes none
        // must not be sent an empty credential.
        XCTAssertNil(HTTPTransport.getRequest(url: url).value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: The reply

    /// Case-variant duplicates both survive an exact dedup, so the ordering between them
    /// has to come from the names rather than from the sort's internals.
    func testCaseVariantNamesSortDeterministically() {
        let body: [String: Any] = ["data": [["id": "gpt-4o"], ["id": "GPT-4o"], ["id": "alpha"]]]
        XCTAssertEqual(ModelCatalog.parse(body), ["alpha", "GPT-4o", "gpt-4o"])
    }

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
