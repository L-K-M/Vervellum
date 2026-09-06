import Foundation

/// Turns a search tool's raw MCP result into the numbered `Source` list the model
/// cites against.
///
/// The shape of that result is not standardised: z.ai's server has returned hits as
/// structured JSON, and as a single MCP *text* block whose string is itself a JSON
/// document, and the field names for a hit's title and summary vary between
/// versions. So this walks the whole payload looking for objects that *behave* like
/// a search hit — something with a usable link — rather than matching one schema.
///
/// Being permissive here is safe because the output is only ever a list of links
/// Vervellum fetched; being strict would silently drop real evidence and leave the
/// model with nothing to cite.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum EvidenceExtractor {

    /// Upper bound on sources offered to the model. Beyond this the citation list
    /// stops being something a reader can hold in their head, and the context cost
    /// grows faster than the answer improves.
    static let maxSources = 24
    /// Snippets are trimmed hard: they are a reminder of what the page said, not a
    /// substitute for reading it, and long ones crowd out real evidence in context.
    static let maxSnippetLength = 600

    private static let titleKeys = ["title", "name", "heading", "page_title"]
    private static let snippetKeys = ["snippet", "content", "summary", "description", "text", "abstract"]
    private static let dateKeys = ["publish_date", "published_at", "published", "date", "publishedDate"]
    private static let linkKeys = ["url", "link", "href"]
    private static let ignoredLinkKeys: Set<String> = ["icon", "favicon", "site_icon", "siteicon", "logo"]

    /// Extracts hits from `results`, numbering them from `startingAt`.
    /// Duplicate URLs collapse to the first occurrence, so two searches that both
    /// surface the same page do not get two citation numbers.
    static func sources(from results: [Any], startingAt startNumber: Int = 1) -> [Source] {
        var hits: [(url: String, title: String, snippet: String, date: String?)] = []
        var seen: Set<String> = []
        for result in results {
            collect(result, into: &hits, seen: &seen, depth: 0)
        }
        return hits.prefix(maxSources).enumerated().map { offset, hit in
            Source(number: startNumber + offset,
                   url: hit.url,
                   title: hit.title,
                   snippet: hit.snippet,
                   publishedAt: hit.date)
        }
    }

    private static let maxDepth = 24

    private typealias Hit = (url: String, title: String, snippet: String, date: String?)

    private static func collect(_ value: Any?,
                                into hits: inout [Hit],
                                seen: inout Set<String>,
                                depth: Int) {
        guard depth <= maxDepth, hits.count < maxSources else { return }
        switch value {
        case let dictionary as [String: Any]:
            var consumed: Set<String> = []
            if let hit = hit(from: dictionary) {
                if !seen.contains(hit.url) {
                    seen.insert(hit.url)
                    hits.append(hit)
                }
                // This dictionary *is* a source. Its title, summary and date were taken
                // as that source's own fields; walking into them again would turn every
                // link mentioned inside a summary into a source of its own.
                consumed = Set((titleKeys + snippetKeys + dateKeys).map { $0.lowercased() })
            }
            // Sorted, not in dictionary order: Swift randomises that per process, and a
            // result with hits under two keys would otherwise number its sources
            // differently on every launch. The model cites whatever numbering it was
            // shown, so a thread stays consistent either way — but two people with the
            // same response would get different lists, and a fixture could not assert
            // a number.
            for key in dictionary.keys.sorted() {
                let lowered = key.lowercased()
                if ignoredLinkKeys.contains(lowered) || linkKeys.contains(lowered)
                    || consumed.contains(lowered) { continue }
                collect(dictionary[key], into: &hits, seen: &seen, depth: depth + 1)
            }
        case let array as [Any]:
            for item in array { collect(item, into: &hits, seen: &seen, depth: depth + 1) }
        case let text as String:
            if let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               parsed is [String: Any] || parsed is [Any] {
                collect(parsed, into: &hits, seen: &seen, depth: depth + 1)
                return
            }
            // Not JSON. A server may hand its results back as prose — titles, links and
            // summaries in one text block — and a link in prose is still evidence. Each
            // item around a link becomes a hit whose snippet is that item, so the model
            // sees the words the link came with rather than a bare address.
            for hit in proseHits(in: text) where hits.count < maxSources && !seen.contains(hit.url) {
                seen.insert(hit.url)
                hits.append(hit)
            }
        default:
            break
        }
    }

    // MARK: Prose results

    /// Hits harvested from a text block that is not JSON.
    ///
    /// Blank lines separate items, which is how every list-shaped result reads. Within
    /// an item, one link means the whole item is that link's context; several links —
    /// a list with no blank lines between entries — give each link the lines between
    /// its neighbours.
    private static func proseHits(in text: String) -> [Hit] {
        var found: [Hit] = []
        var paragraph: [String] = []
        func flush() {
            found.append(contentsOf: hits(inParagraph: paragraph))
            paragraph.removeAll()
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { paragraph.append(line) }
        }
        flush()
        return found
    }

    private static func hits(inParagraph lines: [String]) -> [Hit] {
        let linkLines = lines.indices.filter { !SourceHarvester.bareURLs(in: lines[$0]).isEmpty }
        guard !linkLines.isEmpty else { return [] }

        var found: [Hit] = []
        for (position, index) in linkLines.enumerated() {
            let start = position == 0 ? 0 : linkLines[position - 1] + 1
            let end = position + 1 < linkLines.count ? linkLines[position + 1] - 1 : lines.count - 1
            let item = Array(lines[start...end])
            let urls = SourceHarvester.bareURLs(in: lines[index])

            // The snippet is the item with its addresses removed: the words, not the
            // links, are what the model should read.
            var prose = item.joined(separator: "\n")
            for url in urls { prose = prose.replacingOccurrences(of: url, with: " ") }
            let snippet = prose.trimmed(to: maxSnippetLength)

            // The first link-free line, when it is short enough to be a title.
            let heading = item
                .first { SourceHarvester.bareURLs(in: $0).isEmpty && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(proseTitle) ?? ""

            for url in urls {
                found.append((url: url,
                              title: heading.isEmpty ? displayTitle(for: url) : heading,
                              snippet: snippet,
                              date: nil))
            }
        }
        return found
    }

    /// A list item's first line as a title: the list marker and bold markers stripped,
    /// and rejected when it is too long to be one.
    private static func proseTitle(_ line: String) -> String {
        var title = line.trimmingCharacters(in: .whitespaces)
        if let marker = listMarker {
            title = marker.stringByReplacingMatches(
                in: title, range: NSRange(title.startIndex..<title.endIndex, in: title), withTemplate: "")
        }
        title = title.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        return title.count <= 160 ? title : ""
    }

    /// `- `, `* `, `• `, `## `, `1. `, `12) ` at the start of a line.
    private static let listMarker = try? NSRegularExpression(pattern: #"^(?:[-*•#]+|\d{1,3}[.)])\s+"#)

    // MARK: Diagnostics

    private static let maxDiagnosticFields = 12
    private static let diagnosticKeys = Set(titleKeys + snippetKeys + dateKeys + linkKeys + [
        "content", "structuredContent", "type", "isError", "result", "results", "data",
        "search_result", "search_results", "web_search_result", "web_search_results",
    ])

    /// A content-free description of a result's structure, for the log.
    ///
    /// Known schema keys, array lengths, string lengths, and whether a string parses
    /// as JSON — never arbitrary keys, titles, summaries, or links. It exists for the one failure that is
    /// otherwise undiagnosable from a log that must not contain results: a search that
    /// answered, in a shape this extractor did not recognise.
    static func shape(of value: Any?, depth: Int = 0) -> String {
        guard let value else { return "null" }
        guard depth < 6 else { return "…" }
        switch value {
        case let dictionary as [String: Any]:
            // A provider can put secrets in keys too. Only application-known names
            // may reach the log; unknown fields contribute a count, not their bytes.
            let keys = diagnosticKeys.filter { dictionary[$0] != nil }.sorted()
            var fields = keys.prefix(maxDiagnosticFields).map {
                "\($0): \(shape(of: dictionary[$0], depth: depth + 1))"
            }
            if keys.count > maxDiagnosticFields { fields.append("…") }
            let unknownCount = dictionary.count - keys.count
            if unknownCount > 0 {
                fields.append("\(unknownCount) other field\(unknownCount == 1 ? "" : "s")")
            }
            return "{" + fields.joined(separator: ", ") + "}"
        case let array as [Any]:
            guard let first = array.first else { return "[]" }
            return "[\(array.count) × \(shape(of: first, depth: depth + 1))]"
        case let text as String:
            if let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               parsed is [String: Any] || parsed is [Any] {
                return "json-string(\(text.count) chars: \(shape(of: parsed, depth: depth + 1)))"
            }
            return "string(\(text.count) chars, \(SourceHarvester.bareURLs(in: text).count) links)"
        case is NSNull:
            return "null"
        case is NSNumber, is Int, is Double, is Bool:
            return "scalar"
        default:
            return "other"
        }
    }

    /// Reads one dictionary as a search hit, or returns nil if it isn't one.
    private static func hit(from dictionary: [String: Any])
        -> (url: String, title: String, snippet: String, date: String?)? {
        var link: String?
        for key in linkKeys {
            if let candidate = firstString(dictionary, key), let normalized = SourceHarvester.normalized(candidate) {
                link = normalized
                break
            }
        }
        guard let url = link else { return nil }

        let title = titleKeys.compactMap { firstString(dictionary, $0) }
            .first(where: { !$0.isEmpty })?.trimmed(to: 200)
        let snippet = snippetKeys.compactMap { firstString(dictionary, $0) }
            .first(where: { !$0.isEmpty })?.trimmed(to: maxSnippetLength)
        let date = dateKeys.compactMap { firstString(dictionary, $0) }.first(where: { !$0.isEmpty })

        return (url: url,
                // `url` came back from `SourceHarvester.normalized`, so it is already a
                // valid absolute URL — no second round of optional handling needed.
                title: title ?? Self.displayTitle(for: url),
                snippet: snippet ?? "",
                date: date)
    }

    /// Case-insensitive lookup: servers have shipped both `publishedAt` and
    /// `published_at` for the same field.
    private static func firstString(_ dictionary: [String: Any], _ key: String) -> String? {
        if let value = dictionary[key] as? String { return value }
        let lowered = key.lowercased()
        for (candidate, value) in dictionary where candidate.lowercased() == lowered {
            if let text = value as? String { return text }
        }
        return nil
    }

    /// A readable stand-in when a hit carries no title: the host plus the last path
    /// segment, which is nearly always the slug.
    static func displayTitle(for url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let segments = components.path.split(separator: "/").filter { !$0.isEmpty }
        guard let slug = segments.last else { return host }
        let readable = slug
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return "\(host) — \(readable)"
    }
}

private extension String {
    /// Collapses whitespace and truncates on a word boundary.
    func trimmed(to limit: Int) -> String {
        let collapsed = split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }
}
