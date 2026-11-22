import Foundation

/// Both a revision and an additional research round can leave a comparison draft.
/// Offer it only when it differs from the answer on screen.
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
                               hint: "This draft predates the additional research. The findings assess the displayed answer.")
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
