# Vervellum — analysis & work queue

A consolidated review of the codebase (pipeline, both front ends, packaging, CI,
tests), written so a future contributor — human or LLM — can pick an item and go.
Items are ordered by user impact within each section. File references point at the
code as of `main` (6809080).

## In flight (PRs open, do not redo)

Each branch is self-contained; merge order does not matter, except that #32
(tables) touches `MarkdownParser` and everything else avoids it.

| PR | Branch | Scope |
| --- | --- | --- |
| #38 | `k3/fix-archive-test-inference` | CI: main was red on both platforms — Swift toolchain drift made `(raw as? UInt).map(Int.init)` ambiguous in ThreadArchiveTests, and the desktop-entry validation copied to a non-reverse-DNS filename, which desktop-file-utils 0.27+ rejects for a DBusActivatable entry. |
| #22 | `k3/atx-heading-closing-sequence` | Bug: `# C#` rendered as "C" — trailing `#` stripped without the required preceding space. Core + tests. |
| #23 | `k3/reject-fractional-citations` | Bug: `AssessmentParser` rounded a fractional source number (2.7) onto a real source (3). Core + tests. |
| #24 | `k3/streaming-render-throttle` | Perf: macOS republished per token (O(answer²) parsing per turn); now coalesces prose-only updates to 10 Hz, mirroring `LinuxPanel`. `ResearchEngine`. |
| #25 | `k3/ask-from-history` | Bug: asking while the history list was open ran the research invisibly behind it. `PanelRootView`. |
| #31 | `k3/scroll-follow` | Bug/UX: every token scrolled to bottom even while the user read back. Adds `BottomSentinel` + "Latest" pill; follows only while pinned. |
| #32 | `k3/markdown-tables` | Feature: pipe tables in `MarkdownParser` (delimiter-gated, `\|` escape, ragged rows normalised), `Grid` renderer on macOS, aligned `<tt>` in Pango. 8 tests. |
| #33 | `k3/turn-polish` | Feature: "Ask again" on completed turns; live elapsed clock in the process trail. |
| #34 | `k3/empty-state-examples` | Feature: clickable example questions seed the composer. |
| #35 | `k3/history-search-index` | Perf: history search lowercased every answer per keystroke; `ThreadSearchIndex` builds one haystack per thread on library change. Core + tests. |
| #36 | `k3/completion-signal` | Feature: menu-bar hourglass while running; soft sound when a run completes with the panel closed. |

Notes on verification: Core changes were tested locally on Linux (Swift 6.2.3,
197 tests green). macOS view changes could not be compiled locally (no Mac);
they are deliberately small and idiomatic.

## Bugs not yet fixed

1. **B5 — Reasoning models show dead air before the first token.**
   `ChatCompletionsClient.streamText` reads only `delta.content`. Reasoning
   models (GLM-5, DeepSeek-R1, o-series via gateways) stream
   `delta.reasoning_content` first, sometimes for tens of seconds; the panel
   shows a blinking caret meanwhile. Fix: count reasoning deltas as progress —
   ideally render them as a collapsed, dimmed "thinking" trail (see D1). Touch
   points: `streamText` parsing, `ResearchTurn` (a `thinking` field), both
   front ends' trails. `completeJSON` should also tolerate `reasoning_content`
   on non-streaming replies (content can arrive alongside it).
2. **B6 — Retrying an old failed turn leaves its "Try again" live forever.**
   `ResearchEngine.retry` on a non-last turn appends a new turn but the old
   failure row keeps offering retry, inviting duplicates. Mark the old turn
   retried, or hide the affordance once a newer turn exists for the same
   question.
3. **G6-adjacent — `/direct` with an empty model reply.** `streamText` throws
   "empty answer" for whitespace-only replies — fine — but a `/direct` answer
   that the provider truncates (`finish_reason: length`) fails the whole turn
   instead of keeping the partial. Decide whether partial-but-badged beats
   failed.

## Performance

- **P2 — `TurnView.validation` recomputes per render.** Mostly covered by the
  PR #24 throttle; if profiling still shows it, memoize per answer string.
- **P3 — `ComposerView.height` builds a text stack per keystroke.** Bounded and
  small; only revisit if the composer ever handles large pastes.
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
- **D1 — "Watch it think".** Render `reasoning_content` dimmed and collapsible
  in the trail (depends on B5). Delightful *and* honest — real process instead
  of a spinner.
- **D3 — Verdict dots in History rows.** Green/amber/red per thread from its
  findings distribution; the data is already there.
- **D4 — `/digest`.** Summarise the current thread's unsettled claims into one
  brief, `/direct`-style (no search). Uses the `unsettled` data already in
  `ResearchContext`; zero new infrastructure.
- **D5 — Citation popover.** Hover an inline `[3]` → source title + snippet
  popover instead of a bare tooltip. Anchoring from an AttributedString link is
  fiddly; anchoring at the source-list row is nearly free.
- **V2 — Verdict strip in the collapsed trail.** Echo the findings distribution
  as tiny dots in the one-line trail summary; evidential health at a glance.
- **V3 — Source snippets without hover.** The "Search summary — not the full
  page" reveal is hover-only; keyboard/screen-reader users never see it. An
  expand chevron fixes it.
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

## Standing constraints (do not regress)

- The model may never write URLs — citations are numbers only. Do not "check
  links instead".
- `insufficient`/`opinion` are first-class verdicts; never collapse into false.
- Nothing under `Sources/VervellumKit/Core/` imports a platform framework.
- No `DispatchQueue.main`/`@MainActor` hops in Core (Linux runs GLib).
- No redirect following, no provider error text in logs, keys in the Keychain
  only, context trimmed loudly (`contextTrimmed`), never silently.
