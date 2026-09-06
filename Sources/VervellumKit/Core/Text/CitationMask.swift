import Foundation

/// Shared citation placement; each renderer supplies its own styling and links.
struct CitationMask {
    static let placeholder: Character = "\u{E000}"

    let text: String
    let sourceIndices: [[Int]]

    init(_ text: String, sourceCount: Int) {
        // Blocks have already been parsed. A table cell's backticks are inline syntax.
        let validation = CitationValidator.validate(answer: text, sourceCount: sourceCount, scope: .inline)
        var masked = ""
        var citations: [[Int]] = []

        for span in validation.spans {
            switch span {
            case .text(let value):
                // Raw placeholders must never steal a later citation's position.
                masked += value.replacingOccurrences(of: String(Self.placeholder), with: "")
            case .citation(let indices, _):
                masked.append(Self.placeholder)
                citations.append(indices)
            }
        }
        self.text = masked
        sourceIndices = citations
    }
}
