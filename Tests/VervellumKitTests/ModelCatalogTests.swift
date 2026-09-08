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
        // Case-sensitively, because HTTP paths are. `/v1/Models` is a route of its own
        // as far as this is concerned, so it gains a suffix like any other path rather
        // than being treated as an already-correct list address.
        XCTAssertEqual(ProviderSettings.modelListURL(from: "https://api.example.com/v1/Models")?
            .absoluteString,
                       "https://api.example.com/v1/Models/models")
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
        // And onto a paste that is already the list address. This is the one shape where
        // a passthrough that rebuilt the URL from scheme, host and path — dropping the
        // query — would satisfy every other assertion here, and Azure's list is unusable
        // without `api-version`.
        XCTAssertEqual(
            ProviderSettings.modelListURL(
                from: "https://r.openai.azure.com/openai/v1/models?api-version=2024-02")?
                .absoluteString,
            "https://r.openai.azure.com/openai/v1/models?api-version=2024-02")
    }

    /// The same endpoint hygiene every other address gets.
    func testRejectsUnusableEndpoints() {
        XCTAssertNil(ProviderSettings.modelListURL(from: "http://api.example.com/v1"))
        XCTAssertNil(ProviderSettings.modelListURL(from: "https://user:pass@api.example.com/v1"))
        XCTAssertNil(ProviderSettings.modelListURL(from: ""))
        XCTAssertNil(ProviderSettings.modelListURL(from: "not a url"))
        // The two shapes that actually arrive in this field, neither of which the rows
        // above reach: `URL(string:)` throws out "" and "not a url" on its own, so those
        // never exercise the validator at all. A schemeless host is what provider docs
        // print — and it is refused, because guessing `https` for someone who may have
        // meant a local server is a decision this field must not make for them.
        XCTAssertNil(ProviderSettings.modelListURL(from: "api.example.com/v1"))
        // A good address wearing the whitespace a copy picked up. Accepted: the paste is
        // right and the newline is the clipboard's, not the reader's.
        XCTAssertEqual(ProviderSettings.modelListURL(from: " https://api.example.com/v1\n")?
            .absoluteString,
                       "https://api.example.com/v1/models")
    }

    /// A local model server has no certificate, exactly like a local SearXNG instance.
    func testAllowsLoopbackWithoutTLS() {
        XCTAssertEqual(ProviderSettings.modelListURL(from: "http://localhost:11434/v1")?
            .absoluteString,
                       "http://localhost:11434/v1/models")
        // Ollama and llama.cpp print this form as often as the named one, and the
        // validator accepts both — so a paste of either must reach the same place.
        XCTAssertEqual(ProviderSettings.modelListURL(from: "http://127.0.0.1:11434/v1")?
            .absoluteString,
                       "http://127.0.0.1:11434/v1/models")
        // The third spelling those same docs print. `isLoopback` strips the brackets
        // before comparing, so this is allowed over plain HTTP like the other two — and
        // an IPv6-only local server is a real setup, not a curiosity.
        XCTAssertEqual(ProviderSettings.modelListURL(from: "http://[::1]:11434/v1")?
            .absoluteString,
                       "http://[::1]:11434/v1/models")
    }

    /// Both builders take the same paste, so the address whose questions work has to be
    /// the address whose list works. Written as a comparison rather than as two sets of
    /// literals because the failure this guards against is *drift* — one of them
    /// learning a shape the other does not.
    func testTheListAddressIsTheChatAddressWithItsLastSegmentSwapped() throws {
        for paste in ["https://host.example",
                      "https://host.example/v1",
                      "https://host.example/v1/chat/completions",
                      // A real provider's shape, and the only one here that carries a
                      // query — without it the comparison below is vacuous, since a
                      // builder that dropped the query on one side alone would agree
                      // with itself on every other row in this list. Azure's list is
                      // unusable without `api-version`, so this is the paste where
                      // losing it costs something.
                      "https://r.openai.azure.com/openai/v1/chat/completions?api-version=2024-02"] {
            let chat = try XCTUnwrap(ProviderSettings.chatCompletionsURL(from: paste), paste)
            let list = try XCTUnwrap(ProviderSettings.modelListURL(from: paste), paste)
            XCTAssertEqual(list.host, chat.host, paste)
            XCTAssertEqual(list.port, chat.port, paste)
            XCTAssertEqual(list.path,
                           chat.path.replacingOccurrences(of: "/chat/completions",
                                                          with: "/models"),
                           paste)
            XCTAssertEqual(list.query, chat.query, paste)
        }
    }

    /// The whole shape matrix in one place. `modelListURL` makes six decisions — trailing
    /// slashes, the chat suffix, the Azure deployment fold and its "one segment, nothing
    /// after" rule, `/models` idempotence, the query, the fragment — and a table is the
    /// only form in which a later tweak to one of them is visibly a change to the others.
    func testEveryShapeThePasteFieldAccepts() {
        let cases = [
            ("https://api.example.com", "https://api.example.com/models"),
            ("https://api.example.com/v1", "https://api.example.com/v1/models"),
            ("https://api.example.com/v1/", "https://api.example.com/v1/models"),
            ("https://api.example.com/v1/chat/completions", "https://api.example.com/v1/models"),
            // Idempotent: the list address is itself a plausible paste, because it is the
            // line the provider's documentation prints.
            ("https://api.example.com/v1/models", "https://api.example.com/v1/models"),
            // The query survives and the fragment does not. Azure's list is unusable
            // without `api-version`, and a fragment is never part of a request.
            ("https://r.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-01#x",
             "https://r.openai.azure.com/openai/models?api-version=2024-10-01"),
            // A deeper path under `deployments/` is somebody else's routing scheme, so
            // it is appended beside rather than folded away.
            ("https://r.openai.azure.com/openai/deployments/gpt-4o/extra",
             "https://r.openai.azure.com/openai/deployments/gpt-4o/extra/models"),
            // The fold does not require the chat suffix, and every other Azure row here
            // pairs the deployment with one — so the bare deployment somebody copies out
            // of the portal was the shape this table did not cover. It falls straight out
            // of the current order (strip the suffix if present, then fold), which is
            // exactly why it needs pinning: gating the fold on the suffix would change
            // this input alone, with nothing failing.
            ("https://r.openai.azure.com/openai/deployments/gpt-4o",
             "https://r.openai.azure.com/openai/models"),
        ]
        for (paste, expected) in cases {
            XCTAssertEqual(ProviderSettings.modelListURL(from: paste)?.absoluteString,
                           expected, paste)
        }
    }

    /// The one shape where they part, on purpose: Azure lists every deployment at
    /// `/openai/models`, so the list is not the chat route's sibling and swapping the
    /// last segment would ask for an address that has never existed.
    func testAzureIsTheDeliberateExceptionToThatParity() throws {
        let paste = "https://x.openai.azure.com/openai/deployments/gpt-4o/chat/completions"
        let chat = try XCTUnwrap(ProviderSettings.chatCompletionsURL(from: paste))
        let list = try XCTUnwrap(ProviderSettings.modelListURL(from: paste))
        XCTAssertEqual(chat.path, "/openai/deployments/gpt-4o/chat/completions")
        XCTAssertEqual(list.path, "/openai/models")
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
        // And it does not inherit the transport's generation-sized deadline: a reader
        // waiting on a list of names should not be held for ten minutes by a host that
        // has stopped answering.
        XCTAssertEqual(
            HTTPTransport.getRequest(url: url, timeout: ModelCatalogClient.listTimeout).timeoutInterval,
            ModelCatalogClient.listTimeout)
        XCTAssertLessThan(ModelCatalogClient.listTimeout, HTTPTransport.deadline)
        // What these two do not prove is that `fetch()` passes `listTimeout` at all —
        // a `fetch` that dropped the argument would keep both assertions above green and
        // hold this row for the generation-sized deadline. The test below watches the
        // request the client actually builds and says so.
    }

    /// The bound is only real if the client applies it, which needs the request itself.
    func testFetchAsksWithTheShortListTimeout() async throws {
        let url = try XCTUnwrap(ProviderSettings.modelListURL(from: "https://api.example.com/v1"))
        let transport = StubTransport { _ in .json(["data": [["id": "gpt-4o"]]]) }
        let client = ModelCatalogClient(url: url, apiKey: "k",
                                        trace: ResearchTrace(sink: SilentLog()),
                                        transport: transport)

        let models = try await client.fetch()
        XCTAssertEqual(models, ["gpt-4o"])
        // One call, to the address the client was built with: the stub answers anything,
        // so a `fetch` that started pointing somewhere else would otherwise stay green.
        XCTAssertEqual(transport.calls.count, 1)
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.url.absoluteString, url.absoluteString)
        XCTAssertEqual(call.method, "GET")
        // Both clocks, because they are different ones and a caller that means "not
        // longer than this" has to set each. Checking only the idle timeout would pin
        // half the promise.
        XCTAssertEqual(call.timeout, ModelCatalogClient.listTimeout,
                       "the list request must not inherit the transport's ten-minute deadline")
        XCTAssertEqual(call.deadline, ModelCatalogClient.listTimeout,
                       "nor read the body against it")
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
