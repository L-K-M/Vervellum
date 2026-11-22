import AppKit
import XCTest
@testable import Vervellum

/// The paste routing decision, exercised with a local pasteboard.
///
/// `NSPasteboard.general` is process-global, so these tests never touch it: a test
/// that set it would change the reader's clipboard. `ComposerView.route` is the whole
/// decision, so a local board is enough to pin it.
final class ComposerPasteRedactionTests: XCTestCase {

    private let credential = "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456"
    private let prose = "What is the capital of Australia, and why?"

    func testAPastedCredentialIsRedactedBeforeItReachesTheField() {
        let board = NSPasteboard.withUniqueName()
        board.setString(credential, forType: .string)

        let route = ComposerView.route(board, existing: 0, redact: true)
        guard case .insert(let text, let redactions) = route else {
            return XCTFail("a credential-bearing paste must be redacted, got \(route)")
        }
        XCTAssertEqual(redactions, 1)
        XCTAssertFalse(text.contains("sk-abcdefghijklmnopqrstuvwxyz123456"),
                       "the key must not reach the composer")
        XCTAssertEqual(text, SecretRedactor.placeholder,
                       "the whole assignment is the secret's shape, not just its value")
    }

    func testPlainProseIsPastUnchanged() {
        let board = NSPasteboard.withUniqueName()
        board.setString(prose, forType: .string)
        XCTAssertEqual(ComposerView.route(board, existing: 0, redact: true), .plain)
    }

    /// The composer flattens rich text it is given, so a board with no plain-text
    /// flavour still delivers the credential as text.
    func testACredentialInRichTextAloneIsRedacted() throws {
        let attributed = NSAttributedString(string: credential)
        let rtfd = try XCTUnwrap(attributed.rtfd(from: NSRange(location: 0, length: attributed.length),
                                                 documentAttributes: [:]))
        let flavours: [(NSPasteboard.PasteboardType, Data)] = [(.html, Data("<p>\(credential)</p>".utf8)),
                                                               (.rtfd, rtfd)]
        for (type, data) in flavours {
            let board = NSPasteboard.withUniqueName()
            board.setData(data, forType: type)
            XCTAssertNil(board.string(forType: .string), "the fixture must have no plain text")

            guard case .insert(let text, _) = ComposerView.route(board, existing: 0, redact: true) else {
                XCTFail("\(type.rawValue) reached the composer unredacted")
                continue
            }
            XCTAssertFalse(text.contains("sk-abcdefghijklmnopqrstuvwxyz123456"), type.rawValue)
        }
    }

    /// The preference is the selection one, and it governs both paths.
    func testRedactionCanBeTurnedOff() {
        let board = NSPasteboard.withUniqueName()
        board.setString(credential, forType: .string)
        XCTAssertEqual(ComposerView.route(board, existing: 0, redact: false), .plain)
    }

    /// A whitespace-only board is not a paste of nothing: it is the dead-paste case
    /// `PasteboardIntake` exists to avoid, and it must fall through to AppKit.
    func testAWhitespaceOnlyBoardIsNotARedaction() {
        let board = NSPasteboard.withUniqueName()
        board.setString("   \n", forType: .string)
        XCTAssertEqual(ComposerView.route(board, existing: 0, redact: true), .plain)
    }

    func testAnImagePasteIsStillAnAttachment() {
        let board = NSPasteboard.withUniqueName()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + Data(repeating: 7, count: 8)
        board.setData(png, forType: .png)

        let route = ComposerView.route(board, existing: 0, redact: true)
        guard case .attach(let outcome) = route else {
            return XCTFail("an image paste must attach, got \(route)")
        }
        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertTrue(outcome.refusals.isEmpty)
    }

    /// A full question must refuse the picture rather than attach it, and the refusal
    /// must travel through the same route.
    func testAFullQuestionRefusesAnImagePaste() {
        let board = NSPasteboard.withUniqueName()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + Data(repeating: 7, count: 8)
        board.setData(png, forType: .png)

        let route = ComposerView.route(board, existing: AttachmentIntake.maximumPerQuestion,
                                       redact: true)
        guard case .attach(let outcome) = route else {
            return XCTFail("a refused paste must still be an attachment outcome, got \(route)")
        }
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.refusals, [AttachmentIntake.noRoomMessage])
    }

    func testAFilePasteIsStillAnAttachment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("a attached file".utf8).write(to: file)

        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(board.writeObjects([file as NSURL]))

        let route = ComposerView.route(board, existing: 0, redact: true)
        guard case .attach(let outcome) = route else {
            return XCTFail("a file paste must attach, got \(route)")
        }
        XCTAssertEqual(outcome.accepted.map(\.attachment.name), ["notes.txt"])
    }
}
