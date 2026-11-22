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
        /// Citation numbers outside `1...sourceCount` that the model invented. A range
        /// reports the bound that overshot rather than every number past the list, and a
        /// number too large for `Int` is recorded as `Int.max`. May contain duplicates.
        /// Consumers gate on `isEmpty`; no surface shows the raw array.
        var outOfRangeCitations: [Int]
        /// Bracketed groups that could not be read as a number or a range: a reversed
        /// range such as `[9-2]`, a malformed one such as `[1-3-5]`, or one wider than
        /// `maximumRangeExpansion`.
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
    /// The whitespace runs are possessive (`\s*+`) so a long run of spaces and digits
    /// with no closing bracket cannot make the engine partition the whitespace every
    /// which way. The pattern is matched against model-written text on every rendered
    /// block while an answer streams, so a degenerate marker must not stall that path.
    ///
    /// The digit count is unbounded on purpose. Capped at three, `[1000]` never matched,
    /// so exactly the numbers most likely to be invented were never reported. Magnitude
    /// is decided against the source list below, never by this pattern.
    private static let citationRegex = try? NSRegularExpression(
        pattern: #"\[\s*+\d++(?:\s*+(?:[,;]\s*+\d++|[-–—]\s*+\d++))*\s*+\]"#)

    /// Four-digit numbers read as years when nothing else shares their brackets. Every
    /// value is far past the longest source list, so none can be a real citation.
    private static let plausibleYears = 1500...2100
    private static let yearDigits = 4

    /// The most sources one range expands to: several times what the evidence pool can
    /// hold, and a bound for callers that validate against no list at all.
    static let maximumRangeExpansion = 256

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
            let raw = String(answer[range])
            // Newlines as well as spaces: the regex's `\s*` admits a marker that wraps
            // across a line, and a wrapped `[1,\n2]` is still one citation. Trimming
            // only spaces would leave `"\n2"` and flag it as malformed.
            let groups = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // A year in brackets is prose, so it stays inside the surrounding text
            // rather than becoming a marker that failed validation.
            if groups.allSatisfy(Self.namesYears) { continue }
            if cursor < range.lowerBound {
                spans.append(.text(String(answer[cursor..<range.lowerBound])))
            }

            var indices: [Int] = []
            // Deduplicated in first-occurrence order: a range can overlap a neighbour
            // (`[1, 1-3]`), and the chip's label is built from this order, so `[2, 1]`
            // must still read "2,1".
            var seen = Set<Int>()
            func cite(_ number: Int) {
                guard seen.insert(number).inserted else { return }
                indices.append(number - 1)
                cited.insert(number - 1)
            }

            for group in groups {
                if let single = Int(group) {
                    if single >= 1, single <= sourceCount {
                        cite(single)
                    } else {
                        outOfRange.append(single)
                    }
                } else if let bounds = Self.rangeBounds(in: group) {
                    if bounds.start > bounds.end {
                        // A reversed range is reported, not guessed at: forming a
                        // ClosedRange from the swapped endpoints would trap.
                        malformed.append(group)
                        continue
                    }
                    // A range is expanded in place, so `[1-3]` cites 1, 2 and 3 and
                    // renders as one chip naming all three. Only a bound past the source
                    // list is recorded as invented: walking to it would make the cost of
                    // validation a number the model chose.
                    if bounds.start < 1 { outOfRange.append(bounds.start) }
                    if bounds.end > sourceCount { outOfRange.append(bounds.end) }
                    let first = max(bounds.start, 1)
                    var last = min(bounds.end, sourceCount)
                    guard first <= last else { continue }
                    // Clamping is no bound when the caller passes `Int.max`, as history
                    // stripping does. The shortened range is reported, never cut silently.
                    if last - first >= Self.maximumRangeExpansion {
                        malformed.append(group)
                        last = first + Self.maximumRangeExpansion - 1
                    }
                    for number in first...last { cite(number) }
                } else if group.allSatisfy(\.isNumber) {
                    // A digit run `Int` rejects: too long, or digits ICU's `\d` matches
                    // and `Int` does not read. Either way it names no source.
                    outOfRange.append(.max)
                } else {
                    // Neither a number nor a range — more than one separator, or a
                    // non-numeric endpoint. It is reported rather than guessed at: a
                    // wrong expansion would cite sources the model never named.
                    malformed.append(group)
                }
            }
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

    /// Whether a group is a plausible year, or a forward span of them.
    private static func namesYears(_ group: String) -> Bool {
        if let year = year(group) { return plausibleYears.contains(year) }
        let parts = group.split(omittingEmptySubsequences: false,
                                whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, let first = year(parts[0]), let last = year(parts[1]) else { return false }
        return first <= last && plausibleYears.contains(first) && plausibleYears.contains(last)
    }

    /// `text` as a number, if it is written the way a year is: four ASCII digits.
    private static func year(_ text: String) -> Int? {
        guard text.count == yearDigits,
              text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// The two endpoints of a `[1-3]`-style group, or nil when the group is not a
    /// range at all. A group with more than one separator, or a non-numeric endpoint,
    /// answers nil so the caller reports it rather than guessing an expansion. The
    /// endpoints are returned unordered: a reversed range is a value the caller reports,
    /// and forming a `ClosedRange` from it would trap.
    private static func rangeBounds(in group: String) -> (start: Int, end: Int)? {
        guard let separator = group.firstIndex(where: { $0 == "-" || $0 == "–" || $0 == "—" })
        else { return nil }
        let lower = group[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = group[group.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
