import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class SecretRedactorTests: XCTestCase {

    private func assertRedacted(_ text: String, _ secret: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let result = SecretRedactor.redact(text)
        XCTAssertTrue(result.didRedact, "nothing was redacted from: \(text)", file: file, line: line)
        XCTAssertFalse(result.text.contains(secret),
                       "the secret survived: \(result.text)", file: file, line: line)
    }

    func testRedactsVendorPrefixedKeys() {
        assertRedacted("my key is sk-abcdefghijklmnopqrstuvwxyz123456", "abcdefghijklmnop")
        assertRedacted("token ghp_abcdefghijklmnopqrstuvwxyz1234", "ghp_abcdefghijkl")
        assertRedacted("xoxb-1234567890-abcdefghijkl", "xoxb-1234567890")
        assertRedacted("AIzaSyA1234567890abcdefghijklmnopqrstuv", "AIzaSy")
        assertRedacted("AKIAIOSFODNN7EXAMPLE", "AKIAIOSFODNN7EXAMPLE")
        // Stripe's shape, bare: no `=` and no `Bearer` for the other patterns to find.
        // Assembled at run time so the source file does not itself look like a leak
        // to a secret scanner — which is, after all, the point.
        let stripeBody = String(repeating: "a1", count: 12)
        assertRedacted("sk_live_" + stripeBody, stripeBody)
        assertRedacted("rk_test_" + stripeBody, stripeBody)
    }

    func testRedactsAuthorizationHeaders() {
        assertRedacted("curl -H 'Authorization: Bearer abcdefghijklmnopqrst'", "abcdefghijklmnop")
        assertRedacted("Basic dXNlcjpwYXNzd29yZDEyMw==", "dXNlcjpwYXNz")
        assertRedacted("Bearer abc123def456ghi789jkl", "abc123def456")
        assertRedacted("token 0123456789abcdef", "0123456789abcdef")
        // Inside a header even an all-letter value is a credential.
        assertRedacted("authorization: bearer abcdefghijklmnopqrstuv", "abcdefghijklmnop")
    }

    /// The .env case: the single most likely thing to be selected in a terminal.
    func testRedactsAssignments() {
        assertRedacted("API_KEY=supersecretvalue123", "supersecretvalue123")
        assertRedacted("password: hunter2hunter2", "hunter2hunter2")
        assertRedacted(#"client_secret = "abcd1234efgh5678""#, "abcd1234efgh5678")
        assertRedacted("DATABASE_TOKEN: tok_live_9876543210", "tok_live_9876543210")
        // The keyword is wrapped on both sides here, which a naive word boundary misses.
        assertRedacted("STRIPE_SECRET_KEY=sk_live_abcdefghijkl", "sk_live_abcdefghijkl")
        assertRedacted("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCY", "wJalrXUtnFEMIK")
    }

    func testRedactsPrivateKeyBlocks() {
        let pem = """
            -----BEGIN RSA PRIVATE KEY-----
            MIIEowIBAAKCAQEAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
            -----END RSA PRIVATE KEY-----
            """
        assertRedacted("Here is the key:\n\(pem)", "MIIEowIBAAKCAQEA")
    }

    func testRedactsCredentialsInAURL() {
        assertRedacted("postgres://admin:s3cr3tpass@db.example.com/app", "s3cr3tpass")
    }

    func testRedactsJWTs() {
        assertRedacted("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w",
                       "eyJzdWIiOiIxMjM0")
    }

    /// The other half of the contract: ordinary prose must survive untouched, or the
    /// feature becomes something users turn off.
    func testLeavesOrdinaryTextAlone() {
        for text in [
            "What is the secret of a good sourdough starter?",
            "The password reset flow is broken on Safari.",
            "See https://example.com/docs/api-key for the field list.",
            "Bearer bonds are a kind of debt security.",
            "let token = parser.next()",
            "The access_key rotation policy is documented in the wiki.",
            "Why does the secret sharing scheme need a threshold?",
            "token_count = countTokens(text)",
            "There is a basic misunderstanding of how the tax applies.",
            "A basic well-established principle of contract law.",
            "The token internationalization work is scheduled for later.",
            "The sk_buffer_allocate_pages call is documented in the kernel tree.",
        ] {
            let result = SecretRedactor.redact(text)
            XCTAssertFalse(result.didRedact, "wrongly redacted: \(text) → \(result.text)")
            XCTAssertEqual(result.text, text)
        }
    }

    func testCountsEveryRedaction() {
        let result = SecretRedactor.redact("sk-aaaaaaaaaaaaaaaaaaaa and ghp_bbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertEqual(result.redactionCount, 2)
    }

    func testIsIdempotent() {
        let once = SecretRedactor.redact("API_KEY=supersecretvalue123")
        let twice = SecretRedactor.redact(once.text)
        XCTAssertFalse(twice.didRedact)
        XCTAssertEqual(twice.text, once.text)
    }

    func testHandlesEmptyInput() {
        XCTAssertEqual(SecretRedactor.redact(""), SecretRedactor.Result(text: "", redactionCount: 0))
    }
}
