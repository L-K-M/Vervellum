import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class ResearchErrorTests: XCTestCase {

    /// The rule the whole networking layer exists to enforce: a provider's own error
    /// text never reaches a log or the user, because gateway messages have been seen
    /// echoing request data and credentials back. Only the type name may escape.
    func testAForeignErrorIsReducedToItsTypeName() {
        struct LeakyProviderError: LocalizedError {
            var errorDescription: String? { "401 from https://api.example.com?key=sk-SECRETVALUE" }
        }
        let label = ResearchError.safeLabel(for: LeakyProviderError())
        XCTAssertEqual(label, "LeakyProviderError")
        XCTAssertFalse(label.contains("sk-SECRETVALUE"))
        XCTAssertFalse(label.contains("api.example.com"))
    }

    func testOurOwnMessagesArePassedThrough() {
        let error = ResearchError("The provider returned HTTP 429.")
        XCTAssertEqual(ResearchError.safeLabel(for: error), "The provider returned HTTP 429.")
        XCTAssertEqual(error.errorDescription, "The provider returned HTTP 429.")
    }

    func testAnNSErrorDoesNotLeakItsUserInfo() {
        let error = NSError(domain: "Provider", code: 401,
                            userInfo: [NSLocalizedDescriptionKey: "key sk-SECRET rejected"])
        let label = ResearchError.safeLabel(for: error)
        XCTAssertFalse(label.contains("SECRET"))
    }

    /// Every canned message must name a next step. An error the user cannot act on is
    /// indistinguishable from a crash.
    func testCannedMessagesAreActionable() {
        for error in [ResearchError.notConfigured, .responseTooLarge, .connectionFailed,
                      .invalidResponse, .providerStatus(500)] {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertTrue(error.message.hasSuffix(".") || error.message.hasSuffix("?"),
                          "not a sentence: \(error.message)")
        }
        XCTAssertTrue(ResearchError.notConfigured.message.contains("Settings"))
        XCTAssertTrue(ResearchError.providerStatus(429).message.contains("429"))
    }

    /// The two exclusions are the fallback chain's whole contract about what a spare is
    /// *not* for, and both are promises to the reader: a Stop never spends another
    /// provider's request, and a payload no endpoint could encode is not re-sent to four
    /// of them. Everything else is retried, including the failures that look like
    /// configuration — a rejected key and an unknown model name are exactly the states a
    /// second provider exists to cover.
    func testWhichFailuresAreWorthAnotherProvider() {
        XCTAssertFalse(ResearchError.cancelled.isWorthAnotherProvider, "Stop is not weather")
        XCTAssertFalse(ResearchError.invalidContext.isWorthAnotherProvider,
                       "the same payload is the same size at every endpoint")
        for error in [ResearchError.notConfigured, .connectionFailed, .timedOut,
                      .invalidResponse, .streamInterrupted, .responseTooLarge, .badRequest,
                      .rejectedCredential(401), .rejectedCredential(403),
                      .providerStatus(429), .providerStatus(500)] {
            XCTAssertTrue(error.isWorthAnotherProvider, "not retried: \(error.message)")
        }
    }
}
