import Foundation

/// Reads the pages behind a turn's sources, so the answer can rest on what a page says
/// rather than on a search engine's summary of it.
///
/// This is the one place in Vervellum where the honesty of the whole product is at
/// stake in a subtle way. A search snippet is a *summary*, and the prompts have always
/// said so: never claim to have read a page, never quote from a snippet. Reading the
/// page changes what is true — but only for the pages that were actually read, and only
/// for as much of each as was retrieved. So a reader returns text **per source**, the
/// runner attaches it only where it exists, and every layer downstream — the evidence
/// block, the source list, the process trail — distinguishes a source that was read
/// from one that was not. A source that is *shown* as read but whose text did not fit
/// the model's context would be exactly the lie this app exists to avoid.
///
/// Reading is best-effort by construction. `read` does not throw: a page behind a
/// consent wall, a 404, a PDF, a site that builds itself in JavaScript, a timeout —
/// none of those is a failure of the research turn, they are simply a source that keeps
/// its snippet. Failing the turn over a page that could not be fetched would trade a
/// good answer for no answer.
protocol PageReading: AnyObject {

    /// A name for the log and for user-facing prose. Never a provider's own text.
    var readerName: String { get }

    /// Establishes whatever the reader needs — a protocol handshake, a key check.
    /// Throwing here disables reading for the turn; it never fails the turn.
    func connect() async throws

    /// Reads what it can, returning page text keyed by `Source.number`. A source that
    /// could not be read is simply absent from the result.
    func read(_ sources: [Source]) async -> [Int: String]
}

/// Builds the reader a `ProviderSettings` describes, or nil when reading is off.
enum PageReaderFactory {

    /// The most pages one turn reads.
    ///
    /// Three, because that is where the returns fall off from both directions at once:
    /// the top few results are the ones an answer actually cites, each page costs a
    /// request and several thousand characters of the evidence budget, and a fourth
    /// page usually pushes the third one's text back out of context again.
    static let maxPages = 3

    /// The most pages a `deep` turn reads, across the question's links, the pages the
    /// follow-up rounds ask for by number, and the final fill.
    ///
    /// Eight, sized against the two budgets it spends. A page is capped at 8,000
    /// extracted characters (`HTMLTextExtractor.maxCharacters`), so eight pages are
    /// ~64K characters — inside the deep evidence budget with room for the snippets
    /// around them, and roughly twice what a quick turn reads, which is the least the
    /// word "deep" can honestly mean when every comparable tool reads an order of
    /// magnitude more. The rounds spend the allowance early, on pages the planner
    /// judged decisive; the final fill backstops what they did not name.
    static let maxDeepPages = 8

    static func make(settings: ProviderSettings,
                     readerKey: String?,
                     trace: ResearchTrace,
                     transport: any HTTPTransporting = HTTPTransport.shared) throws -> PageReading? {
        switch settings.pageReading {
        case .off:
            return nil
        case .direct:
            return DirectPageReader(trace: trace, transport: transport)
        case .reader:
            guard let url = ProviderSettings.validatedEndpointURL(settings.readerEndpoint) else {
                throw ResearchError("The page-reader endpoint is not a usable URL.")
            }
            guard let readerKey, !readerKey.isEmpty else {
                throw ResearchError("The page-reader key is missing.")
            }
            return ReaderMCPClient(endpoint: url, apiKey: readerKey, trace: trace, transport: transport)
        }
    }
}

/// Fetches each page itself and extracts its text.
///
/// **This is the only code in Vervellum that makes a request to a host the user did not
/// configure.** Everything else talks to the model provider, the search provider and
/// GitHub. The pages come from search results, so the sites learn the user's IP address
/// — which is why page reading is a setting with three states rather than a silent
/// improvement, and why `PRIVACY.md` says so in as many words.
///
/// Three rules follow from fetching arbitrary URLs:
///
/// * **No credentials, ever.** These requests carry no `Authorization` header, no
///   cookies (the shared session is configured never to store or send them) and no
///   `Referer`. There is nothing to leak to a host that redirects.
/// * **Redirects are re-issued, not followed.** `HTTPTransport` still refuses every
///   automatic redirect, because `URLSession` would re-send headers to the new host.
///   This reader instead reads the `Location` and starts a *fresh* request — which
///   preserves the rule's actual reason (a credential must never reach a host the user
///   did not configure) while letting `http → https` and `example.com → www.example.com`
///   resolve, which a large share of real links need. Two hops, http(s) only.
/// * **A redirect may not cross into private address space.** A page that won a search
///   slot answering `302 http://192.168.1.1/admin` would otherwise make the reader
///   probe the user's own network and send back what it found as evidence. So a chain
///   that started on a public address must stay on one; a chain the *user* started on a
///   private address — a pasted `http://localhost:3000` — is theirs to make, and is the
///   only way the reader ever reaches one. See `isPubliclyRoutable(_:)`.
/// * **Only text is read.** A PDF, an image or a video is skipped on its content type
///   rather than fetched and discarded, and the body is capped well below the
///   transport's own limit.
final class DirectPageReader: PageReading {

