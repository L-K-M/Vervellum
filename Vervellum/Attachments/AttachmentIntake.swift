import AppKit
import UniformTypeIdentifiers

/// Turns what the user pasted or dropped into attachments.
///
/// One place for both gestures, because a paste and a drag that accepted different
/// things would be a difference nobody could explain — and because the interesting
/// decisions (what wins when the clipboard holds several things, what a screenshot on
/// the clipboard actually is) are the same either way.
///
/// It reads a pasteboard and nothing else: no file is written, no state is kept. What
/// comes back is either attachments the composer can hold or sentences the panel can
/// show, and an empty outcome means "not for us" — the caller then lets AppKit paste or
/// drop the way it always did.
enum AttachmentIntake {

    /// The most attachments one question may carry.
    ///
    /// Four rather than a size budget, because the cost that matters is not bytes: each
    /// image is a separate vision payload, and a question carrying eight of them is
    /// usually a drag that went wrong rather than a question about eight pictures.
    static let maximumPerQuestion = 4

    /// What a paste or a drop turned out to hold.
    struct Outcome: Equatable {
        var accepted: [PendingAttachment] = []
        /// Why something was left out, in words the panel can show as they are.
        var refusals: [String] = []

        /// True when the pasteboard held nothing this understands, which is the signal
        /// to let AppKit handle the paste or the drop itself.
        var isEmpty: Bool { accepted.isEmpty && refusals.isEmpty }
    }

    /// The name a pasted image is given, since a clipboard image has none.
    ///
    /// Unique within one paste and no further: two separate pastes of one image each
    /// both produce `pasted image.png`, which is the collision `name(forPastedImage:)`
    /// exists to prevent *inside* a gesture. Closing it means the intake knowing the
    /// names a question already carries rather than only how many, which is a change to
    /// what both front ends hand in.
    static let pastedImageName = "pasted image.png"

    /// The name for the `ordinal`-th image of one paste, counting from one.
    ///
    /// The first keeps `pastedImageName` unchanged: a paste of one image is the whole
    /// of what this normally does, and `pasted image 1.png` would number a series of
    /// one. Only a paste that actually carries several says which of them each is.
    static func name(forPastedImage ordinal: Int) -> String {
        ordinal <= 1 ? pastedImageName : "pasted image \(ordinal).png"
    }

