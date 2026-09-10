import Foundation

/// One web source Vervellum actually fetched, as offered to the model and shown to
/// the user. The `number` is the citation index the model must use — one-based,
/// because that is what reads naturally in prose.
struct Source: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// One-based citation number, stable for the life of the turn.
    var number: Int
    var url: String
    var title: String
    var snippet: String
    /// Explicitly defaulted so the memberwise initializer can omit it.
    var publishedAt: String? = nil
    /// The page's own text, when Vervellum read the page rather than only its summary.
    ///
    /// Nil is the normal state and means exactly one thing: **the answer could only have
    /// seen the snippet.** It is cleared rather than kept when a page was read but its
    /// text did not fit the model's context, because a source shown as read that the
    /// model never read is precisely the overstatement this app exists to avoid.
    ///
    /// Optional, so the synthesized decoder reads it with `decodeIfPresent` and a thread
    /// written before page reading still loads.
    var fullText: String? = nil

    /// Whether the answer could have been written from the page rather than a summary.
    var wasRead: Bool { !(fullText ?? "").isEmpty }

    /// The registrable-looking host, for a compact source chip ("apple.com").
    var domain: String {
        guard let host = URLComponents(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    enum CodingKeys: String, CodingKey {
        case id, number, url, title, snippet, publishedAt, fullText
    }
}

/// A search the model asked for, with the arguments it wrote.
///
/// The arguments are a free-form JSON object shaped by the search tool's own
/// `inputSchema`, which Vervellum does not get to choose — so they are carried as
/// encoded JSON text and re-parsed at call time. That also makes the turn Codable
/// without a heterogeneous-dictionary encoder.
struct PlannedSearch: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// A short phrase naming what this search is meant to settle.
    var purpose: String
    /// The raw arguments object, JSON-encoded.
    var argumentsJSON: String

    init(id: UUID = UUID(), purpose: String, argumentsJSON: String) {
        self.id = id
        self.purpose = purpose
        self.argumentsJSON = argumentsJSON
    }

    init?(purpose: String, arguments: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        self.init(purpose: purpose, argumentsJSON: text)
    }

    var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// The most query-like string in the arguments, for display. Search tools name
    /// this field inconsistently, so the common spellings are tried in order before
    /// falling back to the longest string value.
    var displayQuery: String {
        let arguments = self.arguments
        for key in ["search_query", "query", "q", "keyword", "keywords", "text"] {
            if let value = arguments[key] as? String, !value.isEmpty { return value }
        }
        let strings = arguments.values.compactMap { $0 as? String }
        return strings.max(by: { $0.count < $1.count }) ?? purpose
    }
}

/// The verdict on one claim.
///
/// The five cases are exhaustive on purpose: every claim an answer rests on is
/// either settled by the evidence one way, settled partly, not settled, or not the
/// kind of thing evidence settles. Collapsing "we found nothing" into "false" is the
/// single most damaging thing a research tool can do, so `insufficient` is a
/// first-class verdict rather than an error state.
enum Verdict: String, Codable, CaseIterable, Equatable {
    case supported
    case contradicted
    case mixed
    case insufficient
    case opinion

    /// Whether a verdict of this kind is only meaningful with a citation.
    var requiresSources: Bool {
        switch self {
        case .supported, .contradicted, .mixed: return true
        case .insufficient, .opinion: return false
        }
    }

    var label: String {
        switch self {
        case .supported: return "Supported"
        case .contradicted: return "Contradicted"
        case .mixed: return "Mixed"
        case .insufficient: return "Not established"
        case .opinion: return "Opinion"
        }
    }

    /// SF Symbol shown on the verdict chip.
    var symbolName: String {
        switch self {
        case .supported: return "checkmark.seal"
        case .contradicted: return "xmark.seal"
        case .mixed: return "arrow.triangle.branch"
        case .insufficient: return "questionmark.circle"
        case .opinion: return "bubble.left.and.bubble.right"
        }
    }
}

/// One assessed claim.
struct Finding: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var claim: String
    var verdict: Verdict
    var reasoning: String
    /// One-based source numbers, already checked to be in range.
    var sourceNumbers: [Int]

    enum CodingKeys: String, CodingKey { case id, claim, verdict, reasoning, sourceNumbers }
}