    /// Hard ceiling on one page's bytes. A long article is well under this; anything
    /// above it is an application, not a document.
    static let maxPageBytes = 800_000
    /// Redirect hops. Two covers `http → https → www`; more is a chain that is trying
    /// to do something other than canonicalise.
    static let maxRedirects = 2
    /// How long one page may take. Short on purpose: a slow page must not add to the
    /// wall-clock of a turn that already has an answer to write, and the cost of
    /// giving up is a source that keeps its snippet.
    static let perPageTimeout: TimeInterval = 12

    let readerName = "direct fetch"

    private let trace: ResearchTrace
    private let transport: any HTTPTransporting

    init(trace: ResearchTrace, transport: any HTTPTransporting = HTTPTransport.shared) {
        self.trace = trace
        self.transport = transport
    }

    /// Nothing to establish: there is no service and no key.
    func connect() async throws {}

    /// Fetches the pages concurrently.
    ///
    /// Concurrently because these are unrelated hosts and the alternative is three
    /// round trips in series in the middle of a turn the user is watching. The MCP
    /// reader cannot do this — one session, one id sequence — which is why the batch is
    /// the protocol's unit rather than the single page.
    func read(_ sources: [Source]) async -> [Int: String] {
        await withTaskGroup(of: (Int, String).self) { group in
            for source in sources {
                let number = source.number
                let url = source.url
                group.addTask { [weak self] in
                    guard let self else { return (number, "") }
                    return (number, await self.text(at: url))
                }
            }
            var pages: [Int: String] = [:]
            for await (number, text) in group where !text.isEmpty {
                pages[number] = text
            }
            return pages
        }
    }

    /// One page's text, or an empty string for anything that could not be read.
    private func text(at address: String) async -> String {
        var target = address
        let started = ProcessInfo.processInfo.systemUptime
        // Decided once, from the address this chain started on, because it is a fact
        // about *provenance*: only a URL the user's own question carried reaches here
        // pointing into private space (the runner drops the search results that do), and
        // a redirect must not be able to manufacture what the question did not ask for.
        let startedPrivate = Self.fetchableURL(address).map { !Self.isPubliclyRoutable($0) } ?? false
        for hop in 0...Self.maxRedirects {
            guard let url = Self.fetchableURL(target) else { return "" }
            do {
                // Redirects share the page's budget rather than starting a fresh clock.
                let remaining = Self.perPageTimeout - (ProcessInfo.processInfo.systemUptime - started)
                guard remaining > 0 else { return "" }
                var request = HTTPTransport.getRequest(url: url, timeout: remaining)
                // A page is a document, not an API. Some sites answer a request that
                // only accepts JSON with a 406.
                request.setValue("text/html,text/plain;q=0.9,*/*;q=0.1",
                                 forHTTPHeaderField: "Accept")
                let (response, data) = try await transport.fetch(
                    request, limit: Self.maxPageBytes, deadline: remaining)

                if (300..<400).contains(response.statusCode) {
                    guard hop < Self.maxRedirects,
                          let location = response.value(forHTTPHeaderField: "Location"),
                          let resolved = URL(string: location, relativeTo: url)?.absoluteString,
                          let next = Self.fetchableURL(resolved)
                    else { return "" }
                    guard startedPrivate || Self.isPubliclyRoutable(next) else {
                        // No address in the log: the hop is a host the user did not
                        // choose, and where their network answers is their business.
                        trace.log("Page read stopped: redirect into a private address")
                        return ""
                    }
                    target = next.absoluteString
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    // Only the status reaches the log. A page's own error body is
                    // untrusted content and a URL can carry a token in its query.
                    trace.log("Page read skipped: HTTP \(response.statusCode)")
                    return ""
                }
                let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                guard contentType.isEmpty || contentType.contains("text/") || contentType.contains("xml")
                else {
                    trace.log("Page read skipped: not a text document")
                    return ""
                }
                guard let html = Self.decode(data, contentType: contentType) else { return "" }
                return HTMLTextExtractor.text(from: html)
            } catch {
                // A page that will not load is a source that keeps its snippet. The
                // error is a type name only: a provider's text is never logged.
                trace.log("Page read failed: \(ResearchError.safeLabel(for: error))")
                return ""
            }
        }
        return ""
    }

