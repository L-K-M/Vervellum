import Foundation

/// A file or image the user attached to a question.
///
/// This is the *record* of an attachment, not its bytes. The bytes live in
/// `AttachmentStore`, beside the thread file rather than inside it, and the reason is
/// not tidiness: a thread's history is what gets re-sent to the model on every later
/// turn in that thread. A 2 MB screenshot carried in `ResearchTurn` would be re-encoded
/// into `threads.json` on every save *and* re-billed as vision tokens on every follow-up
/// question — so the turn keeps a name, a type and a size, and the picture keeps its
/// place on disk where reopening a thread can still show it.
///
/// What follows from that split is a rule worth stating plainly: **an attachment is sent
/// on the turn it was attached to, and on no other.** A follow-up that needs the image
/// again is a follow-up the user attaches it to again. Anything else spends the user's
/// money on their behalf without asking.
struct Attachment: Codable, Equatable, Identifiable {

    /// What kind of thing was attached, which decides how it reaches the model: an image
    /// becomes an `image_url` part on the user message, text is inlined into the question
    /// payload where any model can read it.
    ///
    /// Lenient on the way in, for the reason `TurnNotice` is and `ResearchStage` is not:
    /// a kind added by a later build must decode *here* as something this build can
    /// ignore, rather than making the whole thread unreadable. `ResearchModels` explains
    /// what that costs when it is forgotten.
    enum Kind: Codable, Equatable {
        case image
        case text
        /// A kind this build does not know, carrying the string that named it.
        ///
        /// `make` never produces one. It carries the raw string rather than being a bare
        /// case because the record surviving an older build's save is only half of
        /// forward compatibility — the *kind* has to survive it too. Flattened to
        /// `"other"` on the way out, a newer build's `"audio"` would come back from this
        /// build's save permanently downgraded, and the newer build would then be the one
        /// that could not read its own attachment.
        case other(raw: String)

        init(from decoder: Decoder) throws {
            // `try?`, so the leniency covers the *shape* and not only the spelling. A
            // string this build has never seen is answered with `.other` carrying it; a
            // value that is not a string at all — corruption, or a later build changing
            // how it writes this — threw, and the throw climbed the ladder this whole
            // decoder was hand-written to stop: attachment, turn, library.
            let raw = try? decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "image": self = .image
            case "text": self = .text
            // `"other"` for a value that was not a string at all: there is no name to
            // keep, and the field still has to round-trip as something.
            default: self = .other(raw: raw ?? "other")
            }
        }

