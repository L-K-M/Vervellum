import Foundation

/// Renders a turn as plain text, including incomplete research.
///
/// One formatter for two very different destinations — the macOS Copy button and the
/// Linux command line — because the hard part is not the layout, it is deciding what
/// must travel with the prose for it to still mean anything. Copying an answer whose
/// `[3]` markers point at nothing is worse than useless, so the cited sources come
/// with it; so do the verdicts, because an answer without them is exactly the
/// confident-sounding paragraph this app exists to replace.
///
/// Only sources cited by the exported prose or findings are listed. A dump of everything
/// the search happened to return misrepresents what the research actually rests on.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum TranscriptFormatter {

    static func plainText(_ turn: ResearchTurn) -> String {
        var lines: [String] = [turn.question, ""]

        // Copy is available during streaming; partial work must not look verified.
        if turn.stage != .complete {
            lines.append("Status: \(turn.stage.label) — research is incomplete.")
            lines.append("")
        }

        if let failure = turn.failure {
            lines.append("Failed: " + failure)
            lines.append("")
        }

        lines.append(turn.answer)
        var citedNumbers = Set(turn.findings.flatMap(\.sourceNumbers))
        citedNumbers.formUnion(sourceNumbers(in: turn.answer, turn: turn))

        // The earlier answer gives readers the same comparison available in the panel.
        // A blank draft or one identical to the answer adds nothing to the export.
        if let draft = turn.draftAnswer,
           DraftComparison.isOffered(draft: draft, answer: turn.answer) {
            lines.append("")
            let comparison = DraftComparison.description(for: turn)
            lines.append(comparison.heading)
            if !turn.findings.isEmpty { lines.append(comparison.hint) }
            lines.append(draft)
            citedNumbers.formUnion(sourceNumbers(in: draft, turn: turn))
        }

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

        // A verdict can cite evidence the prose did not. Every exported reference
        // needs its source, without listing unrelated search hits or duplicates.
        let cited = turn.sources.filter { citedNumbers.contains($0.number) }
            .sorted { $0.number < $1.number }
        if !cited.isEmpty {
            lines.append("")
            lines.append("Sources")
            // A pasted transcript is read away from the panel, where the source rows say
            // which pages were actually read. It has to carry the same distinction, or
            // every citation in it looks equally strong.
            lines.append(contentsOf: cited.map {
                "[\($0.number)] \($0.title) — \($0.url)"
                    + ($0.wasRead ? " (page read)" : " (search summary)")
            })
        }

        if !turn.limitations.isEmpty {
            lines.append("")
            lines.append("Limitations: " + turn.limitations)
        }

        for notice in turn.notices {
            lines.append("")
            lines.append("Note: " + notice.message)
        }

        return lines.joined(separator: "\n")
    }

    private static func sourceNumbers(in prose: String, turn: ResearchTurn) -> [Int] {
        let validation = CitationValidator.validate(answer: prose, sourceCount: turn.sources.count)
        return turn.citedSources(using: validation).map(\.number)
    }
}
