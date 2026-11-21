import Foundation

/// Whether a turn still has a first draft worth comparing with the answer on screen.
///
/// The revision and regather notices say the draft is kept for comparison. Offering
/// it only when it differs from the answer avoids a disclosure that opens onto the
/// same prose.
enum DraftComparison {
    struct Description {
        let heading: String
        let hint: String
    }

    /// A revision saves the answer that was assessed, even if that answer came
    /// from a second round of research. Regather alone saves the earlier answer.
    static func description(for turn: ResearchTurn) -> Description {
        if turn.notices.contains(.answerRevised) {
            return Description(heading: "Draft before correction",
                               hint: "The findings assess this draft.")
        }
        if turn.notices.contains(.answerRegathered) {
            return Description(heading: "Draft before additional research",
                               hint: "The findings assess the answer written after additional research.")
        }
        return Description(heading: "Earlier draft", hint: "Compare this draft with the displayed answer.")
    }

    static func toggleLabel(expanded: Bool) -> String {
        expanded ? "Hide earlier draft" : "Show earlier draft"
    }

    static func isOffered(draft: String?, answer: String) -> Bool {
        guard let draft else { return false }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
