import XCTest
#if canImport(VervellumKit)
@testable import VervellumKit
#else
@testable import Vervellum
#endif

final class ForbiddenLinkScannerTests: XCTestCase {

    func testCredentialBearingURLIsStillForbiddenInModelOutput() {
        XCTAssertEqual(ForbiddenLinkScanner.links(in: "See https://user:secret@example.com/page."),
                       ["https://user:secret@example.com/page"])
    }

    func testFindsEveryDestinationSpelling() {
        let examples = [
            "HTTPS://EXAMPLE.COM/path",
            "http://[::1]:8080/path",
            "http://[::1]",
            "https://[2001:db8::1].",
            "_https://example.com_",
            "FTP://evil.example/path",
            "gemini://evil.example",
            "x://host",
            "abcdefghijklmnopqrstuvwxyzabcdefghi://host",
            "//example.com/path",
            "//[2001:db8::1]/path",
            "//[::1]",
            "//user@example.com/path",
            "//intranet-server/guide",
            "//例子.中国/path",
            "//192.0.2.1/path",
            "198.51.100.4/details",
            "[2001:db8::1]",
            "[::ffff:192.0.2.1]",
            "[label](/relative/path)",
            "See[docs](/relative/path)",
            "[](/relative/path)",
            #"[la\]bel](/relative/path)"#,
            #"\\[label](/relative/path)"#,
            "[outer [inner] text](/relative/path)",
            "[label\ntext](/relative/path)",
            "[label\r\ntext](/relative/path)",
            "[label](/relative/path (title))",
            "[label](\n/relative/path)",
            "[label](/relative/path\n)",
            #"[label](<foo\>bar>)"#,
            "![alt](image)",
            "[destination]: /relative/path",
            "[proof][la\\]bel]\n\n[la\\]bel]: /private",
            "[proof][x]\n\n[x]:\n  /private",
            "[proof][x]\n\n[x]: /private \"a \\\" title\"",
            "[proof][foo bar]\n\n[foo\n bar]: /private",
            "mailto:user@example.com",
            "<custom+app:open/item>",
            "<user@example.com>",
            "user@example.com",
            "用户@例子.中国",
            "file:/private/report.txt",
            "data:text/plain,private",
            "tel:+41441234567",
            "example.com/path",
            "example.ai/path",
            "example.app/path",
            "example.sh/path",
            "example.design/path",
            "docs.example.co.uk/path",
            "www.example.invalid/path",
            "example.art",
            "example.game",
            "example.link",
            "example.page",
            "例子.中国",
            "service.localhost",
            "www.evil.host",
            "evil.photography/path",
            "evil.unlisted/path",
            "EVIL.COM",
            "com.evil.com",
            "www.evil.id",
        ]
        for example in examples {
            XCTAssertFalse(ForbiddenLinkScanner.links(in: example).isEmpty, example)
        }
    }

    func testIgnoresHighFrequencyDomainAndMarkdownLookalikes() {
        let examples = [
            "3.14", "v1.2.3", "v1.2.3.4", "1.2.3.444",
            "README.md", "package.json", "archive.tar.gz", "drawing.ai", "download.zip",
            "config.prod.json", "docs/README.md", "main.swift", "build.sh",
            "Vervellum.app", "movie.mov",
            "Foundation.URL", "os.Logger", "ASP.NET", "VB.NET", "ADO.NET",
            // Member access whose last label happens to be a delegated TLD: without a
            // path, port or `www.`, these read as code, not destinations.
            "request.data", "array.map", "model.fit(x)", "obj.property", "this.is",
            "cache.host", "self.app.run()", "evil.photography", "user.id",
            "tool@1.2.34", "user@localhost",
            "// comment", "//TODO", "/usr/local/bin",
            "[1:2]", "[a:b]", "//[1:2]", "[1][2]", "[term][case]",
            "[1]: This source says the claim is supported",
            "[1]", "[1, 2]", #"\[label](/escaped)"#, "example.com_value",
        ]
        for example in examples {
            XCTAssertTrue(ForbiddenLinkScanner.links(in: example).isEmpty, example)
        }
    }

    func testMarkdownShapedCodeIsSyntaxButDestinationsInCodeStillFail() {
        let text = "Use `[key](value)` and `<custom+app:open/item>` here.\n"
            + "```swift\n[label](value)\n```"
        XCTAssertTrue(ForbiddenLinkScanner.links(
            in: text, excludingMarkdownSyntaxIn: CitationValidator.codeRanges(in: text)).isEmpty)

        let linkedCode = "`example.com/private`, `user@example.org` and "
            + "```\nhttps://example.org/private\n```"
        XCTAssertEqual(ForbiddenLinkScanner.links(
            in: linkedCode,
            excludingMarkdownSyntaxIn: CitationValidator.codeRanges(in: linkedCode)).count, 3)
    }

    func testInlineCodeInsideALinkLabelDoesNotHideTheOuterDestination() {
        for text in ["[foo `[x]` bar](/relative)", "[foo `[` bar](/relative)"] {
            XCTAssertFalse(ForbiddenLinkScanner.links(
                in: text,
                excludingMarkdownSyntaxIn: CitationValidator.codeRanges(in: text)).isEmpty,
                text)
        }
    }

    func testOverlappingSyntaxIsOneViolation() {
        XCTAssertEqual(ForbiddenLinkScanner.links(in: "[docs](https://example.com)").count, 1)
    }

    func testAnImageMayBeNestedInsideALinkButLinksMayNotNest() {
        XCTAssertEqual(ForbiddenLinkScanner.links(in: "[![moon](moon.jpg)](/uri)"),
                       ["[![moon](moon.jpg)](/uri)"])
        XCTAssertEqual(ForbiddenLinkScanner.links(in: "[a [b](u1)](u2)"), ["[b](u1)"])
        XCTAssertEqual(ForbiddenLinkScanner.links(in: #"\![a](b)"#), ["[a](b)"])
    }

    func testSentencePunctuationIsNotPartOfTheDestination() {
        XCTAssertEqual(ForbiddenLinkScanner.links(in: "Visit example.com."), ["example.com"])
        XCTAssertEqual(ForbiddenLinkScanner.links(in: "See https://example.com/a)."),
                       ["https://example.com/a"])
        XCTAssertEqual(ForbiddenLinkScanner.links(in: "See <https://example.com/a>."),
                       ["<https://example.com/a>"])
    }

    /// A `)` with no `(` inside the destination is sentence punctuation; a balanced
    /// pair is part of the address itself.
    func testOnlyUnbalancedClosingParenthesesAreTrimmed() {
        XCTAssertEqual(ForbiddenLinkScanner.links(
            in: "See https://en.wikipedia.org/wiki/Mercury_(planet)."),
                       ["https://en.wikipedia.org/wiki/Mercury_(planet)"])
        XCTAssertEqual(ForbiddenLinkScanner.links(
            in: "(See https://example.com/a)."), ["https://example.com/a"])
    }

    func testRepeatedDestinationsAreReportedOnce() {
        XCTAssertEqual(ForbiddenLinkScanner.links(
            in: "(See https://example.com/a) and https://example.com/a."),
                       ["https://example.com/a"])
    }

    func testManyDistinctMatchesAreAllReported() {
        let text = (0..<2_000).map { "host\($0).example.com" }.joined(separator: " ")
        XCTAssertEqual(ForbiddenLinkScanner.links(in: text).count, 2_000)
    }
}