    /// The URL to fetch, or nil for anything that is not an absolute http(s) address.
    ///
    /// A redirect target is attacker-influenced in the general case — the link came
    /// from a search result — so every hop is re-checked rather than trusted because
    /// the first one passed. `file:` and `data:` are the reason this is not a
    /// convenience.
    static func fetchableURL(_ raw: String) -> URL? {
        guard let normalized = SourceHarvester.normalized(raw, trimmingPunctuation: false),
              let url = URL(string: normalized) else { return nil }
        return url
    }

    // MARK: Address space

    /// Whether a URL's host is provably in public address space.
    ///
    /// False for the case this exists to stop — a literal inside a range that belongs to
    /// the machine or the network around it: loopback, link-local, the RFC 1918 blocks,
    /// carrier-grade NAT, multicast, the unspecified address. And false, too, for any
    /// host it cannot read as either an ordinary name or a public literal: a decimal or
    /// hexadecimal integer (`http://2130706433/`), an octal-looking quad
    /// (`http://0177.0.0.1/`), a single label with no dot, anything malformed. Those
    /// forms exist in the wild almost exclusively as ways of writing `127.0.0.1` that a
    /// checker will not recognise, so the answer to one is "not provably public" rather
    /// than a guess at what a resolver would make of it. The cost of refusing is a
    /// redirect chain the reader gives up on, which is a source that keeps its snippet.
    ///
    /// **Known gap, deliberately left.** This reads the address the URL *states*, not
    /// the address the request reaches. A hostname that resolves into private space —
    /// an internal name on the user's own network, or a DNS answer that changes between
    /// this check and the connection — passes, because the name is resolved inside
    /// `URLSession` where this code cannot see it and cannot bind the answer to the
    /// socket that follows. Closing that needs a custom connection path, and is a
    /// different piece of work; a check that looked like it closed it would be worse
    /// than one that says plainly where it stops.
    static func isPubliclyRoutable(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        // The reserved loopback names, which resolve to 127.0.0.1 by definition
        // (RFC 6761) and so are decidable here without asking anyone.
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        // `.local` is reserved to mDNS (RFC 6762) and `.localdomain` is the same idea by
        // convention — the default a machine gives itself in `/etc/hosts`. Neither ever
        // resolves off the network it is on, so both are decidable here exactly as
        // `localhost` is, and a redirect to `http://printer.local/admin` is refused
        // without anyone having to resolve anything. A `.local` address the user pasted
        // is unaffected: this same function decides `startedPrivate`, so their chain
        // begins private and stays free to move within it.
        if host.hasSuffix(".local") || host.hasSuffix(".localdomain") { return false }
        // A colon at this point is an IPv6 literal: `URL.host` has already taken the
        // port off, and strips the brackets on Darwin but not everywhere.
        if host.contains(":") {
            guard let bytes = ipv6Bytes(host) else { return false }
            return isPublicIPv6(bytes)
        }
        if let octets = ipv4Octets(host) { return isPublicIPv4(octets) }
        // What is left is either a name or an address written in one of the forms
        // `inet_aton` accepts and `inet_pton` does not — `0x7f.0.0.0x1`, `0177.0.0.1`,
        // `2130706433`, `127.1`. A host whose every label is a number in one of those
        // bases is one of those addresses rather than a name: no registry sells a domain
        // made only of numeric labels, and the resolver reads the whole family as an
        // address while a dotted-quad parser sees nothing it recognises. Refusing the
        // shape rather than the spellings is what stops the next spelling.
        if host.components(separatedBy: ".").allSatisfy({ Self.isNumericAddressPart($0) }) {
            return false
        }
        return isOrdinaryHostname(host)
    }

