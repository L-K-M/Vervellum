import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class SearchMCPClientTests: XCTestCase {

    /// A gateway's own message is only ever *classified*, never shown. The
    /// classification must not tell a user with an exhausted balance to replace a key
    /// that works.
    func testQuotaMessagesAreNotReadAsABadKey() {
        XCTAssertFalse(SearchMCPClient.describesAuthenticationFailure("Insufficient token balance"))
        XCTAssertFalse(SearchMCPClient.describesAuthenticationFailure("tokens per minute limit exceeded"))
        XCTAssertFalse(SearchMCPClient.describesAuthenticationFailure("token quota exhausted"))
    }

    func testKeyMessagesAreReadAsABadKey() {
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("Authentication failed"))
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("Invalid API key"))
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("invalid token"))
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("Token expired"))
        XCTAssertTrue(SearchMCPClient.describesAuthenticationFailure("Unauthorized"))
    }
}