/// How far along a turn is. Drives the progress trail in the UI.
enum ResearchStage: String, Codable, Equatable {
    case queued
    case planning
    case searching
    case answering
    case assessing
    case complete
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .complete, .failed, .cancelled: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .planning: return "Planning searches"
        case .searching: return "Searching the web"
        case .answering: return "Writing the answer"
        case .assessing: return "Checking claims"
        case .complete: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// A caveat Vervellum itself attaches to a turn, distinct from the model's own
/// stated limitations. These are facts about the *run*, not about the subject.
enum TurnNotice: String, Codable, Equatable {
    /// Older turns were left out of the model's context to fit the size budget.
    case contextTrimmed
    /// Some retrieved sources did not fit the evidence budget and were never shown to
    /// the model.
    case evidenceTrimmed
    /// The model cited a source number that does not exist.
    case invalidCitation
    /// The model wrote a literal URL despite being told to cite by number.
    case literalURL
    /// The answer was produced with no web evidence at all.
    case noEvidence
    /// A verdict was dropped because it named no source.
    case uncitedVerdictDropped
    /// A finding was dropped because its verdict was not one of the five words.
    case unreadableVerdictDropped
    /// The assessment call failed, so the answer's claims were never checked.
    case assessmentUnavailable
    /// The check found claims the evidence contradicts or only half-supports, and the
    /// answer above was rewritten against them.
    case answerRevised
    /// The check found claims worth correcting and the rewrite could not be used — it
    /// did not arrive, came back empty, or broke the citation rule and was discarded. So
    /// the answer above is the draft the findings grade.
    ///
    /// One case for all three, because the reader's position is the same in each and
    /// there is nothing different for them to do. The three are told apart in the trace,
    /// which is where the difference matters: a rewrite discarded for inventing a source
    /// number will keep being discarded, and a provider that timed out will not.
    case revisionUnavailable
    /// Page reading was on, but no page could be read — so every source is a summary,
    /// exactly as if it were off.
    case noPagesRead
    /// A page was read but its text did not fit the model's context, so the answer saw
    /// that source's summary only.
    case pageTextTrimmed
    /// The question carried a link, but page reading is off — so the answer rests on
    /// search results rather than on the page the user pointed at.
    case linkReadingOff
    /// A link in the question was not read — it could not be fetched, or it was past
    /// the limit on links per question. Distinct from `noPagesRead`, which is about the
    /// pages behind search results: this one is a page the user chose.
    case linkNotRead
    /// A model provider failed and the next one in the chain answered instead. Not
    /// necessarily the *selected* provider: a turn can move on twice, and the second
    /// failure is a spare's. The turn's `model` is the one that actually answered.
    case modelFellBack
    /// A notice written by a newer build that this one does not know. Kept rather than
    /// failing the whole document: a `notices` array that refused to decode used to make
    /// an older build start from an empty library and overwrite the newer file.
    case unknown

    /// Decodes leniently: an unfamiliar raw value becomes `.unknown` instead of an
    /// error. Adding a case above therefore no longer needs a `ThreadLibrary` version
    /// bump for builds from this one on; removing or renaming one still does.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TurnNotice(rawValue: raw) ?? .unknown
    }

    var message: String {
        switch self {
        case .contextTrimmed:
            return "Earlier context was shortened or omitted to fit the model's context."
        case .evidenceTrimmed:
            return "Some sources were found but not shown to the model, because the "
                + "evidence would not fit its context. The answer could not have used them."
        case .invalidCitation:
            return "The model referred to a source number that does not exist. Those references were left as plain text."
        case .literalURL:
            return "The model wrote a link directly instead of citing a source number. Treat any such link as unverified."
        case .noEvidence:
            return "Answered without web evidence. Nothing here is source-backed."
        case .uncitedVerdictDropped:
            return "A verdict that cited no source was discarded."
        case .unreadableVerdictDropped:
            return "A finding whose verdict Vervellum could not read was discarded."
        case .assessmentUnavailable:
            return "The answer's claims could not be checked, because the assessment call failed. "
                + "Nothing below the answer has been verified."
        case .answerRevised:
            return "The check found claims the evidence does not carry, and the answer was "
                + "rewritten against them. The findings below grade the first draft, which "
                + "is what they were written about."
        case .revisionUnavailable:
            return "The check found claims worth correcting, but the rewrite could not be "
                + "used. The answer above is the draft the findings below describe."
        case .noPagesRead:
            return "No page could be read in full, so every source below is a search summary. "
                + "A summary cannot show that a page says what the answer claims it says."
        case .pageTextTrimmed:
            return "A page was read but did not fit the model's context, so the answer saw that "
                + "source's summary only. It is listed as a summary."
        case .linkReadingOff:
            // Not "the answer rests on search results instead", which this cannot know.
            // A question that carries a link and needs no searches — a definition, a
            // calculation — produces a plan with none, and the answer then rests on the
            // model alone. Saying what did *not* happen is true in every case, and is
            // the part the reader needs.
            return "This question contains a link, but page reading is off in Settings, so its "
                + "contents were not read. The answer does not rest on that page."
        case .linkNotRead:
            return "A link in this question was not read, so nothing below rests on it. Either "
                + "it was past the number of links one question is read from, or the page could "
                + "not be fetched — a login, a consent wall, or a file that is not a document."
        case .modelFellBack:
            return "A model provider failed, so the next one configured answered instead, "
                + "and the rest of this turn used it too. The model named on this turn is "
                + "the one that answered."
        case .unknown:
            return "This turn carries a note recorded by a newer version of Vervellum."
        }
    }
}

