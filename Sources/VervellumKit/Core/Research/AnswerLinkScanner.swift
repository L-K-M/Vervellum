import Foundation

/// Finds destination syntax in model-written prose.
///
/// This is deliberately separate from `SourceHarvester`. Harvesting accepts only a
/// fetchable HTTP URL and normalizes it; answer validation has the opposite job: flag
/// every syntax by which a model could express a destination instead of citing the
/// numbered list Vervellum owns. The stored notice is still named `literalURL` for
/// archive compatibility, but it covers links and bare domains as the prompt promises.
enum AnswerLinkScanner {

    private struct Candidate {
        var range: NSRange
        var text: String
    }

    /// Destination-like runs, in source order, with overlapping spellings collapsed to
    /// the widest outer form (for example, one Markdown link rather than its inner host).
    static func forbiddenLinks(
        in text: String,
        markdownExclusions: [Range<String.Index>] = []
    ) -> [String] {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        var candidates: [Candidate] = []
        let excludedMarkdown = markdownExclusions.map { NSRange($0, in: text) }

        candidates += markdownDestinations(in: text, excluding: excludedMarkdown)
        appendMatches(of: markdownReferenceDefinition, in: text, range: whole,
                      excluding: excludedMarkdown, to: &candidates)
        appendMatches(of: markdownEmailAutolink, in: text, range: whole, to: &candidates) {
            isPlausibleEmail($0)
        }
        appendMatches(of: emailAddress, in: text, range: whole, to: &candidates) {
            isPlausibleEmail($0)
        }
        appendMatches(of: hierarchicalURI, in: text, range: whole, to: &candidates)
        appendMatches(of: opaqueURI, in: text, range: whole, to: &candidates)
        appendMatches(of: protocolRelativeURL, in: text, range: whole, to: &candidates) {
            isPlausibleProtocolRelativeURL($0)
        }
        appendMatches(of: bareIPv4, in: text, range: whole, to: &candidates)
        appendMatches(of: bareIPv6, in: text, range: whole, to: &candidates) { value in
            isIPv6Literal(value)
        }
        appendMatches(of: bareDomain, in: text, range: whole, to: &candidates) { value in
            isPlausibleBareDomain(value)
        }

        candidates.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.range.length > $1.range.length
        }

