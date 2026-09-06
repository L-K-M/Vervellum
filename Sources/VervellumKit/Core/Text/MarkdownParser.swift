import Foundation

/// Splits a markdown answer into renderable blocks.
///
/// Written rather than borrowed for one reason: the text arrives **while it is being
/// parsed**. A streaming answer is re-parsed on every chunk, so the parser must
/// produce something sensible from `## Head` with no newline yet, from `**bold` with
/// no closing marker, and from a code fence that has not been closed. A parser that
/// throws, or that swallows a partial construct until it completes, makes the answer
/// visibly stutter as it arrives.
///
/// So every rule here degrades rather than fails: an unterminated fence is emitted as
/// a code block anyway, an unterminated emphasis marker simply renders literally
/// until its partner arrives, and no input is ever rejected.
///
/// Inline emphasis is deliberately *not* handled — that is left to
/// `AttributedString(markdown:)` in the view, which already does it well. This type
/// only decides block structure, which `AttributedString` does not do at all.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum MarkdownParser {

    /// One renderable block.
    struct Block: Identifiable, Equatable {
        enum Kind: Equatable {
            case paragraph
            /// `#` … `######`, clamped to 1...3 — a panel this narrow has no use for
            /// six heading sizes, and models emit `####` freely.
            case heading(Int)
            case bullet(depth: Int)
            case ordered(number: Int, depth: Int)
            case quote
            /// A fenced code block. The payload is the info string (`swift`, `json`).
            case code(language: String)
            /// A pipe table. The payload carries the header row and the body rows;
            /// `text` is unused (empty), like `.rule`.
            case table(headers: [String], rows: [[String]])
            case rule
        }

        var id: Int
        var kind: Kind
        /// The block's inline markdown source, with its marker removed. Empty for
        /// `.rule`; the verbatim body for `.code`.
        var text: String
    }

    /// Parses `markdown` into blocks.
    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String]?
        var codeLanguage = ""
        var nextID = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            blocks.append(Block(id: nextID, kind: .paragraph, text: text))
            nextID += 1
        }

        func append(_ kind: Block.Kind, _ text: String) {
            flushParagraph()
            blocks.append(Block(id: nextID, kind: kind, text: text))
            nextID += 1
        }

        // `components(separatedBy: .newlines)` would split "\r\n" into two lines and
        // insert a spurious paragraph break for every line of Windows-style output.
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Index-based rather than `for`: the increment happens right after the read,
        // so every `continue` below keeps working, and table parsing can consume a
        // run of lines (header, delimiter, rows) by moving the index itself.
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            index = lines.index(after: index)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Inside a fence, everything is literal until the closing fence.
            if codeLines != nil {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    append(.code(language: codeLanguage), (codeLines ?? []).joined(separator: "\n"))
                    codeLines = nil
                    codeLanguage = ""
                } else {
                    codeLines?.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                codeLines = []
                codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if isRule(trimmed) {
                append(.rule, "")
                continue
            }

            if let (level, text) = heading(trimmed) {
                append(.heading(level), text)
                continue
            }

            if trimmed.hasPrefix(">") {
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                // Consecutive quote lines merge into one block, the way markdown means
                // them, instead of stacking one bar per line.
                if paragraph.isEmpty, var last = blocks.last, last.kind == .quote {
                    last.text += "\n" + text
                    blocks[blocks.count - 1] = last
                } else {
                    append(.quote, text)
                }
                continue
            }

            let depth = indentDepth(line)
            if let text = bullet(trimmed) {
                append(.bullet(depth: depth), text)
                continue
            }
            if let (number, text) = ordered(trimmed) {
                append(.ordered(number: number, depth: depth), text)
                continue
            }

            // A pipe line whose next line is a delimiter row with the same column
            // count is a table (GFM). The delimiter is the trigger, never the pipes
            // alone: "a | b" in prose must not become a table because the next line
            // happens to be dashes. Column-count equality is the second guard —
            // CommonMark demands it, and it stops a rule line ("---") from pairing
            // with a stray pipe above it.
            if trimmed.contains("|"), index < lines.endIndex,
               let columns = delimiterColumns(of: lines[index]) {
                let header = splitRow(trimmed)
                if header.count == columns {
                    flushParagraph()
                    index = lines.index(after: index)   // consume the delimiter
                    var rows: [[String]] = []
                    while index < lines.endIndex {
                        let rowLine = lines[index]
                        let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                        guard !rowTrimmed.isEmpty, rowTrimmed.contains("|") else { break }
                        index = lines.index(after: index)
                        // A repeated delimiter inside the body is decoration, not a row.
                        if delimiterColumns(of: rowLine) != nil { continue }
                        rows.append(splitRow(rowTrimmed, columns: columns))
                    }
                    append(.table(headers: header, rows: rows), "")
                    continue
                }
            }

            paragraph.append(trimmed)
        }

        // A fence still open at the end of the input is normal mid-stream: emit what
        // has arrived rather than hiding it until the closer shows up.
        if let codeLines {
            append(.code(language: codeLanguage), codeLines.joined(separator: "\n"))
        }
        flushParagraph()
        return blocks
    }

    // MARK: Line classification

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0 else { return nil }
        // "#hashtag" is not a heading; ATX headings require a space after the hashes.
        guard index < line.endIndex, line[index] == " " else { return nil }
        let text = String(line[index...]).trimmingCharacters(in: .whitespaces)
        // Trailing hashes are a closing sequence in ATX, not content.
        let cleaned = text.hasSuffix("#")
            ? String(text.reversed().drop(while: { $0 == "#" }).reversed())
                .trimmingCharacters(in: .whitespaces)
            : text
        return (min(level, 3), cleaned)
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func ordered(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        for character in ["-", "*", "_"] where line.allSatisfy({ String($0) == character }) {
            return true
        }
        return false
    }

    /// Nesting depth from leading whitespace, two spaces or one tab per level,
    /// capped so a runaway indent cannot push text off a narrow panel.
    private static func indentDepth(_ line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 }
            else if character == "\t" { spaces += 2 }
            else { break }
        }
        return min(spaces / 2, 3)
    }

    // MARK: Tables

    /// The column count of a table delimiter row (`|---|---|`, `:--|--:`), or nil
    /// when the line is not one. Every cell must be dashes with optional alignment
    /// colons, and at least one cell must exist.
    static func delimiterColumns(of line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return nil }
        let cells = splitRow(trimmed)
        guard !cells.isEmpty else { return nil }
        for cell in cells {
            let body = cell.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, body.contains("-"),
                  body.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
        }
        return cells.count
    }

    /// Splits a table row into cells: the optional outer pipes dropped, cells split
    /// on `|` (except `\|`, which becomes a literal pipe), each trimmed. Rows are
    /// normalised to `columns` when given — short rows pad with empty cells, long
    /// ones drop their tail, so the renderer never juggles ragged rows.
    static func splitRow(_ line: String, columns: Int? = nil) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }

        var cells: [String] = []
        var current = ""
        for character in body {
            if character == "|", !current.hasSuffix("\\") {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current)

        var result = cells.map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|")
        }
        if let columns {
            if result.count < columns {
                result += Array(repeating: "", count: columns - result.count)
            } else if result.count > columns {
                result = Array(result.prefix(columns))
            }
        }
        return result
    }
}
