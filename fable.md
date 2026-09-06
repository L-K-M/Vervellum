# Vervellum — a thorough review

*Reviewer: Claude Fable 5.1 · 2026-09-06 · base commit `5be8eab` ("Activated new icon")*

This is a review of the whole repository: the shared core, the macOS panel, the Linux
front end, the prompts, the packaging and CI, and the documentation. It covers bugs,
performance and stuttering, missing features, visual and layout problems, and ideas
for a faster, friendlier, more delightful panel.

**How it was done.** I read every Swift, C, YAML and Markdown file in the repository,
then ran fourteen independent review passes, one lens each (pipeline correctness,
transport and cancellation, the SwiftUI views, windowing and hotkeys, persistence and
secrets, the Linux front end, prompt engineering, security, docs/CI drift, interaction
design, visual design, missing features, delight, performance), followed by
completeness sweeps and an adversarial verification pass in which every bug claim was
re-derived from the code by independent skeptics before it was kept. I also installed
the Swift 6.1 toolchain and GTK headers on an Ubuntu 24.04 container and ran the real
Linux CI steps (`swift build`, `swift test`, `desktop-file-validate`,
`packaging/build-deb.sh`, `dpkg --install`) to confirm the CI findings by execution
rather than by reading. Line numbers refer to the base commit above.

**Verdict in one paragraph.** This is a well-designed, well-argued codebase. The
architecture (a Foundation-only core compiled into two front ends, the number-only
citation rule, verdicts as a separate call, a transport that refuses redirects) is
right, and the comments explain *why* in a way most projects never manage. The
problems are almost all in the last mile: CI never ran, a handful of real
correctness bugs in streaming and assessment turn the app's own thesis ("never a
silently truncated, confidently wrong answer") against it, the panel does per-token
work it does not need to, the Linux front end has one use-after-free and several
parity gaps, and the interaction design leaves value on the table during the forty
seconds the user spends waiting.

---

## 1. Headlines

The ten things I would fix first, in order.

| # | What | Where | Status |
|---|---|---|---|
| 1 | Both CI workflows have been red since the first commit: the shared test target does not compile (`ambiguous use of 'init'`), and once it does, the Linux job fails `desktop-file-validate` on a filename rule | `Tests/…/ThreadArchiveTests.swift:148`, `.github/workflows/linux.yml` | **Fixed in PR #2** |
| 2 | A stream that ends with an `error` frame, or that is cancelled mid-`/direct`, is recorded as a *complete* answer and then assessed and reused as thread context | `ChatCompletionsClient.streamText`, `ResearchRunner.answerDirectly` | **PR #53** |
| 3 | Every OpenAI reasoning model (o-series, gpt-5 family) fails with an unexplained HTTP 400 because `temperature` is always sent | `ChatCompletionsClient` | **PR #54** |
| 4 | Only z.ai's search tool names are accepted, so the "bring your own MCP search server" promise is false for Brave, Tavily, Exa, SearXNG | `SearchMCPClient.connect` | **PR #55** |
| 5 | Citation validation runs over code, so `argv[0]` in a code block yields "The model referred to a source number that does not exist" and marks sources as cited | `CitationValidator`, `ResearchTurn.applyCitationValidation` | **PR #56** |
| 6 | A failed assessment call throws away a complete, visible answer: the turn is marked failed and silently dropped from all later context | `ResearchRunner.execute` stage 5 | **PR #57** |
| 7 | On Linux the window-manager close button destroys the GTK window while the held D-Bus service keeps the dangling pointer; the next shortcut press is a use-after-free | `LinuxPanel.init` | **PR #59** |
| 8 | Pressing the summon hotkey while the panel is open but no longer key *hides* it instead of refocusing it; the composer is disabled for the whole run; auto-scroll drags a reader who scrolled up back to the bottom on every token | `PanelController.toggle`, `PanelRootView` | B22 withdrawn after dispute (§11.2); B24 is #52 and B25 is #49/#31 by other authors, not duplicated |
| 9 | A markdown link written by the model (`[text](url)`) is rendered as a clickable link by `AttributedString(markdown:)`, which undercuts the number-only citation rule at the rendering layer | `MarkdownText.parseInline` | **PR #67** |
| 10 | Per-token cost: every streamed chunk republishes the whole thread, re-parses the whole answer, re-validates every block and re-measures the composer | `ResearchEngine`, `MarkdownBody`, `PanelRootView` | #51/#24 by other authors cover the coalescing; not duplicated (§11.5) |

---

## 2. Bugs

Severity: **critical** = data loss, crash, security, or build/CI broken; **high** = a core
flow visibly wrong for many users; **medium** = noticeable, with a workaround;
**low** = polish. Each entry names the property it breaks, because in this codebase
that is how the fix is judged.

### 2.1 Build and CI

**B1 · critical · The shared test target does not compile on either platform.**
`Tests/VervellumKitTests/ThreadArchiveTests.swift:148` writes
`(raw as? UInt).map(Int.init)`. `Int.init` as an unapplied reference is ambiguous for
a `UInt` argument (`init(_:)`, `init(bitPattern:)`, `init(truncatingIfNeeded:)`,
`init(clamping:)`), and both the Xcode test target and `swift test` refuse it. Every
push to `main` has been red; no test has ever run in CI. *Fix:* `.map { Int($0) }`.
Verified: 198 tests, 0 failures on Swift 6.1 / Ubuntu 24.04. **Fixed in PR #2.**

**B2 · critical · The Linux job fails `desktop-file-validate` by filename.** The
workflow writes the substituted entry to `/tmp/entry.desktop`, and for a
`DBusActivatable=true` entry the validator checks that the *filename* is reverse-DNS
before it looks at the contents. This was masked by B1. *Fix:* validate under
`ch.lkmc.Vervellum.desktop`. **Fixed in PR #2.**

**B3 · low · `Categories=Utility;Office;` names two main categories.** The validator
warns that the launcher may list the app twice. `packaging/debian/ch.lkmc.Vervellum.desktop`.
*Fix:* `Categories=Utility;` (keep `Keywords`).

**B4 · low · Docs say the Swift image is "pinned by digest"; it is pinned by tag.**
`linux.yml` and `release.yml` use `image: swift:6.1-noble`; the comments and `CICD.md`
claim a digest pin. Either pin `swift@sha256:…` or correct the prose.

### 2.2 Streaming, transport and cancellation

**B5 · high · An answer stream that ends with an error frame is treated as complete.**
`ChatCompletionsClient.streamText` (lines 112–119) only reads `choices[0].delta` and
`finish_reason`. An SSE frame carrying a top-level `error` object (what OpenAI-compatible
servers emit when a stream fails mid-way, usually followed by a clean close and no
`[DONE]`) has no `choices`, so the guard `continue`s past it; the transport finishes
normally; `checkFinishReason(nil)` passes; the partial text is returned, citation-
validated, *assessed*, marked `.complete`, persisted, and fed to every later turn as
history. This is exactly the failure the app exists to prevent. *Fix:* treat
`event["error"] != nil` as a `ResearchError` written by Vervellum (never the provider's
text), and add a test feeding `[{delta:"a"},{error:{…}}]` through the accumulation.

