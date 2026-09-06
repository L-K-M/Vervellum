import Foundation

/// Shared citation placement; each renderer supplies its own styling and links.
struct CitationMask {
    static let placeholder: Character = "\u{FFFC}"

    let text: String
    let sourceIndices: [[Int]]

    init(_ text: String, sourceCount: Int) {
        let validation = CitationValidator.validate(answer: text, sourceCount: sourceCount)
        var masked = ""
        var citations: [[Int]] = []

        for span in validation.spans {
            switch span {
            case .text(let value):
                masked += value
            case .citation(let indices, _):
                masked.append(Self.placeholder)
                citations.append(indices)
            }
        }
        self.text = masked
        sourceIndices = citations
    }
}
