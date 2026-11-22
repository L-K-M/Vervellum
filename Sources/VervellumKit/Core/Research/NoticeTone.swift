import Foundation

/// How strongly a `TurnNotice` is presented.
///
/// A notice is a fact about the run, and the facts are not equally alarming. "The
/// answer was rewritten against the findings" is news; "the answer's claims could not
/// be checked" is a warning; "the stored record is missing a file" is a problem. One
/// warning triangle for all of them spends the panel's most useful scanning signal —
/// which turns deserve a second look — and leaves a reader unable to tell a caveat from
/// a status change.
///
/// The written label never changes, and the verdict colours keep their meaning for the
/// findings table; this is an additional channel, and meaning is still never carried by
/// colour alone because every notice keeps its sentence.
enum NoticeTone: String, Codable, CaseIterable, Equatable {
    /// The run proceeded; the reader may not need to act.
    case informational
    /// Something reduced the evidence or the check; read the answer with it in mind.
    case caution
    /// The answer was never checked, or the stored record is incomplete.
    case critical

    /// A symbol name a front end can draw.
    ///
    /// A string rather than an image so each platform keeps its own symbol set; the
    /// spelling is SF Symbols' because that is the canonical one, and the GTK front end
    /// substitutes a glyph of its own.
    var symbolName: String {
        switch self {
        case .informational: return "info.circle"
        case .caution: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon"
        }
    }
}

extension TurnNotice {
    /// The tone this notice is drawn in. See `NoticeTone`.
    ///
    /// The cases are grouped by what the reader should do, not by what happened:
    /// `answerRevised` and `modelFellBack` need no action, `contextTrimmed` and
    /// `noPagesRead` qualify the evidence, and `assessmentUnavailable` means nothing
    /// below the answer was verified.
    var tone: NoticeTone {
        switch self {
        case .assessmentUnavailable, .attachmentNotStored:
            return .critical
        case .contextTrimmed, .evidenceTrimmed, .invalidCitation, .literalURL,
             .assessmentLinkDropped, .noEvidence, .uncitedVerdictDropped,
             .unreadableVerdictDropped, .revisionUnavailable, .noPagesRead,
             .pageTextTrimmed, .linkNotRead, .imagesNotSent, .attachmentMissing,
             .attachmentTrimmed:
            return .caution
        case .answerRevised, .linkReadingOff, .modelFellBack, .answerRegathered, .singleDomain,
             .unknown:
            return .informational
        }
    }
}
