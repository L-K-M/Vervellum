import XCTest
#if canImport(VervellumKit)
// Linux: the portable code is its own SwiftPM module.
@testable import VervellumKit
#else
// macOS: it is compiled straight into the app target, so there is no separate module.
@testable import Vervellum
#endif

/// The page-reading path's pure parts: turning HTML into readable text, deciding what
/// is fetchable, and reading a reader server's reply.
final class PageReadingTests: XCTestCase {

    // MARK: HTML → text

    func testExtractsProseAndKeepsBlockBoundaries() {
        let html = """
            <html><body><p>First paragraph.</p><p>Second paragraph.</p>
            <ul><li>One</li><li>Two</li></ul></body></html>
            """
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("First paragraph."))
        XCTAssertTrue(text.contains("Second paragraph."))
        // Without block breaks the model reads "First paragraph.Second paragraph." as
        // one sentence, which is how a summary becomes a misquotation.
        XCTAssertFalse(text.contains("paragraph.Second"))
        XCTAssertTrue(text.contains("One"))
        XCTAssertTrue(text.contains("Two"))
    }

    /// Script and style content is never prose, and a page's script can be most of its
    /// bytes — spending the evidence budget on it would crowd out a whole source.
    func testDropsScriptStyleAndChrome() {
        let html = """
            <html><head><style>body { color: red }</style></head>
            <body><nav><a href="/x">Nav link</a></nav>
            <script>var secret = "do not read me";</script>
            <p>The actual sentence.</p>
            <footer>Copyright notice</footer></body></html>
            """
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("The actual sentence."))
        XCTAssertFalse(text.contains("do not read me"))
        XCTAssertFalse(text.contains("color: red"))
        XCTAssertFalse(text.contains("Nav link"))
        XCTAssertFalse(text.contains("Copyright notice"))
    }

    /// A page that says where its content is has told us; a model shown the site's
    /// sidebar under four sources finds agreement between them that does not exist.
    func testPrefersTheArticleWhenThePageMarksOne() {
        let filler = String(repeating: "The article body goes on. ", count: 20)
        let html = """
            <html><body><div>Sidebar clutter that is not the article at all.</div>
            <main><p>\(filler)</p></main></body></html>
            """
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("The article body goes on."))
        XCTAssertFalse(text.contains("Sidebar clutter"))
    }

    /// A `<main>` holding only a heading is a page whose content is elsewhere: trusting
    /// the marker there loses the page.
    func testAnEmptyArticleMarkerFallsBackToTheDocument() {
        let filler = String(repeating: "Real content lives out here. ", count: 20)
        let html = "<html><body><main><h1>Title</h1></main><p>\(filler)</p></body></html>"
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("Real content lives out here."))
    }

    func testDecodesTheEntitiesThatAppearInProse() {
        let html = "<p>Ben &amp; Jerry&rsquo;s &mdash; 20&nbsp;&deg;C &#8212; &#x41;.</p>"
        let text = HTMLTextExtractor.text(from: html, limit: 4_000, minimum: 0)
        XCTAssertTrue(text.contains("Ben & Jerry’s"))
        XCTAssertTrue(text.contains("—"))
        XCTAssertTrue(text.contains("°C"))
        XCTAssertTrue(text.contains("A."))
    }

    /// An unknown entity survives as its own text rather than as a wrong character.
    func testAnUnknownEntityIsLeftAlone() {
        let body = String(repeating: "padding sentence. ", count: 10)
        let text = HTMLTextExtractor.text(from: "<p>&notarealentity; \(body)</p>", limit: 4_000)
        XCTAssertTrue(text.contains("&notarealentity;"))
    }

    /// "a < b" in prose is not a tag, and treating it as one eats the rest of the page.
    func testAStrayLessThanIsNotTreatedAsATag() {
        let body = String(repeating: "padding sentence. ", count: 10)
        let text = HTMLTextExtractor.text(from: "<p>If a < b then something. \(body)</p>",
                                          limit: 4_000)
        XCTAssertTrue(text.contains("If a < b then something."))
    }

    /// A page cut off mid-argument that does not say so is one a model will treat as
    /// complete.
    func testTruncationIsMarked() {
        let html = "<p>" + String(repeating: "word ", count: 4_000) + "</p>"
        let text = HTMLTextExtractor.text(from: html, limit: 500, minimum: 0)
        XCTAssertLessThanOrEqual(text.count, 520)
        XCTAssertTrue(text.hasSuffix("[…]"))
    }

    /// Whatever came back was navigation, a consent wall, or a page that builds itself
    /// in JavaScript. Offering it as "the page" would be a lie with a label on it.
    func testAPageWithNoRealTextReadsAsNothing() {
        XCTAssertEqual(HTMLTextExtractor.text(from: "<html><body><div></div></body></html>"), "")
        XCTAssertEqual(HTMLTextExtractor.text(from: "<html><body><p>Enable JS</p></body></html>"), "")
    }

    // MARK: Fetchable addresses

    /// A redirect target came, ultimately, from a search result. Every hop is checked
    /// rather than trusted because the first one passed.
    func testOnlyAbsoluteHTTPAddressesAreFetchable() {
        XCTAssertNotNil(DirectPageReader.fetchableURL("https://example.com/a"))
        XCTAssertNotNil(DirectPageReader.fetchableURL("http://example.com/a"))
        XCTAssertNil(DirectPageReader.fetchableURL("file:///etc/passwd"))
        XCTAssertNil(DirectPageReader.fetchableURL("data:text/html,<p>x</p>"))
        XCTAssertNil(DirectPageReader.fetchableURL("/relative/path"))
        XCTAssertNil(DirectPageReader.fetchableURL(""))
    }

    // MARK: Address space

    /// The addresses a page on the public internet has no business redirecting to.
    /// `169.254.169.254` is in the list on its own account: it is the cloud metadata
    /// service, and the classic thing an SSRF is pointed at.
    func testAddressesInPrivateSpaceAreNotPubliclyRoutable() {
        for address in ["http://127.0.0.1/", "http://127.9.9.9/x", "http://localhost/",
                        "http://localhost:3000/notes", "http://api.localhost/",
                        "http://10.0.0.5/", "http://172.16.0.1/", "http://172.31.255.255/",
                        "http://192.168.1.1/admin", "http://169.254.169.254/latest/meta-data/",
                        "http://0.0.0.0/", "http://100.64.0.1/", "http://100.127.255.255/",
                        "http://255.255.255.255/", "http://239.0.0.1/",
                        "http://printer.local/admin", "http://host.localdomain/",
                        "http://[::1]/", "http://[fd00::1]/"] {
            guard let url = URL(string: address) else {
                XCTFail("\(address) did not parse as a URL at all")
                continue
            }
            XCTAssertFalse(DirectPageReader.isPubliclyRoutable(url), address)
        }
    }

    /// The other half of the rule, and the half a check like this usually gets wrong: an
    /// ordinary page must still be reachable, or every redirect in the world stops
    /// resolving and the reader quietly reads nothing.
    func testOrdinaryPublicAddressesStayRoutable() {
        for address in ["https://example.com/a", "https://www.example.co.uk/a",
                        "https://a-b.example.com/", "https://sub.domain.example.org/x?y=1",
                        "http://8.8.8.8/", "http://172.32.0.1/", "http://172.15.0.1/",
                        "http://100.63.0.1/", "http://100.128.0.1/",
                        "http://0day.example.com/", "http://9gag.com/",
                        "http://2024.example.com/", "http://[2606:4700::1111]/"] {
            guard let url = URL(string: address) else {
                XCTFail("\(address) did not parse as a URL at all")
                continue
            }
            XCTAssertTrue(DirectPageReader.isPubliclyRoutable(url), address)
        }
    }

    /// Every one of these names the loopback to a resolver while looking nothing like it
    /// to a checker that only knows dotted quads: `inet_aton` reads hexadecimal labels,
    /// octal labels, short forms and a bare integer, and `getaddrinfo` inherits all of
    /// it. They are refused for not being *provably* public rather than recognised one
    /// by one, which is the only version of this a new spelling cannot walk around.
    ///
    /// Asserted as "cannot be fetched" rather than "is not routable", because there are
    /// two ways to refuse an address and both are refusals: a form Foundation will not
    /// parse never becomes a URL, and one it does parse is classified. Pinning only the
    /// second would make the test vacuous on a platform whose parser is stricter, and
    /// pinning only the first would break on one whose parser is more lenient.
    func testTheSpellingsThatHideALoopbackCannotBeFetched() {
        var classified = 0
        for address in ["http://2130706433/", "http://0x7f000001/", "http://0177.0.0.1/",
                        "http://012.0.0.1/", "http://0x7f.1/", "http://0x7f.0x1/",
                        "http://0x7f.0.0.0x1/", "http://0177.0.0.0x1/", "http://127.1/",
                        "http://intranet/", "http://router/status"] {
            guard let url = DirectPageReader.fetchableURL(address) else { continue }
            classified += 1
            XCTAssertFalse(DirectPageReader.isPubliclyRoutable(url), address)
        }
        // Counted, because "every address was refused by the parser" and "the classifier
        // was never asked" look identical from a green test. A stricter parser is a fine
        // reason for a spelling to be skipped; it is not a reason for all of them to be.
        XCTAssertGreaterThan(classified, 0, "no spelling reached the classifier at all")
        // And not vacuously refusing everything: the same shape, with a name in it, is
        // still reachable.
        XCTAssertNotNil(DirectPageReader.fetchableURL("https://0x7f.example.com/"))
        XCTAssertTrue(DirectPageReader.isPubliclyRoutable(
            URL(string: "https://0x7f.example.com/")!))
    }

    /// The rule underneath those spellings, stated on its own so the reason survives:
    /// a label that is a number in a base a resolver reads is an address part, and a
    /// host made only of those is an address rather than a name. A label that merely
    /// *starts* with a digit is an ordinary name — `0day.com` and `9gag.com` are real
    /// domains, and refusing them would be the check breaking the product.
    func testNumericLabelsAreAddressPartsAndDigitsAloneAreNot() {
        for label in ["0", "12", "0177", "012", "255", "0x7f", "0X7F", "0xdeadbeef"] {
            XCTAssertTrue(DirectPageReader.isNumericAddressPart(label), label)
        }
        for label in ["", "0day", "9gag", "0x", "0xzz", "example", "a1", "1a", "1-2"] {
            XCTAssertFalse(DirectPageReader.isNumericAddressPart(label), label)
        }
    }

    /// The IPv6 literal forms, taken at the byte level so the answer does not depend on
    /// how a platform's `URL` chooses to hand back a host.
    func testIPv6LiteralsAreClassifiedByTheirBytes() {
        func isPublic(_ text: String) -> Bool? {
            DirectPageReader.ipv6Bytes(text).map(DirectPageReader.isPublicIPv6)
        }
        XCTAssertEqual(isPublic("::1"), false)                      // loopback
        XCTAssertEqual(isPublic("0:0:0:0:0:0:0:1"), false)          // the same, written out
        XCTAssertEqual(isPublic("::"), false)                       // unspecified
        XCTAssertEqual(isPublic("[::1]"), false)                    // brackets, as some hosts arrive
        XCTAssertEqual(isPublic("fc00::1"), false)                  // unique local
        XCTAssertEqual(isPublic("fd12:3456:789a::1"), false)
        XCTAssertEqual(isPublic("fe80::1"), false)                  // link-local
        XCTAssertEqual(isPublic("fe80::1%en0"), false)              // with a zone id
        XCTAssertEqual(isPublic("febf::1"), false)                  // the top of fe80::/10
        XCTAssertEqual(isPublic("ff02::1"), false)                  // multicast
        XCTAssertEqual(isPublic("::ffff:192.168.0.1"), false)       // v4-mapped, and private
        XCTAssertEqual(isPublic("::ffff:127.0.0.1"), false)
        // The same two addresses in hex groups. Pinned because the premise of this test
        // is that classification reads parsed bytes: a check that matched the `::ffff:`
        // and a dotted quad as *text* would let these through.
        XCTAssertEqual(isPublic("::ffff:7f00:1"), false)            // 127.0.0.1
        XCTAssertEqual(isPublic("::ffff:c0a8:1"), false)            // 192.168.0.1
        XCTAssertEqual(isPublic("::ffff:808:808"), true)            // 8.8.8.8
        // RFC 2765's v4-translated form puts the marker one group earlier, which is a
        // third spelling of "the address is in the last four bytes" — and was a fourth
        // case nobody had: it read as public while carrying 10.0.0.1.
        XCTAssertEqual(isPublic("::ffff:0:10.0.0.1"), false)
        XCTAssertEqual(isPublic("::ffff:0:169.254.169.254"), false)
        XCTAssertEqual(isPublic("::ffff:0:127.0.0.1"), false)
        XCTAssertEqual(isPublic("::ffff:0:8.8.8.8"), true)
        // And the deprecated v4-compatible form, which has no marker at all.
        XCTAssertEqual(isPublic("::10.0.0.1"), false)
        XCTAssertEqual(isPublic("2002:c0a8:0101::"), false)          // 6to4 around 192.168.1.1
        XCTAssertEqual(isPublic("2002:7f00:0001::"), false)          // 6to4 around 127.0.0.1
        XCTAssertEqual(isPublic("64:ff9b::192.168.1.1"), false)      // NAT64 around the same
        XCTAssertEqual(isPublic("2606:4700::1111"), true)
        XCTAssertEqual(isPublic("2002:0808:0808::"), true)           // 6to4 around 8.8.8.8
        XCTAssertEqual(isPublic("64:ff9b::8.8.8.8"), true)
        XCTAssertEqual(isPublic("fec0::1"), false)                  // site-local: deprecated, still private
        XCTAssertEqual(isPublic("::ffff:8.8.8.8"), true)
        XCTAssertNil(isPublic("not-an-address"))
        XCTAssertNil(isPublic("fe80::1::2"))                        // two gaps is not an address
        XCTAssertNil(isPublic("12345::1"))
    }

    /// A dotted quad is read only in the form it is written in. `0177.0.0.1` is the
    /// loopback to `inet_aton` and nothing at all to this, which is why the caller
    /// refuses what this cannot read rather than passing it on.
    func testOnlyCanonicalDottedQuadsParse() {
        XCTAssertEqual(DirectPageReader.ipv4Octets("192.168.0.1"), [192, 168, 0, 1])
        XCTAssertEqual(DirectPageReader.ipv4Octets("8.8.8.8"), [8, 8, 8, 8])
        XCTAssertNil(DirectPageReader.ipv4Octets("0177.0.0.1"))
        // The one that mattered: three digits fit the length bound, so without the
        // leading-zero rule this read as decimal 12 — a public address — while the
        // resolver reads octal 012 and lands on 10.0.0.1.
        XCTAssertNil(DirectPageReader.ipv4Octets("012.0.0.1"))
        XCTAssertNil(DirectPageReader.ipv4Octets("010.0.0.1"))
        XCTAssertEqual(DirectPageReader.ipv4Octets("0.0.0.0"), [0, 0, 0, 0])
        XCTAssertNil(DirectPageReader.ipv4Octets("256.1.1.1"))
        XCTAssertNil(DirectPageReader.ipv4Octets("1.2.3"))
        XCTAssertNil(DirectPageReader.ipv4Octets("1.2.3.4.5"))
        XCTAssertNil(DirectPageReader.ipv4Octets("1.2.3."))
        XCTAssertNil(DirectPageReader.ipv4Octets("١.٢.٣.٤"))  // Arabic-Indic digits are `isNumber`
    }

    /// A redirect is where an address the user never typed gets in, so this is the case
    /// the guard exists for: a page that won a search slot answering `302` with the
    /// user's own router. The request must never be *made* — a refusal after the fetch
    /// would have already probed the network.
    func testARedirectIntoPrivateSpaceIsNotFollowed() async {
        let stub = StubTransport { call in
            guard call.url.absoluteString == "https://public.example.com/a" else { return .unrouted }
            return .page(status: 302, headers: ["Location": "http://192.168.1.1/admin"], text: "")
        }
        let reader = DirectPageReader(trace: ResearchTrace(sink: SilentLog()), transport: stub)
        let source = Source(number: 1, url: "https://public.example.com/a", title: "T", snippet: "S")

        let pages = await reader.read([source])
        XCTAssertTrue(pages.isEmpty)
        XCTAssertEqual(stub.trail, ["fetch https://public.example.com/a"],
                       "the private hop was requested, which is the whole thing this stops")
    }

    /// The same refusal for a `Location` only a lenient parser reads as the loopback.
    /// A redirect target must go through the classifier rather than any earlier or
    /// cheaper check, or a hop written as `http://0x7f000001/` walks straight through
    /// a guard that only knows what `192.168.1.1` looks like.
    func testAnObfuscatedPrivateLocationIsAlsoRefused() async {
        let stub = StubTransport { call in
            guard call.url.absoluteString == "https://public.example.com/a" else { return .unrouted }
            return .page(status: 302, headers: ["Location": "http://0x7f000001/"], text: "")
        }
        let reader = DirectPageReader(trace: ResearchTrace(sink: SilentLog()), transport: stub)
        let source = Source(number: 1, url: "https://public.example.com/a", title: "T", snippet: "S")

        let pages = await reader.read([source])
        XCTAssertTrue(pages.isEmpty)
        XCTAssertEqual(stub.trail, ["fetch https://public.example.com/a"],
                       "only the public page may be fetched — a disguised loopback is "
                       + "still a loopback")
    }

    /// A `Location` need not carry a scheme — `//host/path` inherits the one it was
    /// served over, and plenty of sites send exactly that. The hop is therefore resolved
    /// against the page it came from *before* anything classifies it, and it is the
    /// resolved address that has to be refused. A guard that read the header instead of
    /// the merged URL would pass this one straight through.
    func testASchemeRelativePrivateLocationIsAlsoRefused() async {
        let stub = StubTransport { call in
            guard call.url.absoluteString == "https://public.example.com/a" else { return .unrouted }
            return .page(status: 302,
                         headers: ["Location": "//169.254.169.254/latest/meta-data/"],
                         text: "")
        }
        let reader = DirectPageReader(trace: ResearchTrace(sink: SilentLog()), transport: stub)
        let source = Source(number: 1, url: "https://public.example.com/a", title: "T", snippet: "S")

        let pages = await reader.read([source])
        XCTAssertTrue(pages.isEmpty)
        XCTAssertEqual(stub.trail, ["fetch https://public.example.com/a"],
                       "the cloud metadata address was requested")
    }

    /// The mirror of the refusal above, and the half a guard like this usually gets
    /// wrong: a scheme-relative hop to a *public* host is still followed. Refusing the
    /// form rather than the address would break one of the most common redirect shapes
    /// on the web, and would do it silently.
    func testASchemeRelativePublicLocationIsStillFollowed() async {
        let stub = StubTransport { call in
            switch call.url.absoluteString {
            case "https://public.example.com/a":
                return .page(status: 302, headers: ["Location": "//other.example.com/b"],
                             text: "")
            case "https://other.example.com/b":
                return .html("<p>Behind a scheme-relative hop.</p>")
            default:
                return .unrouted
            }
        }
        let reader = DirectPageReader(trace: ResearchTrace(sink: SilentLog()), transport: stub)
        let source = Source(number: 1, url: "https://public.example.com/a", title: "T", snippet: "S")

        let pages = await reader.read([source])
        XCTAssertTrue(pages[1]?.contains("Behind a scheme-relative hop.") ?? false,
                      "a scheme-relative hop to a public host stopped being followed")
    }

    /// And the same refusal one hop later, because a chain that starts public must stay
    /// public for its whole length rather than only across its first hop.
    func testAPublicChainCannotTurnPrivateOnItsSecondHop() async {
        let stub = StubTransport { call in
            switch call.url.absoluteString {
            case "https://public.example.com/a":
                return .page(status: 301, headers: ["Location": "https://public.example.com/b"],
                             text: "")
            case "https://public.example.com/b":
                return .page(status: 302, headers: ["Location": "http://127.0.0.1:8080/"], text: "")
            default:
                return .unrouted
            }
        }
        let reader = DirectPageReader(trace: ResearchTrace(sink: SilentLog()), transport: stub)
        let source = Source(number: 1, url: "https://public.example.com/a", title: "T", snippet: "S")

        let pages = await reader.read([source])
        XCTAssertTrue(pages.isEmpty)
        XCTAssertEqual(stub.trail, ["fetch https://public.example.com/a",
                                    "fetch https://public.example.com/b"])
    }

    /// The address the *user* typed is a different thing, and the reason the rule is
    /// about the chain rather than about the hop: a pasted `http://localhost:3000` is a
    /// page they asked for, and a local dev server that redirects to itself must still
    /// be read. Nothing else reaches the reader pointing at private space — the runner
    /// drops the search results that do.
    ///
    /// That allowance rests on Vervellum being the user's own program on the user's own
    /// machine: "their network" and "this process's network" are the same network. A
    /// build that ever fetched pages from a server would have to drop it, because there
    /// the pasted address would name the *server's* loopback, which is the textbook
    /// shape of the thing this file otherwise refuses.
    func testAPastedPrivateAddressMayRedirectWithinPrivateSpace() async {
        let stub = StubTransport { call in
            switch call.url.absoluteString {
            case "http://localhost:3000/notes":
                return .page(status: 302, headers: ["Location": "http://127.0.0.1:3000/notes/"],
                             text: "")
            case "http://127.0.0.1:3000/notes/":
                return .html("<p>The note the user asked about.</p>")
            default:
                return .unrouted
            }
        }
        let reader = DirectPageReader(trace: ResearchTrace(sink: SilentLog()), transport: stub)
        let source = Source(number: 1, url: "http://localhost:3000/notes", title: "T", snippet: "S")

        let pages = await reader.read([source])
        XCTAssertTrue(pages[1]?.contains("The note the user asked about.") ?? false,
                      "a pasted local address stopped being readable")
    }

    /// The other direction of the same chain, pinned because it was unstated: a local
    /// page that redirects out to a public one is followed. There is nothing to protect
    /// against — the user asked for the chain, and its target is a public page like any
    /// other — and the rule is "a chain that started public may not turn private", not
    /// "a chain may not change".
    func testAPastedPrivateAddressMayRedirectOutToAPublicPage() async {
        let stub = StubTransport { call in
            switch call.url.absoluteString {
            case "http://localhost:3000/docs":
                return .page(status: 302, headers: ["Location": "https://example.com/docs"],
                             text: "")
            case "https://example.com/docs":
                return .html("<p>The upstream documentation.</p>")
            default:
                return .unrouted
            }
        }
        let reader = DirectPageReader(trace: ResearchTrace(sink: SilentLog()), transport: stub)
        let source = Source(number: 1, url: "http://localhost:3000/docs", title: "T", snippet: "S")

        let pages = await reader.read([source])
        XCTAssertTrue(pages[1]?.contains("The upstream documentation.") ?? false)
    }

    /// The ordinary redirect the reader exists to follow, kept as a test of its own so
    /// that a change to the guard cannot break `http → https` without saying so.
    func testAnOrdinaryRedirectIsStillFollowed() async {
        let stub = StubTransport { call in
            switch call.url.absoluteString {
            case "http://example.com/a":
                return .page(status: 301, headers: ["Location": "https://www.example.com/a"],
                             text: "")
            case "https://www.example.com/a":
                return .html("<p>The page behind two hops.</p>")
            default:
                return .unrouted
            }
        }
        let reader = DirectPageReader(trace: ResearchTrace(sink: SilentLog()), transport: stub)
        let source = Source(number: 1, url: "http://example.com/a", title: "T", snippet: "S")

        let pages = await reader.read([source])
        XCTAssertTrue(pages[1]?.contains("The page behind two hops.") ?? false)
    }

    /// A page in an encoding nobody declared is read with mojibake in the accents
    /// rather than dropped entirely.
    func testDecodingFallsBackRatherThanFailing() {
        let latin1 = Data([0x3C, 0x70, 0x3E, 0xE9, 0x3C, 0x2F, 0x70, 0x3E]) // <p>é</p> in Latin-1
        XCTAssertNotNil(DirectPageReader.decode(latin1, contentType: "text/html; charset=iso-8859-1"))
        XCTAssertNotNil(DirectPageReader.decode(latin1, contentType: "text/html"))
        XCTAssertEqual(DirectPageReader.decode(Data("<p>ok</p>".utf8), contentType: "text/html"),
                       "<p>ok</p>")
    }

    // MARK: The reader server's reply

    /// The published documentation names the endpoint and the tool but not the argument
    /// schema, so the argument the URL goes in is read from what the server advertised.
    func testTheURLArgumentComesFromTheAdvertisedSchema() {
        XCTAssertEqual(ReaderMCPClient.urlArgument(in: [
            "properties": ["uri": ["type": "string"]], "required": ["uri"],
        ]), "uri")
        XCTAssertEqual(ReaderMCPClient.urlArgument(in: [
            "properties": ["page_url": ["type": "string"], "format": ["type": "string"]],
        ]), "page_url")
        // A reader with exactly one required argument has told us what it is, even
        // spelled unusually.
        XCTAssertEqual(ReaderMCPClient.urlArgument(in: ["required": ["address"]]), "address")
        // No schema at all: the documented spelling is the last resort.
        XCTAssertEqual(ReaderMCPClient.urlArgument(in: [:]), "url")
    }

    func testTheReaderToolIsResolvedByKnownNameOnly() {
        let listing: [[String: Any]] = [
            ["name": "delete_page"],
            ["name": "webReader", "inputSchema": ["required": ["url"]]],
        ]
        XCTAssertEqual(ReaderMCPClient.resolveReaderTool(from: listing),
                       ReaderMCPClient.ReaderTool(name: "webReader", urlArgument: "url"))
        XCTAssertNil(ReaderMCPClient.resolveReaderTool(from: [["name": "do_something"]]))
    }

    /// The standard MCP envelope splits one document across several text blocks, so the
    /// blocks are joined rather than the biggest one taken.
    func testTheStandardContentEnvelopeIsJoined() {
        let body = String(repeating: "Sentence of the page. ", count: 8)
        let result: [String: Any] = ["content": [
            ["type": "text", "text": "First half. " + body],
            ["type": "text", "text": "Second half. " + body],
        ]]
        let text = ReaderMCPClient.pageText(from: result)
        XCTAssertTrue(text.contains("First half."))
        XCTAssertTrue(text.contains("Second half."))
    }

    /// A reader returns a title, a description *and* the article under content-shaped
    /// keys; only one of them is the page.
    func testTheLongestContentFieldWins() {
        let article = String(repeating: "The article itself. ", count: 20)
        let result: [String: Any] = ["structuredContent": [
            "title": "Short", "text": "A one-line description.", "content": article,
        ]]
        XCTAssertTrue(ReaderMCPClient.pageText(from: result).contains("The article itself."))
    }

    /// A long URL sitting beside a short article must not win: only content-shaped keys
    /// are candidates.
    func testAMetadataStringIsNotMistakenForThePage() {
        let article = String(repeating: "Body sentence. ", count: 10)
        let result: [String: Any] = [
            "url": "https://example.com/" + String(repeating: "x", count: 4_000),
            "content": article,
        ]
        let text = ReaderMCPClient.pageText(from: result)
        XCTAssertTrue(text.contains("Body sentence."))
        XCTAssertFalse(text.contains("xxxx"))
    }

    /// A reader that returns markup is common, and markup in the evidence block is
    /// worse than useless.
    func testMarkupFromAReaderIsRead() {
        let body = String(repeating: "<p>A real sentence.</p>", count: 10)
        let result: [String: Any] = ["content": "<html><body>\(body)</body></html>"]
        let text = ReaderMCPClient.pageText(from: result)
        XCTAssertTrue(text.contains("A real sentence."))
        XCTAssertFalse(text.contains("<p>"))
    }

    // MARK: Settings

    /// Off is off: no reader is built, so nothing is fetched.
    func testNoReaderIsBuiltWhenReadingIsOff() throws {
        var settings = ProviderSettings(modelEndpoint: "https://a.example.com/v1", modelName: "m")
        settings.pageReading = .off
        XCTAssertNil(try PageReaderFactory.make(settings: settings, readerKey: nil,
                                                trace: ResearchTrace(sink: SilentLog())))
    }

    func testTheFactoryBuildsTheReaderTheSettingsName() throws {
        var settings = ProviderSettings(modelEndpoint: "https://a.example.com/v1", modelName: "m")
        let trace = ResearchTrace(sink: SilentLog())

        settings.pageReading = .direct
        let direct = try PageReaderFactory.make(settings: settings, readerKey: nil, trace: trace)
        XCTAssertNotNil(direct as? DirectPageReader)

        settings.pageReading = .reader
        let hosted = try PageReaderFactory.make(settings: settings, readerKey: "k", trace: trace)
        XCTAssertNotNil(hosted as? ReaderMCPClient)
        XCTAssertThrowsError(try PageReaderFactory.make(settings: settings, readerKey: nil,
                                                        trace: ResearchTrace(sink: SilentLog())),
                             "A hosted reader with no key is a configuration problem, not a fetch")
    }

    /// A source is "read" only when the answer could have used the page — which is why
    /// the runner clears the text rather than keeping it for the record.
    func testASourceIsOnlyReadWhenItCarriesText() {
        var source = Source(number: 1, url: "https://a.example.com", title: "T", snippet: "S")
        XCTAssertFalse(source.wasRead)
        source.fullText = ""
        XCTAssertFalse(source.wasRead)
        source.fullText = "The page."
        XCTAssertTrue(source.wasRead)
    }
}
