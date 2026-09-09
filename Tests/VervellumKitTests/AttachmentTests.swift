import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// What may be attached to a question, and what the bytes turn out to be.
final class AttachmentTests: XCTestCase {

    private func png(_ payload: Int = 32) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: payload)
    }

    // MARK: What the bytes are

    /// The type comes from the bytes, never from the name. A file's extension is the one
    /// part of it that carries no evidence about what it is, and this type is about to be
    /// announced to a provider and base64'd into a request on that claim.
    func testTheTypeIsSniffedRatherThanTakenFromTheName() {
        XCTAssertEqual(Attachment.imageMediaType(sniffing: png()), "image/png")
        XCTAssertEqual(Attachment.imageMediaType(sniffing: Data([0xFF, 0xD8, 0xFF, 0xE0])),
                       "image/jpeg")
        XCTAssertEqual(Attachment.imageMediaType(sniffing: Data("GIF89a...".utf8)), "image/gif")

        var webp = Data("RIFF".utf8) + Data([0x20, 0x00, 0x00, 0x00]) + Data("WEBP".utf8)
        webp.append(contentsOf: [0x56, 0x50, 0x38, 0x20])
        XCTAssertEqual(Attachment.imageMediaType(sniffing: webp), "image/webp")

        // A RIFF container that is not a WebP — a WAV, say — is not an image.
        let wav = Data("RIFF".utf8) + Data([0x20, 0x00, 0x00, 0x00]) + Data("WAVE".utf8)
        XCTAssertNil(Attachment.imageMediaType(sniffing: wav))
        XCTAssertNil(Attachment.imageMediaType(sniffing: Data("<html></html>".utf8)))
        XCTAssertNil(Attachment.imageMediaType(sniffing: Data()))
    }

    /// A file called `diagram.png` whose bytes are text is text. The name loses.
    func testAMisnamedFileIsWhatItsBytesSay() throws {
        let result = Attachment.make(from: Data("plain, honest text".utf8), name: "diagram.png")
        // Unwrapped directly: a failure here should report the refusal, not "nil".
        let (attachment, bytes) = try result.get()
        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.mediaType, "text/plain")
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "plain, honest text")
    }

    /// UTF-8 that decodes but carries a NUL is a binary that happens to start legibly,
    /// not a text file. Cheaper and more honest than guessing from an extension.
    func testBinaryWithANulIsNotText() {
        XCTAssertNil(Attachment.text(from: Data("head\0tail".utf8)))
        XCTAssertNotNil(Attachment.text(from: Data("head\ttail\n".utf8)))
        // Invalid UTF-8 is not text either.
        XCTAssertNil(Attachment.text(from: Data([0xFF, 0xFE, 0x00, 0x01])))
    }

    /// A long text file is too *large*, not unsupported: it is exactly the sort of thing
    /// that can be attached, and being told otherwise sends its owner looking for a
    /// format problem that is not there.
    func testAnOversizedTextFileIsRefusedForItsSizeRatherThanItsKind() {
        let long = Data(String(repeating: "a", count: Attachment.maxImageBytes + 1).utf8)
        guard case .failure(let reason) = Attachment.make(from: long, name: "huge.log") else {
            return XCTFail("accepted an oversized file")
        }
        XCTAssertEqual(reason, .tooLarge(name: "huge.log", byteCount: long.count))
    }

    /// An empty file is refused rather than attached. It would otherwise be stored,
    /// listed, and its name carried into every later turn — telling the model about a
    /// file whose contents are nothing.
    func testAnEmptyFileIsNotAnAttachment() {
        guard case .failure = Attachment.make(from: Data(), name: "empty.txt") else {
            return XCTFail("accepted an empty file")
        }
    }

    func testAnUnsupportedFileIsRefusedByName() {
        let refusal = Attachment.make(from: Data([0x00, 0x01, 0x02, 0x03]), name: "thing.bin")
        guard case .failure(let reason) = refusal else { return XCTFail("accepted a binary") }
        XCTAssertEqual(reason, .unsupported(name: "thing.bin"))
        XCTAssertTrue(reason.message.contains("thing.bin"), reason.message)
    }

    // MARK: Size

    /// Refused rather than scaled: scaling needs an imaging framework, and nothing under
    /// `Core/` may import one. The message says what to do instead, because "too large"
    /// with no number is a dead end.
    func testAnImageOverTheCapIsRefusedWithItsSize() {
        let huge = png(Attachment.maxImageBytes)
        guard case .failure(let reason) = Attachment.make(from: huge, name: "shot.png") else {
            return XCTFail("accepted an oversized image")
        }
        XCTAssertEqual(reason, .tooLarge(name: "shot.png", byteCount: huge.count))
        XCTAssertTrue(reason.message.contains("shot.png"), reason.message)
        XCTAssertTrue(reason.message.contains("MB"), reason.message)

        // And the byte below the cap is fine, so the boundary is the documented one.
        let exact = png(Attachment.maxImageBytes - 8)
        XCTAssertEqual(exact.count, Attachment.maxImageBytes)
        XCTAssertNoThrow(try Attachment.make(from: exact, name: "shot.png").get())
    }

    /// A long file is truncated with the same visible marker a truncated page carries.
    /// Nobody is told the model saw more than it did.
    func testLongTextIsTruncatedVisibly() throws {
        let long = String(repeating: "a", count: Attachment.maxTextCharacters + 500)
        // Unwrapped directly, like the test above: a refusal here should say which one.
        let (attachment, bytes) = try Attachment.make(from: Data(long.utf8),
                                                      name: "notes.txt").get()
        let text = String(decoding: bytes, as: UTF8.self)

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertTrue(text.hasSuffix("[…]"), "no truncation marker")
        XCTAssertLessThan(text.count, long.count)
        XCTAssertEqual(attachment.byteCount, bytes.count,
                       "the record's size must be the size of what was stored")
    }

    // MARK: The name

    /// A name is display text and goes into a JSON payload the model reads. A newline in
    /// it could forge a line there; a slash would make it look like a path.
    func testANameIsCleanedUp() {
        XCTAssertEqual(Attachment.displayName(for: "sh\not.png"), "shot.png")
        XCTAssertEqual(Attachment.displayName(for: "../../etc/passwd"), ".._.._etc_passwd")
        XCTAssertEqual(Attachment.displayName(for: "a\\b.txt"), "a_b.txt")
        XCTAssertEqual(Attachment.displayName(for: "   "), "attachment")
        XCTAssertEqual(Attachment.displayName(for: ""), "attachment")
        XCTAssertEqual(Attachment.displayName(for: String(repeating: "x", count: 300)).count, 120)
    }

    /// A name reaches both the panel and the model's payload, so the invisible
    /// characters that make "photo.png" render as something else have to go with the
    /// newlines. `CharacterSet.controlCharacters` is Cc *and* Cf, which is what covers
    /// the bidi overrides and the zero-width marks — pinned here because that is a
    /// property of Foundation this code relies on rather than one it states.
    func testANameCannotCarryInvisibleReorderingMarks() {
        let overridden = "photo\u{202E}gnp.txt"
        XCTAssertFalse(Attachment.displayName(for: overridden).unicodeScalars
            .contains { $0.value == 0x202E }, Attachment.displayName(for: overridden))
        let zeroWidth = "sh\u{200B}ot.png"
        XCTAssertEqual(Attachment.displayName(for: zeroWidth), "shot.png")
        // A name that is nothing but invisible characters still comes back usable.
        XCTAssertEqual(Attachment.displayName(for: "\u{202A}\u{2069}"), "attachment")

        // U+2028 and U+2029 are Zl and Zp, so `controlCharacters` does not catch them —
        // and both break a layout exactly the way a newline does.
        XCTAssertEqual(Attachment.displayName(for: "sh\u{2028}ot.png"), "shot.png")
        XCTAssertEqual(Attachment.displayName(for: "sh\u{2029}ot.png"), "shot.png")
    }

    // MARK: Decoding

    /// A kind written by a later build decodes as something this one can skip, rather
    /// than making the whole thread unreadable — the mistake `ResearchStage` documents.
    func testAnUnknownKindDecodesRatherThanFailing() throws {
        let json = """
            {"id":"\(UUID().uuidString)","kind":"video","name":"clip.mov",
             "mediaType":"video/quicktime","byteCount":10}
            """
        let decoded = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .other)
        XCTAssertEqual(decoded.name, "clip.mov")
    }

    /// A turn written before attachments existed still loads, with none.
    func testATurnWrittenBeforeAttachmentsDecodes() throws {
        let json = """
            {"id":"\(UUID().uuidString)","question":"Q","askedAt":"2026-01-01T00:00:00Z",
             "stage":"complete","reading":"","searches":[],"sources":[],"answer":"A",
             "findings":[],"limitations":"","followups":[],"notices":[],"model":"m"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let turn = try decoder.decode(ResearchTurn.self, from: Data(json.utf8))
        XCTAssertTrue(turn.attachments.isEmpty)
    }

    /// A provider nobody has said has eyes is one an image would fail on, so an absent
    /// flag reads as "no" rather than as "try it and see".
    func testAProfileWrittenBeforeTheImageFlagDefaultsToNotSendingThem() throws {
        let json = """
            [{"id":"\(UUID().uuidString)","name":"P","endpoint":"https://a.example/v1",
              "model":"m","keyAccount":"model-api-key"}]
            """
        let profiles = try XCTUnwrap(ProviderSettings.decodeModelProfiles(json))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertFalse(profiles[0].sendsImages)
    }
}
