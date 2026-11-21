# Vervellum review — tmp.md (2026-11-21)

Fresh review of the repo (based on `origin/main` at `e90efc3`/`9c3e3d7`), covering the
shared core (`Sources/VervellumKit/Core`), the macOS front end (`Vervellum/`), tests and
CI docs. Method: full reads of the panel views, panel/engine/store/app classes, settings
panes, transport/session/coalescer core and the composer-command layer, plus three
parallel deep-reads of the core pipeline, the store/text/platform layer, and the
macOS views/settings (helper reports merged below). Every candidate finding was
cross-checked against the existing backlog in `ANALYSIS.md`; existing IDs are cited so
nothing is proposed twice.

Hard constraints respected throughout (AGENTS.md): numeric-only citations (the model
may never write URLs); Core stays Foundation/Dispatch-only, no main-actor hops;
credentials only in the secret stores; panel window flags, `LSUIElement`, the
`NSTextView` composer and the main menu unchanged; redirects refused, response caps,
sanitized errors; setext headings stay a deliberate contract (ANALYSIS.md preamble).

## What is genuinely good (do not re-litigate)

- The citation contract is structural, and validator/mask/renderer/transcript all agree.
- Streaming performance is already engineered: `SnapshotCoalescer`, `TurnView:
  Equatable`, `SelectableText`/`MeasuringTextView`, hover state isolated from parsing.
- Focus/activation handoff, full-screen behaviour, Escape ordering, VoiceOver
  announcements on key-driven meaning changes.
- Crash-safe, honest persistence: atomic writes, `.bak`, `0600`, tombstones, read-only
  guard, synchronous erase, attachment sweep with grace window.

## Findings

### Implemented in this session (each its own branch + PR; local branches deleted after)

| # | PR | Finding | Fix |
|---|----|---------|-----|
| 1 | #230 `review/larger-header-hit-areas` | Header buttons' hit area was the 20×18 glyph frame (`PanelHeaderView.swift:81`) — barely larger than the glyph at max text scale, five in a row 6 pt apart | Hit shape grows 3×4 pt past the frame (26×26), never overlapping neighbours; pure `hitShape(for:)` + `PanelHeaderViewTests` |
| 2 | #239 `review/thread-scroll-shortcuts` | No keyboard way to scroll a long thread: composer holds first responder, ↑/↓ and PageUp/PageDown never reach the thread's scroll view | ⌘↑/⌘↓ post new `scrollToTop`/`scrollToBottom` panel commands; `PanelRootView` scrolls via a boxed `ScrollViewReader` proxy to a new top anchor; `/help` lists them (macOS only); `PanelCommandTests` + help-text tests |
| 3 | #241 `review/redactor-case-insensitive-scheme` | `SecretRedactor`'s `urlUserInfo` scheme class was lowercase-only; `HTTPS://u:p@host` passed redaction (schemes are case-insensitive, `URL` accepts them) | `(?i)` on the scheme class; `testRedactsCredentialsInAnUppercaseSchemeURL` (verified 0→1 matches) |
| 4 | #244 `review/composer-whitespace-consistency` | `ComposerCommand.parse` split on `Character.isWhitespace` while `commandWord` used `CharacterSet.whitespacesAndNewlines`; U+200B is in the set but not `isWhitespace`, so the two could classify the same pasted input differently | One shared `whitespace` set + `isWhitespace(_:)` predicate used by both; consistency test |
| 5 | #246 `review/about-version-string` | About pane printed `Version Optional("0.3.1")` — `Bundle.shortVersionString` is `String?` and interpolating an optional prints the debug description | Read `CFBundleShortVersionString` with an `unknown` fallback via pure `AboutView.versionText(_:)` + `AboutViewTests` |
| 6 | #250 `review/citation-regex-unbounded-digits` | Citation regex capped numbers at 3 digits, so `[1000]` never matched: rendered as plain text and never flagged in `outOfRangeCitations` — the invalid-citation warning never fired for the largest fabricated numbers | `\d+`; range check decides validity; `testFlagsFourDigitInventedCitations` |
| 7 | #251 `review/strip-hostile-source-fields` | `publishedAt` passed through `HostileText` unstripped, and `linkTitle` built from `URLComponents.path` (percent-decodes, so `%E2%80%AE` RLO reaches the title) — both displayed in the source list/preview | Strip both; tests in `EvidenceExtractorTests` and `QuestionLinkTests` |
| 8 | #253 `review/theme-restyle-open-thread` | Theme change never restyled the open thread: `PanelTheme.palette` is a global, so `TurnView.==` never saw the change and `linkTextAttributes` was set once | `TurnView` carries and compares the palette; `MarkdownBody` passes font/colour explicitly to every `MarkdownText`; `AnswerTextView` refreshes `linkTextAttributes` only when the accent moved; `TurnViewThemeTests` |

