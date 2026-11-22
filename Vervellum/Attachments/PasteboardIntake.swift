import AppKit
import UniformTypeIdentifiers

/// Reads a pasteboard for the composer: the AppKit half of attaching.
///
/// One place for both gestures, because a paste and a drag that accepted different
/// things would be a difference nobody could explain. What is decided *here* is what
/// AppKit alone can answer — which of several things on a pasteboard the user meant,
/// and what a clipboard screenshot actually is. What may be attached at all, and in
/// what words it is refused, is `AttachmentIntake` in Core, so the GTK front end
/// answers the same way.
///
/// Nothing is written and no state is kept. An empty outcome means "not for us", and
/// the caller then lets AppKit paste or drop the way it always did.
enum PasteboardIntake {

    /// Reads `pasteboard` for a question that already carries `existing` attachments.
    ///
    /// Files win over text. Dropping a file on the composer, or copying one in Finder
    /// and pasting, means the file — pasting its path instead would be a surprise, and
    /// the path is not what the model can read.
    ///
    /// Otherwise image data is taken only when there is no text on the pasteboard.
    /// Copying from a web page puts *both* on it, and a paste that swallowed the words
    /// in favour of a stray favicon would be the worse guess by far.
    static func read(_ pasteboard: NSPasteboard, existing: Int = 0,
                     textWins: Bool = true) -> AttachmentIntake.Outcome {
        // The declared type decides, not what `NSURL` can be talked into reading. It will
        // build a file URL out of a plain string that looks like a path, so a pasteboard
        // carrying only text would take the file branch — and pasting the words
        // "/usr/local" into a question would refuse instead of pasting them.
        if carriesFiles(pasteboard),
           let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty {
            // Straight to Core: reading a path is the same job on both platforms, and a
            // forwarder here would only be a second place for the two to drift apart.
            return AttachmentIntake.read(files: files, existing: existing)
        }
        // Text wins, but only text that is *there*. `string(forType:)` answers a
        // zero-length or whitespace-only flavour with a non-nil string, and image
        // sources put one on the board often enough — some editors and capture tools do
        // — that reading presence as content turned Cmd-V into a gesture that did
        // nothing at all: no chip, no refusal, no paste. A dead paste is the one outcome
        // this file's every other decision is arranged to avoid.
        //
        // Only on a paste. A drag that reaches this at all is a drag of a picture or a
        // file — a text-only one never arrives, because the composer registers for
        // neither — and a browser hands over the image *and* its address as text on the
        // same board. Under this rule that drop pasted a URL into the question, after
        // the cursor had promised a copy, which is the drag half of the dead paste
        // above. The GTK drop has never had the rule: a texture arrives and is taken.
        if textWins, let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AttachmentIntake.Outcome()
        }
        // Every item, not only the first. `data(forType:)` asked of the *pasteboard*
        // answers from whichever item carries the type soonest, and a copy of several
        // images is one item each — four screenshots from Finder, a handful of photos.
        // One chip appearing where four were copied is not a refusal anyone can act on;
        // it is the gesture half working, with nothing said.
        //
        // But the cap bounds the *conversion*, not only what is kept. Every item read
        // here is a full copy of a picture and, for the TIFF a screenshot tool leaves, a
        // decode and a re-encode — tens of megabytes for one retina capture. A drag of
        // twenty photos onto a composer with room for four did all twenty before the cap
        // looked at any of them, on the main thread, mid-gesture. There is nothing to
        // learn from the twenty-first that the first four have not already answered.
        let room = max(0, AttachmentIntake.maximumPerQuestion - existing)
        var candidates: [AttachmentIntake.Candidate] = []
        var wereMore = false
        for item in pasteboard.pasteboardItems ?? [] {
            // Only an item carrying a flavour this reads can be left out, so only those
            // count against the cap. Asked of `types` rather than by reading: an item
            // answers `data(forType:)` for what it declares and nothing else, so this is
            // the same question one step earlier and without the copy — the conversion
            // stays bounded by `room`, which is the whole point of the guard below.
            //
            // Without it a board's own stray flavours trip the cap. A drag carries the
            // picture and the page's address, an image source appends an empty string
            // beside the bytes; four images and one of those, with room for four, took
            // every image and then told the reader the rest were left out. A sentence
            // about what was dropped is the one thing here that must not be invented.
            guard item.types.contains(where: { Self.imageTypes.contains($0) }) else {
                continue
            }
            guard candidates.count < room else {
                wereMore = true
                break
            }
            guard let data = imageData(on: item) else { continue }
            // Numbered from the second, and named off the bytes —
            // `AttachmentIntake.name(forPastedImage:sniffing:)` is where that rule and
            // its reasons live, in Core, so a GTK paste of four images names them the
            // same way. A JPEG taken as-is is a `.jpg`, not a `.png` claim.
            candidates.append(AttachmentIntake.Candidate(
                data, name: AttachmentIntake.name(forPastedImage: candidates.count + 1,
                                                  sniffing: data)))
        }
        // A pasteboard that advertises a type without vending an item for it still has
        // to work — that is what a promise from a lazy provider looks like — so the
        // whole-pasteboard read stays as the fallback it always was.
        if candidates.isEmpty, room > 0, let single = imageData(on: pasteboard) {
            candidates = [AttachmentIntake.Candidate(
                single, name: AttachmentIntake.name(forPastedImage: 1, sniffing: single))]
        }
        guard !candidates.isEmpty else {
            // Nothing was converted, and there are two reasons for that. With no room,
            // the board's picture was never looked at — the question is full, and the
            // sentence for that says so. Otherwise the board is carrying a picture this
            // cannot read: GIF or WebP, which no branch above takes, or a promise that
            // resolved to nothing. That one has no other flavour to fall back to — no text, no
            // file — so AppKit's own paste does nothing either, which is the dead Cmd-V
            // every other decision in this file is arranged to avoid.
            guard carriesImage(pasteboard) else { return AttachmentIntake.Outcome() }
            return AttachmentIntake.Outcome(
                refusals: [room > 0 ? unreadableImageMessage : AttachmentIntake.noRoomMessage])
        }
        var result = AttachmentIntake.outcome(from: candidates, existing: existing)
        // Said here rather than by `outcome`, which cannot see what the loop above chose
        // not to convert. `tooManyMessage` and not the pair, because reaching this line
        // means the loop stopped on a full quota — the question had room, and what it had
        // room for is in `candidates`.
        if wereMore { result.refusals.append(AttachmentIntake.tooManyMessage) }
        return result
    }

    /// Said when the clipboard's picture is in a form this cannot read.
    ///
    /// Here rather than in Core with the other refusals, which is where the words a
    /// gesture is refused in belong. This sentence is not about what may be attached —
    /// a JPEG *file* is attached happily, on both platforms, because a file is sniffed
    /// by its bytes. It is about what this pasteboard was asked for, which is a fact
    /// about AppKit; GTK hands over a decoded texture and never reaches it.
    static var unreadableImageMessage: String {
        "That picture is in a form Vervellum cannot take from a clipboard, which reads "
            + "PNG, JPEG and TIFF. Saving it to a file and dropping the file in will attach it."
    }

    /// Whether the pasteboard is carrying an image of *some* kind, readable or not.
    ///
    /// Conformance rather than the exact types, which is the whole point: the question
    /// is what was on the board that this could not take, and it is asked only once
    /// every branch that could have taken something has declined.
    private static func carriesImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    /// The bytes for an image sitting on the pasteboard, in any form it arrives in.
    ///
    /// A macOS screenshot taken to the clipboard is TIFF, and TIFF is not something a
    /// provider will look at — so it is re-encoded to PNG here, in the front end, where
    /// an imaging framework is allowed. `Core` cannot do this, which is why it refuses
    /// an image it does not recognise rather than converting one. JPEG is taken as the
    /// bytes it is: `Attachment` sniffs it and sends it as image/jpeg, and re-encoding a
    /// photograph to PNG just to keep a `.png` name could multiply its size past the
    /// attachment cap. PNG and JPEG only need no conversion at all.
    static func imageData(on item: NSPasteboardItem) -> Data? {
        pastedImage(png: item.data(forType: .png),
                    jpeg: item.data(forType: jpegType),
                    tiff: item.data(forType: .tiff))
    }

    /// The flavours the two `imageData` overloads look at, for a caller that needs to
    /// know whether an item is worth counting before it is worth reading.
    ///
    /// Beside them deliberately. The type matrix is the delicate part of this file and a
    /// second copy of it is a second place to forget to change; this is that second copy,
    /// kept where anyone changing the first will see it.
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, jpegType]

    /// The same, asked of the whole pasteboard.
    static func imageData(on pasteboard: NSPasteboard) -> Data? {
        pastedImage(png: pasteboard.data(forType: .png),
                    jpeg: pasteboard.data(forType: jpegType),
                    tiff: pasteboard.data(forType: .tiff))
    }

    /// Which of the two forms won, given whatever each was asked for.
    ///
    /// Takes the bytes rather than the receiver, so the pasteboard and one of its items
    /// share this instead of spelling it twice. The type matrix above is the delicate
    /// part of this file — what is accepted, what is converted, what a name may claim —
    /// and a second copy of it is a second place to forget to change.
    ///
    /// `@autoclosure` on both, so sharing the matrix does not cost a read. A screenshot
    /// tool puts *both* flavours on the board and the TIFF is the larger one — tens of
    /// megabytes for a retina capture — so evaluating the arguments eagerly pulled it
    /// across for every paste that a PNG already answered, once per item in a four-image
    /// copy. Deferred, the TIFF is fetched only on the branch that needs it.
    ///
    /// `NSBitmapImageRep(data:)` reads the *first* image in the data, so a multi-page
    /// TIFF — a scanner's output, some annotation tools — attaches as its first page and
    /// nothing says the others were there. Accepted rather than closed: reading the rest
    /// means one attachment per page against a cap of four, which is a decision about
    /// what a paste means rather than a fix.
    private static func pastedImage(png: @autoclosure () -> Data?,
                                    jpeg: @autoclosure () -> Data?,
                                    tiff: @autoclosure () -> Data?) -> Data? {
        // Non-empty, not merely non-nil. A pasteboard read can answer with zero bytes —
        // a promise resolved after the board changed, a race as a drag lands — and
        // returning those would attach nothing under a name, refused downstream as
        // "unsupported" in words that describe the wrong problem. Worse, it would skip
        // the flavour beside it, which is the one that would have worked.
        if let png = png(), !png.isEmpty { return png }
        // JPEG before TIFF: the bytes are already what Core will send, and a re-encode
        // is the one flavour here that can change the size enough to matter.
        if let jpeg = jpeg(), !jpeg.isEmpty { return jpeg }
        guard let tiff = tiff(), let representation = NSBitmapImageRep(data: tiff)
        else { return nil }
        return representation.representation(using: .png, properties: [:])
    }

    /// The pasteboard types the composer accepts in a drag.
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, jpegType]

    /// `public.jpeg`, spelled through `UTType` because `PasteboardType` has no `.jpeg`
    /// member on this SDK.
    private static let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    /// Whether `pasteboard` is actually carrying a file.
    ///
    /// Asked of every item rather than of `types`, which answers for the first one only:
    /// a copy that puts a path string on item 0 and the file on item 1 is a copy of a
    /// file, and the first item alone would say otherwise.
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes:
            [NSPasteboard.PasteboardType.fileURL.rawValue])
    }

    /// Whether `pasteboard` is carrying anything the composer would attach — the
    /// question a drag has to answer before it lands, so the cursor can promise a copy.
    static func carriesAttachment(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: draggedTypes.map(\.rawValue))
    }
}