**B6 · medium · Stop during a `/direct` answer marks the truncated answer as complete.**
Cancelling the consuming task while `streamText` is suspended in `for try await` makes
`AsyncThrowingStream.next()` return `nil` (the stream is terminated with `.cancelled`,
not finished with an error), so the loop exits *normally*, the `Task.checkCancellation()`
inside the loop never runs, and `streamText` returns the fragment. The research path
is rescued by the `checkCancellation()` at `ResearchRunner.swift:290`; `answerDirectly`
has no such check, so `run` sets `.complete`. `ResearchEngine.cancel()` had already
marked the turn `.cancelled`, but `finish(id, with:)` then overwrites it with the
runner's `.complete` turn, which is persisted and becomes history. *Fix:*
`try Task.checkCancellation()` after the loop in `streamText`, and again after the
call in `answerDirectly`.

**B7 · low · A `[DONE]` sentinel that follows a `data:` line without a blank line drops
that frame.** `streamJSONEvents` returns `false` on `[DONE]` before flushing `payload`,
and the post-loop flush is guarded by `!finished` (HTTPTransport.swift:223–231). A
gateway that emits the last delta and the sentinel in one event block loses the last
delta — typically the one carrying `finish_reason`. *Fix:* decode the pending payload
before honouring the sentinel.

**B8 · low · The SSE line splitter ignores CR-only line endings and a leading BOM.**
`readLines` splits on `0x0A` only. Both are permitted by the SSE grammar and both are
rare in practice; the reader is the one place the code says it owns SSE framing, so
they belong there. *Fix:* split on CR or LF (consuming CRLF as one), strip `EF BB BF`
once at the start.

**B9 · low · A partial answer kept after Stop or a late stream failure is never
citation-validated.** `applyCitationValidation` only runs when `streamText` returns.
A literal URL the model wrote in paragraph two carries no warning if the user stops in
paragraph three. *Fix:* validate in `run`'s catch when `answer` is non-empty.

**B10 · low · The gateway-envelope heuristic misreports quota errors as bad keys.**
`SearchMCPClient.checkGatewayEnvelope` classifies any `msg` containing "token" as an
authentication failure; "insufficient token balance" tells the user to replace a key
that works. *Fix:* drop the bare "token" match, prefer the numeric `code`.

### 2.3 Research pipeline

**B11 · high · `temperature` is always sent; reasoning models reject it with 400.**
`completeJSON` sends `0.2`, `streamText` sends `0.4`. OpenAI's o1/o3/o4-mini and the
gpt-5 family reject any non-default temperature with HTTP 400, which the app reports
as "Check the endpoint, key, model and quota" — none of which is the cause, and there
is no setting to remove it. Every research turn and every `/direct` turn fails.
*Fix:* keep the low temperature where it is accepted, but on an HTTP 400 for a request
that carried optional sampling parameters retry exactly once without them (the 400
arrives before any streamed content, so this is safe for the streaming call too), and
remember the outcome for the rest of the turn. The same mechanism can carry
`response_format: {"type": "json_object"}` for the two JSON stages, which materially
reduces "did not return the requested JSON" on smaller models and is rejected by some
gateways in exactly the same way. Extend the 400 message to name the possibility.

**B12 · medium · Only z.ai's tool names pass the MCP handshake.**
`SearchMCPClient.searchToolNames = ["web_search_prime", "webSearchPrime"]`; any other
server (Brave `brave_web_search`, Tavily `tavily-search`, Exa `web_search_exa`,
SearXNG) fails with "did not advertise a supported web-search tool", while README and
PLAN describe the search side generically. Nothing downstream depends on the name: the
schema is fetched, the arguments are validated against it, and `EvidenceExtractor`
walks any shape. *Fix:* resolve by shape — known names first, then a single advertised
tool, then the first tool whose name contains "search" and whose schema has a string
property named `search_query`/`query`/`q`; list the advertised names in the error.

**B13 · medium · Citation validation runs over fenced and inline code.**
`citationRegex` matches any `[digits]`; `applyCitationValidation` scans the raw
markdown. `argv[0]` in a code sample produces `outOfRangeCitations = [0]` and the notice
"The model referred to a source number that does not exist"; `items[1]` marks source 1
as cited in the Sources list and the transcript though no chip exists in the rendered
answer; in inline code the renderer *does* mask it into a chip. Both renderers skip
fenced code deliberately, so the model is shown one thing, the renderer another, and
the validator judges a third. *Fix:* make `CitationValidator` skip fenced blocks and
backtick spans (a pure change, testable), and tell the model in the answer prompt that
a bracketed number inside code is code.

**B14 · medium · A failed assessment fails a completed answer.** Any error in stage 5 —
unrecoverable JSON, `finish_reason: "length"` because a gateway's default output cap is
smaller than eight findings plus limitations, a transient 5xx — propagates to `run`,
which marks the turn `.failed`. The answer is still on the turn, but the panel labels
it failed, `ResearchContext` excludes it from all later context (it filters on
`.complete`), and the "length" message tells the user to shorten a question that had
nothing to do with it. *Fix:* catch non-cancellation errors from the assess stage, add
a notice ("The answer's claims could not be checked"), and let the turn complete with
no findings; fail the turn only when the answer itself failed.

**B15 · medium · Historic answers carry `[n]` markers that index a different source
list.** `ResearchContext.historyEntry` sends the shortened previous answer verbatim.
A model that restates "X is true [1]" from turn 1 produces a chip that links to
whatever *this* turn's source 1 is, passes range validation, and shows a clean badge.
This is a wrong attribution the number-only rule is supposed to make impossible.
*Fix:* strip citation spans from historic answers before they enter the payload, and
say in the answer prompt that numbers inside `thread[].answer` are not citations.

**B16 · medium · `sources` is only read as a JSON array.** `"sources": "1, 3"`,
`"sources": 3` or `["[1]"]` yield an empty list, and a correctly cited *supported*
verdict is dropped with the notice "A verdict that cited no source was discarded",
which blames the model for a citation it made. *Fix:* accept scalars and extract
decimal runs from strings; test each shape.

**B17 · low · An unrecognised verdict word drops the finding silently.** "Not
established" (the app's own label), "unsupported", "refuted", "partially supported" all
hit `Verdict(rawValue:)`'s `nil` and are skipped with no notice, so a reply whose
verdicts all used a synonym yields an empty table and no explanation. *Fix:* trim, map
an unambiguous synonym table (never `unsupported` → `contradicted`), and record a
notice for anything still unusable.

**B18 · low · Retry re-asks in `/direct` mode after an empty plan with no `reading`.**
`wasAskedDirectly` is `notices.contains(.noEvidence) && reading.isEmpty`; a plan reply
of `{"searches": []}` makes a research turn indistinguishable from a direct one, so
Retry skips the planner the user never opted out of. *Fix:* substitute a fixed reading
sentence in the empty-plan branch, or record the asked mode on the turn.

**B19 · low · `decodeJSONObject` takes the first `{`.** A reasoning model that leaks a
`<think>` block mentioning the schema (`{"reading": ..., "searches": [...]}`) makes the
first brace-balanced run an unparsable example, and the whole reply is rejected.
*Fix:* strip a leading `<think>…</think>`, and iterate over balanced runs until one
parses.

**B20 · low · Source numbering is not reproducible across launches.**
`EvidenceExtractor.collect` iterates a dictionary; when a result carries hits under two
keys the numbering depends on Swift's per-process hash seed. Threads stay internally
consistent, but two users with the same response get different numbers and fixtures
cannot assert them. *Fix:* iterate sorted keys (or a fixed priority list).