        var accepted: [Candidate] = []
        for candidate in candidates {
            // Candidates are start-sorted and accepted ranges never overlap, so only
            // the latest accepted range can overlap this one. Scanning the whole result
            // for every URL makes a long source list quadratic.
            if let last = accepted.last,
               NSIntersectionRange(last.range, candidate.range).length > 0 { continue }
            accepted.append(candidate)
        }
        var seen: Set<String> = []
        return accepted.compactMap { candidate in
            let display = trimmedDisplay(candidate.text)
            return seen.insert(display).inserted ? display : nil
        }
    }

    private static func appendMatches(
        of regex: NSRegularExpression?,
        in text: String,
        range: NSRange,
        excluding exclusions: [NSRange] = [],
        to candidates: inout [Candidate],
        accepting: (String) -> Bool = { _ in true }
    ) {
        guard let regex else { return }
        for match in regex.matches(in: text, range: range) {
            guard !exclusions.contains(where: { NSLocationInRange(match.range.location, $0) })
            else { continue }
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let value = String(text[swiftRange])
            guard accepting(value) else { continue }
            candidates.append(Candidate(range: match.range, text: value))
        }
    }

    /// Finds inline and reference-style Markdown links with balanced labels and
    /// destinations. A regex can cover only a chosen nesting depth; a linear walk keeps
    /// working for `[a [b [c]]](#details)` without becoming a Markdown renderer.
    private static func markdownDestinations(
        in text: String,
        excluding exclusions: [NSRange]
    ) -> [Candidate] {
        var found: [Candidate] = []
        let squareMatches = matchingDelimiters(in: text, opening: "[", closing: "]")
        let parenthesisMatches = matchingDelimiters(in: text, opening: "(", closing: ")")
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "[",
                  let labelEnd = squareMatches[index] else {
                index = text.index(after: index)
                continue
            }

            let suffixStart = text.index(after: labelEnd)
            var destinationEnd: String.Index?
            if suffixStart < text.endIndex, text[suffixStart] == "(" {
                destinationEnd = parenthesisMatches[suffixStart]
            } else if suffixStart < text.endIndex, text[suffixStart] == "[" {
                destinationEnd = squareMatches[suffixStart]
            }

            guard let destinationEnd else {
                // The outer label was not a link, but it may contain one that is. Move
                // one character rather than past the label so the nested opener is seen.
                index = text.index(after: index)
                continue
            }

            let upperBound = text.index(after: destinationEnd)
            let range = NSRange(index..<upperBound, in: text)
            if !exclusions.contains(where: { NSLocationInRange(range.location, $0) }) {
                found.append(Candidate(range: range, text: String(text[index..<upperBound])))
            }
            index = upperBound
        }
        return found
    }

    /// Computes every balanced pair in one pass. Looking for a closing delimiter from
    /// each `[` separately makes an answer containing many unmatched openers quadratic.
    private static func matchingDelimiters(
        in text: String,
        opening: Character,
        closing: Character
    ) -> [String.Index: String.Index] {
        var stack: [String.Index] = []
        var matches: [String.Index: String.Index] = [:]
        var escaped = false
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == opening {
                stack.append(cursor)
            } else if character == closing, let start = stack.popLast() {
                matches[start] = cursor
            }
            cursor = text.index(after: cursor)
        }
        return matches
    }

    private static let markdownReferenceDefinition = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}\[[^\]\r\n]+\]:[ \t]*(?:<[^>\r\n]*>|[^\s<>]+)(?:[ \t]+(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|\([^\)\r\n]*\)))?[ \t]*$"#)

    private static let markdownEmailAutolink = try? NSRegularExpression(
        pattern: #"(?i)<[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+@[\p{L}\p{N}.-]+\.[\p{L}\p{N}-]{2,63}>"#)

    private static let emailAddress = try? NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-])[\p{L}\p{N}.!#$%&'*+/=?^_`{|}~-]+@[\p{L}\p{N}](?:[\p{L}\p{N}.-]{0,251}[\p{L}\p{N}])?\.[\p{L}\p{N}-]{2,63}"#)

    /// Every RFC-style scheme followed by `//`, including protocols Vervellum never
    /// fetches. A finite allow-list here would merely teach a model which spelling gets
    /// past the rule.
    private static let hierarchicalURI = try? NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#)

    /// Common opaque schemes have no `//`; prose labels such as `Note:` stay outside
    /// this narrower list.
    private static let opaqueURI = try? NSRegularExpression(
        pattern: #"(?i)\b(?:data|file|javascript|magnet|mailto|news|sms|tel|urn):[^\s<>\"']+"#)

    private static let protocolRelativeURL = try? NSRegularExpression(
        pattern: #"(?i)(?<![:/\p{L}\p{N}_-])//(?:\[[0-9a-f:.]+\]|[\p{L}\p{N}](?:[\p{L}\p{N}.-]{0,251}[\p{L}\p{N}])?)(?::[0-9]{1,5})?(?:/[^\s<>\"']*)?"#)

    // A bare IPv4 address is indistinguishable from a four-part numeric version such
    // as `1.2.3.4`. Detection wins that ambiguity: otherwise a model has a reliable
    // spelling for a fabricated destination with no scheme, port, or path.
    private static let bareIPv4 = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_.-])(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?![\p{L}\p{N}_.-])(?::[0-9]{1,5})?(?:/[^\s<>\"']*)?"#)

    private static let bareIPv6 = try? NSRegularExpression(
        pattern: #"(?i)\[(?=[0-9a-f:.]*:)[0-9a-f:.]+\](?::[0-9]{1,5})?(?:/[^\s<>\"']*)?"#)

    /// Conservative boundaries keep this from starting in an absolute URL or member
    /// access. The final label is checked against the root zone below unless the token
    /// carries an unambiguous host signal such as `www.`, a port, or a path.
    private static let bareDomain = try? NSRegularExpression(
        pattern: #"(?i)(?<![@/:\p{L}\p{N}_-])(?:www\.)?(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?(?::[0-9]{1,5})?(?:/[^\s<>\"']*)?"#)

    private static let reservedTopLevelDomains: Set<String> = [
        "example", "invalid", "localhost", "test",
    ]

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

    private static func isPlausibleProtocolRelativeURL(_ raw: String) -> Bool {
        guard raw.hasPrefix("//") else { return false }
        let hostStart = raw.index(raw.startIndex, offsetBy: 2)
        guard hostStart < raw.endIndex else { return false }
        if raw[hostStart] == "[" {
            guard let close = raw[hostStart...].firstIndex(of: "]") else { return false }
            return isIPv6Literal(String(raw[hostStart...close]))
        }

        let tail = raw[hostStart...]
        let delimiter = tail.firstIndex(where: { $0 == ":" || $0 == "/" })
        let host = delimiter.map { tail[..<$0] } ?? tail[...]
        if host.contains(".") || host.lowercased() == "localhost" { return true }
        // A single-label authority is indistinguishable from a no-space source-code
        // comment (`//TODO`) until a port or path makes the URL intent explicit.
        return delimiter != nil
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
        let host = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
        let withoutPort = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        // Foundation applies IDNA conversion here, so the same IANA snapshot covers
        // both `xn--...` spellings and a model-written Unicode host such as `例子.中国`.
        let normalized = URL(string: "https://\(withoutPort)")?.host ?? withoutPort
        let labels = normalized.split(separator: ".")
        guard let suffix = labels.last?.lowercased() else { return false }
        if withoutPort.lowercased().hasPrefix("www.") || raw.contains("/") || raw.contains(":") {
            return true
        }
        return TopLevelDomain.contains(suffix) || reservedTopLevelDomains.contains(suffix)
    }

    private static func trimmedDisplay(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, ".,;:!?".contains(last) { result.removeLast() }
        var parenthesisBalance = 0
        for character in result {
            if character == "(" { parenthesisBalance += 1 }
            if character == ")" { parenthesisBalance -= 1 }
        }
        while result.last == ")", parenthesisBalance < 0 {
            result.removeLast()
            parenthesisBalance += 1
        }
        return result
    }
}