All eight branches are pushed; PRs #230 #239 #241 #244 #246 #250 #251 #253 are open against main.

### Found by review, not yet implemented (candidates for future work)

High value / likely bugs:

- **Theme-restyle was also reported by the views helper as findings 1–2** — implemented
  above (item 8).
- **Agent-loop `try?` swallows total provider failure** (`ResearchRunner.swift:1229`):
  a provider outage becomes "no usable sources" and blames the question. Re-throw
  non-parse `ResearchError`s. (Helper; not in ANALYSIS.)
- **`contextTrimmed` not reported for deep follow-up/regather payloads**
  (`ResearchRunner.swift:1030,1225,1636`): those can drop history silently. Add the
  notice after each `assemble`. (Helper; related to the "never truncate silently" rule.)
- **`fixedContent` measures empty reading/searches_run** (`ResearchRunner.swift:585`,
  `ResearchContext.swift:235`): the answer/assessment payloads carry the real ones, so a
  long reading can push assessment past the cap and fail soft. Measure per stage.
  (Helper.)
- **`ProviderSettings.problems` never checks `searchProfiles.isEmpty`**
  (`ProviderSettings.swift:650,675`): readiness says "ready" while the runner throws "no
  search provider configured". (Helper.)
- **`checkFinishReason` treats a missing `finish_reason` as interrupted**
  (`ChatCompletionsClient.swift:409`): local gateways omitting it on a valid completion
  discard a good answer. Accept `nil` as normal. (Helper.)
- **ResponseParsers keeps a malformed `arguments` value** (`ResponseParsers.swift:72`):
  present-but-not-a-dict falls back to the raw entry. Throw invalid-plan instead. (Helper.)
- **ProviderCredentialCommit leaks foreign error text into the UI**
  (`ProviderCredentialCommit.swift:66`): `secretWriteAfterCommit` appends
  `error.localizedDescription`. Use a fixed sentence + account name. (Helper; security.)
- **ThreadArchive: read-only archive can still be erased via the history toggle**
  (`ThreadArchive.swift:261` etc.): `eraseEverything()` has no `isReadOnly` guard, so a
  newer-version document is deleted and the archive stays read-only forever. (Helper;
  overlaps A12/A14 — coordinate.)
- **Launch trim deletes attachments of recoverable threads** (`ThreadArchive.swift:206`
  + `AttachmentStore.swift:194`): lowering the limit behind the app's back trims in
  memory only, but the launch sweep deletes the trimmed threads' pictures while the
  threads themselves come back on relaunch. (Helper; data loss.)
- **Empty provider list resurrects defaults on relaunch** (`CorePreferences.swift:243`):
  present-but-empty decodes as "no list". Distinguish key absence from `[]`. (Helper.)
- **Settings close steals focus** (`SettingsWindowController.swift:94`):
  `windowWillClose` restores activation unconditionally; `PanelController` guards with
  `NSApp.isActive`. Match it. (Helper; related to A77.)
- **Appearance "Automatic → explicit" freezes the current appearance**
  (`AppearanceView.swift:299`): the fallback resolves the semantic colour against the
  *current* appearance and stores it, so ticking Text on in Dark Mode pins white text
  after a switch to Light. (Helper.)
- **Popover closes on every streamed replacement under a resting pointer**
  (`AnswerTextView.swift:101`): re-evaluate the chip under the last pointer location
  after a storage swap. (Helper.)
- **ProvidersView model menu `ForEach(models, id: \.self)`** (`:342`): duplicate aliases
  from an endpoint make identity ambiguous. Use enumerated ids. (Helper.)
- **Model-list tasks can write state after the pane is gone** (`ProvidersView.swift:410`):
  cancel on `onDisappear` too. (Helper; related to A18b.)
- **Code-block language label has no line limit** (`MarkdownText.swift:405`): a long
  fence info string grows the header. `.lineLimit(1)`. (Helper.)