**B21 · low · The user payload is serialised without `sortedKeys`.** The question's
position relative to a 70 KB evidence block differs between runs and platforms, which
defeats deterministic replay and provider prefix caching. *Fix:* `.sortedKeys` at both
call sites (which also lands `question` *after* `evidence`, the placement long-context
guidance prefers).

### 2.4 macOS panel

**B22 · high · The summon hotkey hides a panel that is open but no longer key.**
`PanelController.toggle()` hides whenever `isOpen` and the pointer is on the same
screen. The common case — the user clicked into their editor to keep working, then
pressed the shortcut to ask a follow-up — makes the panel vanish, and a second press
brings it back. Spotlight and Raycast re-focus in this state. *Fix:* if the panel is
open but not key, `focus(panel)` instead of `hide()`.

**B23 · high · Model-written markdown links are clickable.** `MarkdownText.parseInline`
uses `.inlineOnlyPreservingWhitespace`, which still parses `[text](url)` into a
`.link` run, and SwiftUI `Text` renders it as a tappable link opened through
`openURL`. `CitationValidator` flags the literal URL with a notice, but the link is
still live, and the scheme is whatever the model (or a prompt-injected search result
that reached the model) wrote — `file:` included. The number-only rule is meant to make
a link the model wrote *inexpressible*; the renderer re-expresses it. *Fix:* after
parsing, remove `.link` from every run before the citation chips are substituted, so
the only links in an answer are chips pointing at sources Vervellum fetched.

**B24 · medium · The composer is disabled for the whole run.** `isEnabled:
!engine.isRunning` makes the field non-editable for the forty seconds in which the
follow-up is freshest. *Fix:* keep it editable; queue a question submitted while
running and start it when the turn ends (see idea F3).

**B25 · medium · Auto-scroll fights the reader.** `.onChange(of: turns.last?.answer)`
scrolls to the bottom on every chunk, so a reader who scrolled up to re-read paragraph
one is dragged back within ~100 ms until the answer finishes. *Fix:* only stick to the
bottom while the bottom anchor is visible; show a "↓ Latest" pill otherwise.

**B26 · medium · Hover on a source row changes its height.** The snippet appears only
under the pointer and the row grows, so moving down the list reflows every row above
the target under the pointer, and the snippet is unreachable by keyboard or VoiceOver.
*Fix:* a stable one-line snippet preview with click/Space to expand.

**B27 · medium · A shortcut that fails to register is silently dead.**
`CarbonHotkey.register` returns `false` when another app owns the combination;
`AppDelegate.registerHotkeys` ignores it. The user learns nothing. *Fix:* surface it in
Settings ▸ Shortcuts and in the status menu.

**B28 · low · The empty-state hint and `/help` ignore `submitOnReturn`.** With the
preference inverted the hint says the opposite of what Return does.

**B29 · low · History delete has no confirmation and no undo.** One click on the hover
trash icon deletes a thread.

**B30 · low · The panel is neither resizable nor position-stable.** The style mask lacks
`.resizable`; width is only reachable through a Settings slider; `panelHeight` has no
UI at all; a dragged panel is re-placed on every show.

**B31 · low · `Preferences.launchAtLogin` calls `SMAppService.mainApp.status` (an XPC
round trip) on every render of the General pane.**

**B32 · low · `HotkeyRecorder` compares `keyCode == 53` instead of `KeyCode.escape`.**

### 2.5 Linux front end

**B33 · high · The window-manager close button destroys the window; the next shortcut
press uses freed memory.** Nothing sets `gtk_window_set_hide_on_close` or handles
`close-request`, so GTK's default destroys the `GtkApplicationWindow`. The process is
held (`g_application_hold`) and `ensurePanel()` returns the cached `LinuxPanel`, whose
`toggle()` then calls `gtk_widget_get_visible` on a finalised object. Every later
shortcut press routes to this dead primary instance until the user finds and kills it,
and there is no Quit in the UI. *Fix:* `gtk_window_set_hide_on_close(…, 1)` in
`LinuxPanel.init`.

**B34 · medium · The composer's key controller runs before the input method.** Return
during an IME preedit (Japanese, Chinese, Korean, Compose) submits the half-composed
text; Escape wipes the draft. macOS explicitly yields to the IME. *Fix:* pass the event
through `gtk_text_view_im_context_filter_keypress` first.

**B35 · medium · Return cancels an in-flight run.** `submitOrStop` is bound to both the
button and Return; typing a follow-up and pressing Return out of habit aborts the
current answer. The status line says "press Ask again to stop" while the button says
"Stop". *Fix:* Return ignores a running turn (as on macOS); only the button stops.

**B36 · medium · `settings.json` is read once per process and the service never
exits.** The empty state tells the user to edit the file but not that a restart is
needed; Close and Escape only hide the window; the `quit` action is exposed nowhere.
*Fix:* reload the file when its modification date changes; expose Ctrl+Q.

**B37 · medium · The thread never scrolls to the newest turn.** After the first screen,
a new question and its streaming answer land below the fold. *Fix:* set the vertical
adjustment to its upper bound after appending a turn and while streaming, unless the
user scrolled up.

**B38 · low · A cancelled turn is indistinguishable from a completed one** (no
"Stopped" in the trail). **B39 · low · No Retry on a failed turn**, and the trail omits
the planned queries. **B40 · low · `render()` spawns `secret-tool` twice, synchronously,
on the GTK main loop** whenever the thread is empty, which blocks on the keyring unlock
dialog. **B41 · low · The first GUI launch re-installs the default shortcut** and
overwrites a binding the user changed after `--install-shortcut`, because the CLI path
never sets the `shortcutInstalled` flag. **B42 · low · `ShortcutInstaller` records
success even when every `gsettings set` fails** (exit codes are discarded).
**B43 · low · The Linux empty-state hint is hard-coded to Return-sends**, and
Ctrl+Return (the always-send key) has no meaning.

**B44 · medium · `render()` rebuilds the whole widget tree up to ten times a second**
while streaming, which drops text selection and reflows the view. Documented as a
choice; still the single thing that makes the Linux window feel worse than it is.
*Fix:* keep the widgets of finished turns; rebuild only the running turn's box.

### 2.6 Persistence, preferences and secrets

**B45 · low · A crash mid-answer loses the partial answer.** `ResearchEngine` calls
`onThreadChanged` only on ask/finish/cancel; snapshots never reach the archive until
the turn ends. Acceptable, but worth a throttled save (see P4).

**B46 · low · `ThreadLibrary` bounds threads at 200 but never bounds turns inside a
thread**, and `search` is a substring scan over every question and answer on every
keystroke of the history filter. Fine at today's scale; note it.

**B47 · medium · A newer build's document with an unknown `TurnNotice` raw value makes
an older build overwrite it.** `notices: [TurnNotice]` is a synthesized array of a
raw-value enum, so one unknown value fails the whole `ThreadLibrary` decode. The
read-only guard only fires on a `version` bump; without one, `ThreadArchive.load` tries
`.bak` (written by the same newer build, so it fails too), returns `nil`, `isReadOnly`
stays false, the archive starts empty, and the next save rotates the newer file into
`.bak` and replaces it. A second save loses it entirely. *Fix:* decode an unknown
notice as a visible "recorded by a newer version" case instead of failing, and treat
any additive change to a persisted enum as a `currentVersion` bump.

### 2.7 Documentation drift

