import Foundation

/// What may ride on one question, and what to say about anything that may not.
///
/// The policy half of attaching, and portable on purpose: a paste on macOS and a drop
/// on GNOME have to accept the same things and refuse them in the same words, or the
/// difference is one nobody could explain. Each front end reads its own clipboard and
/// hands the bytes here; this decides.
enum AttachmentIntake {

    /// The most attachments one question may carry.
    ///
    /// Four rather than a size budget, because the cost that matters is not bytes: each
    /// image is a separate vision payload, and a question carrying eight of them is
    /// usually a drag that went wrong rather than a question about eight pictures.
    static let maximumPerQuestion = 4

    /// The name a pasted image is given, since an image on a clipboard has none.
    ///
    /// The extension is for the reader, never for the media type: clipboard images are
    /// as often TIFF or JPEG as PNG, and `Attachment.make` reads the type off the bytes.
    /// A name has no evidence in it about what a file is, which is the whole reason
    /// sniffing exists.
    ///
    /// Unique within one paste and no further: two separate pastes of one image each
    /// both produce `pasted image.png`, which is the collision `name(forPastedImage:)`
    /// exists to prevent *inside* a gesture. Closing it means this knowing the names a
    /// question already carries rather than only how many, which is a change to what
    /// both front ends hand in.
    static let pastedImageName = "pasted image.png"

    /// The name for the `ordinal`-th image of one paste, counting from one.
    ///
    /// Here rather than in a front end, because a paste of four images is a paste of
    /// four images on both of them, and two toolkits numbering them differently is a
    /// difference nobody could explain.
    ///
    /// The first keeps `pastedImageName` unchanged: a paste of one image is the whole
    /// of what this normally does, and `pasted image 1.png` would number a series of
    /// one. Only a paste that actually carries several says which of them each is —
    /// four chips reading `pasted image.png` are four things the reader cannot pick
    /// between in order to remove one, and the model is told about four files under a
    /// single name, which invites it to treat them as one thing sent four times.
    static func name(forPastedImage ordinal: Int) -> String {
        ordinal <= 1 ? pastedImageName : "pasted image \(ordinal).png"
    }

    /// What a paste or a drop turned out to hold.
    struct Outcome: Equatable {
        var accepted: [PendingAttachment] = []
        /// Why something was left out, in words a panel can show as they are.
        var refusals: [String] = []

        /// True when the gesture held nothing this understands, which is the signal to
        /// let the toolkit paste or drop it the way it always did.
        var isEmpty: Bool { accepted.isEmpty && refusals.isEmpty }
    }

    /// Something a front end read and would like attached: bytes, and what to call them.
    struct Candidate: Equatable {
        let data: Data
        let name: String

        init(_ data: Data, name: String) {
            self.data = data
            self.name = name
        }
    }

    /// Runs each candidate past `PendingAttachment.make` — which is `Attachment.make`
    /// with its bytes kept — and the per-question limit, for a
    /// question that already carries `existing` attachments.
    static func outcome(from candidates: [Candidate], existing: Int = 0) -> Outcome {
        var outcome = Outcome()
        // Clamped: a restore may leave a composer above the cap, and two spellings of
        // one invariant is how one of them drifts.
        var room = max(0, maximumPerQuestion - existing)
        for candidate in candidates {
            guard room > 0 else {
                outcome.refusals.append(capRefusal(nothingTaken: outcome.accepted.isEmpty))
                break
            }
            switch PendingAttachment.make(from: candidate.data, name: candidate.name) {
            case .success(let pending):
                outcome.accepted.append(pending)
                room -= 1
            case .failure(let refusal):
                outcome.refusals.append(refusal.message)
            }
        }
        return outcome
    }

