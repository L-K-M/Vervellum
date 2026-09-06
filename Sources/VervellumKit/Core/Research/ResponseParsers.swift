import Foundation

/// Validates the model's search plan.
///
/// A plan is cheap to get wrong and expensive to act on: each entry becomes a billed
/// search request. So the count is capped, the arguments must be an object, and a
/// plan that is malformed is rejected outright rather than partially executed.
enum PlanParser {

    struct Plan: Equatable {
        var reading: String
        var searches: [PlannedSearch]
    }

    static func parse(_ object: [String: Any], maxSearches: Int) throws -> Plan {
        let reading = (object["reading"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // An absent "searches" key is a malformed plan; an explicitly empty array is
        // a valid decision that the question needs no evidence. The distinction
        // matters, so it is not collapsed into `?? []`.
        guard let raw = object["searches"] as? [Any] else {
            throw ResearchError("The model returned an invalid search plan. Try again or choose another model.")
        }
        guard raw.count <= maxSearches else {
            throw ResearchError("The model asked for more searches than Vervellum allows in one turn.")
        }

        var searches: [PlannedSearch] = []
        for entry in raw {
            guard let entry = entry as? [String: Any] else {
                throw ResearchError("The model returned an invalid search plan. Try again or choose another model.")
            }
            // Tolerate a model that put the arguments at the top level instead of
            // under "arguments" — a common shape slip that costs nothing to accept.
            let arguments = (entry["arguments"] as? [String: Any])
                ?? entry.filter { $0.key != "purpose" }
            let purpose = (entry["purpose"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !arguments.isEmpty,
                  let search = PlannedSearch(purpose: purpose.isEmpty ? "Search" : purpose,
                                             arguments: arguments)
            else {
                throw ResearchError("The model produced search arguments Vervellum could not encode.")
            }
            searches.append(search)
        }
        return Plan(reading: reading, searches: searches)
    }
}

/// Validates the model's claim assessment.
///
/// Two rules are enforced here and nowhere else, because they are what separates a
/// verdict from a vibe:
///
/// * A verdict of supported / contradicted / mixed **must** cite at least one
///   source. Without that it is the model's prior dressed as a finding, so it is
///   dropped and the user is told one was dropped.
/// * A cited source number **must** exist. An out-of-range number is a fabricated
///   citation; it is stripped, and if that empties a verdict's citations the verdict
///   goes with it.
enum AssessmentParser {

    struct Assessment: Equatable {
        var findings: [Finding]
        var limitations: String
        var followups: [String]
        var notices: [TurnNotice]
    }

    /// Cap on findings kept, matching the prompt's own limit.
    static let maxFindings = 8
    static let maxFollowups = 3

    private static let booleanEncoding = String(cString: NSNumber(value: true).objCType)

    private static func sourceNumber(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            // JSON booleans use a distinct NSNumber encoding. `as? Bool` also
            // accepts numeric 0/1, while `as? Int` turns true into source 1.
            guard String(cString: number.objCType) != booleanEncoding else { return nil }
            if let integer = value as? Int { return integer }

            // Exact conversion rejects fractions, infinities, and overflow without
            // trapping; rounded() would manufacture a source the model never cited.
            return Int(exactly: number.doubleValue)
        }

        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: .whitespaces))
    }

    static func parse(_ object: [String: Any], sourceCount: Int) throws -> Assessment {
        guard let rawFindings = object["findings"] as? [Any] else {
            throw ResearchError("The model returned an incomplete assessment. Try again.")
        }

        var findings: [Finding] = []
        var notices: Set<TurnNotice> = []

        // Iterate everything and stop once enough findings have been *kept*. Slicing
        // the input to `maxFindings` first would let a malformed entry consume a slot,
        // so a reply whose first three findings were unusable would silently drop three
        // good ones from the end.
        for entry in rawFindings {
            if findings.count >= maxFindings { break }
            guard let entry = entry as? [String: Any],
                  let claim = (entry["claim"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !claim.isEmpty
            else { continue }
            // A claim with no readable verdict is dropped — but not silently. A reply
            // whose verdicts all used a synonym the table below does not know would
            // otherwise yield an empty table with nothing telling the user why.
            guard let verdict = Self.verdict(from: entry["verdict"]) else {
                notices.insert(.unreadableVerdictDropped)
                continue
            }

            let reasoning = (entry["reasoning"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Malformed references must not be reinterpreted as different sources.
            let claimed = entry["sources"] as? [Any] ?? []
            let valid = claimed.compactMap(sourceNumber).filter { $0 >= 1 && $0 <= sourceCount }
            if valid.count != claimed.count || (entry["sources"] != nil && !(entry["sources"] is [Any])) {
                notices.insert(.invalidCitation)
            }

            if verdict.requiresSources && valid.isEmpty {
                notices.insert(.uncitedVerdictDropped)
                continue
            }
            // Valid citations are kept whatever the verdict. "Not established, and
            // here are the two sources that failed to settle it" is strictly more
            // useful than a bare verdict — the requirement is that an *evidential*
            // verdict must cite something, not that the others must not.
            findings.append(Finding(claim: claim,
                                    verdict: verdict,
                                    reasoning: reasoning,
                                    sourceNumbers: Array(Set(valid)).sorted()))
        }

        let limitations = (object["limitations"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let followups = (object["followups"] as? [Any] ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxFollowups)

        return Assessment(findings: findings,
                          limitations: limitations,
                          followups: Array(followups),
                          notices: notices.sorted { $0.rawValue < $1.rawValue })
    }

    // MARK: Lenient fields

    /// Reads a verdict the way models actually write one: any case, padded with
    /// whitespace, or one of a few unambiguous synonyms. "Not established" is the
    /// app's own label for `insufficient` and models echo it; "refuted" is plainly
    /// `contradicted`. Deliberately absent: "unsupported", which some models use for
    /// "no evidence either way" and others for "false" — mapping it to `contradicted`
    /// would collapse *not established* into *false*, the one thing this app must never
    /// do, so it is left unreadable and reported.
    static func verdict(from value: Any?) -> Verdict? {
        guard let text = value as? String else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        if let exact = Verdict(rawValue: key) { return exact }
        switch key {
        case "not established", "unestablished", "unverified", "unclear", "uncertain",
             "unknown", "inconclusive", "insufficient evidence", "not enough evidence":
            return .insufficient
        case "refuted", "false", "incorrect", "disputed", "contradicts", "contradicted by evidence":
            return .contradicted
        case "partial", "partially supported", "partly supported", "mixed evidence":
            return .mixed
        case "confirmed", "true", "correct", "verified", "well supported", "fully supported":
            return .supported
        case "subjective", "value judgement", "value judgment", "preference":
            return .opinion
        default:
            return nil
        }
    }

}