        /// Hand-written for the same reason the decoder is: the synthesized one would
        /// write the case, and the case is not what was read.
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .image: try container.encode("image")
            case .text: try container.encode("text")
            case .other(let raw): try container.encode(raw)
            }
        }
    }

    var id: UUID
    var kind: Kind
    /// What the panel shows and what the model is told the file was called. Sanitised on
    /// the way in — see `displayName(for:)`.
    var name: String
    /// The type the *bytes* turned out to be, never the one the file extension claimed.
    var mediaType: String
    /// The size of the stored bytes, so the panel can say "1.4 MB" without reading them.
    var byteCount: Int

    init(id: UUID = UUID(), kind: Kind, name: String, mediaType: String, byteCount: Int) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mediaType = mediaType
        self.byteCount = byteCount
    }

    // MARK: Codable

    /// Hand-written for the reason `ResearchTurn`'s is, and it is worth saying twice
    /// because the consequence here is one step worse. Swift's synthesized decoder
    /// requires every key, so the first field ever added to this type would make every
    /// document containing an attachment unreadable — and this type is decoded *inside*
    /// a `ResearchTurn`, so the failure would not stop at one attachment. It would take
    /// the turn, then the library, and an older build would start from an empty one and
    /// overwrite the newer file. That is the exact sequence `TurnNotice.unknown` exists
    /// to prevent, arriving one level down.
    ///
    /// `try?` on every field but `id`, so the leniency covers the *shape* and not only
    /// the presence — for the reason `Kind`'s own decoder gives. `decodeIfPresent` answers
    /// a missing key with nil and a present-but-wrong-typed one by **throwing**, so a
    /// `"byteCount": "1.4 MB"` in a hand-edited document would take the attachment, then
    /// the turn, then the library, and an older build would start from an empty one and
    /// overwrite the newer file. That is the same ladder, climbed by a corrupted scalar
    /// rather than by a field this build has never seen.
    ///
    /// `id` is the exception and stays required: it is the name of the bytes on disk, and
    /// an attachment with a minted one would point at a file that is not its own. A
    /// record without it is not a record of anything.
    ///
    /// `encode(to:)` stays synthesized, and `CodingKeys` covers every stored property, so
    /// the round-trip test catches a field that goes missing from it.
    enum CodingKeys: String, CodingKey {
        case id, kind, name, mediaType, byteCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .other(raw: "other")
        // Through `displayName` like every other way a name arrives. The property says
        // it is sanitised on the way in, and this was a way in that was not: a document
        // hand-edited, restored from a backup, or written by anything but this code
        // could put a newline, a bidi override or a path separator straight into the
        // panel and the request payload. Idempotent, so a name this build wrote is
        // unchanged — and it is also what bounds the length, which is the other promise
        // the property makes.
        let storedName = try? container.decodeIfPresent(String.self, forKey: .name)
        name = Attachment.displayName(for: storedName ?? "attachment")
        mediaType = (try? container.decodeIfPresent(String.self, forKey: .mediaType))
            ?? "application/octet-stream"
        byteCount = (try? container.decodeIfPresent(Int.self, forKey: .byteCount)) ?? 0
    }

    // MARK: Limits

    /// The largest attachment of any kind, before base64.
    ///
    /// Of any kind, and named that way: this is the ceiling `make` applies before it has
    /// looked at the bytes, so it is what refuses an oversized log exactly as it refuses
    /// an oversized screenshot — and it is what the front ends check a dropped file
    /// against before reading it. The number was chosen against the image case, but a
    /// screenshot and a pasted log go down the same pipe into the same context window,
    /// and one ceiling is the honest way to say so. A name that said `image` would have
    /// to be disbelieved at every one of those call sites.
    ///
    /// Chosen against what happens next rather than against what a disk can hold: the
    /// bytes are base64-encoded into a JSON request body, which costs a third again, and
    /// most providers refuse a request much past a handful of megabytes. Four megabytes
    /// is a generous screenshot and a small photograph. Refusing above it, rather than
    /// scaling the image down, is deliberate — scaling needs an imaging framework, and
    /// nothing under `Core/` may import one.
    static let maxAttachmentBytes = 4 * 1024 * 1024

    /// The most text an attached file contributes to the question payload.
    ///
    /// Small on purpose. This text is inlined into the same payload as the question and
    /// the evidence, and `ResearchContext` has a fixed budget for the whole thing: a file
    /// large enough to be interesting is also large enough to push the turn's actual
    /// evidence out of context. Beyond this the text is truncated with a visible marker,
    /// the way a read page is, so nobody is told the model saw more than it did.
    static let maxTextCharacters = 24_000

    /// The image types worth accepting, keyed by the bytes that identify them.
    ///
    /// Sniffed rather than taken from the file name, because the name is the one part of
    /// a dropped file that carries no evidence about what it is. A `.png` that is really
    /// something else would otherwise be announced to the provider as an image and
    /// base64'd into a request on that claim.
    static let imageSignatures: [(bytes: [UInt8], mediaType: String)] = [
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "image/png"),
        ([0xFF, 0xD8, 0xFF], "image/jpeg"),
        // The full six bytes, not the four of "GIF8". The other two signatures contain
        // bytes that cannot appear in valid UTF-8, so they can never collide with a text
        // file — this one is pure ASCII, and a note beginning "GIF8" is ordinary enough
        // that four bytes was not a signature at all. Six narrows it to a file that opens
        // with the literal "GIF87a" or "GIF89a" and is not one: that collision is still
        // there, and is accepted rather than closed. Closing it would mean preferring a
        // successful text decode over the magic bytes, which trades a note nobody writes
        // for a real GIF read as text — the same failure pointing the other way.
        ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], "image/gif"),
        ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], "image/gif"),
    ]

    /// The image type these bytes actually are, or nil if they are not an image this
    /// build offers to send.
    ///
    /// WebP is checked separately because its signature is split: `RIFF`, four bytes of
    /// length, then `WEBP`.
    static func imageMediaType(sniffing data: Data) -> String? {
        for signature in imageSignatures where data.starts(with: signature.bytes) {
            return signature.mediaType
        }
        let riff: [UInt8] = [0x52, 0x49, 0x46, 0x46]   // "RIFF"
        let webp: [UInt8] = [0x57, 0x45, 0x42, 0x50]   // "WEBP"
        // `prefix`/`suffix` rather than `data[8..<12]`: a `Data` handed over as a slice
        // of a bigger buffer keeps the parent's indices, so the absolute range would
        // read the wrong four bytes — or trap. `starts(with:)` was already index-safe.
        if data.count >= 12, data.starts(with: riff),
           Array(data.prefix(12).suffix(4)) == webp {
            return "image/webp"
        }
        return nil
    }

    /// Whether these bytes read as text a model can be shown.
    ///
    /// UTF-8 that decodes and contains no NUL. The NUL check is what separates a source
    /// file from a binary that happens to be valid UTF-8 for its first few bytes, and it
    /// is cheaper and more honest than guessing from an extension.
    static func text(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            return nil
        }
        return text
    }

    /// `text` cut to `maxTextCharacters`, with the same visible marker a truncated page
    /// carries, so the model is never handed a fragment presented as a whole file.
    static func truncated(_ text: String) -> String {
        guard text.count > maxTextCharacters else { return text }
        return String(text.prefix(maxTextCharacters)) + "\n[…]"
    }

    /// A file name fit to show and to put in a JSON payload.
    ///
    /// Control characters out — a name carrying a newline would break the panel's layout
    /// and could forge a line in the payload the model reads. That set is Unicode
    /// categories **Cc and Cf**, not Cc alone, so the bidi overrides and the zero-width
    /// marks — the characters that make one name render as another — go with them.
    /// `AttachmentTests` pins that, because it is a property of Foundation this relies
    /// on rather than one this code states.
    ///
    /// The line and paragraph separators are added by hand: U+2028 and U+2029 are
    /// categories Zl and Zp, so neither set above catches them, and both break a layout
    /// exactly the way a newline would. This app has met U+2028 before — `ComposerView`
    /// documents `insertLineBreak:` inserting one where a newline was meant.
    ///
    /// Path separators out too: nothing here uses the name as a path, because the store
    /// keys by `id`, and keeping it that way is easier than remembering why it is safe.
    static func displayName(for raw: String, fallback: String = "attachment") -> String {
        let invisible = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "\u{2028}\u{2029}"))
        let cleaned = raw
            .components(separatedBy: invisible).joined()
            .components(separatedBy: CharacterSet(charactersIn: "/\\")).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return fallback }
        return String(cleaned.prefix(120))
    }

    // MARK: Building one

    /// The attachment these bytes are, or nil for anything this build will not send.
    ///
    /// One function so both front ends agree about what may be attached: a drag and a
    /// paste that accept different things would be a difference nobody could explain.
    /// The size check comes before the text decode because a 40 MB file is refused
    /// without first being turned into a 40 MB `String`.
    static func make(from data: Data, name: String) -> Result<(Attachment, Data), Refusal> {
        let display = displayName(for: name)
        // Size first, so both kinds are refused for the same reason in the same words: a
        // 6 MB log told it is "not something Vervellum can attach" would send its owner
        // looking for a format problem that is not there.
        guard data.count <= maxAttachmentBytes else {
            return .failure(.tooLarge(name: display, byteCount: data.count))
        }
        // Sniffed before decoded, which costs one thing worth naming: the GIF signatures
        // are ASCII, so a text file whose first bytes really are `GIF89a` is classified
        // as an image and base64'd into the request on that claim. Deciding by text
        // first would close that — and it is *nearly* free, because PNG (`0x89`) and
        // JPEG (`0xFF`) open with bytes that cannot begin valid UTF-8, so neither could
        // ever be read as text. Nearly, not entirely: `text(from:)` refuses only on
        // invalid UTF-8 or a NUL, and a small GIF need not contain either in its header.
        // Both risks are about equally unreachable, so this stays as it is — the bytes
        // decide, and the one that identifies itself first wins.
        if let mediaType = imageMediaType(sniffing: data) {
            return .success((Attachment(kind: .image, name: display, mediaType: mediaType,
                                        byteCount: data.count), data))
        }
        // An empty file is refused rather than attached. It would be stored, listed in
        // the panel, and its name carried into every later turn's history — telling the
        // model about a file whose contents are nothing, which is an invitation to
        // explain the emptiness rather than answer the question.
        guard let text = text(from: data),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.unsupported(name: display))
        }
        let kept = truncated(text)
        let bytes = Data(kept.utf8)
        return .success((Attachment(kind: .text, name: display, mediaType: "text/plain",
                                    byteCount: bytes.count), bytes))
    }

    /// Why an attachment was refused, in words a person can act on.
    enum Refusal: Error, Equatable {
        /// Past the cap. One case for both kinds, because "too big" is the same fact
        /// about a screenshot and a log file, and a text file refused as *unsupported*
        /// would be told the wrong thing: it is exactly the sort of thing that can be
        /// attached, just not at that size.
        case tooLarge(name: String, byteCount: Int)
        case unsupported(name: String)

        var message: String {
            switch self {
            case .tooLarge(let name, let byteCount):
                let megabytes = Double(byteCount) / (1024 * 1024)
                return String(format: "%@ is %.1f MB. An attachment can be at most "
                              + "%ld MB — scale it down, or attach a shorter file.",
                              name, megabytes, Attachment.maxAttachmentBytes / (1024 * 1024))
            case .unsupported(let name):
                // "UTF-8", because that is what `text(from:)` accepts. A Latin-1 file
                // refused as simply "not something Vervellum can attach" sends its owner
                // looking for the wrong problem — and the encoding is the thing they can
                // actually change.
                return "\(name) is not something Vervellum can attach. Images (PNG, JPEG, "
                    + "GIF, WebP) and UTF-8 text files are."
            }
        }
    }
}
