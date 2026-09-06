import Foundation
import XCTest
#if canImport(VervellumKit)
@testable import VervellumKit
#else
@testable import Vervellum
#endif

final class EvidenceDiagnosticsTests: XCTestCase {

    func testUnknownKeysNeverReachDiagnostics() {
        let secret = "private-question\nBearer sk-sensitive-test-value"
        let shape = EvidenceExtractor.shape(of: [secret: "value", "second-private-key": 3])
        XCTAssertFalse(shape.contains(secret))
        XCTAssertFalse(shape.contains("second-private-key"))
        XCTAssertFalse(shape.contains("Bearer"))
        XCTAssertTrue(shape.contains("2 other fields"))
    }

    func testUnknownKeysStayPrivateInsideArraysAndJSONStringBlocks() throws {
        let secret = "credential-shaped-dictionary-key"
        let nested: [String: Any] = ["content": [["text": [secret: "value"]]]]
        let data = try JSONSerialization.data(withJSONObject: nested)
        let shape = EvidenceExtractor.shape(of: String(decoding: data, as: UTF8.self))
        XCTAssertFalse(shape.contains(secret))
        XCTAssertTrue(shape.contains("json-string"))
        XCTAssertTrue(shape.contains("content:"))
        XCTAssertTrue(shape.contains("text:"))
        XCTAssertTrue(shape.contains("1 other field"))
    }

    func testKnownFieldNamesRemainUsefulButValuesStayPrivate() {
        let shape = EvidenceExtractor.shape(of: [
            "title": "private title",
            "snippet": "private summary",
            "url": "https://private.example/secret",
        ])
        XCTAssertTrue(shape.contains("title: string("))
        XCTAssertTrue(shape.contains("snippet: string("))
        XCTAssertTrue(shape.contains("url: string("))
        XCTAssertFalse(shape.contains("private"))
        XCTAssertFalse(shape.contains("secret"))
    }

    func testManyUnknownKeysCannotCrowdOutKnownFields() {
        var object: [String: Any] = ["title": "A result"]
        for index in 0..<100 { object["\(index)-private"] = "value" }
        let shape = EvidenceExtractor.shape(of: object)
        XCTAssertTrue(shape.contains("title: string("))
        XCTAssertTrue(shape.contains("100 other fields"))
        XCTAssertFalse(shape.contains("private"))
    }

    func testDiagnosticKeysAreCaseSensitiveAndExact() {
        let shape = EvidenceExtractor.shape(of: ["Title": "x", "title\nsecret": "x", "title": "x"])
        XCTAssertTrue(shape.contains("title: string("))
        XCTAssertTrue(shape.contains("2 other fields"))
        XCTAssertFalse(shape.contains("Title:"))
        XCTAssertFalse(shape.contains("secret"))
    }
}