- **`sourcesByURL` rebuilt per streamed chunk** (`AnswerTextView.swift:69`): guard the
  index rebuild on `sources` changing. (Helper; perf.)
- **Citation substitution is O(n·m)** (`MarkdownText.swift:316`): `range(of:)` rescans
  from the start per citation. Track the search cursor. (Helper; perf.)
- **`Formatting.relativeDate` uses an unpinned DateFormatter** (`Formatting.swift:44`):
  non-Gregorian locale → Buddhist year; also allocates per row. Pin locale/calendar,
  cache behind a lock. (Helper.)
- **AttachmentStore sweep can't remove uppercase-UUID filenames on Linux**
  (`AttachmentStore.swift:231`): parses `UUID(uuidString:)` but removes
  `url(for: id)` (canonical form). Remove the original name. (Helper.)
- **JSONFileSettingsStore bridges bools↔numbers** (`SettingsStore.swift:71,67`):
  `{"keptThreads": true}` becomes 10. Reject wrong types. (Helper.)
- **AttachmentStore.removeAll deletes non-UUID files** (`AttachmentStore.swift:204`):
  erase removes anything in the directory, not just attachment files. (Helper.)
- **backup rotation trusts launch-time trustworthiness** (`ThreadArchive.swift:376`):
  an externally replaced primary is copied over the good `.bak`. (Helper; overlaps A14.)

Already tracked in ANALYSIS.md (helpers confirmed, not re-listed as new): A11/A11a
(source URL userinfo — open PR #200; adjacent snippets), A09 (per-query outcomes),
A12 (unknown enum values — helper confirmed `ResearchStage`/`Verdict` strict decode),
A20 (re-parse per chunk), A66 (heading semantics), A75b (ordered marker width), A77e
(sync AX on summon), A07 (truncation metadata), A18b (unsaved provider edits), A63
(paste redaction), A28 (history keyboard), A36 (copy confirmation), A50 (rename), A65
(keyboard traversal), A60f (chrome), A13/A14 (erasure/backup).

### Deliberately not changed

- Setext headings stay as-is (explicit ANALYSIS.md contract), quote-merge and `1.`-at-EOL
  parser edges (helper findings; small, but the parser's contracts are tested — change
  only with a design decision), `.orig` test backup (open PR #199 owns it).

## Performance observations

Mostly already engineered (see "what is good"). Remaining measured-not-guessed items:
N03/N10 (per-turn publication, delta delivery), the helper's per-chunk costs above
(sources index, citation substitution, history re-validation), R06 (large-library
search). Profile before redesigning — the panel's freeze history is in
`SelectableText`'s docs.

## Visual / UX observations

- Dense but coherent; fixed header / scrolling thread / fixed composer is right;
  disclosures start closed; verdicts never colour-only.
- Header hit areas were the one clear physical-UI gap (fixed, #230).
- Source-row snippet is hover-only: tap opens the page. A first tap could expand the
  snippet inline (helper idea; small).
- Empty state is text-only (A60g proposes an illustration).

## Novel / delightful ideas (new unless an ANALYSIS ID is given)

1. Keyboard citation peek: Tab into the answer, arrows across chips, Return presents the
   same `SourcePreview`; plus chip accessibility labels ("Source 1, title") — closes the
   VoiceOver gap the helper found (#10). Related: N13, A64.
2. Cross-highlight: hovering `[7]` underlines source row 7; hovering a row highlights
   its chips. Pure view state, Reduce-Motion safe.
3. Answer-footer micro-metrics: word count, reading time, citation count next to the
   model name — pure function over `turn.answer`/`turn.sources`, testable in `Formatting`.
4. Copy-the-question hover affordance on each question row (complements Copy-answer;
   related A36).
5. One-shot status-item pulse when a detached run finishes (macOS half of A36e).
6. Inline theme mock in Appearance: a small flat-fill panel preview animating live with
   the sliders (never nest glass; honour Reduce Transparency).
7. Source provenance chips: which planned query/round produced each source (data already
   in `PlannedSearch`/`Source`).
8. "Not settled" section surfacing `insufficient` findings with a one-click re-ask of
   that sub-question.

## Verification gaps

Static review cannot confirm Liquid Glass on macOS 26, real VoiceOver order, IME
composition, frame times on long threads, or full-screen placement. CI (macOS + Linux
jobs + automated GLM review) is the gate; GUI QA remains manual.
