import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Vervellum

/// What a paste or a drop on the composer turns out to be.
final class AttachmentIntakeTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private var directory: URL!

    override func setUpWithError() throws {
        pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vervellum-intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The PNG magic number and nothing behind it — enough for the byte sniffing that
    /// classifies an attachment, not a decodable image. Every test that only needs "this
    /// is an image" uses it; one that ever needs a real picture has to draw one.
    private func png(_ payload: Int = 16) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: payload)
    }

    @discardableResult
    private func write(_ data: Data, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: What wins

    /// An ordinary text paste must reach the text view untouched, which is what an empty
    /// outcome means: nothing here claimed it.
    func testPlainTextIsNotAnAttachment() {
        XCTAssertTrue(pasteboard.setString("just words", forType: .string))
        XCTAssertTrue(AttachmentIntake.read(pasteboard).isEmpty)
    }

    /// Copying from a web page puts the words *and* a picture on the pasteboard. Taking
    /// the picture there would swallow the paste the user actually asked for.
    func testTextBesideAnImageStillPastesAsText() {
        // One item carrying both flavours, which is the shape such a copy arrives in —
        // and the shape that keeps the setup honest. The pasteboard's own setters answer
        // for one declared type at a time, so a second flavour set that way can quietly
        // not be there, leaving a test that passes because there was no image to take.
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("a heading and its body", forType: .string))
        XCTAssertTrue(item.setData(png(), forType: .png))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertTrue(AttachmentIntake.read(pasteboard).isEmpty)
    }

    /// But a *drop* of that same board takes the picture. A browser hands over the image
    /// and the page's address as text together, and the address is not something anybody
    /// dragged — while a drag carrying only text never reaches the composer at all, so
    /// there is no paste to protect here. The cursor has already promised a copy by the
    /// time this is asked.
    func testADroppedImageBesideItsAddressIsStillAttached() {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("https://example.com/cat", forType: .string))
        XCTAssertTrue(item.setData(png(), forType: .png))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let dropped = AttachmentIntake.read(pasteboard, textWins: false)
        XCTAssertEqual(dropped.accepted.count, 1, "\(dropped.refusals)")
        XCTAssertEqual(dropped.accepted.first?.attachment.kind, .image)
        // And the paste of the same board is unchanged: there the words are the point.
        XCTAssertTrue(AttachmentIntake.read(pasteboard).isEmpty)
    }

    /// A file wins over the path-shaped string that comes with it. Pasting a file into a
    /// question means the file; the text of its path is not what a model can read.
    func testAFileWinsOverTheStringBesideIt() throws {
        let url = try write(png(), named: "shot.png")
        // The path on one item and the file on another, which is what a copy in Finder
        // leaves behind — and the case `carriesFiles` documents itself by: the first
        // item alone would say this pasteboard carries no file at all.
        let path = NSPasteboardItem()
        XCTAssertTrue(path.setString(url.path, forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([path, url as NSURL]))

        let outcome = AttachmentIntake.read(pasteboard)
        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.accepted.first?.attachment.name, "shot.png")
        XCTAssertEqual(outcome.accepted.first?.attachment.kind, .image)
    }

    /// A screenshot taken to the clipboard is TIFF, which no provider will look at. It is
    /// re-encoded here, in the one layer allowed an imaging framework.
    func testAPastedTIFFScreenshotBecomesAPNG() throws {
        // The handler form rather than lockFocus/unlockFocus: that pair draws into
        // whatever focus context happens to be current, which is a thing a headless test
        // runner is not obliged to have. This one brings its own.
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.drawSwatch(in: rect)
            return true
        }
        XCTAssertTrue(pasteboard.setData(try XCTUnwrap(image.tiffRepresentation),
                                         forType: .tiff))

        let outcome = AttachmentIntake.read(pasteboard)
        let attached = try XCTUnwrap(outcome.accepted.first)
        XCTAssertEqual(attached.attachment.mediaType, "image/png")
        XCTAssertEqual(attached.attachment.name, AttachmentIntake.pastedImageName)
        XCTAssertEqual(Attachment.imageMediaType(sniffing: attached.data), "image/png")
    }

    /// Several images copied at once are several items on the pasteboard, and asking
    /// the pasteboard itself for the data answers from whichever carries it first. The
    /// gesture is meant to take all of them.
    func testEveryImageOnAMultiItemPasteboardIsAttached() {
        let first = NSPasteboardItem()
        XCTAssertTrue(first.setData(png(), forType: .png))
        let second = NSPasteboardItem()
        XCTAssertTrue(second.setData(png(24), forType: .png))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let outcome = AttachmentIntake.read(pasteboard)
        XCTAssertEqual(outcome.accepted.count, 2, "\(outcome.refusals)")
        XCTAssertTrue(outcome.accepted.allSatisfy { $0.attachment.kind == .image })
        // And they are told apart. Two chips reading `pasted image.png` are two things
        // the user cannot pick between in order to remove one, and two files under one
        // name is what the model is told it was sent.
        XCTAssertEqual(outcome.accepted.map { $0.attachment.name },
                       [AttachmentIntake.pastedImageName, "pasted image 2.png"])
        // And the cap still counts them: two more on top of three is one taken and a
        // note, not two silently dropped.
        let onFull = AttachmentIntake.read(pasteboard,
                                           existing: AttachmentIntake.maximumPerQuestion - 1)
        XCTAssertEqual(onFull.accepted.count, 1)
        XCTAssertEqual(onFull.refusals, [AttachmentIntake.tooManyMessage])
    }

    /// A paste of more images than the question can hold takes what fits and says so
    /// once — and, the part that is not visible from the outcome, converts only what it
    /// took. Every item read is a full copy and, for a screenshot tool's TIFF, a decode
    /// and a re-encode; a drag of twenty photos onto a composer with room for four used
    /// to do all twenty on the main thread before the cap looked at any of them.
    ///
    /// Exactly one refusal, which is the part a test can hold: the loop that stops early
    /// and the cap inside `outcome` are two places that could each decide to say
    /// something, and a paste that explained itself twice would be the tell.
    func testAPasteOfMoreImagesThanFitTakesWhatItCanAndSaysSoOnce() {
        let items = (0..<(AttachmentIntake.maximumPerQuestion + 2)).map { index -> NSPasteboardItem in
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setData(png(8 + index), forType: .png))
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))

        let outcome = AttachmentIntake.read(pasteboard)
        XCTAssertEqual(outcome.accepted.count, AttachmentIntake.maximumPerQuestion)
        XCTAssertEqual(outcome.refusals, [AttachmentIntake.tooManyMessage])
        // And they are still numbered from the first, so the cap did not renumber what
        // it kept.
        XCTAssertEqual(outcome.accepted.first?.attachment.name, AttachmentIntake.pastedImageName)
        XCTAssertEqual(outcome.accepted.last?.attachment.name,
                       "pasted image \(AttachmentIntake.maximumPerQuestion).png")
    }

    /// A board's own stray flavours do not count against the cap. A browser hands over
    /// the pictures *and* the page's address, and a capture tool appends an empty string
    /// beside the bytes — so the item that trips the cap need not be a picture at all.
    /// Four images and one of those, with room for exactly four, took every image and
    /// then told the reader the rest were left out. A sentence about what was dropped is
    /// the one thing here that must not be invented.
    func testAnItemCarryingNoPictureIsNotCountedAgainstTheCap() {
        var items = (0..<AttachmentIntake.maximumPerQuestion).map { index -> NSPasteboardItem in
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setData(png(8 + index), forType: .png))
            return item
        }
        let address = NSPasteboardItem()
        XCTAssertTrue(address.setString("https://example.com/gallery", forType: .string))
        items.append(address)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))

        // Read as a drop. On a paste the address wins the whole gesture before the cap
        // is ever reached, which is a different rule and tested above; the drag is where
        // an image and its address arrive together and both are looked at.
        let outcome = AttachmentIntake.read(pasteboard, textWins: false)

        XCTAssertEqual(outcome.accepted.count, AttachmentIntake.maximumPerQuestion,
                       "\(outcome.refusals)")
        XCTAssertEqual(outcome.refusals, [], "every picture on the board was taken")
    }

    /// The numbering starts at the *second* image, so the ordinary paste of one is
    /// unchanged by it — a series of one numbered `pasted image 1.png` would be worse
    /// than the plain name it replaced. That the single-image paths still produce that
    /// name is pinned by the TIFF test above; this pins the rule they get it from.
    func testTheFirstPastedImageOfAPasteIsNotNumbered() {
        XCTAssertEqual(AttachmentIntake.name(forPastedImage: 1),
                       AttachmentIntake.pastedImageName)
        XCTAssertEqual(AttachmentIntake.name(forPastedImage: 2), "pasted image 2.png")
    }

    /// A copied *link* is a real `NSURL` on the pasteboard, and must not be claimed.
    ///
    /// The sibling of `testAPathShapedStringWithNoFileBehindItStillPastesAsText`, from
    /// the other direction: that one guards a path-shaped string, this one an item that
    /// genuinely is a URL and genuinely is not a file. `carriesFiles` asks for
    /// conformance to `public.file-url`, which an `https` address does not have — and if
    /// that ever loosened to `public.url`, every link a reader pasted into a question
    /// would disappear into a chip instead.
    func testACopiedWebLinkIsNotAnAttachment() throws {
        let url = try XCTUnwrap(NSURL(string: "https://example.com/notes"))
        XCTAssertTrue(pasteboard.writeObjects([url]))
        XCTAssertTrue(AttachmentIntake.read(pasteboard).isEmpty)
    }

    /// A JPEG-only clipboard — some capture tools and editors offer nothing else — has
    /// no other flavour to fall back on: no text, no file, and a picture this does not
    /// read. Left as "not for us" it was a Cmd-V that did nothing whatsoever, which is
    /// the one outcome the whole file is arranged to avoid.
    func testAPictureInAFormThisCannotReadIsRefusedRatherThanIgnored() {
        XCTAssertTrue(pasteboard.setData(
            Data([0xFF, 0xD8, 0xFF, 0xE0]),
            forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)))

        let outcome = AttachmentIntake.read(pasteboard)
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals, [AttachmentIntake.unreadableImageMessage])
        // And it is *claimed*: an empty outcome would hand the gesture back to AppKit,
        // which has nothing to paste from this board either.
        XCTAssertFalse(outcome.isEmpty)
    }

    /// But a picture beside words is still a paste of the words, refusal or not: the
    /// text branch answers first, and a sentence about an unreadable image would be
    /// wrong about a gesture that worked.
    func testWordsBesideAnUnreadablePictureStillPasteAsWords() {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("a heading and its body", forType: .string))
        XCTAssertTrue(item.setData(Data([0xFF, 0xD8, 0xFF, 0xE0]),
                                   forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertTrue(AttachmentIntake.read(pasteboard).isEmpty)
    }

    /// Nothing recognisable is nothing claimed, so AppKit's own handling stands.
    func testAnEmptyPasteboardClaimsNothing() {
        XCTAssertTrue(AttachmentIntake.read(pasteboard).isEmpty)
    }

    /// The inverse of `testAFileWinsOverTheStringBesideIt`, and the one that guards the
    /// composer against eating a paste: `NSURL` will happily build a file URL out of a
    /// string that merely looks like a path, so reading the pasteboard's *declared*
    /// types rather than what `NSURL` can be talked into is what keeps "/usr/local" a
    /// pair of words. Nothing pins that from this side otherwise.
    func testAPathShapedStringWithNoFileBehindItStillPastesAsText() {
        XCTAssertTrue(pasteboard.setString("/usr/local/share/notes.txt", forType: .string))
        XCTAssertTrue(AttachmentIntake.read(pasteboard).isEmpty)
    }

    // MARK: The cap, and the one gesture it must not apply to

    /// A paste or a drop is an intake: the cap is the answer, and what is past it is
    /// declined while the file sits untouched wherever the user got it.
    func testAPasteIsCappedAndSaysWhatWasLeftOut() {
        let over = AttachmentIntake.admitted(existing: AttachmentIntake.maximumPerQuestion - 1,
                                             incoming: 3, restoring: false)
        XCTAssertEqual(over.taken, 1)
        XCTAssertEqual(over.note, AttachmentIntake.tooManyMessage)

        let fits = AttachmentIntake.admitted(existing: 0,
                                             incoming: AttachmentIntake.maximumPerQuestion - 1,
                                             restoring: false)
        XCTAssertEqual(fits.taken, AttachmentIntake.maximumPerQuestion - 1)
        XCTAssertNil(fits.note)

        // And a composer with no room at all gets the other sentence here too. This is
        // the panel's own check rather than an intake's, so it is the one place the
        // wording could have drifted from the two above without a gesture noticing.
        let full = AttachmentIntake.admitted(existing: AttachmentIntake.maximumPerQuestion,
                                             incoming: 2, restoring: false)
        XCTAssertEqual(full.taken, 0)
        XCTAssertEqual(full.note, AttachmentIntake.noRoomMessage)
    }

    /// A composer already at the cap is the other sentence, and it has to be the other
    /// sentence: nothing was "left out" of anything, because nothing was taken at all,
    /// and the only move that helps is removing one. Both intakes reach it by their own
    /// guard, so both are asked here — the wording is shared, the code is not.
    func testAPasteOntoAFullComposerSaysThereIsNoRoom() throws {
        XCTAssertTrue(pasteboard.setData(png(), forType: .png))
        let pasted = AttachmentIntake.read(pasteboard,
                                           existing: AttachmentIntake.maximumPerQuestion)
        XCTAssertTrue(pasted.accepted.isEmpty)
        XCTAssertEqual(pasted.refusals, [AttachmentIntake.noRoomMessage])

        let file = try write(png(), named: "shot.png")
        let dropped = AttachmentIntake.read(files: [file],
                                            existing: AttachmentIntake.maximumPerQuestion)
        XCTAssertTrue(dropped.accepted.isEmpty)
        XCTAssertEqual(dropped.refusals, [AttachmentIntake.noRoomMessage])
    }

    /// A question handed back by the queue is an undo, and the cap cannot apply to it.
    /// The bytes of a pasted screenshot are on no disk anywhere — the hand-back is the
    /// only copy there is — so dropping one here would not decline a file, it would
    /// destroy one, and tell its owner it had been "left out" of somewhere they could
    /// go and get it again.
    func testARestoreKeepsEverythingAndWarnsInsteadOfDropping() {
        let over = AttachmentIntake.admitted(existing: 2,
                                             incoming: AttachmentIntake.maximumPerQuestion,
                                             restoring: true)
        XCTAssertEqual(over.taken, AttachmentIntake.maximumPerQuestion,
                       "a returned attachment is the only copy of itself")
        XCTAssertEqual(over.note, AttachmentIntake.overCapMessage)
        XCTAssertNotEqual(over.note, AttachmentIntake.tooManyMessage,
                          "nothing was left out, and the words must not say it was")

        let under = AttachmentIntake.admitted(existing: 0, incoming: 2, restoring: true)
        XCTAssertEqual(under.taken, 2)
        XCTAssertNil(under.note, "under the cap there is nothing to warn about")
    }

    // MARK: Files

    /// The size is read from the directory entry, so a huge file is refused without
    /// first being pulled into memory to find out how big it is.
    func testAnOversizedFileIsRefusedByItsSizeOnDisk() throws {
        let url = try write(Data(repeating: 0x41, count: Attachment.maxAttachmentBytes + 1),
                            named: "huge.log")
        let outcome = AttachmentIntake.read(files: [url])

        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals.count, 1)
        // Claimed, not merely refused: an empty outcome hands the gesture back to AppKit
        // and the sentence below is never shown — which is the drop that appears to do
        // nothing, wearing the costume of a drop that explained itself.
        XCTAssertFalse(outcome.isEmpty)
        XCTAssertTrue(outcome.refusals[0].contains("huge.log"), outcome.refusals[0])
        XCTAssertTrue(outcome.refusals[0].contains("MB"), outcome.refusals[0])
    }

    /// A dropped folder is refused out loud. A drag that appears to do nothing reads as
    /// a drop target that does not work.
    func testADroppedFolderIsRefusedRatherThanIgnored() throws {
        let folder = directory.appendingPathComponent("papers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let outcome = AttachmentIntake.read(files: [folder])
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals.count, 1)
        XCTAssertFalse(outcome.isEmpty, "an unclaimed refusal is a refusal nobody sees")
        XCTAssertTrue(outcome.refusals[0].contains("papers"), outcome.refusals[0])
    }

    /// One bad file among good ones does not take them with it.
    func testAGoodFileSurvivesABadOneBesideIt() throws {
        let good = try write(Data("read timeout".utf8), named: "log.txt")
        // Refused because nothing can name what it is: no image signature, and a NUL in
        // the first bytes is what separates a binary from text that happens to decode.
        // Not its size and not its extension — the name is the one part of a file that
        // carries no evidence about it.
        let bad = try write(Data([0x00, 0x01, 0x02]), named: "thing.bin")

        let outcome = AttachmentIntake.read(files: [bad, good])
        XCTAssertEqual(outcome.accepted.map(\.attachment.name), ["log.txt"])
        XCTAssertEqual(outcome.refusals.count, 1)
    }

    // MARK: The limit

    func testTheLimitCountsWhatTheQuestionAlreadyCarries() throws {
        let url = try write(png(), named: "shot.png")
        let files = Array(repeating: url, count: AttachmentIntake.maximumPerQuestion)

        let fresh = AttachmentIntake.read(files: files)
        XCTAssertEqual(fresh.accepted.count, AttachmentIntake.maximumPerQuestion)
        // Classified by their bytes on the way through, which only the pasteboard path
        // asserted — and a drop is how files actually arrive.
        XCTAssertTrue(fresh.accepted.allSatisfy { $0.attachment.kind == .image })
        XCTAssertTrue(fresh.refusals.isEmpty)

        // The same drop onto a question that already carries one leaves the last out,
        // and says so rather than dropping it in silence.
        let onTop = AttachmentIntake.read(files: files, existing: 1)
        XCTAssertEqual(onTop.accepted.count, AttachmentIntake.maximumPerQuestion - 1)
        XCTAssertEqual(onTop.refusals, [AttachmentIntake.tooManyMessage])
    }

    /// Every attachment is its own record even when the same file is dropped twice, so
    /// removing one chip cannot remove the other.
    func testTheSameFileTwiceIsTwoAttachments() throws {
        let url = try write(png(), named: "shot.png")
        let outcome = AttachmentIntake.read(files: [url, url])
        XCTAssertEqual(outcome.accepted.count, 2)
        XCTAssertNotEqual(outcome.accepted[0].id, outcome.accepted[1].id)
    }
}
