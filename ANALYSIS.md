# Vervellum — analysis & work queue

A consolidated review of the codebase (pipeline, both front ends, packaging, CI,
tests), written so a future contributor — human or LLM — can pick an item and go.
Merges the original review with a second, independent pass (astra.md); items that
overlap are consolidated, and everything both passes found is kept. File
references point at the code as of `main`.

## In flight (PRs open, do not redo)

Two independent passes produced overlapping PRs. Where two rows solve the same
problem, pick one — the other should then be closed, not rebased on top.

| PR | Branch | Scope |
| --- | --- | --- |
| #46 | `astra2/swift62-test-compile` | CI fix: `(raw as? UInt).map(Int.init)` ambiguous on Swift 6.2 — the compile error that had main red. (Overlaps the test half of #38.) |
| #38 | `k3/fix-archive-test-inference` | CI fix: same Swift 6.2 ambiguity **plus** the desktop-entry validation copying to a non-reverse-DNS filename, which desktop-file-utils 0.27+ rejects for a DBusActivatable entry. |
| #22 | `k3/atx-heading-closing-sequence` | Bug: `# C#` rendered as "C" — trailing `#` stripped without the required preceding space. Core + tests. |
| #23 | `k3/reject-fractional-citations` | Bug: `AssessmentParser` rounded a fractional source number (2.7) onto a real source (3). Core + tests. |
| #24 | `k3/streaming-render-throttle` | Perf: macOS republished per token; coalesces prose-only updates to 10 Hz, mirroring `LinuxPanel`. `ResearchEngine`. (Same problem as #51, different implementation.) |
| #51 | `astra2/coalesced-snapshots` | Perf: same throttle as #24 as a shared, tested Core type (`SnapshotCoalescer`); also feeds `onThreadChanged` during the stream so a mid-run crash no longer loses the partial answer. |
| #25 | `k3/ask-from-history` | Bug: asking while the history list was open ran the research invisibly behind it. `PanelRootView`. |
| #31 | `k3/scroll-follow` | Bug/UX: every token scrolled to bottom even while the user read back. `BottomSentinel` + "Latest" pill; follows only while pinned. (Same problem as #49.) |
| #49 | `astra2/pinned-autoscroll` | Bug/UX: same yank as #31, fixed with preference-probe geometry and hysteresis thresholds sized above coalesced-batch growth (no ordering assumption between geometry reports and scroll decisions). |
| #32 | `k3/markdown-tables` | Feature: pipe tables in `MarkdownParser`, `Grid` renderer on macOS, aligned `<tt>` in Pango. 8 tests. |
| #33 | `k3/turn-polish` | Feature: "Ask again" on completed turns; live elapsed clock in the process trail. |
| #34 | `k3/empty-state-examples` | Feature: clickable example questions seed the composer. |
| #35 | `k3/history-search-index` | Perf: history search lowercased every answer per keystroke; `ThreadSearchIndex` builds one haystack per thread on library change. (Same problem as #47.) |
| #47 | `astra2/history-search-perf` | Perf: same cost as #35, fixed allocation-free with `range(of:options:.caseInsensitive)` — no index structure to keep warm. Behavior pinned by tests. |
| #36 | `k3/completion-signal` | Feature: menu-bar hourglass while running; soft sound when a run completes with the panel closed. |
| #48 | `astra2/search-progress` | Feature: live "Searching the web · 2 of 3" in the running trail (both platforms) via `ResearchTurn.searchesCompleted`; first-ever `ResearchTurn` field addition, with the hand-written tolerant `init(from:)` that keeps every existing threads.json loading. |
| #50 | `astra2/composer-fixes` | Bug: composer height computed against the unclamped width preference (wraps early on clamped panels) — now measured from the row. Also clears the redaction banner on panel hide. |
| #52 | `astra2/queued-question` | Feature: the composer stays editable while a run is in flight; a submit mid-run queues the question (one slot, newest wins, chip + cancel), asked the moment the answer lands. macOS + Linux + engine. |

