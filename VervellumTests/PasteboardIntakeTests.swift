import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Vervellum

/// What a paste or a drop on the composer turns out to be.
final class PasteboardIntakeTests: XCTestCase {

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
        XCTAssertTrue(PasteboardIntake.read(pasteboard).isEmpty)
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

        XCTAssertTrue(PasteboardIntake.read(pasteboard).isEmpty)
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

        let dropped = PasteboardIntake.read(pasteboard, textWins: false)
        XCTAssertEqual(dropped.accepted.count, 1, "\(dropped.refusals)")
        XCTAssertEqual(dropped.accepted.first?.attachment.kind, .image)
        // And the paste of the same board is unchanged: there the words are the point.
        XCTAssertTrue(PasteboardIntake.read(pasteboard).isEmpty)
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

        let outcome = PasteboardIntake.read(pasteboard)
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

        let outcome = PasteboardIntake.read(pasteboard)
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

        let outcome = PasteboardIntake.read(pasteboard)
        XCTAssertEqual(outcome.accepted.count, 2, "\(outcome.refusals)")
        XCTAssertTrue(outcome.accepted.allSatisfy { $0.attachment.kind == .image })
        // And they are told apart. Two chips reading `pasted image.png` are two things
        // the user cannot pick between in order to remove one, and two files under one
        // name is what the model is told it was sent.
        XCTAssertEqual(outcome.accepted.map { $0.attachment.name },
                       [AttachmentIntake.pastedImageName, "pasted image 2.png"])
        // And the cap still counts them: two more onto a question one short of full is
        // one taken and a note, not two silently dropped.
        let onFull = PasteboardIntake.read(pasteboard,
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

        let outcome = PasteboardIntake.read(pasteboard)
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
        let outcome = PasteboardIntake.read(pasteboard, textWins: false)

        XCTAssertEqual(outcome.accepted.count, AttachmentIntake.maximumPerQuestion,
                       "\(outcome.refusals)")
        XCTAssertEqual(outcome.refusals, [], "every picture on the board was taken")
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
        XCTAssertTrue(PasteboardIntake.read(pasteboard).isEmpty)
    }

    /// A JPEG-only clipboard — some capture tools and editors offer nothing else — has
    /// no other flavour to fall back on: no text, no file, and a picture this does not
    /// read. Left as "not for us" it was a Cmd-V that did nothing whatsoever, which is
    /// the one outcome the whole file is arranged to avoid.
    func testAPictureInAFormThisCannotReadIsRefusedRatherThanIgnored() {
        XCTAssertTrue(pasteboard.setData(
            Data([0xFF, 0xD8, 0xFF, 0xE0]),
            forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)))

        let outcome = PasteboardIntake.read(pasteboard)
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals, [PasteboardIntake.unreadableImageMessage])
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

        XCTAssertTrue(PasteboardIntake.read(pasteboard).isEmpty)
    }

    /// Nothing recognisable is nothing claimed, so AppKit's own handling stands.
    func testAnEmptyPasteboardClaimsNothing() {
        XCTAssertTrue(PasteboardIntake.read(pasteboard).isEmpty)
    }

    /// The inverse of `testAFileWinsOverTheStringBesideIt`, and the one that guards the
    /// composer against eating a paste: `NSURL` will happily build a file URL out of a
    /// string that merely looks like a path, so reading the pasteboard's *declared*
    /// types rather than what `NSURL` can be talked into is what keeps "/usr/local" a
    /// pair of words. Nothing pins that from this side otherwise.
    func testAPathShapedStringWithNoFileBehindItStillPastesAsText() {
        XCTAssertTrue(pasteboard.setString("/usr/local/share/notes.txt", forType: .string))
        XCTAssertTrue(PasteboardIntake.read(pasteboard).isEmpty)
    }


    // MARK: Files

    /// The file half is Core's, and `Tests/VervellumKitTests/AttachmentIntakeTests.swift`
    /// covers it there: an oversized file refused from its directory entry without being
    /// read, a dropped folder named in the refusal, one bad file not taking the good ones
    /// with it, the limit counting what the question already carries, and the same file
    /// twice yielding two attachments. This is the one case that has to be true *through*
    /// the pasteboard: a file that arrives on it reaches that code at all, and comes back
    /// classified by its bytes. It is read with the question one short of full, which is
    /// the other side of the boundary `testTheLimitIsForwardedWhenReadingFilesFromThePasteboard`
    /// pins — a forwarded count has to leave the last slot usable, not just refuse past it.
    func testAFileOnThePasteboardIsReadThroughCore() throws {
        let url = try write(Data("read timeout".utf8), named: "log.txt")
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))

        let outcome = PasteboardIntake.read(pasteboard,
                                            existing: AttachmentIntake.maximumPerQuestion - 1)
        XCTAssertEqual(outcome.accepted.map(\.attachment.name), ["log.txt"])
        XCTAssertEqual(outcome.accepted.first?.attachment.kind, .text)
    }

    /// The composer hands in what the question already carries, and this is the hop that
    /// carries it: a `read` that dropped the argument would compile, pass every test
    /// here that omits it, and quietly restore unlimited pasting. Not *every* test —
    /// the two-image case reads one short of full and would notice — but that one
    /// counts images against the cap incidentally, on its way to something else. This
    /// is the assertion whose whole subject is the hop.
    func testTheLimitIsForwardedWhenReadingFilesFromThePasteboard() throws {
        let url = try write(png(), named: "shot.png")
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))

        let outcome = PasteboardIntake.read(pasteboard,
                                            existing: AttachmentIntake.maximumPerQuestion)
        XCTAssertTrue(outcome.accepted.isEmpty)
        // The full-question words, not the ones for a drop that was partly taken:
        // nothing was left out anywhere, and the file is still where it was dropped from.
        XCTAssertEqual(outcome.refusals, [AttachmentIntake.noRoomMessage])
    }

    /// The accepting side of the boundary for images, which the file branch has and this
    /// one did not: a forwarded count has to leave the last slot usable, not only refuse
    /// past it, and an off-by-one in the image branch would have passed the suite.
    func testAPastedImageFillsTheLastSlot() {
        XCTAssertTrue(pasteboard.setData(png(), forType: .png))

        let outcome = PasteboardIntake.read(pasteboard,
                                            existing: AttachmentIntake.maximumPerQuestion - 1)
        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.accepted.first?.attachment.kind, .image)
        XCTAssertTrue(outcome.refusals.isEmpty)
    }

    /// And the refusing side. A paste onto a full question is turned away in words
    /// rather than quietly making it fuller.
    func testTheLimitIsForwardedForAPastedImage() {
        XCTAssertTrue(pasteboard.setData(png(), forType: .png))

        let outcome = PasteboardIntake.read(pasteboard,
                                            existing: AttachmentIntake.maximumPerQuestion)
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals, [AttachmentIntake.noRoomMessage])
    }
}