    /// Reads dropped or pasted files, refusing what cannot be read *before* reading it.
    ///
    /// Portable, and deliberately so: a drop on GNOME and a drop on macOS arrive as the
    /// same list of paths, and a file that one front end refused and the other loaded
    /// would be a difference with nothing behind it.
    ///
    /// The size comes from the directory entry rather than from the bytes, so a 900 MB
    /// video is refused without first being pulled into memory to find out how big it
    /// is. `attributesOfItem` rather than `URL.resourceValues`, because the resource-key
    /// API is thinner on Linux and this has to answer the same on both.
    static func read(files: [URL], existing: Int = 0,
                     fileManager: FileManager = .default) -> Outcome {
        var result = Outcome()
        var candidates: [Candidate] = []
        // Recorded here, said at the end. Which of the two cap sentences is true turns on
        // whether anything landed, and nothing here knows that yet: a candidate is a file
        // that got as far as being read, not one that will be accepted, and every one of
        // them can still be refused by `PendingAttachment.make` below. Four empty files
        // and a photograph, dropped together, spent the budget on the four, said "the
        // rest were left out" — and then refused all four, so nothing was taken and the
        // sentence presupposed something that never happened.
        var overflowed = false
        for url in files {
            // The limit before the read, not only inside `outcome`. A folder of thirty
            // photos dragged onto the composer would otherwise be thirty files pulled
            // into memory so that four could be kept — the same waste the size check
            // above exists to avoid, one level up.
            guard candidates.count + existing < maximumPerQuestion else {
                overflowed = true
                break
            }
            let name = url.lastPathComponent
            // Links followed before anything is asked about the file, because
            // `attributesOfItem` reports the *link's* attributes rather than the thing at
            // the end of it. Without this a symlink to an ordinary photo is refused as
            // "not a file" — and a GTK drop hands over the literal path, so it is the
            // platform where it happens. The displayed name stays the one that was
            // dropped: the reader named the link, not its target.
            let path = url.resolvingSymlinksInPath().path
            // Two refusals, not one. Nothing to inspect — a permissions change, a file
            // deleted between the drop and the read — is "could not be read", and it is
            // usually a perfectly ordinary file. Telling someone that the document they
            // can see in their file manager "is not a file Vervellum can attach" sends
            // them looking for the wrong problem.
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
                result.refusals.append(unreadableMessage(name))
                continue
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                // A folder, a socket, a device. Named rather than skipped in silence,
                // because a drag that appears to do nothing reads as a drop target that
                // is broken.
                result.refusals.append(notAFileMessage(name))
                continue
            }
            // Fails closed. `?? 0` passed the ceiling below and then read the whole
            // file to find out how big it was — the exact waste this branch exists to
            // avoid, on the one path where nobody would notice it.
            //
            // `int64Value` rather than `intValue`, because a file size is the one number
            // here that can exceed what a C `int` holds: `intValue` is `Int`-typed but
            // reads the value through a 32-bit conversion on Darwin, so a 4 GiB screen
            // recording arrives as a handful of bytes and walks straight past the
            // ceiling below into `contents(atPath:)`, which is the read this whole
            // branch exists to prevent. `Int(exactly:)` is what makes the 32-bit build
            // refuse rather than wrap.
            guard let size = (attributes[.size] as? NSNumber).flatMap({
                Int(exactly: $0.int64Value)
            }) else {
                result.refusals.append(unreadableMessage(name))
                continue
            }
            guard size <= Attachment.maxAttachmentBytes else {
                result.refusals.append(Attachment.Refusal
                    .tooLarge(name: Attachment.displayName(for: name), byteCount: size).message)
                continue
            }
            guard let data = fileManager.contents(atPath: path) else {
                result.refusals.append(unreadableMessage(name))
                continue
            }
            candidates.append(Candidate(data, name: name))
        }
        let decided = outcome(from: candidates, existing: existing)
        result.accepted = decided.accepted
        // Before the per-file refusals `outcome` came back with, which is where it was
        // appended when it was decided in the loop: the order the panel shows is the
        // order the sentences were written in, and this one is about the gesture rather
        // than about any one file in it.
        if overflowed {
            result.refusals.append(capRefusal(nothingTaken: decided.accepted.isEmpty))
        }
        result.refusals += decided.refusals
        return result
    }

    /// Said by a front end when a gesture brought more than the question can carry, and
    /// by a panel when questions handed back from a queue would together.
    ///
    /// Only for the case where some of them landed. This sentence presupposes that they
    /// did — and the commonest way to reach the cap is pasting into a question that is
    /// already full, where nothing landed at all and it would read as though something
    /// had. That case has its own words below.
    static var tooManyMessage: String {
        "A question can carry \(maximumPerQuestion) attachments at a time. "
            + "The rest were left out."
    }

    /// Said when the question was already full, so nothing at all could be taken.
    ///
    /// Nothing was "left out" of anything here: the files sit untouched wherever they
    /// were got from, and the only move that helps is removing one of the four already
    /// on the question. So the sentence says that instead of describing a leftover the
    /// reader would go looking for.
    /// The rule rather than a count of what is on screen: a restore is allowed to leave
    /// a composer *above* the cap — that is what `overCapMessage` is for — and a sentence
    /// saying "this question already carries four" would then be naming a number the
    /// reader can see is wrong.
    static var noRoomMessage: String {
        "A question can carry \(maximumPerQuestion) attachments at a time. "
            + "Remove one to add another."
    }

    /// Which of the two the cap owes this gesture.
    ///
    /// They are different sentences and the difference is the point: with room for some,
    /// the rest were left out; with none — most often a composer a Stop just handed
    /// several questions back to — nothing was taken at all, and "the rest" describes an
    /// event that did not occur. Chosen here rather than at each site, because the three
    /// places that ask are the candidate intake, the file intake and a panel's own check,
    /// and a wording change that reached two of them is the divergence this file exists
    /// to prevent.
    private static func capRefusal(nothingTaken: Bool) -> String {
        nothingTaken ? noRoomMessage : tooManyMessage
    }

    /// Said when a composer holds an attachment and no question.
    ///
    /// A question is still required — the planner searches the words, and an answer is
    /// written to them — so a screenshot on its own cannot be sent. That was true before
    /// either panel could attach anything and said nothing: the chip appeared, the send
    /// key did nothing, and the one thing the reader had just done was apparently what
    /// broke it. Here rather than in a panel because both of them have to say it, and a
    /// rule stated twice is a rule that will be worded twice.
    static var questionlessMessage: String {
        "Ask something to go with the attachment"
    }

    /// Said when questions handed back by a queue bring a composer past the cap.
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
    ///
    /// Here rather than in either panel because it is the rule and not the presentation.
    /// Only the macOS panel reaches the restoring branch today — the GTK composer has no
    /// queue hand-back yet — and when it grows one this is the answer it should read
    /// rather than a second version of it.
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

    /// Why a path could not be attached, in the same words on both platforms.
    static func notAFileMessage(_ name: String) -> String {
        "\(Attachment.displayName(for: name)) is not a file Vervellum can attach."
    }

    static func unreadableMessage(_ name: String) -> String {
        "\(Attachment.displayName(for: name)) could not be read."
    }
}
