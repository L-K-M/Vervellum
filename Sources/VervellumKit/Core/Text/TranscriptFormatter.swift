import Foundation

/// Renders a finished turn as plain text.
///
/// One formatter for two very different destinations — the macOS Copy button and the
/// Linux command line — because the hard part is not the layout, it is deciding what
/// must travel with the prose for it to still mean anything. Copying an answer whose
/// `[3]` markers point at nothing is worse than useless, so the cited sources come
/// with it; so do the verdicts, because an answer without them is exactly the
/// confident-sounding paragraph this app exists to replace.
///
/// Only *cited* sources are listed. A dump of everything the search happened to return
/// misrepresents what the answer actually rests on.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum TranscriptFormatter {

    static func plainText(_ turn: ResearchTurn) -> String {
        var lines: [String] = [turn.question, ""]

        // A failure after the answer streamed — the reply was cut off, the app quit
        // before the checks ran — must not throw the answer away: it is on the turn,
        // it is on screen, and the provider was paid for it. Only a turn with nothing
        // to show is reduced to its failure; otherwise the failure trails the answer.
        if let failure = turn.failure, turn.answer.isEmpty {
            lines.append("Failed: " + failure)
            return lines.joined(separator: "\n")
        }

        // A stopped run must say so. A truncated paragraph over an ordinary Sources
        // section reads as the model simply stopping there, and nobody would know its
        // claims were never checked.
        if turn.stage == .cancelled {
            lines.append("Stopped before the answer finished; what follows is incomplete.")
            lines.append("")
        }

        lines.append(turn.answer)

        if !turn.findings.isEmpty {
            lines.append("")
            lines.append("Claims")
            for finding in turn.findings {
                let citation = finding.sourceNumbers.isEmpty
                    ? ""
                    : " [" + finding.sourceNumbers.map(String.init).joined(separator: ",") + "]"
                lines.append("- \(finding.verdict.label.uppercased())\(citation): \(finding.claim)")
                if !finding.reasoning.isEmpty { lines.append("  \(finding.reasoning)") }
            }
        }

        // Everything the text above points at: the prose's citations, in the order
        // they appear, then any source only a verdict cites. The assessor is shown the
        // whole evidence block and routinely grades a claim against a source the prose
        // never used, and a `[3]` on a claim with no `[3]` below it is exactly the
        // dangling marker this section exists to prevent.
        var cited = turn.citedSources(
            using: CitationValidator.validate(answer: turn.answer, sourceCount: turn.sources.count))
        let verdictNumbers = Set(turn.findings.flatMap(\.sourceNumbers))
        cited += turn.sources
            .filter { verdictNumbers.contains($0.number) && !cited.contains($0) }
            .sorted { $0.number < $1.number }
        if !cited.isEmpty {
            lines.append("")
            lines.append("Sources")
            lines.append(contentsOf: cited.map { "[\($0.number)] \($0.title) — \($0.url)" })
        }

        if !turn.limitations.isEmpty {
            lines.append("")
            lines.append("Limitations: " + turn.limitations)
        }

        if let failure = turn.failure {
            lines.append("")
            lines.append("Failed: " + failure)
        }

        for notice in turn.notices {
            lines.append("")
            lines.append("Note: " + notice.message)
        }

        return lines.joined(separator: "\n")
    }
}