    /// Whether one dot-label is a number in a base a resolver reads: decimal, `0x`
    /// hexadecimal, or the leading-zero octal that `012` means to `inet_aton`.
    static func isNumericAddressPart(_ label: String) -> Bool {
        guard !label.isEmpty else { return false }
        let lowered = label.lowercased()
        if lowered.hasPrefix("0x") {
            let digits = lowered.dropFirst(2)
            return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isHexDigit }
        }
        return lowered.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A host that looks like a DNS name a public resolver would answer: two or more
    /// labels of letters, digits and hyphens, none of them empty or hyphen-edged, and a
    /// last label that is not all digits — which is what a dotted address that got this
    /// far (`0177.0.0.1`, `0x7f.1`) ends in.
    ///
    /// Unicode-tolerant on purpose: `URL` does not normalise an internationalised host
    /// to punycode on every platform, and refusing a redirect to a real domain because
    /// it is written in its own script would be a bug wearing a security hat.
    static func isOrdinaryHostname(_ host: String) -> Bool {
        var name = host
        if name.hasSuffix(".") { name.removeLast() }   // an FQDN's trailing root label
        let labels = name.components(separatedBy: ".")
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
            else { return false }
        }
        // Unicode-aware here while `isNumericAddressPart` is ASCII-only, and the
        // asymmetry is load-bearing rather than an oversight: `127.０.０.１` in fullwidth
        // digits fails the ASCII numeric check above, and this is what then refuses it,
        // because fullwidth digits are still `isNumber`. Tighten this to `isASCII` and
        // that host comes back a "name" — which a resolver applying IDNA mapping would
        // then read as the loopback.
        return !(labels.last?.allSatisfy(\.isNumber) ?? true)
    }

    /// The four octets of a canonical dotted quad, or nil for anything else — including
    /// the octal and short forms a resolver accepts, which is the point: this says yes
    /// only to an address it can read exactly, and `isPubliclyRoutable` refuses the rest.
    ///
    /// A leading zero is the reason for the third guard, and it is not pedantry: `012`
    /// is decimal 12 to `UInt8` and octal 10 to `inet_aton`, so `012.0.0.1` would be
    /// read here as a public address and by the resolver as `10.0.0.1`. Refusing it
    /// hands it to the numeric-label rule above, which reads it as the address it is.
    static func ipv4Octets(_ text: String) -> [UInt8]? {
        let fields = text.components(separatedBy: ".")
        guard fields.count == 4 else { return nil }
        var octets: [UInt8] = []
        for field in fields {
            guard (1...3).contains(field.count),
                  field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  field == "0" || !field.hasPrefix("0"),
                  let value = UInt8(field)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// The sixteen bytes of an IPv6 literal, or nil if the text is not one.
    ///
    /// Hand-rolled because `inet_pton` lives in a platform module and nothing under
    /// `Core/` may import one.
    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var body = text
        if body.hasPrefix("["), body.hasSuffix("]") { body = String(body.dropFirst().dropLast()) }
        // A zone id names an interface on this machine. A zone can ride on more than a
        // link-local address (RFC 4007), so the `%` decides nothing: it is stripped and
        // the address in front of it is judged on its bytes like any other.
        if let zone = body.firstIndex(of: "%") { body = String(body[..<zone]) }
        guard body.contains(":") else { return nil }

        // At most one `::`, which stands for the run of zero groups.
        let halves = body.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func bytes(of groups: String) -> [UInt8]? {
            guard !groups.isEmpty else { return [] }
            var result: [UInt8] = []
            let fields = groups.components(separatedBy: ":")
            for (index, field) in fields.enumerated() {
                // The last group may be a dotted tail: `::ffff:192.168.0.1`.
                if index == fields.count - 1, field.contains(".") {
                    guard let octets = ipv4Octets(field) else { return nil }
                    result.append(contentsOf: octets)
                    continue
                }
                guard (1...4).contains(field.count),
                      field.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                      let value = UInt16(field, radix: 16)
                else { return nil }
                result.append(UInt8(truncatingIfNeeded: value >> 8))
                result.append(UInt8(truncatingIfNeeded: value))
            }
            return result
        }

        guard let head = bytes(of: halves[0]) else { return nil }
        guard halves.count == 2 else { return head.count == 16 ? head : nil }
        guard let tail = bytes(of: halves[1]), head.count + tail.count <= 16 else { return nil }
        return head + Array(repeating: 0, count: 16 - head.count - tail.count) + tail
    }

    /// Whether a dotted quad is in space a page on the public internet could legitimately
    /// redirect to. Everything reserved for the machine, the local network or the carrier
    /// in between is out, and so is multicast and the rest of the top of the range.
    static func isPublicIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (0, _):            return false   // "this network" — 0.0.0.0 is the local host
        case (10, _):           return false   // RFC 1918
        case (100, 64...127):   return false   // RFC 6598 carrier-grade NAT
        case (127, _):          return false   // loopback
        case (169, 254):        return false   // link-local, and the cloud metadata address
        case (172, 16...31):    return false   // RFC 1918
        case (192, 168):        return false   // RFC 1918
        case (224...255, _):    return false   // multicast, reserved, broadcast
        default:                return true
        }
    }

    /// The same question for IPv6, with one rule doing most of the work: **an address
    /// that carries an IPv4 destination inside it is decided by that destination.**
    /// Writing `192.168.1.1` inside an IPv6 literal has to mean what writing it plainly
    /// means, in every spelling that does so: the v4-mapped `::ffff:a.b.c.d`, the
    /// deprecated v4-compatible `::a.b.c.d`, the RFC 2765 v4-translated
    /// `::ffff:0:a.b.c.d`, `2002::/16` (6to4, where the relay encapsulates to the
    /// embedded address) and `64:ff9b::/96` (the prefix a NAT64 network translates).
    ///
    /// Teredo (`2001:0::/32`) is not on that list deliberately: the IPv4 addresses it
    /// embeds are the relay's and the client's own, not a destination inside the user's
    /// network, so there is nothing there to decide.
    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // Eight zero bytes and then a marker: `0000 0000` is the v4-compatible form,
        // `0000 ffff` the v4-mapped one, and `ffff 0000` the v4-translated one — three
        // spellings of "the address is in the last four bytes". Stated as one rule
        // rather than three branches, because the rule is what has to hold: the
        // translated form was written as a fourth case nobody had, and it read as public
        // while carrying `10.0.0.1`.
        if bytes[0..<8].allSatisfy({ $0 == 0 }) {
            let marker = Array(bytes[8..<12])
            if marker == [0, 0, 0, 0] || marker == [0, 0, 0xff, 0xff]
                || marker == [0xff, 0xff, 0, 0] {
                // `::` and `::1` land here too, and fail on their first octet being zero.
                return isPublicIPv4(Array(bytes[12..<16]))
            }
        }
        // 6to4 keeps the address in the second and third groups: `2002:c0a8:0101::`.
        if bytes[0] == 0x20, bytes[1] == 0x02 { return isPublicIPv4(Array(bytes[2..<6])) }
        // NAT64 keeps it where a mapped address keeps it, at the end. Matched on the
        // /32 rather than only the well-known /96 on purpose: a network doing local
        // translation puts real IPv4 destinations under `64:ff9b:1::/48` too, and
        // requiring the middle bytes to be zero would let those through as public.
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b {
            return isPublicIPv4(Array(bytes[12..<16]))
        }
        if bytes[0] & 0xfe == 0xfc { return false }        // fc00::/7  unique local
        if bytes[0] == 0xfe, bytes[1] >= 0x80 { return false }  // fe80::/9: link-local, and the
                                                                // deprecated site-local above it
        if bytes[0] == 0xff { return false }               // ff00::/8  multicast
        return true
    }

    /// Decodes a page's bytes, honouring the charset the response declared.
    ///
    /// The declaration is acted on where it is decisive. BOM-less UTF-16 whose text
    /// is pure ASCII is valid UTF-8 — one byte in two is NUL — so a UTF-8-first
    /// decode reads it as a NUL-filled string (accented UTF-16 is rejected by a
    /// strict UTF-8 decode); an explicit little- or big-endian declaration is
    /// honoured before the generic fallback. For the single-byte charsets the order is the
    /// other way: a server that labels UTF-8 as ISO-8859-1 or Windows-1252 is common
    /// enough that a strict UTF-8 decode wins, and a genuine Windows-1252 page is not
    /// valid UTF-8, so it falls through to the declared codec. The `iso-8859-1` and
    /// `latin1` labels are decoded as Windows-1252 as well, because that is what the
    /// WHATWG Encoding Standard — and every browser — does with those labels; the
    /// codecs agree outside `0x80...0x9F`, where a real page carries the euro and the
    /// smart quotes rather than C1 controls. Latin-1 is the last resort — for a page
    /// that declared nothing, or whose declared codec failed — because it cannot fail.
    static func decode(_ data: Data, contentType: String) -> String? {
        let text: String?
        // WHATWG sniffs a byte-order mark ahead of any declared charset: a body
        // that begins FF FE / FE FF is UTF-16LE/BE whatever the Content-Type says.
        if data.count >= 2,
           (data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xFE)
            || (data[data.startIndex] == 0xFE && data[data.startIndex + 1] == 0xFF) {
            // `utf16` honours the BOM itself, so the default is never used.
            text = Self.utf16(data, defaultingTo: .little)
        } else {
            switch declaredEncoding(contentType) {
            case .utf16LittleEndian:
                text = Self.utf16(data, defaultingTo: .little)
            case .utf16BigEndian:
                text = Self.utf16(data, defaultingTo: .big)
            case .utf16:
                // WHATWG maps the bare `utf-16` label to little-endian (RFC 2781 would
                // default to big-endian; browsers do not). A byte-order mark still wins.
                text = Self.utf16(data, defaultingTo: .little)
            case .utf8:
                text = String(data: data, encoding: .utf8)
            case .windowsCP1252:
                text = String(data: data, encoding: .utf8) ?? Self.windowsCP1252(data)
            case .isoLatin1:
                // The label is decoded as Windows-1252, per WHATWG; see the type comment.
                text = String(data: data, encoding: .utf8) ?? Self.windowsCP1252(data)
            case nil:
                text = String(data: data, encoding: .utf8)
            }
        }
        guard let text else { return String(data: data, encoding: .isoLatin1) }
        // An explicit UTF-16 codec keeps a byte-order mark as U+FEFF; the extractor
        // and the model do not want a zero-width character at the top of the page.
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Which endianness a UTF-16 body decodes as when it carries no byte-order mark.
    private enum UTF16Endianness {
        case little
        case big
    }

    /// Decodes a UTF-16 body, honouring a byte-order mark and otherwise using
    /// `defaultingTo`.
    ///
    /// Foundation's `.utf16` is deliberately not used for a BOM-less body: Darwin
    /// answers nil, swift-corelibs-foundation assumes big-endian, and neither is a
    /// contract. Decoding the code units directly makes the result the same on both
    /// platforms, and a BOM — which the explicit codecs would keep as U+FEFF — is
    /// consumed here.
    ///
    /// An invalid code unit — an unpaired surrogate or a dangling trailing byte — is
    /// replaced with U+FFFD rather than failing the whole body, the way WHATWG's
    /// decoder and every browser behave: one corrupt byte should not cost the reader
    /// the page.
    private static func utf16(_ data: Data, defaultingTo endianness: UTF16Endianness) -> String {
        let effective: UTF16Endianness
        let body: Data
        if data.count >= 2 {
            let first = data[data.startIndex], second = data[data.startIndex + 1]
            if first == 0xFF, second == 0xFE {
                effective = .little
                body = Data(data.dropFirst(2))
            } else if first == 0xFE, second == 0xFF {
                effective = .big
                body = Data(data.dropFirst(2))
            } else {
                effective = endianness
                body = data
            }
        } else {
            effective = endianness
            body = data
        }

        func unit(at index: Data.Index) -> UInt16? {
            guard let next = body.index(index, offsetBy: 1, limitedBy: body.endIndex),
                  next < body.endIndex else { return nil }
            let first = UInt16(body[index]), second = UInt16(body[next])
            return effective == .little ? first | (second << 8) : second | (first << 8)
        }

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(body.count / 2)
        var index = body.startIndex
        while index < body.endIndex {
            guard let leading = unit(at: index) else {
                scalars.append("\u{FFFD}")          // a dangling trailing byte
                break
            }
            index = body.index(index, offsetBy: 2)
            if let scalar = Unicode.Scalar(leading) {
                scalars.append(scalar)
                continue
            }
            // A high surrogate must be followed by a low one. Anything else is
            // replaced, and the surrogate itself is consumed either way.
            if (0xD800...0xDBFF).contains(leading),
               index < body.endIndex,
               let trailing = unit(at: index),
               (0xDC00...0xDFFF).contains(trailing) {
                index = body.index(index, offsetBy: 2)
                let combined = 0x10000 + (UInt32(leading - 0xD800) << 10) + UInt32(trailing - 0xDC00)
                scalars.append(Unicode.Scalar(combined) ?? "\u{FFFD}")
            } else {
                scalars.append("\u{FFFD}")
            }
        }
        return String(scalars)
    }

    /// Windows-1252, decoded here rather than through `String(data:encoding:)`.
    ///
    /// The codec differs from ISO-8859-1 only in `0x80...0x9F`, where a Windows
    /// page carries the euro, the smart quotes, dashes and friends. Darwin's
    /// `.windowsCP1252` applies that table; swift-corelibs-foundation's does not —
    /// it maps the C1 range to the same code points as Latin-1, so the same page
    /// would decode differently on the two platforms. Decoding it explicitly keeps
    /// the evidence identical everywhere, which is the point of the shared core.
    private static func windowsCP1252(_ data: Data) -> String {
        let overrides: [UInt8: Unicode.Scalar] = [
            0x80: "€", 0x82: "‚", 0x83: "ƒ", 0x84: "„", 0x85: "…",
            0x86: "†", 0x87: "‡", 0x88: "ˆ", 0x89: "‰", 0x8A: "Š",
            0x8B: "‹", 0x8C: "Œ", 0x8E: "Ž", 0x91: "‘", 0x92: "’",
            0x93: "“", 0x94: "”", 0x95: "•", 0x96: "–", 0x97: "—",
            0x98: "˜", 0x99: "™", 0x9A: "š", 0x9B: "›", 0x9C: "œ",
            0x9E: "ž", 0x9F: "Ÿ",
        ]
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)
        for byte in data {
            // The bytes undefined in Windows-1252 (0x81, 0x8D, 0x8F, 0x90, 0x9D)
            // fall back to the code point itself; WHATWG's decoder emits U+FFFD
            // there, but keeping the C1 code point preserves the raw byte, which
            // suits an evidence reader better.
            scalars.append(overrides[byte] ?? Unicode.Scalar(byte))
        }
        return String(scalars)
    }

    /// The codec a `Content-Type` declares, or nil when it declares none this build
    /// recognises. Aliases are included because a server's spelling is not a contract.
    private enum DeclaredEncoding {
        case utf8
        case utf16
        case utf16LittleEndian
        case utf16BigEndian
        case windowsCP1252
        case isoLatin1
    }

    private static func declaredEncoding(_ contentType: String) -> DeclaredEncoding? {
        // `charset=` must open a parameter; a match inside another token (e.g.
        // `xcharset=`) is not a declaration — keep scanning for a real one.
        var marker = contentType.range(of: "charset=", options: .caseInsensitive)
        while let found = marker {
            let preceding = contentType[contentType.startIndex..<found.lowerBound]
                .reversed()
                .drop(while: { $0 == " " || $0 == "\t" })
            if preceding.isEmpty || preceding.first == ";" { break }
            marker = contentType.range(of: "charset=", options: .caseInsensitive,
                                       range: found.upperBound..<contentType.endIndex)
        }
        guard let marker = marker else {
            return nil
        }
        let declared = contentType[marker.upperBound...]
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) ?? ""
        switch declared.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "utf-16", "utf16", "unicode":
            return .utf16
        case "utf-16le", "utf-16-le", "utf16le":
            return .utf16LittleEndian
        case "utf-16be", "utf-16-be", "utf16be":
            return .utf16BigEndian
        case "windows-1252", "cp1252", "cp-1252", "x-cp1252":
            return .windowsCP1252
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "latin-1":
            return .isoLatin1
        default:
            return nil
        }
    }
}