Notes on verification: Core changes were tested locally on Linux (Swift 6.2.3,
198+ tests green). macOS view changes could not be compiled locally (no Mac);
they are deliberately small and idiomatic. Fork PRs (astra2/*) currently get
**neither** the GLM review (workflow guard requires same-repo branches) nor CI
(workflows need maintainer approval for first-time fork contributors) — approving
one run of CI on them is worthwhile before merging the view-layer PRs
(#49/#50/#52).

## Bugs not yet fixed

1. **B5 — Reasoning models show dead air before the first token.**
   `ChatCompletionsClient.streamText` reads only `delta.content`. Reasoning
   models (GLM-5, DeepSeek-R1, o-series via gateways) stream
   `delta.reasoning_content` first, sometimes for tens of seconds; the panel
   shows a blinking caret meanwhile. Fix: count reasoning deltas as progress —
   ideally render them as a collapsed, dimmed "thinking" trail (see D1). Touch
   points: `streamText` parsing, `ResearchTurn` (a `thinking` field — decode it
   tolerantly, see the standing constraint below), both front ends' trails.
   `completeJSON` should also tolerate `reasoning_content` on non-streaming
   replies (content can arrive alongside it).
2. **B6 — Retrying an old failed turn leaves its "Try again" live forever.**
   `ResearchEngine.retry` on a non-last turn appends a new turn but the old
   failure row keeps offering retry, inviting duplicates. Mark the old turn
   retried, or hide the affordance once a newer turn exists for the same
   question.
3. **B7 — Small nits worth a sweep.** `/copy` on an empty or failed last turn
   copies a near-empty transcript without saying so; the history row's delete
   button is nested inside the row button's label (works, fragile under
   restyling); `Source.domain` re-parses `URLComponents` on every render of
   every chip (cache it).
4. **G6-adjacent — `/direct` with an empty model reply.** `streamText` throws
   "empty answer" for whitespace-only replies — fine — but a `/direct` answer
   that the provider truncates (`finish_reason: length`) fails the whole turn
   instead of keeping the partial. Decide whether partial-but-badged beats
   failed.

## Performance

- **P2 — `TurnView.validation` recomputes per render.** Mostly covered by the
  throttle PRs (#24/#51); if profiling still shows it, memoize per answer
  string.
- **P3 — `ComposerView.height` builds a text stack per keystroke.** Bounded and
  small; only revisit if the composer ever handles large pastes.
- **P4 — Non-streaming calls inherit the 10-minute wall budget.** `collect`'s
  600 s deadline applies to the two small JSON calls (plan, assess) as well as
  the streamed answer; a wedged gateway holds a turn for ten minutes before the
  user learns anything. Give `completeJSON` a tighter budget (~120–180 s) with
  the same safe-error surface.
- A thread of ~50 turns re-lays-out eagerly on new turns (`LazyVStack` +
  `fixedSize` everywhere). Fine at 10 Hz; revisit only with evidence.

## Robustness / general

- **G1 — No transient-failure retry.** A 429 or a dropped connection fails the
  whole turn. The plan and assess calls are small and idempotent — worth one
  retry with backoff; keep the streamed answer failing fast. `ResearchRunner`
  and `ChatCompletionsClient`.
- **G2 — No token-usage visibility.** `stream_options: {include_usage: true}`
  works on OpenAI and most gateways; surface "2.1k tokens" in the collapsed
  trail. Verify against z.ai first (unknown params are ignored by conforming
  servers, but verify).
- **G3/F9 — `vervellum --json`.** `StandardErrorLog`'s comment already
  anticipates it. Emit the finished turn as JSON (answer, findings, sources,
  notices) for scripting. `LinuxApp.runHeadless` + a `TranscriptFormatter`-style
  encoder in Core.
- **G4 — Linux parity is stubbed.** `/history` and `/settings` print
  "macOS-only". The archive and settings are shared, so a GTK history browser
  and a settings editor are pure UI work. Also missing on Linux: clickable
  follow-ups, Copy, retry buttons.
- **G5 — Read-only-history warning has no UI.** If `threads.json` is from a
  newer build, the archive goes read-only and warns on stderr only; the macOS
  UI shows history silently never updating. `ThreadStore.isReadOnly` is already
  exposed — surface a banner in `HistoryView`.
- **G7 — Accessibility grant-loss loop.** After an ad-hoc-signed update resets
  the grant, pressing the selection shortcut throws an alert every time until
  the user re-grants or disables the shortcut. Add a "just open the panel
  without the selection" escape (and remember it).
- **G8 — Linux: a run outliving its window is invisible.** Escape closes the
  window while research continues (correct), but nothing tells the user it
  finished. A desktop notification on completion would close the loop; pairs
  with #36's macOS signal.
- **Pin the Linux CI image by digest for real.** `linux.yml`'s comment claims a
  digest pin, but the job references the mutable `swift:6.1-noble` tag — the
  drift that broke main (see PR #38) without a code change.

## Features worth building

- **F5 — Shell-style global recall.** `↑`/`↓` walk this thread's questions;
  walking all threads' questions (newest first, deduped) matches shell muscle
  memory. `ThreadStore` lookup in `PanelRootView.recall`.
- **F6 — Export a thread as markdown.** ⌘S → NSSavePanel; extends
  `TranscriptFormatter` to a whole thread. Remember to `NSApp.activate()` first
  from the agent.
- **F8 — Keyboard navigation in History.** ↑/↓ walk results, Return opens,
  ⌫ deletes. Spotlight muscle memory.
- **F12 — Thread rename and per-turn delete.** Threads are titled by their
  first question forever; a 60-character question is a poor library label, and
  a wrong turn cannot be removed without losing the thread. Both are pure
  document operations on `ResearchThread`/`ThreadLibrary`.
- **F13 — ⌘R retries the failed turn.** The failure row has a "Try again"
  button; the keyboard binding is unclaimed and matches muscle memory.
  Coordinate with #33's "Ask again".
- **F14 — `vervellum://ask?q=…` URL scheme.** One-line asks from Shortcuts,
  Alfred, a browser bookmarklet. Small registration, large power-user surface;
  non-sandboxed app, trivially available.
- **F15 — `/clip` command.** Seed the composer from the clipboard *through the
  same redaction path as the selection shortcut* — the safety machinery is
  already built, the command catalogue is already extensible, and it is the
  same "see what will leave the Mac" contract.
- **D1 — "Watch it think".** Render `reasoning_content` dimmed and collapsible
  in the trail (depends on B5). Delightful *and* honest — real process instead
  of a spinner.
- **D3 — Verdict dots in History rows.** Green/amber/red per thread from its
  findings distribution; the data is already there.
- **D4 — `/digest`.** Summarise the current thread's unsettled claims into one
  brief, `/direct`-style (no search). Uses the `unsettled` data already in
  `ResearchContext`; zero new infrastructure.
- **D5 — Citation popover, forward and reverse.** Hover an inline `[3]` →
  source title + snippet popover instead of a bare tooltip (anchoring from an
  AttributedString link is fiddly; anchoring at the source-list row is nearly
  free). The reverse direction is the novel half: click a source row → the
  sentences in the answer that cite it, via a reverse index that is a pure
  function over data already in memory.
- **D6 — Recent threads in the status menu.** The menu-bar icon is the app's
  only persistent surface; five recent thread titles, click to reopen, makes
  history reachable without summoning the panel. Pairs with #36's activity
  icon.
- **V2 — Verdict strip in the collapsed trail.** Echo the findings distribution
  as a tiny stacked bar (GitHub-language-bar idiom) or dots in the one-line
  trail summary; evidential health at a glance. Colorblind-safe because it
  supplements, never replaces, the text.
- **V3 — Source snippets without hover.** The "Search summary — not the full
  page" reveal is hover-only; keyboard/screen-reader users never see it. An
  expand chevron fixes it — or make the cited rows' snippet one always-visible,
  truncating line.
- **V4 — Per-query outcome in the trail.** A failed search shows nothing in the
  expanded trail; a quiet ✓/✕ glyph per planned query would make the audit
  trail complete (the runner already knows).
- **F10 — Planning-stage shimmer.** The plan call is the longest silent gap;
  an indeterminate shimmer on the trail card sells aliveness while waiting.
- **F11 — Custom summon accelerator on Linux.** `ShortcutInstaller` hardcodes
  `<Control><Alt><Super>space`; re-running with a user-chosen binding is a
  `gsettings` call away.

## Deliberately not pursued

- Reasoning display (B5/D1) needs a live reasoning model to tune against.
- Linux UI parity (G4) needs GTK headers to test; out of scope for a headless
  box.
- F6 export and F8 history keys are small but easy to get subtly wrong without
  a Mac to try them on.
- Per-thread reading-position memory (scroll offset persisted in the thread
  document): research threads are usually reopened for the newest answer, which
  sits at the bottom anyway.

## Standing constraints (do not regress)

- The model may never write URLs — citations are numbers only. Do not "check
  links instead".
- `insufficient`/`opinion` are first-class verdicts; never collapse into false.
- Nothing under `Sources/VervellumKit/Core/` imports a platform framework.
- No `DispatchQueue.main`/`@MainActor` hops in Core (Linux runs GLib).
- No redirect following, no provider error text in logs, keys in the Keychain
  only, context trimmed loudly (`contextTrimmed`), never silently.
- New `ResearchTurn` fields must be decoded tolerantly (`decodeIfPresent` in
  `init(from:)`) — Swift's synthesized decoder requires every key, so an
  unhardened addition makes every existing threads.json (and its same-shaped
  `.bak`) unreadable and silently resets the library. The round-trip test
  guards `CodingKeys` against silent drops.
