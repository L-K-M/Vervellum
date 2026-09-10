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
        // The signature is the three bytes before the APPn marker, and that is what
        // makes it a signature rather than a JFIF one: every photograph a phone takes is
        // Exif, whose fourth byte is E1. A four-byte match would have refused all of
        // them as unsupported, and nothing here would have said so.
        XCTAssertEqual(Attachment.imageMediaType(sniffing: Data([0xFF, 0xD8, 0xFF, 0xE1])),
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
        // Shorter than any signature, which is what a truncated download delivers. The
        // sniffer answers nil rather than trapping — a fixed-offset read would not, and
        // nothing else here would tell the two apart.
        for length in 1...7 {
            XCTAssertNil(Attachment.imageMediaType(sniffing: Data(png().prefix(length))),
                         "\(length) bytes is not a signature")
        }
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
        // Invalid UTF-8 is not text either — and with no NUL in it, so that is the only
        // thing wrong with it. A fixture that broke both rules would have gone on
        // passing with the UTF-8 check deleted outright, since the NUL rule above
        // already covers its own case.
        XCTAssertNil(Attachment.text(from: Data([0xFF, 0xFE, 0x21])),
                     "invalid UTF-8, with nothing else wrong with it")
    }

    /// A long text file is too *large*, not unsupported: it is exactly the sort of thing
    /// that can be attached, and being told otherwise sends its owner looking for a
    /// format problem that is not there.
    func testAnOversizedTextFileIsRefusedForItsSizeRatherThanItsKind() {
        let long = Data(String(repeating: "a", count: Attachment.maxAttachmentBytes + 1).utf8)
        guard case .failure(let reason) = Attachment.make(from: long, name: "huge.log") else {
            return XCTFail("accepted an oversized file")
        }
        XCTAssertEqual(reason, .tooLarge(name: "huge.log", byteCount: long.count))
    }

    /// A file holding only a byte-order mark is empty too, and this is the input the
    /// check in `make` is actually written for — `Data()` would be refused by a trim
    /// that only knew about spaces.
    ///
    /// Pinned because it rests on a property of Foundation rather than one this code
    /// states: `CharacterSet.controlCharacters` is Unicode categories Cc *and* Cf, and
    /// U+FEFF is Cf. `testDisplayNameStripsWhatWouldDeceive` pins the same fact for a
    /// file's name; this pins it for a file's contents, which is the half a reader of
    /// `make` has to take on trust.
    func testAFileHoldingOnlyAByteOrderMarkIsRefusedAsEmpty() {
        guard case .failure(let reason) = Attachment.make(from: Data([0xEF, 0xBB, 0xBF]),
                                                          name: "bom.txt")
        else { return XCTFail("accepted a file whose only character draws nothing") }
        XCTAssertEqual(reason, .empty(name: "bom.txt"))
    }

    /// An empty file is refused rather than attached. It would otherwise be stored,
    /// listed, and its name carried into every later turn — telling the model about a
    /// file whose contents are nothing.
    func testAnEmptyFileIsNotAnAttachment() {
        guard case .failure(let reason) = Attachment.make(from: Data(), name: "empty.txt")
        else { return XCTFail("accepted an empty file") }
        // The reason, not only the refusal. A regression that rejected empty files
        // through some other case — or with a message that stopped naming the file —
        // would leave the reader with a sentence they cannot act on, and the assertion
        // above would still be green.
        XCTAssertEqual(reason, .empty(name: "empty.txt"))
        XCTAssertTrue(reason.message.contains("empty.txt"), reason.message)
        // And in its own words. Refused as "unsupported", a `touch`ed file or a download
        // that died sends its owner looking for a format problem in a file whose only
        // problem is that there is nothing in it.
        XCTAssertFalse(reason.message.contains("not something Vervellum can attach"),
                       reason.message)
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
        let huge = png(Attachment.maxAttachmentBytes)
        guard case .failure(let reason) = Attachment.make(from: huge, name: "shot.png") else {
            return XCTFail("accepted an oversized image")
        }
        XCTAssertEqual(reason, .tooLarge(name: "shot.png", byteCount: huge.count))
        XCTAssertTrue(reason.message.contains("shot.png"), reason.message)
        XCTAssertTrue(reason.message.contains("MB"), reason.message)

        // And a file of exactly the cap is fine — `png()` adds an eight-byte header — so
        // the boundary pinned here is the inclusive one the guard actually implements.
        let exact = png(Attachment.maxAttachmentBytes - 8)
        XCTAssertEqual(exact.count, Attachment.maxAttachmentBytes)
        // The happy path, said out loud. `XCTAssertNoThrow` proved only that nothing
        // threw — a regression that classified an accepted image as text, stamped the
        // wrong media type, or recorded the wrong size would have shipped green through
        // it, and this is the PR's central behaviour.
        guard case .success(let (accepted, stored)) =
                Attachment.make(from: exact, name: "shot.png") else {
            return XCTFail("a file of exactly the cap was refused")
        }
        XCTAssertEqual(accepted.kind, .image)
        XCTAssertEqual(accepted.mediaType, "image/png")
        XCTAssertEqual(accepted.byteCount, stored.count)
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
        // And not *much* less: "shorter than the input" is also satisfied by a
        // regression that keeps a fraction of the allowance, which would quietly show
        // the model less of the user's file than the cap promises.
        XCTAssertEqual(text.count, Attachment.maxTextCharacters + "\n[…]".count,
                       "truncation kept something other than the allowance")
        XCTAssertEqual(attachment.byteCount, bytes.count,
                       "the record's size must be the size of what was stored")

        // ASCII cannot tell a character cut from a byte cut — every character is one
        // byte, so both land in the same place. A sliced multi-byte tail would decode
        // lossily and still carry the marker and the shorter length asserted above, so
        // only a fixture that is not ASCII can say which kind of cut this is.
        let emoji = String(repeating: "\u{1F60A}", count: Attachment.maxTextCharacters + 500)
        let (_, emojiBytes) = try Attachment.make(from: Data(emoji.utf8),
                                                  name: "emoji.txt").get()
        XCTAssertFalse(String(decoding: emojiBytes, as: UTF8.self).contains("\u{FFFD}"),
                       "truncation split a multi-byte character")
    }

    /// The GIF signature is the only one made of characters a text file can contain —
    /// PNG and JPEG both start with bytes that are not valid UTF-8. Four bytes of it were
    /// matched once, which meant a note or a changelog that opened with the word GIF8 was
    /// base64'd into a `data:` URL as a picture and its text never sent.
    func testTextThatMentionsGIFIsNotSniffedAsOne() throws {
        let note = "GIF8 is the prefix both GIF versions share, which is why it is not\n"
            + "enough to identify one.\n"
        let (attachment, _) = try Attachment.make(from: Data(note.utf8), name: "note.md").get()
        XCTAssertEqual(attachment.kind, .text)

        for header in ["GIF87a", "GIF89a"] {
            let bytes = Data(header.utf8) + Data(repeating: 0, count: 16)
            let (image, _) = try Attachment.make(from: bytes, name: "real.gif").get()
            XCTAssertEqual(image.kind, .image, header)
            XCTAssertEqual(image.mediaType, "image/gif", header)
        }
    }

    /// The record is decoded inside a turn, which is inside the library — so a field
    /// added to it later must not be able to take the whole document down. `id` is the
    /// exception, because a record whose bytes cannot be found is not a record.
    func testARecordFromAnOlderBuildStillDecodes() throws {
        let id = UUID()
        let sparse = "{\"id\":\"\(id.uuidString)\"}"
        let decoded = try JSONDecoder().decode(Attachment.self, from: Data(sparse.utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.kind, .other(raw: "other"), "an absent kind is the safe reading")
        XCTAssertEqual(decoded.byteCount, 0)
        XCTAssertFalse(decoded.name.isEmpty, "something has to be shown in the panel")

        // Without an id there is nothing to look up, so this one still fails.
        XCTAssertThrowsError(try JSONDecoder().decode(Attachment.self, from: Data("{}".utf8)))
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
        XCTAssertEqual(decoded.kind, .other(raw: "video"))
        XCTAssertEqual(decoded.name, "clip.mov")

        // And it goes back out as `"video"`, not as `"other"`. The record surviving this
        // build's save is only half of it: a kind flattened on the way out would come
        // back to the newer build permanently downgraded, leaving that build unable to
        // read an attachment it wrote itself.
        let written = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "video")
    }

    /// A field of the wrong *type* degrades exactly as a missing one does.
    ///
    /// `decodeIfPresent` answers an absent key with nil and a present-but-wrong-typed one
    /// by throwing, and that throw climbs the ladder the hand-written decoder exists to
    /// stop: attachment, turn, library, and an older build starting from an empty one.
    /// A hand-edited document is exactly where this arrives.
    func testAWrongTypedFieldDegradesRatherThanThrowing() throws {
        let id = UUID()
        let wrong = """
            {"id":"\(id.uuidString)","kind":42,"name":7,
             "mediaType":null,"byteCount":"1.4 MB"}
            """
        let decoded = try JSONDecoder().decode(Attachment.self, from: Data(wrong.utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.kind, .other(raw: "other"))
        XCTAssertEqual(decoded.mediaType, "application/octet-stream")
        XCTAssertEqual(decoded.byteCount, 0)
        XCTAssertFalse(decoded.name.isEmpty, "something has to be shown in the panel")
    }

    /// Sanitising a sanitised name changes nothing, which is what lets the decoder run
    /// every name through `displayName` without the one it wrote coming back different.
    ///
    /// The cut is the case worth pinning: a trimmed name whose 120th character is a
    /// space came back with a trailing one, so the name attached and the name shown
    /// after reopening differed by exactly that.
    func testSanitisingASanitisedNameChangesNothing() {
        let awkward = String(repeating: "a", count: 119) + "   tail.png"
        let once = Attachment.displayName(for: awkward)
        XCTAssertEqual(Attachment.displayName(for: once), once)
        XCTAssertFalse(once.hasSuffix(" "), once)
        XCTAssertFalse(once.isEmpty)
    }

    /// One unreadable record costs one record, not the whole list.
    ///
    /// `id` is the field that cannot be defaulted — it names the bytes on disk, and a
    /// minted one would point at another attachment's file — so a record without a
    /// usable one is not a record. Decoded whole, that single failure took every *other*
    /// attachment on the turn with it, and with them the names a later turn's history
    /// refers to: "the second one" stops meaning anything.
    func testOneUnreadableAttachmentDoesNotTakeTheOthersWithIt() throws {
        let good = UUID()
        let json = """
            {"id":"\(UUID().uuidString)","question":"Q","askedAt":"2026-01-01T00:00:00Z",
             "stage":"complete","reading":"","searches":[],"sources":[],"answer":"A",
             "findings":[],"limitations":"","followups":[],"notices":[],"model":"m",
             "attachments":[
               {"id":"not-a-uuid","name":"broken.png","kind":"image",
                "mediaType":"image/png","byteCount":1},
               {"id":"\(good.uuidString)","name":"kept.png","kind":"image",
                "mediaType":"image/png","byteCount":2}]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let turn = try decoder.decode(ResearchTurn.self, from: Data(json.utf8))

        XCTAssertEqual(turn.attachments.map(\.id), [good])
        XCTAssertEqual(turn.attachments.map(\.name), ["kept.png"])
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

    /// A profile written before the image flag existed is treated as able to see.
    ///
    /// Withholding is the failure this default exists to prevent: a user pastes a
    /// screenshot, the model is told the file could not be sent, and the only way to
    /// find out why is a per-provider switch they have never seen. Defaulting the other
    /// way round would be safe only if a provider that cannot take an image rejected it
    /// gracefully — which is what `ChatCompletionsClient` now does, by retrying without
    /// the picture rather than failing the turn.
    func testAProfileWrittenBeforeTheImageFlagIsSentImages() throws {
        let json = """
            [{"id":"\(UUID().uuidString)","name":"P","endpoint":"https://a.example/v1",
              "model":"m","keyAccount":"model-api-key"}]
            """
        let profiles = try XCTUnwrap(ProviderSettings.decodeModelProfiles(json))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(profiles[0].sendsImages)

        // An explicit no survives, and the key's spelling is pinned. The default above
        // would still pass if the flag were renamed on the way out and read back as
        // absent — and everyone who turned it off for a text-only endpoint would
        // silently start sending images it would reject.
        let optedOut = """
            [{"id":"\(UUID().uuidString)","name":"Q","endpoint":"https://b.example/v1",
              "model":"m","keyAccount":"model-api-key","sendsImages":false}]
            """
        let decoded = try XCTUnwrap(ProviderSettings.decodeModelProfiles(optedOut))
        XCTAssertFalse(try XCTUnwrap(decoded.first).sendsImages)
    }
}