    // MARK: Reading a pasteboard

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
                     textWins: Bool = true) -> Outcome {
        // The declared type decides, not what `NSURL` can be talked into reading. It will
        // build a file URL out of a plain string that looks like a path, so a pasteboard
        // carrying only text would take the file branch — and pasting the words
        // "/usr/local" into a question would refuse instead of pasting them.
        if carriesFiles(pasteboard),
           let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty {
            return read(files: files, existing: existing)
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
            return Outcome()
        }
        // Every item, not only the first. `data(forType:)` asked of the *pasteboard*
        // answers from whichever item carries the type soonest, and a copy of several
        // images is one item each — four screenshots taken from Finder, a handful of
        // photos. One chip appearing where four were copied is not a refusal anyone can
        // act on; it is the gesture half working, with nothing said.
        //
        // But the cap bounds the *conversion*, not only what is kept. Every item read here
        // is a full copy of a picture and, for the TIFF a screenshot tool leaves, a
        // decode and a re-encode — tens of megabytes for one retina capture. A drag of
        // twenty photos onto a composer with room for four did all twenty before the
        // cap looked at any of them, on the main thread, mid-gesture. There is nothing
        // to learn from the twenty-first that the first four have not already answered.
        let room = max(0, maximumPerQuestion - existing)
        var candidates: [(Data, String)] = []
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
            // Numbered from the second, so the ordinary paste of one image keeps the
            // plain name. Four chips reading `pasted image.png` are four things the
            // user cannot tell apart in order to remove one of them — and the model is
            // told about four files with the same name, which invites it to treat them
            // as one thing sent four times.
            candidates.append((data, name(forPastedImage: candidates.count + 1)))
        }
        // A pasteboard that advertises a type without vending an item for it still has
        // to work — that is what a promise from a lazy provider looks like — so the
        // whole-pasteboard read stays as the fallback it always was.
        if candidates.isEmpty, room > 0, let single = imageData(on: pasteboard) {
            candidates = [(single, pastedImageName)]
        }
        guard !candidates.isEmpty else {
            // Nothing was converted, and there are two reasons for that. With no room,
            // the board's picture was never looked at — the question is full, and the
            // sentence for that says so. Otherwise the board is carrying a picture this
            // cannot read: JPEG, which no branch above takes, or a promise that resolved
            // to nothing. That one has no other flavour to fall back to — no text, no
            // file — so AppKit's own paste does nothing either, which is the dead Cmd-V
            // the paragraph at the top of this file calls the one outcome every other
            // decision here is arranged to avoid.
            guard carriesImage(pasteboard) else { return Outcome() }
            return Outcome(refusals: [room > 0 ? unreadableImageMessage : noRoomMessage])
        }
        var result = outcome(from: candidates, existing: existing)
        // Said here rather than by `outcome`, which cannot see what the loop above chose
        // not to convert. `tooManyMessage` and not the pair, because reaching this line
        // means the loop stopped on a full quota — the question had room, and what it
        // had room for is in `candidates`.
        if wereMore { result.refusals.append(tooManyMessage) }
        return result
    }

    /// Reads dropped or pasted files, refusing what cannot be read *before* reading it.
    static func read(files: [URL], existing: Int = 0) -> Outcome {
        var outcome = Outcome()
        // Clamped, as the pasteboard path clamps: a restore may leave a composer above
        // the cap, and three spellings of one invariant is how two of them drift.
        var room = max(0, maximumPerQuestion - existing)
        for url in files {
            guard room > 0 else {
                outcome.refusals.append(capRefusal(nothingTaken: outcome.accepted.isEmpty))
                break
            }
            let name = Attachment.displayName(for: url.lastPathComponent)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else {
                // A folder, a broken symlink, an app bundle. Named rather than skipped
                // in silence, because a drag that appears to do nothing reads as a drop
                // target that is broken.
                outcome.refusals.append("\(name) is not a file Vervellum can attach.")
                continue
            }
            // The size comes from the directory entry, so a 900 MB video is refused
            // without first being pulled into memory to find out how big it is.
            //
            // And fails closed. `?? 0` passed the ceiling below and then read the whole
            // file to find out how big it was — the exact waste this branch exists to
            // avoid, on the one path where nobody would notice it.
            guard let size = values?.fileSize else {
                outcome.refusals.append("\(name) could not be read.")
                continue
            }
            guard size <= Attachment.maxAttachmentBytes else {
                outcome.refusals.append(
                    Attachment.Refusal.tooLarge(name: name, byteCount: size).message)
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                outcome.refusals.append("\(name) could not be read.")
                continue
            }
            accept(PendingAttachment.make(from: data, name: url.lastPathComponent),
                   into: &outcome, room: &room)
        }
        return outcome
    }

    // MARK: Deciding

    /// Runs each candidate past `Attachment.make` and the per-question limit.
    private static func outcome(from candidates: [(Data, String)], existing: Int) -> Outcome {
        var outcome = Outcome()
        var room = max(0, maximumPerQuestion - existing)
        for (data, name) in candidates {
            guard room > 0 else {
                outcome.refusals.append(capRefusal(nothingTaken: outcome.accepted.isEmpty))
                break
            }
            accept(PendingAttachment.make(from: data, name: name),
                   into: &outcome, room: &room)
        }
        return outcome
    }

    /// Records a made attachment, or why it was refused, and spends the room it took.
    ///
    /// One function because the two intakes differ in everything *before* this — a file
    /// is refused by its directory entry before it is read, a pasted image has no entry
    /// to refuse it by — and in nothing after. Spelled twice, the per-question cap and
    /// the words it is refused in lived in two places, and a change to either that
    /// reached one path made a paste and a drop behave differently. That divergence is
    /// what this file's opening paragraph says it exists to prevent.
    private static func accept(_ made: Result<PendingAttachment, Attachment.Refusal>,
                               into outcome: inout Outcome, room: inout Int) {
        switch made {
        case .success(let pending):
            outcome.accepted.append(pending)
            room -= 1
        case .failure(let refusal):
            outcome.refusals.append(refusal.message)
        }
    }

    /// Said by the intake when a paste brings more than the question can carry.
    static var tooManyMessage: String {
        "A question can carry \(maximumPerQuestion) attachments at a time. "
            + "The rest were left out."
    }

    /// Said when the clipboard's picture is in a form this cannot read.
    ///
    /// Names the way out rather than only the problem: saving the picture to a file and
    /// dropping *that* in works, because a file is sniffed by its bytes and `Attachment`
    /// does recognise JPEG. It is only the clipboard that this reads narrowly.
    static var unreadableImageMessage: String {
        "That picture is in a form Vervellum cannot take from a clipboard, which reads "
            + "PNG and TIFF. Saving it to a file and dropping the file in will attach it."
    }

    /// Whether the pasteboard is carrying an image of *some* kind, readable or not.
    ///
    /// Conformance rather than the exact types, which is the whole point: the question
    /// is what was on the board that this could not take, and it is asked only once
    /// every branch that could have taken something has declined.
    private static func carriesImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    /// Which of the two the cap owes this gesture.
    ///
    /// They are different sentences and the difference is the point: with room for some,
    /// the rest were left out; with none — most often a composer a Stop just handed
    /// several questions back to — nothing was taken at all, and "the rest" describes an
    /// event that did not occur. Chosen here rather than at each site, because the three
    /// places that ask are the paste, the drop and the panel's own check, and a wording
    /// change that reached two of them is precisely the divergence `accept` was pulled
    /// out to prevent.
    private static func capRefusal(nothingTaken: Bool) -> String {
        nothingTaken ? noRoomMessage : tooManyMessage
    }

    /// Said when the composer had no room, so nothing at all could be taken.
    /// The rule rather than a count of what is on screen: a restore is allowed to leave
    /// the composer *above* the cap — that is what `overCapMessage` is for — and a
    /// sentence saying "this question already carries four" would then be naming a
    /// number the reader can see is wrong.
    static var noRoomMessage: String {
        "A question can carry \(maximumPerQuestion) attachments at a time. "
            + "Remove one to add another."
    }

    /// Said when questions handed back by the queue bring the composer past the cap.
    ///
    /// Not a refusal, and worded so it cannot be read as one: nothing was left out, and
    /// that is the point. It is the only warning that what is on screen is more than one
    /// question may carry, given while every file is still there to be removed.
    static var overCapMessage: String {
        "These came back from questions that were still waiting. A question can carry "
            + "\(maximumPerQuestion) at a time — remove what this one does not need."
    }

    /// How many of `incoming` a composer already holding `existing` should take, and
    /// what to tell the user about the rest.
    ///
    /// Two callers with opposite needs, which is the whole reason this is a function and
    /// not a `prefix`. A paste or a drop is an *intake*: the cap is the answer, and what
    /// is past it is declined while the file sits untouched on the user's disk, exactly
    /// where they got it. A question handed back by the queue is an *undo*: the bytes of
    /// a pasted screenshot are on no disk anywhere — that is the whole reason the queue
    /// hands them back at all — so declining one there does not decline it, it destroys
    /// it, and the notice explaining that a file was left out is addressed to someone
    /// who no longer has the file. Three waiting questions can between them carry more
    /// than one question may; the answer to that is a composer holding more than four
    /// for as long as it takes to remove one, not a Stop that eats a picture.
    static func admitted(existing: Int, incoming: Int,
                         restoring: Bool) -> (taken: Int, note: String?) {
        guard !restoring else {
            // `incoming > 0`, because the sentence opens "These came back from questions
            // that were still waiting" — and a hand-back of nothing has nothing to say
            // that about. The same rule `capRefusal` exists for, on the other branch.
            let over = incoming > 0 && existing + incoming > maximumPerQuestion
            return (incoming, over ? overCapMessage : nil)
        }
        let room = max(0, maximumPerQuestion - existing)
        let taken = min(incoming, room)
        guard incoming > room else { return (taken, nil) }
        // Reachable only from a caller that did not cap first — which is exactly what
        // this function is for, so it answers rather than leaving the case to the one
        // caller that happens not to reach it today.
        return (taken, capRefusal(nothingTaken: taken == 0))
    }

    /// PNG bytes for an image sitting on the pasteboard, in either form it arrives in.
    ///
    /// A macOS screenshot taken to the clipboard is TIFF, and TIFF is not something a
    /// provider will look at — so it is re-encoded here, in the front end, where an
    /// imaging framework is allowed. `Core` cannot do this, which is why it refuses an
    /// image it does not recognise rather than converting one.
    ///
    /// PNG and TIFF only, deliberately for now. `Attachment` does recognise JPEG, so a
    /// pasteboard carrying `public.jpeg` and nothing else — some apps offer only that —
    /// comes back empty and pastes as whatever else was on it. Adding the type is not
    /// the whole change: `pastedImageName` says `.png`, and re-encoding a photograph to
    /// PNG to keep that true can multiply its size and get it refused by a cap it was
    /// under. It wants a name that follows the bytes, on both front ends, which is more
    /// than this belongs to.
    static func imageData(on pasteboard: NSPasteboard) -> Data? {
        pngEncoded(png: pasteboard.data(forType: .png), tiff: pasteboard.data(forType: .tiff))
    }

    /// The same, for one item of a pasteboard carrying several.
    static func imageData(on item: NSPasteboardItem) -> Data? {
        pngEncoded(png: item.data(forType: .png), tiff: item.data(forType: .tiff))
    }

    /// The flavours the two above look at, for a caller that needs to know whether an
    /// item is worth counting before it is worth reading.
    ///
    /// Beside them deliberately. The type matrix is the delicate part of this file and a
    /// second copy of it is a second place to forget to change; this is that second copy,
    /// kept where anyone changing the first will see it.
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

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
    private static func pngEncoded(png: @autoclosure () -> Data?,
                                   tiff: @autoclosure () -> Data?) -> Data? {
        // Non-empty, not merely non-nil. A pasteboard read can answer with zero bytes —
        // a promise resolved after the board changed, a race as a drag lands — and
        // returning those would attach nothing under a name, refused downstream as
        // "unsupported" in words that describe the wrong problem. Worse, it would skip
        // the TIFF beside it, which is the flavour that would have worked.
        if let png = png(), !png.isEmpty { return png }
        guard let tiff = tiff(), let representation = NSBitmapImageRep(data: tiff)
        else { return nil }
        return representation.representation(using: .png, properties: [:])
    }

    /// The pasteboard types the composer accepts in a drag.
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

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
