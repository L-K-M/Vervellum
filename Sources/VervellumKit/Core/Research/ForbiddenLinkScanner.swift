import Foundation

/// Finds every destination syntax the model-facing prompts forbid.
///
/// This is deliberately separate from `SourceHarvester`. Harvesting asks whether an
/// absolute HTTP address can become evidence; this scanner asks whether model-written
/// prose can express a destination at all. Scheme-relative URLs, bare IP literals,
/// email addresses, relative Markdown links and bare domains fail the second rule even
/// though none can be fetched as a source without interpretation.
///
/// Foundation's link detector is not available in swift-corelibs-foundation, so the
/// implementation stays to bounded regular expressions plus small structural checks.
/// The bare-domain pass is conservative around filenames and code-like member access:
/// a false positive puts a permanent trust warning on otherwise valid prose.
///
/// `codeRanges` exclude Markdown *syntax* examples such as `[key](value)`, not raw
/// addresses. The model-facing rule forbids URLs and bare domains anywhere in an
/// answer, including code, because a destination remains copyable even when a renderer
/// does not activate it. That asymmetry is intentional and keeps the numeric-only
/// citation boundary independent of one renderer's autolink behavior.
enum ForbiddenLinkScanner {

    private struct Candidate {
        var range: NSRange
        var text: String
    }