/// One question and everything the research produced for it.
struct ResearchTurn: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var question: String
    var askedAt: Date
    var stage: ResearchStage = .queued

    /// One sentence stating how the model read the question.
    var reading: String = ""
    var searches: [PlannedSearch] = []
    /// How many of `searches` have been run. Drives the live "2 of 3" progress in the
    /// trail while the searching stage lasts; meaningless once the stage has passed.
    var searchesCompleted: Int = 0
    var sources: [Source] = []
    /// How many pages Vervellum tried to read, and how many it got. Zero for a turn
    /// where page reading was off, which is also what a thread written before page
    /// reading decodes to.
    ///
    /// "Tried" means different things in the two passes, and the difference is policy
    /// rather than drift. The question's own links are all counted, private addresses
    /// included, because the user asked for them and they were handed to the reader. A
    /// search result that fails the public-address filter was never attempted at all —
    /// no request was made and none was going to be — so it is not counted here, only
    /// in the trace.
    var pagesAttempted: Int = 0
    var pagesRead: Int = 0
    /// How many pages are being fetched *right now*, and zero the rest of the time.
    ///
    /// Set by the runner around both reads — the question's links before the plan
    /// exists, and the pages behind the search results after it — because "what is
    /// happening at this moment" is a fact the runner has and `runningProgressLabel` was
    /// previously inferring. The inference was `pagesAttempted > 0` once every search
    /// had completed: true for the second read, and silent for the first, because the
    /// links are read while the stage is still `.planning`. A question that began with a
    /// pasted link therefore read "Planning searches" for as long as three fetches take,
    /// which is up to half a minute of the one moment the label exists to explain.
    ///
    /// A count rather than a flag, because it has to answer *how many* as well as
    /// *whether*, and `pagesAttempted` cannot: that one accumulates across both reads,
    /// so a turn that read one pasted link and is now fetching two search results would
    /// say "Reading 3 pages" with two in flight. One field, both facts, neither of them
    /// inferred.
    ///
    /// Transient in a stronger sense than `searchesCompleted`, which is a tally that
    /// stays true after the fact. This one is a claim about an outstanding request, and
    /// a document is a record of a turn that has stopped running — so it is the one
    /// stored property with no `CodingKeys` case: never written, never read, zero on
    /// every turn that comes back from disk.
    var pagesInFlight: Int = 0
    /// The streamed markdown answer, with `[n]` citations. When a revision replaced it,
    /// this is the revised text — what the reader is shown is always what the turn now
    /// stands behind.
    var answer: String = ""
    /// The answer as first written, kept only when the revision stage replaced it.
    ///
    /// Nil on every turn that was never revised, which is most of them. It exists so the
    /// findings below stay readable: they grade the draft, and a table saying "this claim
    /// is contradicted" over prose that no longer makes the claim is a table that looks
    /// broken. Keeping the draft is what lets the two be shown as what they are — a
    /// check, and what it changed.
    var draftAnswer: String?
    /// Whether a revision call is outstanding right now.
    ///
    /// Transient in the same sense as `pagesInFlight`, and omitted from `CodingKeys` for
    /// the same reason: a document is a record of a turn that has stopped, so nothing on
    /// disk can be evidence that a request is in flight. It reports through
    /// `runningProgressLabel` rather than through a `ResearchStage` case, because a new
    /// case is a value an older build cannot decode — see the note on that method.
    var isRevising = false
    var findings: [Finding] = []
    var limitations: String = ""
    var followups: [String] = []
    var notices: [TurnNotice] = []
    /// A user-facing failure message when `stage == .failed`.
    var failure: String?
    /// Wall-clock seconds from ask to terminal stage.
    var duration: TimeInterval?
    /// The model that produced the answer, recorded because a thread can outlive a
    /// settings change and a verdict is only meaningful with the model attached.
    ///
    /// Settled when the answer stream ends, not while it runs: until a provider has
    /// finished without throwing, which one produced the words is not yet a question
    /// with a right answer. So on a turn that fell back this stays blank for the length
    /// of the stream rather than naming the provider that is being tried. Blank and late
    /// beats confident and wrong.
    var model: String = ""

    init(question: String, askedAt: Date = Date()) {
        self.question = question
        self.askedAt = askedAt
    }

    // MARK: Codable

    // A hand-written decoder for exactly one reason: Swift's synthesized one ignores
    // property defaults and requires *every* key, so the first field ever added to
    // `ResearchTurn` would make every existing threads.json unreadable — and both the
    // file and its `.bak` have the same shape, so the whole library would silently
    // reset. `searchesCompleted`, `pagesAttempted` and `pagesRead` are tolerant of
    // absence; every other field still fails loudly, and a field added later must be
    // given the same treatment here or old documents stop loading again.
    //
    // `encode(to:)` stays synthesized: with this `CodingKeys` covering every stored
    // property, the existing round-trip test catches a field that goes missing from it.
    //
    // `pagesInFlight` is the one deliberate omission, and omitted rather than merely
    // ignored on the way in. A stored property with no case here is skipped by the
    // synthesized encoder, so the count cannot reach a document at all — which makes
    // "never believed from disk" structural instead of a promise a later tidy-up
    // ("why is this one field not `decodeIfPresent`?") could undo. The round-trip test
    // could not have protected it either way: the decoder zeroes it, so the test passes
    // whether or not the key is written.
    enum CodingKeys: String, CodingKey {
        case id, question, askedAt, stage, reading, searches, searchesCompleted, sources
        case pagesAttempted, pagesRead
        case answer, draftAnswer, findings, limitations, followups, notices, failure
        case duration, model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        question = try container.decode(String.self, forKey: .question)
        askedAt = try container.decode(Date.self, forKey: .askedAt)
        stage = try container.decode(ResearchStage.self, forKey: .stage)
        reading = try container.decode(String.self, forKey: .reading)
        searches = try container.decode([PlannedSearch].self, forKey: .searches)
        searchesCompleted = try container.decodeIfPresent(Int.self, forKey: .searchesCompleted) ?? 0
        sources = try container.decode([Source].self, forKey: .sources)
        pagesAttempted = try container.decodeIfPresent(Int.self, forKey: .pagesAttempted) ?? 0
        pagesRead = try container.decodeIfPresent(Int.self, forKey: .pagesRead) ?? 0
        // Not decoded, and not encoded either — see `pagesInFlight`. Nothing written to
        // disk can be evidence that a request is outstanding now. The assignment is here
        // for the initializer's sake and to say so at the point someone would look.
        pagesInFlight = 0
        answer = try container.decode(String.self, forKey: .answer)
        draftAnswer = try container.decodeIfPresent(String.self, forKey: .draftAnswer)
        // Not decoded, and not encoded either — see `isRevising` and `pagesInFlight`.
        isRevising = false
        findings = try container.decode([Finding].self, forKey: .findings)
        limitations = try container.decode(String.self, forKey: .limitations)
        followups = try container.decode([String].self, forKey: .followups)
        notices = try container.decode([TurnNotice].self, forKey: .notices)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        model = try container.decode(String.self, forKey: .model)
    }

    /// Whether this turn was asked with `/direct`.
    ///
    /// Derived rather than stored, so the on-disk document did not have to change. Both
    /// front ends attach `noEvidence` when a turn is *created* in direct mode; the runner
    /// attaches the same notice when the planner decided a question needed no search.
    /// The two are told apart by `reading`: the planner writes one, and direct mode
    /// never runs the planner. Retry uses this to re-ask the way the user asked.
    var wasAskedDirectly: Bool {
        notices.contains(.noEvidence) && reading.isEmpty
    }

    /// The stage label for a running turn, with live progress where there is any:
    /// "Searching the web · 2 of 3" rather than a static label for the whole stage.
    /// Terminal stages fall through to `stage.label`, which is also what logs use.
    ///
    /// Page reading reports through `pagesInFlight` rather than through a stage of its
    /// own. A new `ResearchStage` case would be an enum value an older build cannot
    /// decode, and `ResearchStage` — unlike `TurnNotice` — has no lenient decoder, so it
    /// would make a thread written here unreadable there. A label is not worth that; an
    /// `Int` an older build ignores costs nothing.
    var runningProgressLabel: String {
        // Nothing below describes a turn that has stopped, and the count is the
        // runner's to zero — so the label refuses to speak for a terminal turn rather
        // than trusting that it was zeroed.
        guard !stage.isTerminal else { return stage.label }
        // A fetch in flight outranks everything, in either stage, because it is the one
        // thing the reader is actually waiting on. Asked as a fact rather than inferred
        // from `pagesAttempted`, which cannot tell "reading now" from "read already":
        // both leave the same count behind.
        //
        // No "2 of 3" here, unlike the searches: the direct reader fetches the pages
        // concurrently, so there is no meaningful running count to report — only how
        // many are outstanding, which is what this counts.
        if pagesInFlight > 0 {
            return "Reading \(pagesInFlight) page\(pagesInFlight == 1 ? "" : "s")"
        }
        // Below the fetches and above the stage, because it happens inside `.assessing`
        // and is the more specific truth while it lasts: the claims have been checked,
        // and the answer is being rewritten against what the check found.
        //
        // Gated on the stage as well as the flag. The runner clears the flag on every
        // way out of the revision, so a set flag outside `.assessing` is already a bug —
        // and the cost of that bug is a turn that says it is revising for as long as it
        // is on screen, which is a lie told by the one label that exists to say where the
        // run actually is.
        // Below the fetches, which is safe rather than lucky: every read this turn makes
        // happens in `.planning` or `.searching`, so nothing is outstanding by the time
        // `.assessing` is reached and the two branches cannot both be true.
        if isRevising, stage == .assessing { return "Revising the answer" }
        guard case .searching = stage else { return stage.label }
        if !searches.isEmpty, searchesCompleted < searches.count {
            let attempted = min(max(searchesCompleted, 1), searches.count)
            return "Searching the web · \(attempted) of \(searches.count)"
        }
        guard !searches.isEmpty else { return stage.label }
        return "Searching the web · \(searches.count) of \(searches.count)"
    }

    /// Records a notice once. Notices are a set in spirit but an array on disk, so
    /// that a document written by a newer build keeps its order when read back.
    mutating func addNotice(_ notice: TurnNotice) {
        guard !notices.contains(notice) else { return }
        notices.append(notice)
    }

    /// Checks the answer's citations and records what was wrong with them.
    ///
    /// Runs after the answer has finished streaming rather than per chunk: a citation
    /// marker can be split across two deltas, and flagging a half-arrived `[1` as an
    /// invented reference would put a warning on every answer.
    mutating func applyCitationValidation(sourceCount: Int) {
        let validation = CitationValidator.validate(answer: answer, sourceCount: sourceCount)
        if !validation.outOfRangeCitations.isEmpty { addNotice(.invalidCitation) }
        if !validation.literalURLs.isEmpty { addNotice(.literalURL) }
    }

    /// Sources the answer actually cites, in citation order. The rest stay available
    /// under "all sources" but do not clutter the turn.
    func citedSources(using validation: CitationValidator.Result) -> [Source] {
        validation.citedSourceIndices.compactMap { index in
            sources.indices.contains(index) ? sources[index] : nil
        }
    }

    /// The turn as plain text, for the clipboard and the command line.
    ///
    /// The rendering lives in `TranscriptFormatter` so the macOS Copy button and the
    /// Linux CLI produce the same thing.
    var transcript: String { TranscriptFormatter.plainText(self) }
}

/// A conversation: a sequence of turns with a derived title.
struct ResearchThread: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var turns: [ResearchTurn] = []

    /// The first question, shortened — good enough to pick a thread out of a list,
    /// and it costs no model call.
    var title: String {
        guard let first = turns.first?.question.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty else { return "New thread" }
        let singleLine = first.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > 60 else { return singleLine }
        let cut = singleLine.prefix(60)
        // Break on the last word boundary so the title never ends mid-word.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 30 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }

    var isEmpty: Bool { turns.isEmpty }
}