**B48 · low · README, PLAN and Settings say any MCP web-search server works** (see B12).
**B49 · low · `CICD.md` and workflow comments claim digest pins** (see B4).
**B50 · low · `PLAN.md §1.3` promises "searching the web · 3 of 4"**; the trail shows
the total only. **B51 · low · No `CHANGELOG.md`, no screenshot in the README** for a
product whose whole pitch is visual.

---

## 3. Performance and stuttering

The panel does not stutter because of the network; it stutters because of what it does
with each token.

**P1 · Every chunk republishes the whole thread.** `ResearchRunner.update` snapshots the
entire `ResearchTurn` (sources, snippets, findings) per delta, `ResearchEngine.apply`
replaces it in `thread.turns`, and `@Published thread` invalidates `PanelRootView` and
every `TurnView` in the thread. *Fix:* coalesce deltas at ~30 Hz in the engine (append
chunks to a buffer, flush on a timer on the main queue — FIFO is preserved because the
buffer is only ever appended on the main queue), and give `TurnView` an `Equatable`
gate so finished turns stop re-evaluating.

**P2 · Every render re-parses the whole answer.** `MarkdownBody` calls
`MarkdownParser.parse(markdown)` per body evaluation, then `MarkdownText` runs
`CitationValidator.validate` *and* `AttributedString(markdown:)` per block. For a
30-block answer at 50 tokens/s that is 1,500 markdown parses per second on the main
thread. *Fix:* cache parsed blocks keyed by the block's text (a small LRU keyed by
`String` hash), and re-parse only the last block while streaming; finished turns never
re-parse.

**P3 · `ComposerView.height(for:width:)` builds an `NSTextStorage` and a layout manager
on every `PanelRootView` render**, i.e. per token, to measure a field that did not
change. *Fix:* memoise on `(draft, width)`.

**P4 · `ScrollViewReader.scrollTo` runs per token** and fights the user (B25). *Fix:*
scroll only when pinned to the bottom and only when the content height changed.

**P5 · `TurnView.validation` runs `CitationValidator` on the full answer per render**
just to compute the cited set for `SourcesView`. *Fix:* compute once per answer change.

**P6 · `refreshConfiguredState` performs two Keychain reads on every summon.** Cheap
enough, but it also runs `SecItemCopyMatching` on the main thread; a locked keychain
can prompt. Note only.

**P7 · Linux `render()` rebuild** (B44).

**P8 · `LinuxPanel.render()` runs `secret-tool` synchronously** (B40).

---

## 4. Interaction design

What a user feels in the forty seconds between Return and the verdict table, and what
they can do afterwards.

**U1 · Waiting is a black box.** The trail shows "Searching the web · 4 queries" and a
static list; sources appear in one lump after the last search; a failed search is
invisible unless all of them fail. *Proposal:* per-query state (pending / running /
done with N hits / failed), sources published after each search, an elapsed clock, and
a four-dot stage timeline (Plan → Search → Answer → Assess) while running. This is the
PLAN §1.3 promise, delivered.

**U2 · Typing the next question while reading.** See B24: keep the composer live and
queue the next question.

**U3 · Reading a long answer.** See B25: smart auto-scroll and a "Latest" pill.

**U4 · Recovery on failure.** The failure card offers only "Try again", which re-runs
the identical pipeline. When search failed, the message tells the user to type
`/direct`; when the app is unconfigured it tells them to open Settings. *Proposal:*
put "Answer without search" and "Open Settings…" on the card, driven by a
`failureKind` on the turn.

**U5 · History is mouse-only.** ⌘Y shows a list with its own SwiftUI `TextField` (the
control AGENTS.md says cannot reliably take focus in the reused hosting view), no row
selection, no keyboard open. *Proposal:* the composer becomes the filter while history
is showing; ↑/↓ select, Return opens, Escape leaves; group by Today / Yesterday / This
week / Older.

**U6 · Acting on a result.** One "Copy" (plain text). *Proposal:* Copy as Markdown (with
`[n]: url` reference definitions so the markers become live links in any viewer), copy
one citation, copy a code block, open all cited sources, ⌘⇧C for the last answer, ⌘1–⌘9
to open cited source *n*.

**U7 · First run.** Save validates URL shape only; the first real feedback on a wrong
model name is a failed research turn. *Proposal:* a "Test connection" button that runs
the same two cheap calls the runner starts with (MCP handshake, one tiny JSON
completion against the named model) and reports Vervellum-authored results; and the
empty state points at it.

**U8 · Slash commands.** The completion list is click-only; Tab inserts a tab. *Proposal:*
Tab completes, ↑/↓ walk the list while it is showing.

**U9 · Pasted secrets.** Only Accessibility-captured text is redacted; ⌘V goes straight
through. *Proposal:* route paste through `SecretRedactor` with the same note.

**U10 · Sources.** See B26; also a click on an inline `[3]` should reveal source 3 *in
the panel* (scroll and flash the row), with ⌘-click opening the page, instead of
leaving the panel for the browser on every click.

**U11 · Pin and rename threads**, so a reference thread the user returns to weekly is
not evicted by throwaway questions and two threads starting "What is the difference
between…" can be told apart.

**U12 · Presets and a search budget.** A provider preset picker (OpenAI, z.ai,
OpenRouter, Groq, Ollama, LM Studio, llama.cpp) filling endpoint, model placeholder
and the key-optional note; a "searches per question" setting (1–6) since the plumbing
for `maxSearches` already exists end to end.

---

## 5. Visual design and layout

**V1 · Light mode fails contrast.** The accent `#FF8A4C` is ~2.3:1 on a light ground;
`verdict(.mixed)` ~2.1:1; `supported` ~2.9:1. These carry 10–11 pt text (citation
chips, verdict labels, notices, follow-ups). The Linux palette already chose
light-safe hues (`#c4630f`, `#217a4a`, `#9a6a10`). *Fix:* scheme-aware
`Palette.accent(scheme)` / `verdict(_:scheme)` with the darker values in light mode and
a separate `accentFill` for white-on-orange glyphs.

**V2 · Reduce Motion is never consulted.** The caret blinks forever, the panel slides,
the trail moves. *Fix:* `Motion.isReduced` gating every animation, and observe
`didChangeAccessibilityDisplayOptionsNotification` so Reduce Transparency changes apply
without a re-render.

**V3 · Thirteen font sizes, and only the answer body honours the text-size slider.**
Claims, reasoning, sources, captions and the question are unscaled. *Fix:* a six-step
scale (10/11/13/15/17 + 11.5 mono), every step taking `scale`, threaded from `TurnView`
into every section.

**V4 · Verdict rows say one thing three times** (icon column, tracked uppercase word,
spine). *Fix:* one pill per row (icon + label in a tinted capsule), keep the 2 pt
spine, reclaim the 24 pt icon column.

**V5 · The verdict distribution is buried** as 10 pt tertiary text. *Fix:* a 4 pt
segmented evidence-health bar in the Claims header, with the counts as accessibility
label and tooltip; a 3 pt copy in the collapsed trail line.

**V6 · Sections read as paragraphs.** The gap between the answer and CLAIMS equals the
gap between two paragraphs. *Fix:* larger spacing between sections than within, a
hairline after each section label, a divider between turns.

**V7 · Cards vanish in dark mode; the scrim darkens light mode.** A single `Color.primary
.opacity(0.05)` fill and a single black scrim serve one appearance each. *Fix:*
scheme-tuned fills and a white scrim in light mode; under Reduce Transparency an opaque
window-background tint rather than a HUD blur.

