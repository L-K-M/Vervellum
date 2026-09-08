import Foundation

/// A slash command typed into the composer.
///
/// Slash commands exist because the panel is summoned by a shortcut and dismissed by
/// one: reaching for a toolbar button breaks the flow that made the shortcut worth
/// having. Everything reachable from the header is therefore also reachable by
/// typing, and the composer's own placeholder advertises it.
///
/// Parsing is deliberately strict. A leading slash only counts as a command when the
/// word that follows is one Vervellum knows — otherwise "/etc/hosts is world
/// readable, right?" would silently become an unknown-command error instead of a
/// question.
///
/// Pure and dependency-free, so it is fully unit-testable.
enum ComposerCommand: Equatable {
    /// Research normally.
    case ask(String)
    /// Answer without searching.
    case direct(String)
    case newThread
    case openHistory
    case openSettings
    case copyLastAnswer
    case showHelp
    /// Choose which configured model provider answers from here on. An empty name
    /// means "show me what there is" rather than "pick the one called nothing".
    case selectModel(String)

    /// One command as the completion list shows it.
    ///
    /// A named struct rather than a tuple: a key path cannot reference a tuple element
    /// (`\.name` on `(name: String, …)` is rejected outright), which rules out both
    /// `ForEach(_:id:)` and `map(\.name)` — and both are wanted.
    struct Entry: Identifiable, Equatable {
        var name: String
        var summary: String
        var id: String { name }
    }

    /// Commands offered in the composer's completion list.
    static let catalogue: [Entry] = [
        Entry(name: "direct", summary: "Answer from the model alone, with no web evidence"),
        Entry(name: "model", summary: "List the configured models, or switch to one by name"),
        Entry(name: "new", summary: "Start a fresh thread"),
        Entry(name: "history", summary: "Search earlier threads"),
        Entry(name: "settings", summary: "Open Vervellum Settings"),
        Entry(name: "copy", summary: "Copy the last answer with its sources"),
        Entry(name: "help", summary: "List the commands"),
    ]

    /// Parses composer text. Returns nil for input that is only whitespace.
    static func parse(_ input: String) -> ComposerCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("/") else { return .ask(trimmed) }

