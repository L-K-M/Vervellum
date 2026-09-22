import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

final class SecretBlobTests: XCTestCase {

    func testRoundTrip() throws {
        let secrets = [
            "model-api-key": "sk-test-123",
            "model-api-key.F8B9C7D6-0000-4000-8000-000000000001": "other key",
            "reader-api-key": "a key\nwith a newline",
        ]
        let decoded = SecretBlob.decode(try SecretBlob.encode(secrets))
        XCTAssertEqual(decoded, secrets)
    }

    func testEmptyDictionaryRoundTrips() throws {
        XCTAssertEqual(SecretBlob.decode(try SecretBlob.encode([:])), [:])
    }

    /// A corrupt or foreign payload must read as *unreadable* — nil — never as an
    /// empty dictionary. A caller that emptied it would write the empty result back
    /// and destroy every stored key.
    func testNonDictionaryPayloadDecodesToNil() {
        XCTAssertNil(SecretBlob.decode(Data("not json".utf8)))
        XCTAssertNil(SecretBlob.decode(Data("[1,2,3]".utf8)))
        XCTAssertNil(SecretBlob.decode(Data(#"{"key": 42}"#.utf8)))
        XCTAssertNil(SecretBlob.decode(Data(#"{"key": {"nested": true}}"#.utf8)))
        XCTAssertNil(SecretBlob.decode(Data(#""just a string""#.utf8)))
        XCTAssertNil(SecretBlob.decode(Data("null".utf8)))
        XCTAssertNil(SecretBlob.decode(Data("true".utf8)))
        XCTAssertNil(SecretBlob.decode(Data()))
    }

    /// An account cleared to the empty string stays an empty string here — whether
    /// it counts as *stored* is the store's decision (`KeychainStore` treats it as
    /// absent, the same rule `SecretStore.set` documents), not the codec's.
    func testEmptyStringValuesArePreserved() {
        let decoded = SecretBlob.decode(Data(#"{"account": ""}"#.utf8))
        XCTAssertEqual(decoded, ["account": ""])
    }

    /// The same secrets must encode to the same bytes regardless of dictionary
    /// order, so the stored item is stable.
    func testEncodingIsDeterministic() throws {
        let a = try SecretBlob.encode(["b": "2", "a": "1"])
        let b = try SecretBlob.encode(["a": "1", "b": "2"])
        XCTAssertEqual(a, b)
    }
}
