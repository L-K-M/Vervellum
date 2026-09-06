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
        /// Literal URLs the model wrote despite being told not to.
        var literalURLs: [String]

        var isClean: Bool { outOfRangeCitations.isEmpty && literalURLs.isEmpty }
    }

    /// Matches `[3]`, `[3, 4]`, `[3,4 , 12]` — digits and separators only, so an
    /// ordinary markdown link `[text](url)` or a bracketed aside never matches.
    private static let citationRegex = try? NSRegularExpression(
        pattern: #"\[\s*\d{1,3}(?:\s*[,;]\s*\d{1,3})*\s*\]"#)

    /// Parses `answer` against a source list of `sourceCount` entries.
    ///
    /// Code is not prose: a bracketed number inside a fenced block or a backtick span
    /// (`argv[0]`, `items[1]`) is an index, not a citation, and both renderers already
    /// show code literally. Reading it as a citation here would accuse the model of
    /// inventing source `[0]`, mark source 1 as "cited" by a code sample, and — for a
    /// backtick span — render a chip in the middle of the code. So markers inside code
    /// are left as text, and the validator, the renderers and the transcript agree.
    static func validate(answer: String, sourceCount: Int) -> Result {
        var spans: [Span] = []
        var cited: Set<Int> = []
        var outOfRange: [Int] = []

        guard let regex = citationRegex else {
            return Result(spans: [.text(answer)], citedSourceIndices: [],
                          outOfRangeCitations: [], literalURLs: SourceHarvester.bareURLs(in: answer))
        }

        let full = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        let code = codeRanges(in: answer)
        var cursor = answer.startIndex

        for match in regex.matches(in: answer, range: full) {
            guard let range = Range(match.range, in: answer) else { continue }
            if code.contains(where: { $0.overlaps(range) }) { continue }
            if cursor < range.lowerBound {
                spans.append(.text(String(answer[cursor..<range.lowerBound])))
            }
            let raw = String(answer[range])
            let numbers = raw
                .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

            var indices: [Int] = []
            for number in numbers {
                if number >= 1 && number <= sourceCount {
                    indices.append(number - 1)
                    cited.insert(number - 1)
                } else {
                    outOfRange.append(number)
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
                      literalURLs: SourceHarvester.bareURLs(in: answer))
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
        var fenceStart: String.Index?
        var lineStart = text.startIndex
        var paragraphStart = text.startIndex

        func flushInline(to end: String.Index) {
            ranges.append(contentsOf: inlineCodeRanges(in: text[paragraphStart..<end]))
        }

        while lineStart < text.endIndex {
            // CRLF is one Swift Character; searching only for LF misses the whole line.
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let nextLine = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            let trimmed = text[lineStart..<lineEnd].drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if let start = fenceStart {
                    ranges.append(start..<lineEnd)
                    fenceStart = nil
                } else {
                    flushInline(to: lineStart)
                    fenceStart = lineStart
                }
                paragraphStart = nextLine
            } else if fenceStart == nil, trimmed.isEmpty {
                flushInline(to: lineStart)
                paragraphStart = nextLine
            }
            lineStart = nextLine
        }
        if let start = fenceStart {
            ranges.append(start..<text.endIndex)
        } else {
            flushInline(to: text.endIndex)
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