        let body = trimmed.dropFirst()
        let split = body.firstIndex(where: { $0.isWhitespace })
        let word = String(split.map { body[..<$0] } ?? body).lowercased()
        let rest = split.map { String(body[$0...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

        switch word {
        case "direct":
            // "/direct" with nothing after it is a mode request with no question yet,
            // not an empty question — leave it to the caller to keep the composer open.
            return rest.isEmpty ? nil : .direct(rest)
        case "model", "models":
            // Unlike "/direct", a bare "/model" is a complete request: list them.
            return .selectModel(rest)
        case "new", "clear":
            return .newThread
        case "history", "threads":
            return .openHistory
        case "settings", "prefs", "preferences":
            return .openSettings
        case "copy":
            return .copyLastAnswer
        case "help", "?":
            return .showHelp
        default:
            // Not a command Vervellum knows: it is part of the question.
            return .ask(trimmed)
        }
    }

    /// Command names matching a partially typed `/prefix`, for the completion list.
    ///
    /// Nil when the input is not a bare command word being typed — and nil, not `[]`,
    /// when it is one that matches nothing. A caller holding a list is holding rows, so
    /// nothing has to decide what an empty completion card would look like.
    static func completions(for input: String) -> [Entry]? {
        guard isBareCommandWord(input) else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let prefix = String(trimmed.dropFirst()).lowercased()
        // Both sides lowered. Every catalogue name is lowercase today, so this is a
        // no-op — but `parse` matches case-insensitively, and a name that arrived
        // capitalised would otherwise submit fine while never appearing in the list.
        let matches = catalogue.filter { $0.name.lowercased().hasPrefix(prefix) }
        return matches.isEmpty ? nil : matches
    }

    /// A slash and one unbroken word: `/`, `/h`, `/model`. Not `/model gpt-4o`, and not
    /// prose that happens to contain a slash.
    ///
    /// One function because two things depend on it and they must not drift: the
    /// completion list is open for exactly these inputs, and `isHalfTypedCommand`
    /// withholds Return for exactly these inputs. Widening this widens both, which is
    /// the right coupling — it is what "still typing the command word" means.
    static func isBareCommandWord(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/")
            && !trimmed.dropFirst().contains(where: { $0.isWhitespace })
    }

    /// Where ↑/↓ moves the highlight in a completion list of `count` rows.
    ///
    /// Pure and here rather than in the view so the edges are testable on both platforms,
    /// because the edges are the whole design:
    ///
    /// * **Nothing is highlighted to begin with.** Return *accepts* a highlighted row, so
    ///   preselecting the first would mean typing `/new` and pressing Return filled the
    ///   field instead of starting a thread.
    /// * **↓ enters at the top, ↑ enters at the bottom**, the way a menu opened upward
    ///   behaves.
    /// * **↑ off the top returns to nothing highlighted** rather than wrapping. Wrapping
    ///   would leave no way back to plain typing without the mouse. A further ↑ then
    ///   enters at the bottom again, by the rule above — which is not the wrap this
    ///   forbids, because the state in between is a real one: nothing is highlighted, and
    ///   Return submits rather than accepting. Going 0 → last in a single press would
    ///   skip past it.
    /// * **↓ off the bottom stays**, because there is nowhere below the list to go.
    static func moveSelection(_ current: Int?, up: Bool, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let last = count - 1
        switch (up, current) {
        case (false, nil): return 0
        case (true, nil): return last
        // Both ends are clamped on both paths, because an index that is out of range is
        // the same hazard whichever way it points: it highlights nothing, and the view's
        // own `indices.contains` guard then falls through to submitting the draft — with
        // a half-typed slash command in the field. Before the clamping, `-1` was the one
        // negative the down path survived, `min(-1 + 1, last)` having landed on `0` by
        // luck, and `-2` and below came back negative.
        // `index >= last` before the step, not `min` after it: this function's whole job
        // is to take any integer and return a safe one, and `Int.max + 1` traps rather
        // than clamping. The one input it exists to survive should not be the one input
        // that crashes.
        case (false, let index?): return index >= last ? last : max(index + 1, 0)
        case (true, let index?):
            // An index left over from a longer list must step up from the last row that
            // exists, not from where it used to be: stepping up from 9 in a two-row list
            // would return 8. A negative clamps to 0 and then deselects, on purpose: it
            // is a row that no longer exists rather than "nothing highlighted" the way
            // `nil` is, so ↑ hands typing back instead of entering at the bottom.
            let clamped = min(max(index, 0), last)
            return clamped == 0 ? nil : clamped - 1
        }
    }

    /// Whether `input` is a slash word Vervellum does not recognise — a command still
    /// being typed, rather than a question.
    ///
    /// `parse` sends an unknown slash word to `.ask`, on the reasoning that a stray
    /// slash mid-sentence is part of the question. That reasoning does not survive the
    /// completion list: while `/h` is on screen under `history` and `help`, the user is
    /// visibly picking a command, and Return sending `/h` to the model as a question
    /// spends a real request on a typo.
    ///
    /// So Return declines instead, which is what `/direct` with no argument already
    /// does — a command that is not finished is not a question, and the composer keeps
    /// the text so the next keystroke continues it. An exact command still submits:
    /// `parse` recognises `/new`, so this is false for it, and Return starts a thread.
    ///
    /// What the two answers mean, because only one of them is a decision: `true` means
    /// keep the text and send nothing. `false` means carry on to `parse`, which can
    /// still keep it — `/direct` alone returns nil there and the composer holds the
    /// draft. `false` is not, on its own, permission to submit, and a caller that
    /// treated it as one would break the command this function deliberately leaves
    /// alone.
    ///
    /// Pure and here rather than in the view for the same reason as `moveSelection` —
    /// the rule is the interesting part, and it should be testable on both platforms.
    static func isHalfTypedCommand(_ input: String) -> Bool {
        // The shape is asked for directly rather than inferred from a non-nil list. It is
        // what makes an unknown slash word like `/asdf hello` fall through to `parse` and
        // be asked as a question — and asking for it here means widening how names are
        // *matched* (substrings, fuzzy, an argument-aware list) cannot widen what Return
        // withholds. Only widening `isBareCommandWord` does that, and that is the one
        // change that should. The direction being refused is a real question silently
        // never sent.
        guard isBareCommandWord(input), completions(for: input) != nil else { return false }
        // `parse` already returns nil for a command that is complete but wants an
        // argument (`/direct`), and the composer handles that by keeping the text.
        // Withholding it a second time here would be the same answer twice.
        guard let command = parse(input) else { return false }
        if case .ask = command { return true }
        return false
    }

    /// The configured model providers as markdown, for a bare `/model`.
    ///
    /// Lives here rather than on `ProviderSettings` so both front ends print the same
    /// list, and so the wording sits with the rest of the command text instead of on the
    /// value it describes.
    static func modelListing(_ settings: ProviderSettings) -> String {
        guard !settings.modelProfiles.isEmpty else {
            return "## Models\n\nNo model provider is configured yet. "
                + "Add one in Settings ▸ Providers."
        }
        let active = settings.selectedModel?.id
        let rows = settings.modelProfiles.map { profile -> String in
            let mark = profile.id == active ? "**·**" : "-"
            let identifier = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = identifier.isEmpty || identifier == profile.displayName
                ? "" : " — `\(identifier)`"
            let suffix = profile.id == active ? " *(active)*" : ""
            return "\(mark) **\(profile.displayName)**\(detail)\(suffix)"
        }.joined(separator: "\n")
        return "## Models\n\n\(rows)\n\nSwitch with `/model <name>`."
    }

    /// What to say when `/model <name>` matched nothing.
    static func unknownModel(_ name: String, in settings: ProviderSettings) -> String {
        let known = settings.modelProfiles.map { "`\($0.displayName)`" }.joined(separator: ", ")
        let suffix = known.isEmpty ? "" : " Configured: \(known)."
        return "## No such model\n\nNothing configured is named “\(name)”.\(suffix)"
    }

    /// The help text `/help` prints into the thread.
    static var helpText: String {
        let rows = catalogue.map { "- `/\($0.name)` — \($0.summary)" }.joined(separator: "\n")
        return """
            ## Commands

            \(rows)

            ## Choosing a model

            `/model` lists the configured providers and marks the active one; \
            `/model <name>` switches to one by its name or its model identifier. \
            Add and remove providers in Settings ▸ Providers.

            ## Keys

            - `Return` — ask (`Shift-Return` for a new line; swap them in Settings)
            - `⌘Return` — ask, whichever way Return is configured
            - `Esc` — clear the draft, then close the panel
            - `↑` / `↓` — earlier questions in this thread
            - `⌘N` — new thread
            - `⌘Y` — earlier threads
            - `⌘.` — stop the running research
            - `⌘,` — Settings
            - `⌘W` — close the panel
            """
    }
}
