import Foundation

/// Turns a fetched HTML page into the readable text a model can be shown.
///
/// This is deliberately a *reader*, not a parser. Vervellum has no dependencies and is
/// not going to grow a DOM: what the answer stage needs is the prose a person would see
/// on the page, and what it must not receive is the page's script, its navigation, or
/// its cookie banner — all of which cost context and none of which is evidence.
///
/// So the pipeline is four passes, in this order, and the order matters:
///
/// 1. **Remove whole elements** whose content is never prose — `script`, `style`, and
///    the chrome elements (`nav`, `header`, `footer`, `aside`) that otherwise
///    contribute the same forty links on every page of a site.
/// 2. **Narrow to the article** when the page says where it is. `<main>` and
///    `<article>` are the two elements whose entire purpose is to answer that, and a
///    page that uses one has told us what it considers the content.
/// 3. **Turn block boundaries into line breaks** *before* stripping tags, or every
///    paragraph, heading and list item runs into the next one and the model reads a
///    single unpunctuated wall.
/// 4. **Strip the remaining tags, decode entities, and normalise whitespace.**
///
/// It is lossy and it is meant to be: a table becomes lines, an image becomes nothing.
/// The alternative — showing the model raw HTML — spends the evidence budget on markup
/// and invites it to quote an attribute as though it were a sentence.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum HTMLTextExtractor {

    /// How much of one page reaches the model.
    ///
    /// Generous next to a 600-character search snippet and small next to a long article.
    /// The whole point is to be able to check a claim against the page rather than
    /// against a summary of it, and the first few thousand characters of a page are
    /// where a page says what it is; past that the evidence budget is better spent on
    /// another source.
    static let maxCharacters = 8_000

    /// Below this, whatever came back was navigation, a consent wall, or a page that
    /// builds itself in JavaScript. Offering it as "the page" would be a lie with a
    /// label on it, so the reader drops it and the source keeps its snippet.
    static let minimumUsefulCharacters = 80

    /// The readable text of `html`, or an empty string when there is none worth having.
    ///
    /// `minimum` is a parameter rather than a constant only so a test can exercise the
    /// four passes on a short fixture without padding it to article length.
    static func text(from html: String,
                     limit: Int = maxCharacters,
                     minimum: Int = minimumUsefulCharacters) -> String {
        var working = removeElements(Self.strippedElements, in: html)
        working = article(in: working) ?? working
        working = breakingBlocks(in: working)
        working = stripTags(working)
        working = decodingEntities(working)
        let normalized = normalize(working, limit: limit)
        return normalized.count < minimum ? "" : normalized
    }

    // MARK: 1 — whole elements

    /// Elements whose content is never the article.
    ///
    /// `nav`, `header`, `footer` and `aside` are here for a practical reason rather
    /// than a purist one: on a typical site they are identical on every page, so they
    /// crowd out the part that differs — and a model shown the same sidebar under four
    /// sources will find agreement between them that does not exist.
    private static let strippedElements = [
        "script", "style", "noscript", "template", "svg", "iframe", "object", "canvas",
        "form", "nav", "header", "footer", "aside",
    ]

    private static func removeElements(_ names: [String], in html: String) -> String {
        var working = html
        for name in names {
            guard let regex = try? NSRegularExpression(
                pattern: "<\(name)\\b[^>]*>.*?</\(name)\\s*>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            working = regex.stringByReplacingMatches(
                in: working, range: NSRange(working.startIndex..., in: working), withTemplate: " ")
        }
        return working
    }

    // MARK: 2 — the article

    /// The content of the page's `<main>`, or failing that its first `<article>`.
    ///
    /// Greedy to the *last* closing tag, because a page that nests a second `<article>`
    /// inside its main one is common and stopping at the first close would cut the
    /// piece in half. Nil when the page marks neither, which is when the whole document
    /// is the best guess available.
    private static func article(in html: String) -> String? {
        for name in ["main", "article"] {
            guard let regex = try? NSRegularExpression(
                pattern: "<\(name)\\b[^>]*>(.*)</\(name)\\s*>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]),
                let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: html)
            else { continue }
            let content = String(html[range])
            // A `<main>` holding only a heading is a page whose content is elsewhere;
            // falling back to the whole document loses less than trusting the marker.
            if content.count > 200 { return content }
        }
        return nil
    }

    // MARK: 3 — block boundaries

    /// Elements that end a line of prose. Everything else is inline and closes without
    /// a break, so "the <em>fastest</em> route" does not become three lines.
    private static let blockElements =
        "p|div|li|ul|ol|h[1-6]|tr|td|th|section|article|main|blockquote|pre|figcaption|dd|dt|hr"

    private static func breakingBlocks(in html: String) -> String {
        var working = html
        if let breaks = try? NSRegularExpression(pattern: "<br\\s*/?>", options: [.caseInsensitive]) {
            working = breaks.stringByReplacingMatches(
                in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "\n")
        }
        if let blocks = try? NSRegularExpression(
            pattern: "</?(?:\(blockElements))\\b[^>]*>", options: [.caseInsensitive]) {
            working = blocks.stringByReplacingMatches(
                in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "\n")
        }
        return working
    }

    // MARK: 4 — tags, entities, whitespace

    /// Removes `<…>` runs, including comments and doctype.
    ///
    /// Hand-written rather than a regex: a page is up to hundreds of kilobytes, this
    /// runs once per source, and a single linear scan is both faster and easier to be
    /// sure of than a backtracking pattern over a document that may not be well formed.
    ///
    /// A `<` only starts a tag when what follows it could begin one — a letter, `/`,
    /// `!` or `?`. Without that test, "if a < b then" swallows everything up to the
    /// next `>`, which on a real page is the rest of the paragraph and often the rest
    /// of the document. Browsers make the same distinction, and an unescaped `<` in
    /// prose is common enough to matter.
    static func stripTags(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var insideTag = false
        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            if insideTag {
                if character == ">" { insideTag = false }
            } else if character == "<", startsTag(html, after: index) {
                insideTag = true
            } else {
                result.append(character)
            }
            index = html.index(after: index)
        }
        return result
    }

    private static func startsTag(_ html: String, after index: String.Index) -> Bool {
        let next = html.index(after: index)
        guard next < html.endIndex else { return false }
        let character = html[next]
        return character.isLetter || character == "/" || character == "!" || character == "?"
    }

    /// The named entities that actually appear in prose, plus numeric references.
    ///
    /// Not the full HTML5 table — that is two thousand names, and the ones missing here
    /// survive as their own literal text rather than as a wrong character.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "middot": "·", "bull": "•", "copy": "©",
        "reg": "®", "trade": "™", "deg": "°", "euro": "€", "pound": "£", "times": "×",
        "shy": "", "zwnj": "", "thinsp": " ", "ensp": " ", "emsp": " ",
    ]

    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&" else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            // An entity is short; anything longer is a bare ampersand in prose.
            let horizon = text.index(index, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            guard let semicolon = text[index..<horizon].firstIndex(of: ";") else {
                result.append("&")
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index)..<semicolon])
            if let decoded = decodeEntity(name) {
                result.append(decoded)
            } else {
                result.append(contentsOf: text[index...semicolon])
            }
            index = text.index(after: semicolon)
        }
        return result
    }

    private static func decodeEntity(_ name: String) -> String? {
        if let known = namedEntities[name.lowercased()] { return known }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let scalarValue: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            scalarValue = UInt32(digits.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(digits)
        }
        guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { return nil }
        return String(Character(scalar))
    }

    /// Collapses runs of spaces and blank lines, then truncates on a word boundary.
    ///
    /// Truncation is marked with `[…]`, because a page cut off mid-argument that does
    /// not say so is a page a model will happily treat as complete.
    private static func normalize(_ text: String, limit: Int) -> String {
        var lines: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let collapsed = rawLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if collapsed.isEmpty {
                if lines.last?.isEmpty == false { lines.append("") }
            } else {
                lines.append(collapsed)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }

        let joined = lines.joined(separator: "\n")
        guard joined.count > limit else { return joined }
        let cut = joined.prefix(limit)
        if let space = cut.lastIndex(where: { $0.isWhitespace }),
           cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "\n\n[…]"
        }
        return cut + "\n\n[…]"
    }
}
