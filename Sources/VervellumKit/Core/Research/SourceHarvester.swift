import Foundation

/// URL hygiene for everything that came from a search result or a model.
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
