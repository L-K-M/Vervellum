import Foundation

/// URL hygiene for every URL Vervellum did not construct itself — a search result's,
/// a model's, or one the user pasted into a question.
///
/// Two of its pieces are on the main path. `normalized(_:)` is what
/// `EvidenceExtractor` accepts as a source link — anything that is not an absolute
/// http(s) URL with a host is not a source — and `bareURLs(in:)` is how
/// `CitationValidator` catches a model writing a link despite being told to cite by
/// number. Citations themselves are checked as *numbers*, never against a URL list, so
/// this type is not an allow-list; see `CitationValidator` for why.
///
/// `urls(in:)`, the exhaustive walk, is kept for diagnostics and tests. It has to be
/// greedy in exactly one direction — it may over-collect, but it must never miss a URL
/// that really was in the results — and three things make that harder than walking a
/// JSON tree:
///
/// * MCP tool results wrap their payload in *text* blocks, so a whole JSON document
///   can arrive as a string that has to be re-parsed.
/// * Result objects use `url`, `link` and `href` interchangeably for the source.
/// * Free-text summaries contain bare URLs with no key at all.
///
/// Icon and favicon fields are skipped: they point at a CDN, never at a source, and
/// allowing them would let a model "cite" a favicon.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum SourceHarvester {

    /// Keys whose string value is taken to be a source link.
    private static let linkKeys: Set<String> = ["url", "link", "href"]
    /// Keys skipped entirely — their links are decoration, not evidence.
    private static let ignoredKeys: Set<String> = ["icon", "favicon", "site_icon", "siteicon", "logo"]

    /// Every distinct http(s) URL reachable inside `value`.
    static func urls(in value: Any?) -> Set<String> {
        var found: Set<String> = []
        collect(value, into: &found, depth: 0)
        return found
    }

    /// Guards against a pathological (or hostile) deeply nested payload spending the
    /// whole run in recursion. Real MCP results nest a handful of levels.
    private static let maxDepth = 24

    private static func collect(_ value: Any?, into found: inout Set<String>, depth: Int) {
        guard depth <= maxDepth else { return }
        switch value {
        case let dictionary as [String: Any]:
            for (key, item) in dictionary {
                let lowered = key.lowercased()
                if ignoredKeys.contains(lowered) { continue }
                if linkKeys.contains(lowered), let text = item as? String {
                    if let normalized = normalized(text, trimmingPunctuation: false) { found.insert(normalized) }
                } else {
                    collect(item, into: &found, depth: depth + 1)
                }
            }
        case let array as [Any]:
            for item in array { collect(item, into: &found, depth: depth + 1) }
        case let text as String:
            // An MCP text block may itself be a JSON document; re-parse it before
            // falling back to scanning for bare URLs.
            if let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               parsed is [String: Any] || parsed is [Any] {
                collect(parsed, into: &found, depth: depth + 1)
            } else {
                for match in bareURLs(in: text) { found.insert(match) }
            }
        default:
            break
        }
    }

    /// Bare `http(s)://…` runs inside free text.
    static func bareURLs(in text: String) -> [String] {
        guard let regex = urlRegex else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return normalized(String(text[swiftRange]))
        }
    }

    private static let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'\\)\]}]+"#)

    /// The links the user pasted into a question, in the order they were typed.
    ///
    /// Deduplicated by `canonicalKey`, because the same address typed twice is one page
    /// — and reading it twice would spend two requests to put the same text in the
    /// evidence under two numbers, which is an invitation to cite it as if two sources
    /// agreed. The *first* spelling of a page is the one kept, because it is the one the
    /// user wrote.
    ///
    /// `limit` is applied last, so it counts *pages* rather than occurrences: a question
    /// that repeats one link and then adds a second still gets both.
    ///
    /// This is prose, so `bareURLs` trims the punctuation a URL picks up at the end of a
    /// sentence — "see https://example.com/a." is a link and a full stop, not a path
    /// ending in a dot. That is the opposite of what a search hit's `url` field wants,
    /// and it is why `normalized` takes the choice as a parameter.
    ///
    /// A closing parenthesis that belongs to the address is put back; see
    /// `reclosingParentheses`.
    static func links(inQuestion question: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return Array(distinctLinks(inQuestion: question).prefix(limit))
    }

    /// How many distinct links the question carries, so a caller that reads only the
    /// first few can say that the rest were left rather than silently dropping them.
    ///
    /// The same list `links` returns before the limit, rather than a second count of its
    /// own. The two numbers are compared against each other to decide whether anything
    /// was left behind, and two counts of different things would report a link dropped
    /// every time a question mentioned one page twice. Sharing the walk makes that
    /// structural rather than a rule two functions have to keep agreeing on.
    static func linkCount(inQuestion question: String) -> Int {
        distinctLinks(inQuestion: question).count
    }

    /// Every distinct page the question links to, in the order it was typed.
    private static func distinctLinks(inQuestion question: String) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for match in bareURLs(in: question) {
            let url = reclosingParentheses(match, in: question)
            guard seen.insert(canonicalKey(for: url)).inserted else { continue }
            ordered.append(url)
        }
        return ordered
    }

    /// Puts back a closing parenthesis that belongs to the address.
    ///
    /// `bareURLs`'s pattern excludes `)` entirely, so a match can never contain one and
    /// every `(` inside one is unclosed. That is right for the walk `CitationValidator`
    /// shares — a model writing "(see https://example.com/a)" must not have the closing
    /// paren pulled into the URL it is being flagged for — and wrong here, where the
    /// string is prose a person typed and `/wiki/Mercury_(planet)` is an address they
    /// meant. Without this, the most-pasted URL shape after a news link is cut to
    /// `/wiki/Mercury_(planet` and fetched as a page that cannot exist.
    ///
    /// Repaired against the question rather than by counting alone: a closer is added
    /// only where the text really does carry one straight after the match. So a URL that
    /// genuinely ends mid-parenthesis is left as it is rather than having an ending
    /// invented for it, and "(see https://example.com/a)" is untouched because its match
    /// opened nothing. Nested parentheses close one at a time, and the loop is bounded by
    /// the question's own length.
    static func reclosingParentheses(_ url: String, in question: String) -> String {
        var candidate = url
        while candidate.filter({ $0 == "(" }).count > candidate.filter({ $0 == ")" }).count,
              question.contains(candidate + ")") {
            candidate += ")"
        }
        return candidate
    }

    /// The key two addresses are compared by when deciding whether they are one page.
    ///
    /// Exact string equality is the wrong test for that, and it is the test the first
    /// version of this used. A URL pasted out of a browser routinely carries what the
    /// address bar added — a `#section`, Chrome's `#:~:text=` scroll-to-text fragment, a
    /// trailing slash, a `utm_` tag recording how the reader arrived — and a search
    /// engine returns the canonical form with none of it. Compared byte for byte those
    /// are two sources, and the model is then shown one page twice under two numbers.
    ///
    /// Deliberately conservative: only differences that **cannot change which document
    /// the server sends** are folded away.
    ///
    /// * The scheme and host are lowercased and a leading `www.` dropped. Case is not
    ///   significant in either, and `www.` is a redirect on all but a vanishing few hosts.
    /// * The fragment is dropped. It selects a position *within* a document the server
    ///   has already sent, and is never transmitted to the server at all.
    /// * One trailing slash is dropped from the path.
    /// * Attribution parameters are dropped. They record how a reader arrived, never
    ///   which document is served.
    ///
    /// The path keeps its case and every other query item is kept, because either can
    /// select a different document — and collapsing two real pages into one loses
    /// evidence, which is the worse mistake of the two.
    ///
    /// Only ever a comparison key. What is fetched, numbered, cited and shown to the
    /// reader stays the address exactly as it was given.
    static func canonicalKey(for url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        if let host = components.host?.lowercased() {
            components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        // The `percentEncoded` accessors throughout, because the plain ones decode on
        // read and re-encode on write — and that round trip is not lossless where it
        // matters. `%2F` in a path decodes to "/" and re-encodes as "/", turning one
        // path segment into two; `%2B` in a query decodes to "+" and stays "+", which is
        // a different value. Either would fold two genuinely different documents onto one
        // key, which is the mistake this function's own rule calls the worse one. Read as
        // written, the comparison is purely structural.
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        if let query = components.percentEncodedQuery {
            // Split by hand rather than through `queryItems` for the same reason. An
            // item's name is everything before the first "="; a bare flag has no "=" at
            // all and is its own name.
            let kept = query.split(separator: "&").filter { item in
                let name = item.split(separator: "=", maxSplits: 1).first.map { String($0) } ?? ""
                return !attributionParameters.contains(name.lowercased())
            }
            // Emptied rather than left empty: an empty query still renders a trailing
            // "?", so a URL whose only parameter was a tracking tag would not match the
            // same URL without one — the case this exists for.
            components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        }
        return components.url?.absoluteString ?? url
    }

    /// Query items that say how a reader arrived, never what they arrived at.
    ///
    /// Every entry is a click identifier whose removal provably cannot change which
    /// document is served — the page's own identity always lives in another parameter or
    /// in the path. `si` and `ref` are deliberately absent despite being share-link
    /// parameters on large sites: both are also used as ordinary, meaningful parameters
    /// elsewhere, and dropping one that mattered would merge two real pages, which this
    /// file treats as the worse of the two mistakes.
    private static let attributionParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "fbclid", "gclid", "msclkid", "twclid", "yclid", "igshid", "li_fat_id",
        "mc_cid", "mc_eid", "ref_src",
    ]

    /// Rejects anything that isn't an absolute http(s) URL with a host and, for a URL
    /// lifted out of prose, trims the punctuation it picked up at the end of a sentence.
    ///
    /// A structured field — a search hit's `url` — is an address, not prose. A closing
    /// parenthesis there is part of the path (`/wiki/Mercury_(planet)`), and trimming
    /// it sends the reader to a page that does not exist, shows the model a link it
    /// cannot have seen, and lets two different pages collapse into one number. Those
    /// callers pass `trimmingPunctuation: false`.
    static func normalized(_ raw: String, trimmingPunctuation: Bool = true) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmingPunctuation, let last = trimmed.last, ".,;:!?)]}>\"'".contains(last) {
            trimmed.removeLast()
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return trimmed
    }
}
