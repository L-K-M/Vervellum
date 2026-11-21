import Foundation

/// Validates and parses the numeric citations in a model's answer.
///
/// Vervellum's answer prompt forbids the model from writing URLs at all: it may
/// only refer to evidence by the index of a source Vervellum itself fetched, as
/// `[3]` or `[1, 4]`. That single rule is what makes a fabricated link
/// *structurally impossible* rather than merely discouraged — there is no syntax in
/// which the model could express one, and any URL that appears anyway is a prompt
/// violation the validator can flag on sight.
///
/// Checking indices is also cheaper and far more reliable than string-matching URLs:
/// a model that reformats a link (adds a tracking parameter, drops a trailing slash,
/// percent-encodes a character) would fail an exact-match allow-list even though it
/// cited a real source. An integer either is or isn't in range.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum CitationValidator {

    enum Scope { case document, inline }

    /// One piece of a parsed answer: either literal text, or a citation referring to
    /// `sourceIndices` (already converted to zero-based positions in the source list).
    enum Span: Equatable {
        case text(String)
        case citation(sourceIndices: [Int], raw: String)
    }

    /// What validation found. `isClean` is the only thing the UI gates trust on.
    struct Result: Equatable {
        /// The answer split into renderable spans, in order.
        var spans: [Span]
        /// Zero-based source indices actually cited, ascending.
        var citedSourceIndices: [Int]
        /// Citation numbers outside `1...sourceCount` that the model invented.
        var outOfRangeCitations: [Int]
        /// Bracketed groups that could not be read as a number or a range — a
        /// reversed range such as `[9-2]`, or a malformed one such as `[1-3-5]`.
        /// They carry the same `invalidCitation` notice an invented number does.
        var invalidCitationGroups: [String]
        /// Direct destinations the model wrote despite being told to cite by number.
        /// Populated only for document scope; inline scope exists solely for the
        /// renderer's citation masking and deliberately skips destination scanning.
        var forbiddenLinks: [String]

        var isClean: Bool {
            outOfRangeCitations.isEmpty && invalidCitationGroups.isEmpty && forbiddenLinks.isEmpty
        }
    }

    /// Matches `[3]`, `[3, 4]`, `[3,4 , 12]` and the range spellings `[1-3]`,
    /// `[1–3]`, `[2—4]` — digits and separators only, so an ordinary markdown link
    /// `[text](url)` or a bracketed aside never matches. A range is expanded by the
    /// parser below; a group that cannot be read as a number or a range is reported.
    private static let citationRegex = try? NSRegularExpression(
        pattern: #"\[\s*\d{1,3}(?:\s*(?:[,;]\s*\d{1,3}|[-–—]\s*\d{1,3}))*\s*\]"#)

    /// Parses `answer` against a source list of `sourceCount` entries.
    ///
    /// Code is not prose: a bracketed number inside a fenced block or a backtick span
    /// (`argv[0]`, `items[1]`) is an index, not a citation, and both renderers already
    /// show code literally. Reading it as a citation here would accuse the model of
    /// inventing source `[0]`, mark source 1 as "cited" by a code sample, and — for a
    /// backtick span — render a chip in the middle of the code. So markers inside code
    /// are left as text, and the validator, the renderers and the transcript agree.
    static func validate(answer: String, sourceCount: Int, scope: Scope = .document) -> Result {
        var spans: [Span] = []
        var cited: Set<Int> = []
        var outOfRange: [Int] = []
        var malformed: [String] = []
        let code = scope == .document ? codeRanges(in: answer) : inlineCodeRanges(in: answer[...])
        // Inline validation runs for every rendered Markdown block while an answer is
        // streaming, and its caller uses only citation spans. Destination policy is a
        // final-document decision; scanning here would repeat several regex walks on
        // every token-driven render and discard the result.
        let forbiddenLinks = scope == .document
            ? ForbiddenLinkScanner.links(in: answer, excludingMarkdownSyntaxIn: code)
            : []

        guard let regex = citationRegex else {
            return Result(spans: [.text(answer)], citedSourceIndices: [],
                          outOfRangeCitations: [], invalidCitationGroups: [],
                          forbiddenLinks: forbiddenLinks)
        }

        let full = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        var cursor = answer.startIndex

        for match in regex.matches(in: answer, range: full) {
            guard let range = Range(match.range, in: answer) else { continue }
            if code.contains(where: { $0.overlaps(range) }) { continue }
            if cursor < range.lowerBound {
                spans.append(.text(String(answer[cursor..<range.lowerBound])))
            }
            let raw = String(answer[range])
            let inner = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            func record(_ number: Int) {
                if number >= 1 && number <= sourceCount {
                    cited.insert(number - 1)
                } else {
                    outOfRange.append(number)
                }
            }

            var indices: [Int] = []
            for group in inner.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let trimmed = group.trimmingCharacters(in: .whitespaces)
                if let single = Int(trimmed) {
                    record(single)
                    if single >= 1, single <= sourceCount { indices.append(single - 1) }
                } else if let bounds = Self.rangeBounds(in: trimmed) {
                    if bounds.start > bounds.end {
                        // A reversed range is reported, not guessed at: forming a
                        // ClosedRange from the swapped endpoints would trap.
                        malformed.append(trimmed)
                        continue
                    }
                    // A range is expanded in place, so `[1-3]` cites 1, 2 and 3 and
                    // renders as one chip naming all three. Endpoints past the source
                    // list are recorded as invented, exactly as a bare `[99]` is.
                    for number in bounds.start...bounds.end {
                        record(number)
                        if number >= 1, number <= sourceCount { indices.append(number - 1) }
                    }
                } else {
                    // Neither a number nor a range — more than one separator, or a
                    // non-numeric endpoint. It is reported rather than guessed at: a
                    // wrong expansion would cite sources the model never named.
                    malformed.append(trimmed)
                }
            }
            // Deduplicated in first-occurrence order: a range can overlap a neighbour
            // (`[1, 1-3]`), and the chip's label is built from this order, so `[2, 1]`
            // must still read "2,1".
            var unique: [Int] = []
            for index in indices where !unique.contains(index) { unique.append(index) }
            indices = unique
            // A marker whose every number was invented is kept as plain text rather
            // than rendered as a chip that leads nowhere.
            if indices.isEmpty {
                spans.append(.text(raw))
            } else {
                spans.append(.citation(sourceIndices: indices, raw: raw))
            }
            cursor = range.upperBound
        }

        if cursor < answer.endIndex {
            spans.append(.text(String(answer[cursor...])))
        }
        if spans.isEmpty { spans = [.text(answer)] }

        return Result(spans: spans,
                      citedSourceIndices: cited.sorted(),
                      outOfRangeCitations: outOfRange,
                      invalidCitationGroups: malformed,
                      forbiddenLinks: forbiddenLinks)
    }

    /// The two endpoints of a `[1-3]`-style group, or nil when the group is not a
    /// range at all. A group with more than one separator, or a non-numeric endpoint,
    /// answers nil so the caller reports it rather than guessing an expansion. The
    /// endpoints are returned unordered: a reversed range is a value the caller reports,
    /// and forming a `ClosedRange` from it would trap.
    private static func rangeBounds(in group: String) -> (start: Int, end: Int)? {
        guard let separator = group.firstIndex(where: { $0 == "-" || $0 == "–" || $0 == "—" })
        else { return nil }
        let lower = group[..<separator].trimmingCharacters(in: .whitespaces)
        let upper = group[group.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard let start = Int(lower), let end = Int(upper) else { return nil }
        return (start, end)
    }

    // MARK: Code

    /// The ranges of `text` that are code: fenced blocks (``` or ~~~, to the closing
    /// fence or to the end when it has not arrived yet) and inline backtick spans.
    ///
    /// Deliberately the same block rule `MarkdownParser` applies, so what the validator
    /// skips is exactly what the renderers show literally. An unterminated fence is
    /// the normal case mid-stream, and everything after it is code until the closer
    /// arrives — which is also what the renderer draws.
    static func codeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        // Consume the renderer's parser, rather than maintaining a second set of
        // block rules that can pair backticks across headings, bullets, or cells.
        for block in MarkdownParser.parse(text) {
            let raw = text[block.sourceRange]
            switch block.kind {
            case .code:
                ranges.append(block.sourceRange)
            case .table:
                for line in raw.split(whereSeparator: \.isNewline) {
                    for cell in MarkdownParser.tableCells(in: line) {
                        ranges.append(contentsOf: inlineCodeRanges(in: cell))
                    }
                }
            default:
                ranges.append(contentsOf: inlineCodeRanges(in: raw))
            }
        }
        return ranges
    }

    private static func isEscaped(_ index: String.Index, in text: Substring) -> Bool {
        var cursor = index
        var slashes = 0
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            guard text[cursor] == "\\" else { break }
            slashes += 1
        }
        return !slashes.isMultiple(of: 2)
    }

    /// Matched backtick runs may span lines, but not paragraphs. An unmatched or
    /// escaped opener remains prose, so it cannot suppress subsequent citations.
    private static func inlineCodeRanges(in line: Substring) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index] == "`", !isEscaped(index, in: line) else {
                index = line.index(after: index)
                continue
            }
            let runEnd = line[index...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
            let length = line.distance(from: index, to: runEnd)
            var search = runEnd
            var closer: Range<String.Index>?
            while search < line.endIndex, closer == nil {
                guard line[search] == "`" else { search = line.index(after: search); continue }
                let candidateEnd = line[search...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
                if line.distance(from: search, to: candidateEnd) == length {
                    closer = search..<candidateEnd
                }
                search = candidateEnd
            }
            guard let closer else { index = runEnd; continue }
            ranges.append(index..<closer.upperBound)
            index = closer.upperBound
        }
        return ranges
    }
}