    /// Forbidden destinations, in source order. Overlapping spellings are reported
    /// once: `[docs](https://example.com)` is one violation, not a URL plus a link.
    /// A destination spelled the same way twice is reported once as well — the list
    /// exists to tell the reader *which* destinations appeared, not how often.
    static func links(in text: String,
                      excludingMarkdownSyntaxIn codeRanges: [Range<String.Index>] = []) -> [String] {
        guard !text.isEmpty else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var candidates: [Candidate] = []

        collect(absoluteURLRegex, in: text, range: fullRange, into: &candidates) { raw in
            let candidate = trimmingLinkPunctuation(raw)
            // Source admission rejects URL userinfo, but model-written destinations
            // must still be flagged even when they cannot become numbered sources.
            guard let components = URLComponents(string: candidate),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = components.host, !host.isEmpty else { return nil }
            return candidate
        }
        collect(hierarchicalURIRegex, in: text, range: fullRange, into: &candidates) {
            trimmingLinkPunctuation($0)
        }
        collect(commonURIRegex, in: text, range: fullRange, into: &candidates) {
            trimmingLinkPunctuation($0)
        }
        collect(markdownURIAutolinkRegex, in: text, range: fullRange, into: &candidates,
                excluding: codeRanges) { $0 }
        collect(markdownEmailAutolinkRegex, in: text, range: fullRange, into: &candidates,
                excluding: codeRanges) { isPlausibleEmail($0) ? $0 : nil }
        collect(emailAddressRegex, in: text, range: fullRange, into: &candidates) {
            isPlausibleEmail($0) ? $0 : nil
        }
        collect(schemeRelativeRegex, in: text, range: fullRange, into: &candidates) { raw in
            // Trim before judging: a sentence's final `.` would otherwise read as
            // part of the authority and make `//TODO.` look like a dotted host.
            let candidate = trimmingLinkPunctuation(raw)
            return isPlausibleSchemeRelativeDestination(candidate) ? candidate : nil
        }
        candidates.append(contentsOf: markdownInlineLinks(in: text, excluding: codeRanges))
        collect(markdownReferenceDefinitionRegex, in: text, range: fullRange, into: &candidates,
                excluding: codeRanges) { $0 }
        collect(bareIPv4Regex, in: text, range: fullRange, into: &candidates) {
            trimmingLinkPunctuation($0)
        }
        collect(bareIPv6Regex, in: text, range: fullRange, into: &candidates) { raw in
            isIPv6Literal(raw) ? trimmingLinkPunctuation(raw) : nil
        }
        collect(bareDomainRegex, in: text, range: fullRange, into: &candidates) { raw in
            let candidate = trimmingLinkPunctuation(raw)
            return isPlausibleBareDomain(candidate) ? candidate : nil
        }

        let ordered = candidates.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.range.length > $1.range.length
        }
        var distinct: [Candidate] = []
        for candidate in ordered {
            if let previous = distinct.last,
               NSIntersectionRange(previous.range, candidate.range).length > 0 {
                continue
            }
            distinct.append(candidate)
        }
        var seen: Set<String> = []
        return distinct.compactMap {
            seen.insert($0.text).inserted ? $0.text : nil
        }
    }

    private static func collect(_ regex: NSRegularExpression?,
                                in text: String,
                                range: NSRange,
                                into candidates: inout [Candidate],
                                excluding excludedRanges: [Range<String.Index>] = [],
                                transform: (String) -> String?) {
        guard let regex else { return }
        for match in regex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text),
                  !isContained(swiftRange, in: excludedRanges),
                  let rendered = transform(String(text[swiftRange])),
                  !rendered.isEmpty
            else { continue }
            candidates.append(Candidate(range: match.range, text: rendered))
        }
    }

    /// Finds inline/image Markdown links with a structural walk rather than a regex.
    /// Escaped brackets, even runs of backslashes, nested destination parentheses and
    /// parenthesized titles are all significant to CommonMark, and expressing those in
    /// one regular expression either misses real links or backtracks pathologically.
    private static func markdownInlineLinks(
        in text: String,
        excluding excludedRanges: [Range<String.Index>]
    ) -> [Candidate] {
        let parentheses = matchingParentheses(in: text, excluding: excludedRanges)
        var openBrackets: [String.Index] = []
        var found: [Candidate] = []
        var index = text.startIndex
        var previousWasNewline = false
        var excludedIndex = 0

        while index < text.endIndex {
            while excludedIndex < excludedRanges.count,
                  excludedRanges[excludedIndex].upperBound <= index {
                excludedIndex += 1
            }
            if excludedIndex < excludedRanges.count,
               excludedRanges[excludedIndex].contains(index) {
                let skipped = text[excludedRanges[excludedIndex]]
                if skipped.contains(where: \.isNewline) {
                    openBrackets.removeAll(keepingCapacity: true)
                }
                index = excludedRanges[excludedIndex].upperBound
                continue
            }
            let character = text[index]
            if character.isNewline {
                // CommonMark permits one line break inside a label, but not a blank
                // paragraph. Keep the bracket stack for the former and reset it for
                // the latter so distant prose cannot be paired into a synthetic link.
                if previousWasNewline { openBrackets.removeAll(keepingCapacity: true) }
                previousWasNewline = true
                let next = text.index(after: index)
                if character == "\r", next < text.endIndex, text[next] == "\n" {
                    index = text.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            previousWasNewline = false
            if character == "[", !isEscaped(index, in: text) {
                openBrackets.append(index)
                index = text.index(after: index)
                continue
            }
            guard character == "]", !isEscaped(index, in: text),
                  let opener = openBrackets.popLast()
            else {
                index = text.index(after: index)
                continue
            }

            let openParenthesis = text.index(after: index)
            guard openParenthesis < text.endIndex, text[openParenthesis] == "(",
                  let closeParenthesis = parentheses[openParenthesis]
            else {
                index = text.index(after: index)
                continue
            }
            let destinationStart = text.index(after: openParenthesis)
            let destination = text[destinationStart..<closeParenthesis]
            guard isValidInlineDestination(destination) else {
                index = text.index(after: index)
                continue
            }

            let wholeRange = opener..<text.index(after: closeParenthesis)
            if !isContained(wholeRange, in: excludedRanges) {
                found.append(Candidate(range: NSRange(wholeRange, in: text),
                                       text: String(text[wholeRange])))
            }
            // CommonMark permits an image inside a link, but never a link inside a
            // link. Keep the outer opener after an image; a real link deactivates it.
            let isImage: Bool
            if opener > text.startIndex {
                let marker = text.index(before: opener)
                isImage = text[marker] == "!" && !isEscaped(marker, in: text)
            } else {
                isImage = false
            }
            if !isImage {
                openBrackets.removeAll(keepingCapacity: true)
            }
            index = text.index(after: closeParenthesis)
        }
        return found
    }

    private static func matchingParentheses(
        in text: String,
        excluding excludedRanges: [Range<String.Index>]
    ) -> [String.Index: String.Index] {
        var stack: [String.Index] = []
        var matches: [String.Index: String.Index] = [:]
        var index = text.startIndex
        var excludedIndex = 0
        while index < text.endIndex {
            while excludedIndex < excludedRanges.count,
                  excludedRanges[excludedIndex].upperBound <= index {
                excludedIndex += 1
            }
            if excludedIndex < excludedRanges.count,
               excludedRanges[excludedIndex].contains(index) {
                let skipped = text[excludedRanges[excludedIndex]]
                if skipped.contains(where: \.isNewline) {
                    stack.removeAll(keepingCapacity: true)
                }
                index = excludedRanges[excludedIndex].upperBound
                continue
            }
            if !isEscaped(index, in: text) {
                if text[index] == "(" {
                    stack.append(index)
                } else if text[index] == ")", let opener = stack.popLast() {
                    matches[opener] = index
                }
            }
            index = text.index(after: index)
        }
        return matches
    }

    private static func isContained(_ candidate: Range<String.Index>,
                                    in excludedRanges: [Range<String.Index>]) -> Bool {
        excludedRanges.contains {
            $0.lowerBound <= candidate.lowerBound && $0.upperBound >= candidate.upperBound
        }
    }

    private static func isEscaped(_ index: String.Index, in text: String) -> Bool {
        var cursor = index
        var slashes = 0
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            guard text[cursor] == "\\" else { break }
            slashes += 1
        }
        return !slashes.isMultiple(of: 2)
    }

    /// CommonMark permits a bare or angle-bracketed destination, then an optional
    /// single-, double-, or parenthesis-delimited title. This validation keeps prose
    /// such as `[1]: This source says …` and `[x](ordinary words here)` from becoming
    /// links merely because they contain familiar punctuation.
    private static func isValidInlineDestination(_ raw: Substring) -> Bool {
        guard !containsBlankLine(raw) else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return true }

        let remainder: Substring
        if value.first == "<" {
            guard let closer = value.indices.first(where: {
                value[$0] == ">" && !isEscaped($0, in: value)
            }) else { return false }
            remainder = value[value.index(after: closer)...]
        } else if let whitespace = value.firstIndex(where: \.isWhitespace) {
            remainder = value[whitespace...]
        } else {
            return true
        }

        let title = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return true }
        guard let first = title.first, let last = title.last else { return false }
        return (first == "\"" && last == "\"")
            || (first == "'" && last == "'")
            || (first == "(" && last == ")")
    }

    private static func containsBlankLine(_ text: Substring) -> Bool {
        var sawLineBreak = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline {
                if sawLineBreak { return true }
                sawLineBreak = true
                let next = text.index(after: index)
                if character == "\r", next < text.endIndex, text[next] == "\n" {
                    index = text.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if sawLineBreak, character != " ", character != "\t" {
                sawLineBreak = false
            }
            index = text.index(after: index)
        }
        return false
    }

    private static let absoluteURLRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![A-Z0-9])https?://[^\s<>"'\\}]*[^\s<>"'\\}_*]"#)

    /// HTTP is by far the common case and receives stricter URL validation above, but
    /// any hierarchical URI still gives the model a direct destination channel.
    private static let hierarchicalURIRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![A-Z0-9+.-])[A-Z][A-Z0-9+.-]*://[^\s<>"'\\}]+"#)

    /// Common non-hierarchical schemes become actionable in Markdown renderers even
    /// without `//`. Keeping this set explicit avoids treating ordinary `label:value`
    /// prose as a URI merely because it happens to satisfy the generic URI grammar.
    private static let commonURIRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![A-Z0-9+.-])(?:data|facetime|file|javascript|magnet|mailto|news|sms|tel|urn|webcal):[^\s<>"'\\}]+"#)

    /// CommonMark autolinks admit any URI scheme inside angle brackets. The renderer
    /// can make these live even when the prose around them is otherwise plain.
    private static let markdownURIAutolinkRegex = try? NSRegularExpression(
        pattern: #"(?i)<[A-Z][A-Z0-9+.-]*:[^ <>\r\n]+>"#)

    /// The angle-bracketed spelling of an email gets the same plausibility check as
    /// the bare one, so a version-like `<tool@1.2.34>` stays prose.
    private static let markdownEmailAutolinkRegex = try? NSRegularExpression(
        pattern: #"(?i)<[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+@[\p{L}\p{N}.-]+\.[\p{L}\p{N}-]{2,63}>"#)

    /// A bare address is a destination the reader can copy even when no renderer
    /// activates it. The domain side needs a dotted suffix, and the plausibility
    /// check below keeps `tool@1.2.34` on the version side of the line.
    private static let emailAddressRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-])[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+@[\p{L}\p{N}](?:[\p{L}\p{N}.-]{0,251}[\p{L}\p{N}])?\.[\p{L}\p{N}-]{2,63}"#)

    /// `//host` is only distinguishable from a no-space comment once its authority
    /// looks like one; the plausibility check below is what makes that decision.
    private static let schemeRelativeRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![/:\p{L}\p{N}_-])//[^\s/<>"'\\}]+(?:/[^\s<>"'\\}]*)?"#)

    private static let markdownReferenceDefinitionRegex = try? NSRegularExpression(
        pattern: #"(?im)^[ \t]{0,3}\[(?:\\[^\r\n]|[^\]\\\r\n]|\r?\n[ \t]+)+\]:[ \t]*(?:\r?\n[ \t]{1,3})?(?:<[^<>\r\n]+>|[^ \t\r\n]+)(?:(?:[ \t]+|\r?\n[ \t]{1,3})(?:"(?:\\[^\r\n]|[^"\\\r\n])*"|'(?:\\[^\r\n]|[^'\\\r\n])*'|\((?:\\[^\r\n]|[^\)\\\r\n])*\)))?[ \t]*$"#)

    // A bare IPv4 address is indistinguishable from a four-part numeric version such
    // as `1.2.3.4`. Detection wins that ambiguity: otherwise a model has a reliable
    // spelling for a fabricated destination with no scheme, port, or path.
    private static let bareIPv4Regex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_.-])(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?![\p{L}\p{N}_.-])(?::[0-9]{1,5})?(?:/[^\s<>"'\\}]*)?"#)

    private static let bareIPv6Regex = try? NSRegularExpression(
        pattern: #"(?i)\[(?=[0-9a-f:.]*:)[0-9a-f:.]+\](?::[0-9]{1,5})?(?:/[^\s<>"'\\}]*)?"#)

    /// Conservative boundaries keep this from starting inside an email address or a
    /// longer identifier. The final label is checked against the IANA root zone
    /// unless the token carries an unambiguous host signal such as `www.`, a port,
    /// or a path.
    private static let bareDomainRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![@\p{L}\p{N}_.-])(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?(?::[0-9]{1,5})?(?:/[^\s<>"'\\\]}]*)?(?![\p{L}\p{N}_-])"#)

    private static func trimmingLinkPunctuation(_ raw: String) -> String {
        var value = raw
        // A ')' only ends the destination when nothing inside it opened the pair:
        // wiki-style titles such as `Mercury_(planet)` keep their closing bracket,
        // while a ')' that belongs to the sentence around the address is not part
        // of it.
        var parenthesisBalance = 0
        for character in value {
            if character == "(" { parenthesisBalance += 1 }
            if character == ")" { parenthesisBalance -= 1 }
        }
        while let last = value.last {
            if last == ")" {
                guard parenthesisBalance < 0 else { break }
                value.removeLast()
                parenthesisBalance += 1
            } else if ".,;:!?]}>\"'".contains(last) {
                if last == "]", closesBracketedAddress(value) { break }
                value.removeLast()
            } else {
                break
            }
        }
        return value
    }

    /// Whether a trailing `]` closes a bracketed address rather than ending a
    /// bracketed aside: the IPv6 host inside `scheme://[...]` and `//[...]`
    /// spellings, or a standalone `[::1]` literal.
    private static func closesBracketedAddress(_ value: String) -> Bool {
        let hostStart: String.Index?
        if let delimiter = value.range(of: "://") {
            hostStart = delimiter.upperBound
        } else if value.hasPrefix("//") {
            hostStart = value.index(value.startIndex, offsetBy: 2)
        } else if value.hasPrefix("[") {
            hostStart = value.startIndex
        } else {
            hostStart = nil
        }
        guard let hostStart, hostStart < value.endIndex, value[hostStart] == "[",
              let closer = value[hostStart...].firstIndex(of: "]")
        else { return false }
        return closer == value.index(before: value.endIndex)
    }

    /// `//host` alone is indistinguishable from a no-space source comment (`//TODO`)
    /// until a dot, a bracketed IP literal, `localhost`, or an explicit port or path
    /// shows the authority was meant as one.
    private static func isPlausibleSchemeRelativeDestination(_ raw: String) -> Bool {
        guard raw.hasPrefix("//") else { return false }
        let tail = raw.dropFirst(2)
        if tail.first == "[", let close = tail.firstIndex(of: "]") {
            return isIPv6Literal(String(tail[...close]))
        }
        let delimiter = tail.firstIndex(where: { $0 == ":" || $0 == "/" })
        // URLComponents reads past any userinfo (`//user@example.com`), which the
        // delimiter split alone would misjudge as a single-label authority.
        let host = URLComponents(string: "https:" + raw)?.host
            ?? String(delimiter.map { tail[..<$0] } ?? tail)
        if host.contains(".") || host.contains(":") || host.lowercased() == "localhost" {
            return true
        }
        return delimiter != nil
    }

    private static func isIPv6Literal(_ raw: String) -> Bool {
        guard raw.first == "[", let close = raw.firstIndex(of: "]") else { return false }
        let address = String(raw[raw.index(after: raw.startIndex)..<close])
        let halves = address.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }

        func groups(in half: String) -> [String]? {
            guard !half.isEmpty else { return [] }
            let groups = half.components(separatedBy: ":")
            return groups.contains(where: \.isEmpty) ? nil : groups
        }

        guard let left = groups(in: halves[0]),
              let right = groups(in: halves.count == 2 ? halves[1] : "") else { return false }
        let groups = left + right
        var count = 0
        for (index, group) in groups.enumerated() {
            if group.contains(".") {
                guard index == groups.indices.last, isIPv4Address(group) else { return false }
                count += 2
            } else {
                guard (1...4).contains(group.utf8.count),
                      group.utf8.allSatisfy({ byte in
                          (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
                      }) else { return false }
                count += 1
            }
        }

        // `::` must stand for at least one omitted group. Without it, all eight groups
        // must be written; an embedded IPv4 address occupies the final two.
        return halves.count == 2 ? count < 8 : count == 8
    }

    private static func isIPv4Address(_ raw: String) -> Bool {
        let octets = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty, octet.count <= 3, let value = Int(octet) else { return false }
            return (0...255).contains(value)
        }
    }

    private static func isPlausibleEmail(_ raw: String) -> Bool {
        let address = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard let at = address.lastIndex(of: "@") else { return false }
        let domain = address[address.index(after: at)...]
        guard let suffix = domain.split(separator: ".").last,
              (2...63).contains(suffix.count) else { return false }
        // Numeric package versions such as `tool@1.2.34` are not email addresses.
        // Punycode contains ASCII letters, and native IDNs contain Unicode letters.
        return suffix.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func isPlausibleBareDomain(_ raw: String) -> Bool {
        if technologyDomainLookalikes.contains(raw) { return false }
        let host = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
        let withoutPort = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        // Foundation applies IDNA conversion here, so the same IANA snapshot covers
        // both `xn--...` spellings and a model-written Unicode host such as `例子.中国`.
        let normalized = URL(string: "https://\(withoutPort)")?.host ?? withoutPort
        guard let suffix = normalized.split(separator: ".").last?.lowercased() else { return false }
        if withoutPort.lowercased().hasPrefix("www.") || raw.contains("/") || raw.contains(":") {
            return true
        }
        guard !fileExtensions.contains(suffix) else { return false }
        // A non-ASCII host (`例子.中国`) is a domain spelling, never code, so the whole
        // IANA snapshot applies to it.
        if withoutPort.unicodeScalars.contains(where: { !$0.isASCII }) {
            return TopLevelDomain.contains(suffix)
        }
        // Without a path, a port or `www.`, a delegated suffix alone is too weak a signal:
        // `.data`, `.map`, `.fit`, `.is` and `.property` are real TLDs and also the
        // member access of every code answer. Flagging them would warn about links the
        // model never wrote and discard a correct revision whole — the worst outcome
        // for this check. A bare host therefore needs a suffix that reads as a
        // destination on its own: a high-confidence generic one, a delegated two-letter
        // country code that is not a common code word, or a reserved name.
        return genericTLDs.contains(suffix)
            || (suffix.count == 2 && TopLevelDomain.contains(suffix)
                && !ambiguousCodeSuffixes.contains(suffix))
            || reservedTopLevelDomains.contains(suffix)
    }

    /// Common file suffixes that are domain-like in prose. Several are also delegated
    /// domains (`.sh`, `.md`, `.zip`, `.app`, `.mov`); without a host signal such as a
    /// path or port they are overwhelmingly filenames, and the trust UI should prefer
    /// the high-precision reading.
    private static let fileExtensions: Set<String> = [
        "7z", "a", "ai", "app", "bat", "bash", "bz2", "c", "cc", "cfg", "cmd", "conf",
        "cpp", "csv", "css", "deb", "dll", "dmg", "doc", "docx", "dylib", "exe",
        "fish", "gif", "go", "gz", "h", "hpp", "html", "ini", "java", "jpeg", "jpg",
        "js", "json", "jsx", "kt", "kts", "lock", "log", "m", "markdown", "md", "mm", "mov",
        "o", "pdf", "pbxproj", "pkg", "plist", "png", "ppt", "pptx", "ps1", "py",
        "rar", "rb", "rpm", "rs", "scala", "sh", "so", "svg", "swift", "tar", "toml",
        "ts", "tsx", "txt", "webp", "xls", "xlsx", "xcconfig", "xml", "xz", "yaml",
        "yml", "zip", "zsh",
    ]

    /// Reserved-by-specification suffixes the IANA snapshot deliberately omits: they
    /// are not delegated, but they still name a destination a reader could resolve.
    private static let reservedTopLevelDomains: Set<String> = [
        "example", "invalid", "localhost", "test",
    ]

    /// Two-letter country codes that are also everyday code words (`x.is`, `user.id`).
    private static let ambiguousCodeSuffixes: Set<String> = ["as", "do", "id", "if", "in", "is", "to"]

    /// High-confidence suffixes that make a bare host destination-like on their own.
    /// Any other delegated suffix still counts with a path, a port, `www.` or a
    /// non-ASCII host; common file suffixes stay suppressed without that signal.
    private static let genericTLDs: Set<String> = [
        "academy", "aero", "agency", "ai", "app", "art", "biz", "blog", "cat", "center",
        "cloud", "co", "com", "company", "coop", "dev", "digital", "edu", "email", "game",
        "global", "gov", "group", "info", "int", "io", "jobs", "life", "link", "live", "me",
        "media", "mil", "mobi", "mov", "museum", "name", "net", "network", "news", "one",
        "online", "org", "page", "pro", "services", "shop", "site", "social", "solutions",
        "space", "store", "studio", "support", "systems", "tech", "today", "travel", "tv",
        "website", "world", "xyz",
    ]

    /// These case-sensitive tokens are product/framework names, not destinations.
    /// Lowercase spellings remain domains, as do these labels when they carry a path.
    private static let technologyDomainLookalikes: Set<String> = ["ADO.NET", "ASP.NET", "VB.NET"]
}
