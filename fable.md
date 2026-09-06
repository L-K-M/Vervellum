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
| 2 | A stream that ends with an `error` frame, or that is cancelled mid-`/direct`, is recorded as a *complete* answer and then assessed and reused as thread context | `ChatCompletionsClient.streamText`, `ResearchRunner.answerDirectly` | PR planned |
| 3 | Every OpenAI reasoning model (o-series, gpt-5 family) fails with an unexplained HTTP 400 because `temperature` is always sent | `ChatCompletionsClient` | PR planned |
| 4 | Only z.ai's search tool names are accepted, so the "bring your own MCP search server" promise is false for Brave, Tavily, Exa, SearXNG | `SearchMCPClient.connect` | PR planned |
| 5 | Citation validation runs over code, so `argv[0]` in a code block yields "The model referred to a source number that does not exist" and marks sources as cited | `CitationValidator`, `ResearchTurn.applyCitationValidation` | PR planned |
| 6 | A failed assessment call throws away a complete, visible answer: the turn is marked failed and silently dropped from all later context | `ResearchRunner.execute` stage 5 | PR planned |
| 7 | On Linux the window-manager close button destroys the GTK window while the held D-Bus service keeps the dangling pointer; the next shortcut press is a use-after-free | `LinuxPanel.init` | PR planned |
| 8 | Pressing the summon hotkey while the panel is open but no longer key *hides* it instead of refocusing it; the composer is disabled for the whole run; auto-scroll drags a reader who scrolled up back to the bottom on every token | `PanelController.toggle`, `PanelRootView` | PR planned |
| 9 | A markdown link written by the model (`[text](url)`) is rendered as a clickable link by `AttributedString(markdown:)`, which undercuts the number-only citation rule at the rendering layer | `MarkdownText.parseInline` | PR planned |
| 10 | Per-token cost: every streamed chunk republishes the whole thread, re-parses the whole answer, re-validates every block and re-measures the composer | `ResearchEngine`, `MarkdownBody`, `PanelRootView` | PR planned |

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
2. **`fix/streaming-robustness`** — B5, B6, B7, B8, B9, B21: error frames fail the
   turn, cancellation is honoured after the loop and in `/direct`, `[DONE]` flushes,
   CR/BOM handled, partial answers validated, payloads sorted. Tests for each.
3. **`fix/provider-compat`** — B11 (+Q6), B19, B10: retry once without optional
   parameters on 400, JSON mode, `<think>` stripping, better 400 message, gateway
   heuristic.
4. **`fix/search-tool-resolution`** — B12/B48: resolve the search tool by shape, list
   advertised names in the error, README wording.
5. **`fix/citations-in-code`** — B13/Q4: code-aware `CitationValidator`, prompt line,
   tests.
6. **`fix/assessment-failure`** — B14, B16, B17, B18, B20: an assessment failure
   caveats instead of fails; lenient `sources`; verdict synonyms with a notice; retry
   mode; deterministic numbering.
7. **`fix/history-citation-markers`** — B15/Q5.
8. **`fix/linux-window-lifecycle`** — B33, B35, B37, B38, B39, B43: hide-on-close,
   Return does not cancel, scroll to the newest turn, "Stopped", Retry, hint text.
9. **`fix/panel-focus-and-links`** — B22, B23, B27, B28: refocus instead of hide,
   strip model-written links, surface hotkey registration failure, honest hints.
10. **`feat/streaming-perf`** — P1–P5: chunk coalescing, parsed-block cache,
    memoised composer height, pinned auto-scroll with a "Latest" pill (B25).
11. **`feat/live-composer-queue`** — B24/F3.
12. **`feat/prompt-quality`** — Q1, Q2, Q3, Q7.
13. **`feat/evidence-health`** — V4, V5, F12 (pills, bar, one-line summary).
14. **`feat/visual-tokens`** — V1, V2, V3, V6, V7.

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