**V8 · Inline citations interrupt the line like code tokens.** *Fix:* superscript chips
(`baselineOffset`) in a rounded 9 pt weight, brackets kept so a copied sentence still
reads.

**V9 · Sources are visually identical rows.** *Fix:* a deterministic 16 pt domain
monogram (FNV-1a hue, first letter of the registrable label). No favicon fetch: PRIVACY
promises nothing leaves the Mac except provider calls.

**V10 · Header chrome is flat**; close sits with content actions; no resize affordance.
*Fix:* close at the leading edge, New/History grouped trailing, Settings demoted;
`.resizable` on the style mask with min/max sizes written back to preferences.

**V11 · Empty state has no anchor.** A 44 pt SF Symbol composition (search · evidence ·
verdict) and the four-dot pipeline in its pending state.

**V12 · Linux parity** achievable with Pango + CSS: per-finding cards with a coloured
left border, `alpha="65%"` secondary text that follows the theme instead of `#7a7a7a`,
superscript citations, a block-character health bar.

---

## 6. Missing features

Ordered by value to the thesis "the evidence is the product".

**F1 · "Verify this claim."** A per-finding action that plans two searches aimed at that
claim (one to confirm, one to disconfirm), appends new sources with continuing numbers
(`EvidenceExtractor.sources(from:startingAt:)` already exists), and re-grades only that
claim. Turns an `insufficient` verdict from a dead end into a next step.

**F2 · "Read the page."** User-initiated, at most two per turn: GET the source through
`HTTPTransport` with *no* Authorization header, cap at 1.5 MB, reject non-text content
types, extract readable text with a Foundation-only extractor, attach it as an excerpt,
and re-run stage 4 only. PLAN §8 calls this the largest open question; this is the
bounded version of it.

**F3 · Queue the next question** (B24).

**F4 · Search-backend adapter** (B12) plus presets for Tavily / Exa / Brave / SearXNG.

**F5 · Provider presets** (U12).

**F6 · `/model` override and a separate assessment model.** Stage 4 is the
trust-bearing call; stage 1 is a tiny JSON call. Backlog #4, specified.

**F7 · Export a thread as Markdown** with reference-style links written by Vervellum
from the list it owns (not a relaxation of the citation rule). Backlog #5.

**F8 · `vervellum --ask --json`.** `LogSink` already reserves stdout for it.

**F9 · Services menu "Research with Vervellum"** (needs no Accessibility grant and
survives the ad-hoc re-signing that revokes it) and a `vervellum://ask?q=` URL scheme
for Shortcuts, Raycast and bookmarklets. Both seed the composer through the existing
redaction path and never auto-submit.

**F10 · Linux `/history`, `/settings`, `/copy`.** All three are small GTK4 additions
over Core types that already exist on Linux.

**F11 · "Watch this question."** A pure `ResearchDiff` (verdict changes per claim, new
and lost domains) plus `--compare` on the CLI; scheduling left to cron/launchd.

**F12 · One-line evidential summary per turn**, shared by the trail, the CLI and the
transcript: `✓ 4 searches · 17 sources · 6 claims: 4 supported, 1 mixed, 1 not
established · 0:41`.

**F13 · `/sources`**: plan and search, show the numbered list, skip the two model calls.

**F14 · Tags** (`/tag`, `tag:` filter).

---

## 7. Prompts and research quality

Each item names the property it defends, per AGENTS.md.

**Q1 · Language** (property: *the answer is written for the person who asked*). The
question is a JSON field under an English system prompt, which biases toward English
more than a chat message does. Add "Write in the language of the question" to the
answer and direct prompts, and let the planner choose the query language that surfaces
primary sources.

**Q2 · Dates** (property: *evidence is weighed by when it was written*). Evidence
carries `published` and the payload carries `today`, but the answer prompt never
mentions either; a 2023 blog can beat a 2026 release page for "what is the current
version". Ask the answer stage to prefer the most recent source for current-state
claims and to state its date; ask the assess stage to grade a current-state claim
backed only by an old source as *insufficient*.

**Q3 · The assess prompt addresses a model that "just wrote" the answer**, but the call
is a fresh context with no thread and no reading. Reword, and build the assess payload
with `ResearchContext.assemble` so it carries the budgeted thread and the reading.

**Q4 · Code and citations** (B13): "a bracketed number inside code is code".

**Q5 · Stale markers in history** (B15): "numbers inside `thread[].answer` are not
citations".

**Q6 · JSON mode** (B11): `response_format` behind the retry mechanism.

**Q7 · The plan prompt says "between 1 and N" then "return an empty array"**; say
"up to N, or an empty list".

---

## 8. Delightful, cool and quirky

Cheap, on-thesis, and each one earns its place.

**D1 · The thread title from the planner's reading.** The first question truncated at
60 characters is a poor title; the planner already writes a one-sentence reading. Use
it once the first turn lands (free).

**D2 · Disagreement badge.** When any finding is *contradicted* or *mixed*, the
collapsed trail line gets a small `arrow.triangle.branch` glyph and the tooltip names
the claim. The panel should be proudest when it found a fight.

**D3 · Source age tint.** Colour the citation chip's underline by the source's
`published` age (fresh → accent, a year old → tertiary), with the date in the tooltip.

**D4 · The menu-bar icon breathes while a run is in flight** (template image swap on a
timer, no animation under Reduce Motion) and shows a dot when an answer landed while
the panel was hidden.

**D5 · A Notification Center notification with the first sentence** when a run finishes
while the panel is hidden; clicking it summons the panel.

**D6 · Hotkey double-tap reopens the last thread**; single tap the current one.

**D7 · "Why did you search that?"** — the query's `purpose` on hover of each query row
(the data is already there; the affordance is not).

**D8 · Per-block fade-in** as the answer arrives (count-keyed, so no per-token motion).

**D9 · A quiet "all claims supported" seal** — a single `checkmark.seal.fill` in the
trail summary when every verdict is *supported* and no notice exists; no confetti.

**D10 · `/about` prints the pipeline as an ASCII diagram** in the thread.

**D11 · `/coin` declines to research a coin flip** and flips one, badged "no evidence
was consulted, on purpose".

**D12 · The "Search summary — not the full page" caveat becomes a tiny magnifier chip**
on the source row, so it reads as a property of the evidence rather than a footnote.

---

## 9. What I am shipping, and in what order

Each in its own branch and PR against `main`, smallest and most certain first.

