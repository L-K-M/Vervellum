import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// What may ride on one question — the half both front ends share, so a drop on GNOME
/// and a paste on macOS accept and refuse exactly the same things.
final class AttachmentIntakeTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vervellum-core-intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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

    // MARK: The limit

    /// The cap has two sentences and which one is true turns on whether anything landed —
    /// which is not knowable while the files are still being read. A candidate is a file
    /// that got as far as its bytes, not one that will be kept: every one of them can
    /// still be refused when those bytes are looked at.
    ///
    /// Four files this cannot attach and a fifth that would have fit. The four spent the
    /// budget, the fifth was never read, and the gesture used to say "the rest were left
    /// out" — of nothing, because the four were refused in the same breath.
    func testTheCapSaysNothingLandedWhenTheCandidatesAreAllRefused() throws {
        // A NUL, so `text(from:)` refuses it, and no image signature in front of it. Not
        // an empty file: whether `contents(atPath:)` answers an empty file with `Data()`
        // or with nil is a thing about Foundation, and this test is about neither.
        let unattachable = try (0..<AttachmentIntake.maximumPerQuestion).map { index in
            try write(Data([0x00, 0x01, 0x02, UInt8(index)]), named: "part\(index).bin")
        }
        let wouldHaveFit = try write(png(), named: "shot.png")

        let outcome = AttachmentIntake.read(files: unattachable + [wouldHaveFit])

        XCTAssertTrue(outcome.accepted.isEmpty, "\(outcome.accepted.map(\.attachment.name))")
        XCTAssertTrue(outcome.refusals.contains(AttachmentIntake.noRoomMessage),
                      "\(outcome.refusals)")
        XCTAssertFalse(outcome.refusals.contains(AttachmentIntake.tooManyMessage),
                       "nothing landed, so nothing can have been left out beside it")
    }

    func testTheLimitCountsWhatTheQuestionAlreadyCarries() {
        let four = (0..<AttachmentIntake.maximumPerQuestion).map {
            AttachmentIntake.Candidate(png(), name: "shot\($0).png")
        }
        let fresh = AttachmentIntake.outcome(from: four)
        XCTAssertEqual(fresh.accepted.count, AttachmentIntake.maximumPerQuestion)
        XCTAssertTrue(fresh.refusals.isEmpty)

        let onTop = AttachmentIntake.outcome(from: four, existing: 1)
        XCTAssertEqual(onTop.accepted.count, AttachmentIntake.maximumPerQuestion - 1)
        XCTAssertEqual(onTop.refusals, [AttachmentIntake.tooManyMessage])
    }

    /// A question already at the limit takes nothing more, and says so in its own words
    /// rather than in the ones for a gesture that was partly taken. Nothing was "left
    /// out" of anything: nothing was taken at all, the files are still wherever they
    /// came from, and the only move that helps is removing one of the four.
    ///
    /// Both intakes are asked, because each has its own guard: the candidate path counts
    /// room as it goes, the file path refuses before it reads anything, and the wording
    /// is the only part they share.
    func testAFullQuestionTakesNothingMore() throws {
        let outcome = AttachmentIntake.outcome(from: [.init(png(), name: "shot.png")],
                                               existing: AttachmentIntake.maximumPerQuestion)
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals, [AttachmentIntake.noRoomMessage])
        XCTAssertNotEqual(outcome.refusals, [AttachmentIntake.tooManyMessage])

        let url = try write(png(), named: "shot.png")
        let dropped = AttachmentIntake.read(files: [url],
                                            existing: AttachmentIntake.maximumPerQuestion)
        XCTAssertTrue(dropped.accepted.isEmpty)
        XCTAssertEqual(dropped.refusals, [AttachmentIntake.noRoomMessage])
    }

    /// Nothing at all is nothing claimed, which is the signal to let the toolkit paste
    /// or drop it the way it always did.
    func testNothingToAttachIsAnEmptyOutcome() {
        XCTAssertTrue(AttachmentIntake.outcome(from: []).isEmpty)
    }

    /// One refused candidate does not take the good ones with it.
    ///
    /// `thing.bin` is refused because nothing can name what it is: no image signature,
    /// and a NUL in the first bytes is what separates a binary from text that happens to
    /// decode. Not its size and not its extension — a name is the one part of a file
    /// that carries no evidence about it.
    func testARefusedCandidateDoesNotTakeTheOthersWithIt() {
        let outcome = AttachmentIntake.outcome(from: [
            .init(Data([0x00, 0x01, 0x02]), name: "thing.bin"),
            .init(Data("read timeout".utf8), name: "log.txt"),
        ])
        XCTAssertEqual(outcome.accepted.map { $0.attachment.name }, ["log.txt"])
        XCTAssertEqual(outcome.refusals.count, 1)
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
        // Claimed, not merely refused: an empty outcome hands the gesture back to the
        // toolkit and the sentence below is never shown — which is the drop that appears
        // to do nothing, wearing the costume of a drop that explained itself.
        XCTAssertFalse(outcome.isEmpty)
        XCTAssertTrue(outcome.refusals[0].contains("huge.log"), outcome.refusals[0])
        XCTAssertTrue(outcome.refusals[0].contains("MB"), outcome.refusals[0])
    }

    /// A file whose directory entry says four gigabytes is refused by that entry, and
    /// its bytes are never asked for.
    ///
    /// The size is the one number here that can outgrow a C `int`, and `NSNumber`'s
    /// `intValue` answers for the low 32 bits of it: a 4 GiB screen recording reads back
    /// as a single byte, passes the ceiling, and is pulled into memory whole — which is
    /// the one thing consulting the directory entry exists to prevent. Nothing else in
    /// this suite can reach that size without writing it to a disk.
    func testAHugeFileIsRefusedByItsEntryRatherThanTruncatedIntoIt() {
        let manager = StubbedSize(NSNumber(value: Int64(UInt32.max) + 2))
        let outcome = AttachmentIntake.read(files: [URL(fileURLWithPath: "/tmp/recording.mov")],
                                            fileManager: manager)

        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals.count, 1)
        XCTAssertTrue(outcome.refusals[0].contains("recording.mov"), outcome.refusals[0])
        XCTAssertFalse(manager.wasRead,
                       "a file refused by its entry must not be read to find out its size")
    }

    /// Reports whatever size it is told to, and remembers whether anything went looking
    /// for the bytes behind it.
    private final class StubbedSize: FileManager {
        private let size: NSNumber
        private(set) var wasRead = false

        init(_ size: NSNumber) {
            self.size = size
            super.init()
        }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            [.type: FileAttributeType.typeRegular, .size: size]
        }

        override func contents(atPath path: String) -> Data? {
            wasRead = true
            return nil
        }
    }

    /// A dropped folder is refused out loud. A drag that appears to do nothing reads as
    /// a window that does not accept drops.
    func testADroppedFolderIsRefusedRatherThanIgnored() throws {
        let folder = directory.appendingPathComponent("papers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let outcome = AttachmentIntake.read(files: [folder])
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals.count, 1)
        XCTAssertFalse(outcome.isEmpty, "an unclaimed refusal is a refusal nobody sees")
        XCTAssertTrue(outcome.refusals[0].contains("papers"), outcome.refusals[0])
    }

    /// A path that is not there at all is refused the same way, rather than throwing
    /// out of a drop handler.
    func testAMissingFileIsRefusedRatherThanThrowing() {
        let outcome = AttachmentIntake.read(files: [directory.appendingPathComponent("gone.png")])
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals.count, 1)
    }

    func testAReadFileKeepsItsNameAndKind() throws {
        let url = try write(png(), named: "diagram.png")
        let outcome = AttachmentIntake.read(files: [url])
        XCTAssertEqual(outcome.accepted.map { $0.attachment.name }, ["diagram.png"])
        XCTAssertEqual(outcome.accepted.first?.attachment.kind, .image)
        XCTAssertTrue(outcome.refusals.isEmpty)
    }

    /// An image pasted from a clipboard has no file behind it, and both front ends give
    /// it the same name so a paste on GNOME and a paste on macOS list the same thing.
    func testAPastedImageIsAnImageUnderTheSharedName() {
        let outcome = AttachmentIntake.outcome(
            from: [AttachmentIntake.Candidate(png(), name: AttachmentIntake.pastedImageName)])
        XCTAssertEqual(outcome.accepted.map { $0.attachment.name },
                       [AttachmentIntake.pastedImageName])
        XCTAssertEqual(outcome.accepted.first?.attachment.kind, .image)
        XCTAssertEqual(outcome.accepted.first?.attachment.mediaType, "image/png")
    }

    /// The numbering starts at the *second* image of a paste, so the ordinary paste of
    /// one is unchanged by it — a series of one numbered `pasted image 1.png` would be
    /// worse than the plain name it replaced. Here rather than beside a pasteboard,
    /// because it is the rule both front ends read: GTK hands over one image at a time
    /// and takes the unnumbered name, and only the AppKit side can carry several.
    func testTheFirstPastedImageOfAPasteIsNotNumbered() {
        XCTAssertEqual(AttachmentIntake.name(forPastedImage: 1),
                       AttachmentIntake.pastedImageName)
        XCTAssertEqual(AttachmentIntake.name(forPastedImage: 2), "pasted image 2.png")
    }

    /// The same file dropped twice is two attachments, so removing one chip cannot
    /// remove the other.
    func testTheSameFileTwiceIsTwoAttachments() throws {
        let url = try write(png(), named: "shot.png")
        let outcome = AttachmentIntake.read(files: [url, url])
        XCTAssertEqual(outcome.accepted.count, 2)
        XCTAssertNotEqual(outcome.accepted[0].id, outcome.accepted[1].id)
    }

    /// The panel hands the live chip count to the *read* path on every drop, and the
    /// suite only ever gave `existing` to the candidate path. A read that ignored it
    /// would accept drops past the ceiling with every test still green — and the drop is
    /// how files actually arrive.
    func testTheFileReadPathRespectsWhatIsAlreadyAttached() throws {
        let url = try write(png(), named: "shot.png")
        let drops = Array(repeating: url, count: AttachmentIntake.maximumPerQuestion)
        let outcome = AttachmentIntake.read(files: drops,
                                            existing: AttachmentIntake.maximumPerQuestion - 2)

        XCTAssertEqual(outcome.accepted.count, 2)
        // Classified by their bytes on the way through, which only the candidate path
        // asserted — and a drop is how files actually arrive.
        XCTAssertTrue(outcome.accepted.allSatisfy { $0.attachment.kind == .image })
        XCTAssertEqual(outcome.refusals, [AttachmentIntake.tooManyMessage])
    }

    /// A symlink to an ordinary file is an ordinary file. `attributesOfItem` reports the
    /// link's own attributes, so without following it first a dropped link is refused as
    /// "not a file" — and a GTK drop hands over the literal path, so it is the platform
    /// where a reader would meet it.
    func testASymlinkToARealFileIsAttached() throws {
        let target = try write(png(), named: "real.png")
        let link = target.deletingLastPathComponent().appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let outcome = AttachmentIntake.read(files: [link])
        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.accepted.first?.attachment.kind, .image)
        // Named as dropped: the reader chose the link, not the thing behind it.
        XCTAssertEqual(outcome.accepted.first?.attachment.name, "link.png")

        // A link to nothing is refused rather than attached. Which of the two messages it
        // gets depends on whether Foundation resolves a dangling link to its missing
        // target or leaves the link path alone, and that is Foundation's call to make —
        // so what is pinned here is the refusal, not its wording.
        let dangling = target.deletingLastPathComponent().appendingPathComponent("gone.png")
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: target.deletingLastPathComponent()
                .appendingPathComponent("missing.png"))
        let broken = AttachmentIntake.read(files: [dangling])
        XCTAssertTrue(broken.accepted.isEmpty)
        XCTAssertEqual(broken.refusals.count, 1)
    }

    // MARK: Size, said the same way on both platforms

    func testSizeReadsTheWayAPanelWouldShowIt() {
        func size(_ bytes: Int) -> String {
            Attachment(kind: .image, name: "n", mediaType: "image/png", byteCount: bytes)
                .sizeDescription
        }
        XCTAssertEqual(size(512), "512 bytes")
        XCTAssertEqual(size(2048), "2 KB")
        XCTAssertEqual(size(1_572_864), "1.5 MB")

        XCTAssertEqual(size(1), "1 byte", "the chip must not read \"1 bytes\"")
        // The tier boundary, from both sides. Choosing the tier before rounding printed
        // the first of these as "1024 KB" — one byte below a file that reads "1.0 MB".
        XCTAssertEqual(size(1_048_575), "1.0 MB")
        XCTAssertEqual(size(1_048_576), "1.0 MB")
        XCTAssertEqual(size(1_048_000), "1023 KB")
        // No gigabyte tier, because nothing can reach one: `maxAttachmentBytes` is the
        // ceiling for *every* kind, so an attachment above it never becomes an
        // `Attachment` at all.
        XCTAssertEqual(size(Attachment.maxAttachmentBytes), "4.0 MB")
    }

    // MARK: Size, in memory

    /// A file is refused from its directory entry, before it is read. A pasted image has
    /// no directory entry, so the same ceiling has to be enforced against the bytes
    /// themselves — a different path, and one nothing else here pins down.
    func testAnOversizedPastedImageIsRefusedToo() {
        let huge = Data(repeating: 0, count: Attachment.maxAttachmentBytes + 1)
        let outcome = AttachmentIntake.outcome(
            from: [AttachmentIntake.Candidate(huge, name: AttachmentIntake.pastedImageName)],
            existing: 0)

        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals.count, 1)
        XCTAssertTrue(outcome.refusals[0].contains(AttachmentIntake.pastedImageName),
                      outcome.refusals[0])
        // Refused for its *size*, which is the half a substring cannot pin: bytes past
        // the cap are also bytes nothing sniffed as an image, so the unsupported-kind
        // refusal is the wrong answer that this path could plausibly give — and it would
        // send its owner looking for a format problem that is not there.
        //
        // Compared against the refusal's own message rather than a phrase lifted out of
        // it. The wording is copy: it was rewritten one branch down, from "has to be
        // under" to "can be at most", and this assertion is what noticed — by failing,
        // over a sentence that had become more accurate, not less.
        XCTAssertEqual(outcome.refusals[0],
                       Attachment.Refusal.tooLarge(name: AttachmentIntake.pastedImageName,
                                                   byteCount: Attachment.maxAttachmentBytes + 1)
                           .message)
    }
}