1. **`fix/ci-test-compile`** — B1, B2. *Open: PR #2, green on both platforms.*
2. **`fix/streaming-robustness`** *(PR #53, green)* — B5, B6, B7, B8, B9, B21: error frames fail the
   turn, cancellation is honoured after the loop and in `/direct`, `[DONE]` flushes,
   CR/BOM handled, partial answers validated, payloads sorted. Tests for each.
3. **`fix/provider-compat`** *(PR #54, green)* — B11 (+Q6), B19, B10: retry once without optional
   parameters on 400, JSON mode, `<think>` stripping, better 400 message, gateway
   heuristic.
4. **`fix/search-tool-resolution`** *(PR #55, green)* — B12/B48: resolve the search tool by shape, list
   advertised names in the error, README wording.
5. **`fix/citations-in-code`** *(PR #56, green)* — B13/Q4: code-aware `CitationValidator`, prompt line,
   tests.
6. **`fix/assessment-failure`** *(PR #57, green)* — B14, B16, B17, B18, B20: an assessment failure
   caveats instead of fails; lenient `sources`; verdict synonyms with a notice; retry
   mode; deterministic numbering.
7. **`fix/history-citation-markers`** *(PR #58, green)* — B15/Q5.
8. **`fix/linux-window-lifecycle`** *(PR #59, green; also B52)* — B33, B35, B37, B38, B39, B43: hide-on-close,
   Return does not cancel, scroll to the newest turn, "Stopped", Retry, hint text.
9. **`fix/macos-thread-links-settings`** *(PR #67; macOS-only, compiled by CI)* — B23,
   B70, B71: strip model-written links, keep a deleted thread deleted, open Settings
   above the panel. B22 withdrawn (§11.2); B27 and B28 remain open (§11.1).
10. **`feat/streaming-perf`** — *not opened*: other authors' #51/#24 (coalescing),
    #49/#31 (pinned auto-scroll) and #50 (composer measurement) cover P1, P3 and P4;
    P2 and P5 remain open (§11.5).
11. **`feat/live-composer-queue`** — *not opened*: #52 by another author covers it.
12. **`feat/prompt-quality`** *(PR #65, green)* — Q1, Q2, Q3, Q7.
13. **`feat/evidence-health`** — V4, V5, F12 (pills, bar, one-line summary). *Not
    opened*: macOS visual work needs a desktop to check; specified in ANALYSIS.md.
14. **`feat/visual-tokens`** — V1, V2, V3, V6, V7. *Not opened*, same reason.

Opened beyond the plan, from the second round (§11): **#60** `fix/thread-archive-safety`
(B47, B62–B66), **#61** `fix/transcript-and-source-urls` (B60–B63), **#62**
`fix/pango-emphasis-citations` (B54), **#63** `fix/deb-prerelease-version` (B53),
**#64** `fix/non-streaming-timeout` (B65), **#66** `feat/linux-preferences` (B55),
**#68** `fix/packaging-hygiene` (B3, B58).

Deferred to the backlog with a design (see ANALYSIS.md): F1, F2, F5, F6, F7, F8, F9,
F10, F11, U5, U7, V9, V10, D4, D5, B34, B36, B44.

---

## 10. Declined, with reasons

- **Rendering model-written links as links "because they are flagged".** The badge
  does not make a `file:` link safe to click. Declined; B23 strips them.
- **Raising the panel level to cover the Settings window or alerts.** AGENTS.md is right
  that level is not the lever.
- **Replacing the `NSTextView` composer with a SwiftUI `TextField`** to get `@FocusState`
  for the history filter. The documented focus failure is real; the history filter
  should reuse the composer instead (U5).
- **Fetching favicons.** PRIVACY.md promises nothing leaves the Mac except provider
  calls; a favicon fetch to every cited host breaks that. Monograms instead (V9).
- **Running assessment in parallel with the answer.** Explicitly forbidden by AGENTS.md
  for a good reason; the latency is hidden behind reading anyway.
- **Auto-fetching page text for every source.** Cost, latency and injection surface all
  scale with it; F2 is the on-demand version.

---

## 11. Round two: the completeness sweep, verification, and what changed

After the first pass I ran five completeness critics (core, macOS, Linux + CI, tests,
product ideas) that were handed the round-one list and asked only for what it missed,
then put every finding — round one and round two — through two independent verifiers
(a code tracer and a user-impact judge) and three idea judges. This section records
what that produced. Numbering continues from §2.

### 11.1 Findings the first pass missed

**B52 · medium · Linux `toggle()` hides a buried window.** It tested only
`gtk_widget_get_visible`; a visible window behind the editor is "up" to GTK and not to
the user, so the shortcut cost two presses. **Fixed in #59** (hide only when active).

**B53 · medium · A pre-release tag built a `.deb` that outranks the release.**
`1.1.0-beta.1` reads as upstream `1.1.0` with Debian revision `beta.1`, which sorts
*above* `1.1.0`; apt refused the stable package as a downgrade. Verified with
`dpkg --compare-versions`. **Fixed in #63** (`1.1.0~beta.1`).

**B54 · low · Bold or italic spanning a citation printed literal asterisks on Linux.**
`PangoMarkup.inline` parsed emphasis per text span between citations, so `**Cost [2]:**`
never matched. **Fixed in #62** (placeholder character, one emphasis pass).

**B55 · low · `textScale` and `showProcessTrail` were shared preferences the GTK front
end never read**, while PRIVACY.md said text scale lives in `settings.json` on Linux.
**Fixed in #66.**

**B56 · low · README promises Up/Down recall and searchable threads for both
platforms**; the Linux build has neither. *Open:* mark them macOS in the feature list
until Linux history (F10) lands.

**B57 · low · `CICD.md` says three workflows; the table lists four.** *Open* (one word).

**B58 · low · `release.yml` gave `contents: write` to the Debian build job.**
**Fixed in #68** (job-level `contents: read`).

**B59 · low · The Linux service can only be quit through an undocumented D-Bus action.**
Close and the WM button hide; `quit` is in neither `--help` nor the `.desktop` actions.
*Open:* `vervellum --quit`, a `[Desktop Action quit]`, and a line in README.

**B60 · medium · Structured source URLs lost a trailing `)`.** `SourceHarvester.normalized`
trims prose punctuation, and `EvidenceExtractor.hit(from:)` ran every `url` field
through it, so `…/wiki/Mercury_(planet)` was recorded, shown to the model and linked
without its parenthesis. **Fixed in #61** (`trimmingPunctuation:` flag).

**B61 · medium · The transcript listed only the prose's citations**, so a verdict's
`[3]` could point at nothing. **Fixed in #61.**

**B62 · low · A cancelled turn's partial answer was copied as complete.** **Fixed in #61**
("Stopped before the answer finished; what follows is incomplete.").

**B63 · medium · The transcript discarded the whole answer whenever `failure` was set**,
so `vervellum --ask` printed nothing of a paid-for answer after a late failure.
**Fixed in #61** (the answer stays; the failure trails it).

**B64 · low · After recovering from `.bak`, the next write rotated the corrupt primary
over the only good copy.** **Fixed in #60** (rotate only a primary that decoded or was
written by this process).

**B65 · high · The 120 s idle timeout killed every non-streaming plan or assessment
call that took longer than two minutes.** A non-streaming call is silent until the
model finishes, so "idle" was the whole generation; a local model on a large evidence
block hit it every time and the message blamed the connection. **Fixed in #64**
(per-request `timeoutInterval`: the 600 s deadline for `completeJSON`, the idle timeout
for streams; a distinct "did not answer in time" message).

**B66 · low · A turn saved mid-run came back as running forever** after a crash or
force-quit: a spinner nothing stops, no retry. One verifier corrected the round-one
claim that the dead turn was sent as history — `ResearchContext` filters on
`.complete`, so it is not. **Fixed in #60** (non-terminal turns load as failed with
"Vervellum quit before this answer finished", partial answer kept).

**B67 · low · Range citations (`[1-3]`, `[1–3]`) are neither rendered nor flagged.**
The regex accepts only `,`/`;` separators, so a range is left as text and the turn
reads as clean. *Open:* accept `\d+\s*[-–—]\s*\d+` and expand it (bounded), or flag it
as `invalidCitation`.

**B68 · low · Markdown tables are neither parsed nor forbidden.** A comparison answer
renders as raw pipes. *Covered by another author's #32*; the prompt-side fallback
("never use tables") is the cheap alternative.

**B69 · low · The test `testUnterminatedEmphasisStaysInTheParagraph` cannot fail for the
reason it states** (the block parser never touches emphasis); the real guard in
`MarkdownText` is untested. *Open* (test gap). Likewise **the history-off and
Delete-All tests never create a `.bak`**, so a backup left behind would pass. *Open.*

**B70 · medium · Deleting the open thread did not touch the engine's copy**, so the next
publish wrote it back to disk. **Fixed in #67.**

**B71 · medium · Settings opened underneath the floating panel**; centred, it was almost
entirely hidden. **Fixed in #67** (the panel is dismissed first without restoring
activation; Settings restores the remembered app on close).

**B72 · medium · Programmatic draft replacement bypasses `NSTextView`'s undo**, so the
"undo puts the draft back" promise is false and the stale undo stack targets ranges
that no longer exist. *Open:* replace through `shouldChangeText(in:replacementString:)`.

**B73 · low · Opening a thread from history while research runs cancels the run
silently.** *Open* (another author's #25 touches asking from history; check overlap).

**B74 · low · The composer's height ignores the trailing empty line**, so Shift-Return
at the end scrolls the first line away. *Open* (check #50 first).

**B75 · low · The shortcut recorder accepts ⌘W, ⌘Q, ⌘C as the global hotkey**, which a
Carbon hot key then steals from every app. *Open:* reject bare-⌘ editing chords.

**B76 · low · The Providers pane reloads stored values on every tab selection**,
discarding unsaved edits. *Open:* load once per presentation.

**B77 · low · With "Show what each search did" off, a running macOS turn shows nothing
for the whole plan-and-search phase.** *Open* on macOS; #66 keeps the stage line on
Linux regardless of the preference.

### 11.2 Disputes, corrections and withdrawals

- **B22 (hotkey hides an open-but-not-key panel) — withdrawn.** A verifier showed that
  PLAN §5.1, the §5.3 key table and the Shortcuts footnote all document "press again to
  dismiss". Re-focusing instead is a product decision, not a bug; recorded as such in
  ANALYSIS.md. The other half of the finding (a stale `appToRestoreOnClose` after the
  user clicks through a third app) stands and is open.
- **B35 (Return cancels a run on Linux) — kept, flagged.** One verifier called the
  Return-equals-Ask binding a documented Linux choice. I kept the change in #59 because
  the status line ("press Ask again to stop") and the button ("Stop") disagreed on the
  same frame, and because a habitual Return losing a forty-second answer is the failure
  PLAN §5.2 names. It is one `guard` to revert if the maintainer prefers the old model.
- **B45 / B66 — corrected.** The dead turn is not sent to the model as history.
- **B47 — narrowed.** Real, but the trigger is a newer build adding an enum case
  without a version bump; #60 reads the version stamp before decoding, and #57 decodes
  an unknown `TurnNotice` as `.unknown` instead of failing the document.
- **Keychain re-prompt after every ad-hoc-signed update** (round one, macOS) — lowered
  to a documentation gap: `KeychainStore` deliberately collapses a denied read to "no
  key", and SECURITY.md should say so next to the Accessibility note.
- **B12 severity** — one verifier argued the z.ai-only tool name was documented in the
  code and the fix is a one-line doc change; I kept the shape-based resolver (#55)
  because README, PLAN and the Settings footnote all promise a generic MCP server, and
  AGENTS.md says the docs state what is implemented.

### 11.3 Verification summary

Every finding — 90 from round one, 26 from the sweep — was handed to two independent
verifiers: a code tracer told to refute anything it could not re-derive from the source,
and a user-impact judge told to refute anything unreachable or cosmetic. A finding was
kept when at least one confirmed and none refuted, or both confirmed.

| | Count |
|---|---|
| Findings verified | 116 |
| Confirmed by both or unopposed | 105 |
| Refuted or unresolved | 11 |
| Severity raised by the verifiers | 3 |
| Severity lowered | 14 |

The eleven not confirmed, and what I did with each: B35 (Return cancels on Linux —
kept, see 11.2); Q3, Q1 and Q2 (prompt language, dates and the assessment's context —
refuted as "documented limitation" or "enhancement", which is what §7 called them; they
shipped in #65 as prompt work, not as bug fixes); Q6 (`response_format` — a feature;
shipped behind #54's retry so a gateway that rejects it costs one request); the `.bak`
permissions claim (refuted on the facts: `copyItem` preserves the mode on both
platforms — dropped); the Linux CI cache and the fabricated Debian changelog
(optimisation and documented behaviour — dropped); B7 (`[DONE]` without a blank line —
the code tracer confirmed the drop, the impact judge could not name a gateway that
emits it; the two-line fix shipped in #53 anyway because the assembler is now tested);
the read-only banner (real, low; carried in ANALYSIS.md A12); and B74 (composer trailing
line — the verifiers showed `usedRect(for:)` does include the extra line fragment, so
the premise was wrong — dropped).

The three ideas judges (daily user, engineer bound by AGENTS.md, designer) scored all 89
ideas from 1 to 10. The top of the table, with the mean: "Read the page" 9.3; let the
reader scroll up while streaming 8.7; Test connection 8.7; per-search progress with
live source arrival 8.3; appearance-adaptive accent and verdict colours 8.3; Verify this
claim 8.3; search-backend adapter 8.3 (shipped, #55); coalesced snapshots 8.3 (#51/#24
by other authors); composer-driven history filter 8.0; Reduce Motion 8.0; redact pasted
text 7.7; stable source rows 7.7; Markdown export 7.7; tag the disconfirming search 7.7;
`Equatable` turn views 7.7; research the clipboard 7.7. At the bottom, with agreement
from all three: `/about` and `/coin` 2.0, localisation readiness 2.7 (right, but not
now), the all-supported seal 3.0, tags 3.0, Notification Center banner 3.3, the
empty-state illustration 3.3, source monograms 3.7. The full table is in ANALYSIS.md
("Idea scores from the Fable judges").

### 11.6 First-round findings that §2 did not itemise

These came out of the same fourteen lenses as §2 and survived verification, but the
first draft folded them into prose or left them out. Recorded here so nothing is lost;
ANALYSIS.md carries each under a task.

**macOS panel and views.** **B78 · medium** — the ordered-list marker is clamped to a
16 pt frame, so `10.` (or `9.` above ~116 % text scale) does not fit (`MarkdownText.listRow`).
**B79 · medium** — `tertiaryText` multiplies the already-translucent secondary colour by
0.62, about 2:1 for the smallest text; use `.tertiaryLabelColor`. **B80 · low** — fixed
verdict RGB colours are used as sentence colour, not only for glyphs, and fail light-mode
contrast. **B81 · low** — the text-scale preference is ignored by the question, the claims
table and captions (V3). **B82 · low** — submitting while the history list is open runs
the research behind the list (`showsHistory` stays true). **B83 · low** — a turn cancelled
during planning renders as a bare question with no status and no retry. **B84 · low** — a
literal U+FFFC in the answer (common in PDF-derived snippets) shifts every citation chip
after it. **B85 · low** — `[n]` inside inline code becomes a citation chip on macOS because
masking runs before markdown parsing (#56 fixes the validator, not the renderer).
**B86 · low** — a multi-source marker `[2, 5]` links only to source 2 and the tooltip the
code builds is never rendered. **B87 · low** — the verdict label and its chips sit in a
non-wrapping `HStack`; at 360 pt a finding with many sources compresses the label.
**B88 · low** — the history search field never receives focus; typing goes into the
composer (U5). **B89 · medium** — with dismiss-on-focus-loss on, opening Settings hid the
panel and yanked activation to the remembered app, burying Settings — *fixed in #67*.
**B90 · medium** — both `NSAlert` paths (update available, Accessibility prompt) activate
Vervellum at an arbitrary moment and never hand activation back; the update alert's
default button is Download. **B91 · medium** — `HotkeyRecorder` accepts Shift-only and
Option-only chords, registering a global hotkey that steals every capital S system-wide.
**B92 · low** — activation is restored with `.activateAllWindows`, which raises every
window of the previous app. **B93 · low** — Settings opened from the panel had nothing to
hand activation back to — *fixed in #67*. **B94 · low** — width and position changes in
Settings do not reach an open panel. **B95 · low** — re-entering an open panel snaps a
header-dragged panel back to its computed position. **B96 · low** — nothing observes
display disconnect while the panel is open. **B97 · low** — `SelectedTextReader` blocks
the main thread on a hung frontmost app for the AX messaging timeout, up to four times,
before the panel appears; set `AXUIElementSetMessagingTimeout` and show first, seed later.
**B98 · low** — the keychain ACL is tied to the ad-hoc signature's cdhash, so every update
re-prompts for the stored keys and a denied prompt reads as "no key"; SECURITY.md should
say so. **B99 · low** — read-only mode (a newer document on disk) is never surfaced in
the UI.

**Packaging, CI and documentation.** **B100 · medium** — the Linux binary's version is
never stamped from the tag: `AppIdentity.version` falls back to `0.1.0` because the
executable has no bundle, so a released `.deb` reports `0.1.0` forever from `--version`
and the User-Agent; stamp it at build time. **B101 · medium** — SECURITY.md, PRIVACY.md,
README and PLAN state the Linux key ladder as keyring → environment → file; the code
tries the environment first. **B102 · low** — SECURITY.md says every outbound request
goes through the one transport; the update check and download use a plain `URLSession`.
**B103 · low** — `/help` on Linux advertises ⌘ shortcuts and Settings the GTK panel does
not have; split the platform rows. **B104 · low** — the release workflow installs
`desktop-file-utils` but never validates the entry; only `linux.yml` does, and it does
not run for tags. **B105 · low** — `0.1.0` is hard-coded in README's install line and
the build-deb examples outside the release-bump marker. **B106 · low** — ICON-CREDITS.md
lists 19 SF Symbols; the app renders 32. **B107 · low** — PRIVACY.md describes the update
User-Agent as the bundle identifier (it is name/version) and logging in macOS-only terms.
**B108 · low** — the Linux secrets docs describe a 0600 key file the app never writes and
whose format is undocumented; `backendDescription` hedges because nothing records which
tier answered a read.

### 11.4 Ideas the sweep added

Judged with the round-one ideas (§11.5). The ones worth carrying forward:

- **VoiceOver pass** — announce stage changes, mark section labels as headers, label the
  composer, and never hide the only Delete control behind hover. (A28 in ANALYSIS.md
  covers part of this.)
- **Keyboard-complete thread** — Tab out of the composer to the answer's actions;
  ⌥1–3 for follow-ups; ⌘E trail; ⌘R retry; ⌘⇧A all sources.
- **⌘F find in the thread**, with highlighted matches and ⌘G/⌘⇧G.
- **Network-aware failure states** — an offline gate before spending a call, and a
  429 `Retry-After` countdown instead of "try again".
- **App Intents** — "Research with Vervellum" and "Ask Vervellum" for Shortcuts and
  Spotlight (the same seed-the-composer path as the URL scheme, F9).
- **Print / Save as PDF / share sheet** for a turn.
- **Research the clipboard** — a permission-free sibling of Research the Selection
  through the same redaction path (A52).
- **Persist the draft and the open thread across relaunch.**
- **Diagnostics** — "Copy diagnostic report" in About and `vervellum --doctor` on Linux:
  versions, endpoints (never keys), backend, last failure class.
- **Claim ↔ prose linking** — hovering a finding highlights the sentences it grades.
- **Library backup and restore** from Settings, with the version guard.
- **A reading window** — open the thread in a normal resizable window for a long read.
- **Localisation readiness** — a String Catalog and locale-aware dates before the
  first translation.
- **Token usage meter** per turn (`stream_options.include_usage`, behind a provider
  capability).

Judged as drops, and I agree: `/about` ASCII art and `/coin` (D10, D11 — cute, off
thesis), the "all supported" seal (D9 — a badge for the absence of a finding invites
trust the evidence did not earn), source-age tint (D3 — colour carrying a date is
unreadable; the tooltip already has it), per-block fade-in (D8 — motion during
reading), and the Notification Center banner (D5 — answer text on a lock screen).

### 11.5 Overlap with other authors' pull requests

Other reviewers worked the same repository in parallel; per the brief I did not read
their branches. From the titles alone, #24/#51 (coalesced snapshots), #49/#31
(pinned auto-scroll), #50 (composer measurement), #52 (queued question), #32 (tables),
#27 (SSE framing), #26 (transcripts) and #28 (GTK close lifecycle) overlap P1, P3, P4,
B24, B68, B7/B8, B60–B63 and B33 respectively. Where I had already opened a PR on the
same defect (#53 vs #27, #61 vs #26, #59 vs #28) both exist; the maintainer should
merge one and close the other. ANALYSIS.md records each pairing.

---

## 12. Pull requests opened by this review

All against `main`, all green on both CI workflows unless noted, none merged.

| PR | Branch | What |
|---|---|---|
| #2 | `fix/ci-test-compile` | B1, B2 — the test target compiles; the desktop entry validates under its real name |
| #53 | `fix/streaming-robustness` | B5–B9, B21 — error frames fail the turn; cancellation honoured; `[DONE]` flushes; CR/BOM; partial answers validated |
| #54 | `fix/provider-compat` | B10, B11, B19, Q6 — retry once without optional parameters on 400; JSON mode; `<think>` stripping |
| #55 | `fix/search-tool-resolution` | B12, B48 — resolve the MCP search tool by shape |
| #56 | `fix/citations-in-code` | B13, Q4 — code-aware `CitationValidator` |
| #57 | `fix/assessment-failure` | B14, B16–B18, B20 — assessment failure caveats; lenient verdicts and sources; deterministic numbering |
| #58 | `fix/history-citation-markers` | B15, Q5 |
| #59 | `fix/linux-window-lifecycle` | B33, B35, B37–B39, B43, B52 |
| #60 | `fix/thread-archive-safety` | B47, B64, B66 + Stripe keys and a bearer false positive in `SecretRedactor` |
| #61 | `fix/transcript-and-source-urls` | B60–B63 |
| #62 | `fix/pango-emphasis-citations` | B54 |
| #63 | `fix/deb-prerelease-version` | B53 |
| #64 | `fix/non-streaming-timeout` | B65 |
| #65 | `feat/prompt-quality` | Q1, Q2, Q3, Q7 |
| #66 | `feat/linux-preferences` | B55 |
| #67 | `fix/macos-thread-links-settings` | B23, B70, B71 — macOS only; compiled by CI, not locally |
| #68 | `fix/packaging-hygiene` | B3, B58 |

Every Core and Linux change was built and its tests run on Swift 6.1 / Ubuntu 24.04
before pushing (198 → 204 tests, 0 failures). The GLM review workflow is configured
without its key and skips every PR, so no automated review arrived; steady state for
each PR was green CI on both platforms with no comments.
