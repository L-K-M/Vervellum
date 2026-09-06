# Vervellum — consolidated work queue

Combines the prior cumulative `main` analysis (`0ce3a2d`) with the
[Astra review](https://github.com/L-K-M/Vervellum/blob/4b35bba4554a7a975e8eb9f4755689b943120563/astra.md).
Checked against `main` at `0ce3a2d`: application code remains at the reviewed baseline;
later changes are release metadata, README, the screenshot, and analysis.

Implemented or in-flight work is separated below; do not reimplement it. Original
Astra findings remain in review PR #40. Earlier identifiers are mapped to consolidated
tasks so neither distinct requirements nor their provenance disappear.

**P1:** trust, data loss, blocking behavior. **P2:** usability/performance.
**P3:** expansion. **S/M/L:** local change / several components / design work.
`Core/` means `Sources/VervellumKit/Core/`; `Linux/` means
`Sources/VervellumKit/Linux/`. Visual hypotheses require desktop verification.

## Implemented, awaiting review and merge

### Astra patches

All branches now live in `L-K-M/Vervellum`. Merge #21 first, then review the five
independent fixes. Remove pending rows only when upstream contains the work.

| ID | Patch | Remaining work |
|---|---|---|
| A41, A42 | [#21 — Test/CI baseline](https://github.com/L-K-M/Vervellum/pull/21) | Merge first: explicit `UInt` conversion and correct desktop-validation basename. |
| A02 | [#30 — Exact assessment citations](https://github.com/L-K-M/Vervellum/pull/30) | Review and merge; preserve Boolean/fraction/overflow rejection. |
| A03 | [#26 — Self-contained transcripts](https://github.com/L-K-M/Vervellum/pull/26) | Review Copy/CLI output and merge. |
| A21 | [#27 — Linear SSE line framing](https://github.com/L-K-M/Vervellum/pull/27) | Review byte-framing changes and merge. |
| A08 | [#29 — Private result diagnostics](https://github.com/L-K-M/Vervellum/pull/29) | Review retained diagnostic schema and merge. |
| A16 | [#28 — GTK native-close lifecycle](https://github.com/L-K-M/Vervellum/pull/28) | Merge; verify GNOME Wayland close/reopen manually. |

Fork-backed #4/#5/#6/#7/#8/#11 were replaced respectively by
#21/#30/#26/#27/#29/#28. The CI-only correction in #37 was consolidated into #21:
without both baseline fixes, CI still fails. Documentation PR #40 replaces #1 and
preserves `astra.md`; this queue is published directly to `main`. No code PR was merged.

Every fix followed an observed failure. The five original fixes combine without
conflicts and pass **226 tests** locally on Swift 6.0.3/GTK 4.8.3, including Xvfb
close/reopen. The SSE debug stress fixture took 0.886s before and 0.036s after; this
is not a UI benchmark. All six current code PRs pass macOS build/tests and Ubuntu
build/tests/package/install CI; #28 also passes its Xvfb lifecycle check.

GLM was attempted twice per migrated code PR. `ZAI_API_KEY` is unavailable, so both
attempts skipped the actual review despite a green workflow result. No review or
inline feedback arrived. This is reviewer unavailability, not approval. Real-desktop
layout, GNOME Wayland, full-screen placement, Accessibility selection, and IME still
need manual QA.

### In-flight work retained from the earlier analysis

These entries are preserved from `main`; their PRs were not opened, inspected, or
modified during the Astra review. Their listed scope is prior analysis, not new
verification. Do not duplicate their implementation.

| PR | Branch | Recorded scope |
|---|---|---|
| #46 | `astra2/swift62-test-compile` | Repair Swift test inference; overlaps the test half of #21/#38. |
| #38 | `k3/fix-archive-test-inference` | Repair test inference and desktop-validation basename failures that made main CI red on both platforms. |
| #22 | `k3/atx-heading-closing-sequence` | Preserve literal trailing `#` in headings unless a valid space-prefixed closing sequence exists. Core/tests. |
| #23 | `k3/reject-fractional-citations` | Reject fractional source numbers instead of rounding them onto real sources. Core/tests. |
| #24 | `k3/streaming-render-throttle` | Coalesce macOS prose-only updates to 10 Hz in `ResearchEngine`; alternative to #51. |
| #51 | `astra2/coalesced-snapshots` | Shared, tested Core `SnapshotCoalescer`; streamed `onThreadChanged` callbacks also checkpoint partial answers. |
| #25 | `k3/ask-from-history` | Show the active research when asking while History is open. |
| #31 | `k3/scroll-follow` | `BottomSentinel` and “Latest” control; follow only while pinned; alternative to #49. |
| #49 | `astra2/pinned-autoscroll` | Preference-probe geometry and hysteresis above coalesced-batch growth; no geometry/scroll ordering assumption. |
| #32 | `k3/markdown-tables` | Delimiter-gated pipe tables, escaped pipes, normalized ragged rows; macOS Grid and aligned Pango monospace rendering; eight recorded tests. |
| #33 | `k3/turn-polish` | Ask Again on complete turns; live elapsed process-trail clock. |
| #34 | `k3/empty-state-examples` | Clickable examples seed the composer. |
| #35 | `k3/history-search-index` | `ThreadSearchIndex` builds one normalized haystack per thread on library change; alternative to #47. Core/tests. |
| #47 | `astra2/history-search-perf` | Case-insensitive `range(of:options:)` avoids per-keystroke lowercase allocations without maintaining an index; behavior tests. |
| #36 | `k3/completion-signal` | Menu-bar hourglass during runs; completion sound when the panel is closed. |
| #48 | `astra2/search-progress` | Both trails show completed-search counts through `ResearchTurn.searchesCompleted`; tolerant custom decoding preserves older archives. |
| #50 | `astra2/composer-fixes` | Measure composer height from actual row width; clear redaction banner on hide. |
| #52 | `astra2/queued-question` | Editable composer during runs; one-slot newest-wins queue with chip/cancel, across both front ends and engine. |

Choose one implementation where patches overlap; close superseded alternatives
rather than stacking them blindly. Baseline repairs overlap across #46/#21/#38;
citation fixes across #23/#30; publication throttling across #24/#51; autoscroll
across #31/#49; history search across #35/#47. #22/#32 cover parts of A29; #48, #50,
#51, and #52 cover parts of A09, A26, A15/A20, and A23 respectively. Preserve remaining
acceptance criteria below instead of implementing another copy.

Earlier validation reported 197, later 198+, tests on Swift 6.2.3 and no local Mac
build. Its fork branches were reported blocked by the same-repository GLM guard and
first-contributor CI approval, especially view changes now numbered #49/#50/#52;
those statuses were not rechecked here. A41 was also reproduced on Swift 6.0.3 and Ubuntu Swift 6.1.
Desktop filename rejection was reproduced with desktop-file-utils 0.26 as well as the
earlier queue's noted 0.27+. Counts describe snapshots, not comparable coverage totals.
The CI-image pinning gap is retained as A49.

### Earlier identifier map

B5/D1 → A48; B6/F13 → A31; B7 → A20/A28/A36; G6-adjacent → A04;
P2/P3 → A20; P4 → A22; G1 → A43; G2 → A33; G3/F9 → A44;
G4 → A24/A30/A31; G5 → A12; G7 → A45; G8 → A36;
F5 → A23; F6 → A46; F8 → A28; F10 → A36; F11 → A18;
F12 → A50; F14 → A51; F15 → A52; D3/V2 → A32; D4 → A47;
D5 → A25/A32; D6 → A53; V3 → A25; V4 → A09.
The portability footgun is A41/#21; CI-image pinning is A49.

## Next: trust and data preservation

### A01 · P1/M — Only numbered citations create actionable links

**Where:** `Vervellum/Views/MarkdownText.swift`, `Core/Research/CitationValidator.swift`.

Model Markdown currently creates `AttributedString` link attributes without being
stripped. Post-stream warnings do not prevent activation. Remove model-origin links
before inserting application-owned citation links. Treat literal U+FFFC separately
so it cannot shift placeholder substitution. Keep links inert even while streaming;
do not replace numeric citations with URL allow-list matching.

**Accept:** tests cover Markdown/autolinks, custom schemes, emphasis, literal U+FFFC,
partial streams, and grouped citations. Only app-resolved citation numbers produce
links. Correct the corresponding security claims. See A25 for grouped-source UX.

### A04 · P1/M — Detect incomplete or erroneous answer streams

**Where:** `HTTPTransport.streamJSONEvents`, `ChatCompletionsClient.streamText`.

Malformed JSON frames and error envelopes can be ignored; clean EOF without a finish
reason can pass as success. The non-streaming fallback's `try? messageContent`
discards useful failure classification. Introduce a completion-state parser with an
explicit compatibility policy; preserve partial prose but never assess a failed
answer as though complete. Keep provider errors sanitized.

Earlier G6-adjacent proposed accepting truncated `/direct` output. Partial prose is
already retained by the runner; #26 also preserves it in exports. The remaining
choice is incomplete-result labeling/retry, not treating `finish_reason: length` as
success. Whitespace-only replies must still fail.

**Accept:** fixture tests for EOF mid-answer, malformed data, error envelopes,
`length`, filters, fallback JSON, `[DONE]`, and usage-only frames. Document which
explicit completion signals are accepted. Keep this separate from A21's line parser.

### A05 · P1/S — Validate retained prose on every terminal path

**Where:** `Core/Research/ResearchRunner.swift`.

Validation runs only after successful streaming. Validate a stopped/failed answer
once in terminal cleanup and attach notices for invalid references or literal URLs.
Do not flag half-arrived markers during normal streaming.

**Accept:** stop/failure after an invalid marker or URL preserves the prose and its
warning. Successful/direct turns still validate once. Complements A01 and A04.

### A06 · P1/M — Enforce budgets for every stage

**Where:** `Core/Research/ResearchContext.swift`, `ResearchRunner.swift`.

Dropping history cannot fix an oversized question/schema/evidence block; the current
assembler returns it anyway. Assessment bypasses assembly. Size estimates omit array
commas. Bytes are described as characters/tokens; 110 KB is no universal 32k-token
guarantee. Historic answer shortening is silent despite whole-turn-trimming claims.

Give each stage a measured budget and output reserve. Reject oversized current input
visibly, disclose historical shortening, count serialized punctuation, and distinguish
heuristics from provider token limits. Replace repeated array `removeFirst` with
prefix indices.

**Accept:** giant question/schema/answer, Unicode, exact boundaries, zero-history,
and long-history tests. No silently over-budget or silently cropped current input.

### A07 · P1/M — Redact before selection truncation

**Where:** `Vervellum/Selection/SelectedTextReader.swift`, `App/AppDelegate.swift`,
`Core/Platform/SecretRedactor.swift`.

The 8,000-character selection cap can remove a PEM closing delimiter before the
redactor sees it, defeating its complete-block pattern. Partial selections already
need conservative treatment. Return capture metadata, redact bounded captured text
before display truncation, and redact unterminated private-key blocks conservatively.

**Accept:** long complete PEMs, cut-off delimiters, ordinary prose, and visible
truncation/redaction notices. Captured text stays opt-in and is never auto-sent/logged.

### A12 · P1/M — Check archive versions before decoding turns

**Where:** `Core/Store/ThreadArchive.swift`, `ThreadLibrary.swift`.

Full decoding precedes the version check. An unknown future enum can fail decoding,
trigger fallback, and let an older build overwrite the newer file. Decode a minimal
version envelope first; expose missing/corrupt/newer/recovered states to the UI.

**Accept:** unknown verdict/notice/stage and missing fields in a newer document never
allow writes, even with a valid older backup or history disabled. Explain read-only
status rather than pretending saves work. Surface `ThreadStore.isReadOnly` in a
History banner; a stderr warning is not sufficient (earlier G5).

### A13 · P1/M — Make erasure truthful and durable

**Where:** `ThreadArchive`, macOS engine/store/settings, `LinuxEnvironment`/panel.

History-off and Delete All discard deletion errors. Active research can be saved
again after erasure. Linux startup with history already disabled leaves old files.
Define stored-history deletion versus active-session retention; coordinate their
state and report sanitized deletion errors with retry.

**Accept:** denied deletion, queued writes, completion after Delete All, and relaunch
with history disabled. Primary and backup disappear or a visible error says they did
not. A deleted thread must not silently resurrect.

### A14 · P1/M — Private, recoverable archive writes

**Where:** `Core/Store/ThreadArchive.swift`.

Atomic writes use default temporary permissions before chmod. Backup/permission
failures are swallowed. After backup recovery, rotation can replace the good backup
with a corrupt primary. `isHistoryEnabled` is also read on the write queue while the
UI can mutate it.

Use restrictive temporary-file creation, atomic replacement, validated backup
rotation, and serialized archive state. Keep bytes private before writing content.

**Accept:** permission inspection before content writes, recovery followed by write
failure, backup preservation, concurrent erase/flush, and read-only archive tests.

### A15 · P1/M — Checkpoint active turns and recover interruptions

**Where:** `Vervellum/Research/ResearchEngine.swift`, `Store/ThreadStore.swift`,
`Linux/LinuxPanel.swift`, `Core/Store/ThreadArchive.swift`.

macOS persists the initial and final turn, not streamed snapshots; Linux saves only
at finish. Quit/crash can lose the current answer. Loaded nonterminal turns stay
apparently active, and queued cancelled callbacks can overwrite newer state.

#51 already records streamed snapshot checkpointing; verify it before adding another
macOS write path. Cover remaining platform and dismissal/termination gaps at a bounded
cadence. Cancel/snapshot before shutdown; recover nonterminal turns as interrupted
with partial text and retry.
Guard callbacks by run/session identity. Coordinate with A13, not per-token writes.

**Accept:** relaunch from every stage, quit during streaming, immediate cancel/new
run, and old callbacks after history replacement. Verify final snapshots are durable.

### A17 · P1/M — Bound Linux credential subprocesses

**Where:** `LinuxSecretStore`, `ShortcutInstaller`, runner environment acquisition.

Subprocesses have no deadlines and credential reads block GTK during construction
and Ask. Keyring deletion errors are discarded. Backend descriptions follow writes,
not actual reads; environment keys win despite contrary documentation.

Introduce asynchronous bounded acquisition behind the secret service. Terminate
stalled children; return backend and outcome states, explain environment overrides,
and report failed deletion. Keep secrets off argv and out of errors/logs.

**Accept:** hung/missing/failing secret-tool, locked keyring, environment override,
and deletion tests; GTK remains responsive. Correct Linux key-precedence documentation.

### A38 · P1/L — Authenticate distribution and bound updater downloads

**Where:** release workflows, `Core/Updates/`, `Vervellum/Updates/`.

Ad-hoc signing resets selection grants; updates authenticate neither bytes nor Team
ID. Updater networking follows redirects and checks size only after download. GitHub
assets legitimately redirect without provider credentials: use a separate bounded,
credential-free policy, not the research transport's authorization path.

**Accept:** Developer ID/notarization and signature/Team-ID verification; byte/time
caps enforced during download; failure never offers an unverified artifact as
verified. Keep unsigned limitations explicit until implemented. A future apt channel
needs signed repository metadata. Signing requires maintainer-owned credentials.

## Next: reading stability, input, and accessibility

### A19 · P2/M — Validate the pending reader-controlled scrolling

**Where:** `Vervellum/Views/PanelRootView.swift`.

The earlier queue records alternatives #31/#49; do not build another follow-mode
patch. The target is to detach on deliberate scrolling, expose “Latest ↓”,
and resume explicitly or for a new submission, not merely because layout changed.
After that patch lands, verify selection, bottom proximity, and newly arriving
verdicts; implement only uncovered behavior.

**Accept:** scroll-up, selection, momentum, history switching, resizing, and arriving
findings preserve reading position. New content remains discoverable. No scroll
animation is retargeted per token.

### A20 · P2/M — Coalesce updates; keep rendered identity

**Where:** runner callbacks, macOS engine/Markdown/composer, Linux panel/GTK.

Every delta copies/reports the growing turn and enqueues UI work. macOS reparses text,
citations, and composer layout; GTK queues everything and rebuilds all turn widgets
up to 10 Hz, destroying selection/focus/link state.

The earlier queue records alternatives #24/#51 for publication throttling. Do not
duplicate them; measure remaining queue depth before adding pre-enqueue coalescing. Retain every token
and the exact terminal frame; stage changes remain immediate. Reuse completed GTK
turn widgets and update only the active answer.

Profile `TurnView.validation` before adding per-answer memoization (earlier P2).
Composer text-stack allocation is bounded today: cache/reuse measurement only if
large-paste profiling justifies it (P3), rather than adding speculative machinery.
Also profile repeated `Source.domain`/`URLComponents` parsing (B7); cache immutable
domains only with correct URL-change invalidation.

**Accept:** benchmark 50-turn threads, `LazyVStack`/`fixedSize` layout, long pastes,
and bursty streams for bounded queues, responsive Stop, stable selection, and exact
final text. Keep GLib/main-queue dispatch in platform layers, never MainActor in
Core. Pair with A19.

### A23 · P2/M — Preserve drafts and make commands keyboard-first

**Where:** `PanelRootView`, `ComposerView`, command completions.

Editing is disabled during runs. Clicking a suggestion replaces a nonempty draft;
programmatic `NSTextView.string` replacement is not a reliable undo promise. Recall
stays active after edits, so arrows can discard them. Slash suggestions lack keyboard
selection.

#52 already records editable drafting and a one-slot question queue; do not duplicate
it. Verify replacement/cancel feedback and that queued work waits for terminal
assessment, not merely the last answer token. Preserve or explicitly replace drafts
on suggestions, end recall after edits, and support
arrows/Tab/Escape in command completion without breaking IME. Offer an explicit
shell-style recall scope across saved threads: newest first, deduplicated, restoring
the current draft on exit (earlier F5). Recall seeds the composer; it never sends.

**Accept:** multiline drafts, edited recalled text, suggestions during runs, undo,
keypad/modified Return, and CJK composition. No unintended send or data loss.

### A24 · P2/M — Linux keyboard and help must match capabilities

**Where:** `LinuxPanel`, `GTK.observeKeys`, shared command help.

Help advertises macOS-only actions; history/settings/copy print apologies, follow-ups
are inert, and Return during a run invokes Stop. Verify whether the bubble-phase
controller sees Return before GtkTextView consumes it on supported GTK releases.

Generate platform-capability help; add Ctrl-Return, a dedicated Stop shortcut,
clickable follow-ups, and GTK clipboard support through the platform abstraction.
Earlier G4's remaining parity items—settings, history, retry—belong in A30/A31,
not another persistence backend.

**Accept:** actual GTK key-event tests with IME, Shift-Return, keypad Enter, drafts,
and a live run. Do not consume unrelated editing keys. Coordinate setup/history with A30.

### A25 · P2/M — Stable, inspectable evidence cards

**Where:** `SourcesView`, `MarkdownText`, Linux Pango/panel rendering.

Hover expands summaries and moves rows; keyboard users cannot reach the summary-only
caveat. Linux shows neither summary nor caveat. Grouped answer citations open only
the first source; the macOS tooltip string is built but unused.

Use explicit disclosure or a fixed-size source inspector. Expose every grouped
source, domain/date, exact retrieved snippet, and “Search summary — not the full
page.” A citation title/snippet popover may anchor to a source row when inline-link
anchoring is impractical (earlier D5/V3); it still needs keyboard activation. A fixed,
always-visible snippet line plus explicit disclosure is another option.
Opening several tabs should never be an implicit group action.

**Accept:** keyboard/screen-reader inspection; hover never changes transcript height;
group citations expose all sources. Preserve numeric ownership from A01.

### A26 · P2/M — Scale all evidence and wrap crowded rows

**Where:** `PanelTheme`, `FindingsView`, `SourcesView`, composer geometry.

Text scale affects the answer but not most evidence, questions, controls, or composer.
The verdict/citation HStack cannot wrap. Composer height uses the preferred width,
not the actual clamped window width.

#50 already records actual-width composer measurement; verify clamped layouts after
it lands. Apply a consistent reading scale to meaningful text, wrap citation chips
and long metadata, and measure remaining geometry. Essential information must not depend on tiny
secondary labels.

**Accept:** minimum width, 140% text, long model/domain/date labels, RTL/CJK, many source
chips, and short displays without clipped controls or overflowing content.

### A27 · P2/M — Adaptive contrast and accessible motion

**Where:** macOS theme/background/panel/caret; Linux Pango colors/styles.

Fixed accents/verdict colors, compounded tertiary opacity, a black-only scrim, and
small hard-coded Linux text need contrast measurements. Reduced Transparency still
selects blur, with no explicit opaque fallback. Motion preferences are ignored.

Add semantic light/dark/high-contrast palettes and an opaque fallback. Observe
accessibility changes live; reduce panel, disclosure, and caret motion when requested.

**Accept:** measured contrast over bright/dark content and Adwaita themes; live Reduce
Transparency/Reduce Motion changes; meaning remains readable without color. GUI QA
is required before claiming an aesthetic improvement.

### A28 · P2/M — Accessible history actions and progress

**Where:** `HistoryView`, headers, finding accessibility, status presentation.

History nests a hover-only Delete button inside Open. Icon actions rely on help;
combined finding labels may hide reasoning/actions. Progress has no stable live
announcement.

Separate row actions, label contextual menus, add deletion undo/confirmation, focus
history search on opening, and restore composer focus on exit. Add ↑/↓ result
navigation, Return to open, and Delete with undo (earlier F8), without intercepting
composer editing keys. Announce stage changes, not streamed tokens.

**Accept:** VoiceOver/Orca reading order, focus, source actions, errors, no-results
states, and keyboard deletion without hover. Keep controls reachable at larger scale.

### A29 · P2/M — Render common research Markdown correctly

**Where:** shared `MarkdownParser`, both renderers.

Fence closers ignore marker type/length; ATX headings lose literal trailing `#`
(`## C#`). Tables are unsupported. Linux loses nested inline emphasis and wraps code
inside the same label.

Heading closers and tables are already recorded in #22/#32; do not duplicate those
patches. Fix matching fences with tests, then verify pending renderer parity. Add
only missing horizontal overflow handling, code-copy actions, and nested Linux
inline formatting. Keep citations literal in code and render partial constructs
during streaming.

**Accept:** mismatched/long fences, C# headings, comparison tables, nested emphasis,
long code, and every incomplete-stream prefix. No dependency or HTML renderer added.

## Reliability and provider compatibility

### A09 · P2/M — Show what each search actually did

**Where:** runner, research models, progress views, answer context.

Plans are passed as `searches_run` even when requests fail. Mixed failure is hidden;
progress counts planned rather than successful searches. #48 already records live
completion counts; do not implement another counter. Add persisted per-query
pending/running/succeeded/failed state, safe errors, elapsed time, and contribution.
Show labeled success/failure glyphs beside planned queries in the trail (earlier V4).

**Accept:** “2/4 succeeded” and incomplete-evidence notice for partial failure; only
successful searches are described as run to the model. Test cancellation/migration.
Keep execution sequential until MCP concurrency support is established.

### A10 · P2/M — Explicit provider and MCP capabilities

**Where:** `SearchMCPClient`, planner schema validation, provider settings/client.

Only two z.ai tool names and one listing page are supported. Argument keys are
validated, not types/enums. Required temperatures exclude some reasoning endpoints.
Document current support; add explicit tool selection, bounded pagination, supported
schema validation, and provider capability presets. Do not infer safety from names.

**Accept:** real-shaped fixtures for tool pages/schema/types/enums and temperature
capabilities, without live keys. Broaden product claims only after support exists.

### A11 · P2/M — Preserve source URLs and result boundaries

**Where:** `SourceHarvester`, `EvidenceExtractor.hits(inParagraph:)`.

Structured URLs undergo prose punctuation stripping and can contain userinfo.
Exact-string dedup keeps tracking/fragment variants. Neighboring link-line snippets
can overlap and assign one result's context to another.

Separate structured validation from prose cleanup; reject credentials, preserve
legitimate URL punctuation, define conservative dedup keys, and partition prose into
non-overlapping result items.

**Accept:** results without blank lines, query punctuation/parentheses, userinfo,
near-duplicates, and distinct pages. Keep extraction permissive without fabricating
which text belongs to which source.

### A18 · P2/M — Truthful configuration and shortcut outcomes

**Where:** `JSONFileSettingsStore`, `ShortcutInstaller`, macOS hotkey/provider UI.

Linux external JSON edits never reload and stale shortcut bookkeeping can overwrite
them. Shortcut writes/Carbon registration failures are ignored. Keychain Clear says
success despite discarded deletion errors.

Add explicit reload/validation before a full settings editor, preserve external
settings during bookkeeping, check every write/registration result, and surface
conflicts/recoverable failures. Expose a user-chosen Linux summon accelerator through
setup/CLI instead of only the default installer path (earlier F11). Preserve manual
changes unless the user explicitly replaces them. Do not add another settings file.

**Accept:** external edits while running, read-only files, failed dconf writes,
shortcut conflicts, and failed Keychain deletion never report false success.
Custom accelerators still use the desktop GApplication action, not an in-process grab.

### A22 · P2/M — End-to-end deadlines and cancellation tests

**Where:** `Core/Research/HTTPTransport.swift`.

Ten-minute checks happen only on arriving chunks and start after the response head;
they are not an end-to-end deadline. Early-return cancellation relies on continuation
lifetime. Use an independent monotonic per-exchange deadline to cancel the URL task.
Give small `completeJSON` plan/assessment calls a separate, tighter budget than the
stream (earlier P4 suggested 120–180 seconds, subject to provider measurements).
A wedged JSON call should not inherit the full ten-minute streaming allowance.

**Accept:** no headers, idle body, trickle/keepalive, cancellation before registration,
early matching MCP response, refused redirects, and producer caps. Inject clocks/
transport at the service boundary or use loopback fixtures; never live providers.

### A39 · P2/S — Fail packaging when dependency discovery fails

**Where:** `packaging/build-deb.sh`.

Suppressed `dpkg-shlibdeps` failures trigger a minimal GTK fallback, potentially
publishing missing dynamic dependencies. Fail packaging with safe diagnostics instead.

**Accept:** deliberately unavailable/failed dependency discovery produces no release
package; supported Ubuntu builds still generate and verify all dependencies.

### A40 · P2/M — Behavior coverage and falsifiable documentation

**Where:** tests, CI, README/PLAN/SECURITY/PRIVACY/CICD.

Add runner fixtures, cancellation/deadline tests, rendering-safety coverage, a GTK/
Xcode smoke matrix, long-thread profiling, and accessibility checks. #28 begins GTK
lifecycle coverage; it does not replace Wayland or real-desktop testing.

Correct these concrete overclaims: “every claim” versus eight findings; structurally
impossible model URLs versus actual rendering; summary labels “on every source”;
generic MCP support; Linux key precedence; universal redirect refusal; three workflows
beside four rows. See A01/A10/A17/A25/A38 for implementation dependencies.

**Accept:** docs describe tested guarantees and remaining limits. New tests isolate
settings/secrets/history and exercise behavior, not just optimistic code comments.

## Product extensions after the foundations

### A30 · P2/L — Native Linux setup and history

Build a settings/setup window over existing stores: presets, masked keys, explicit
Save, backend warnings, validation, and an optional connection check that discloses
what leaves the machine. Add searchable history, reopen/delete, and thread export.

**Accept:** clean install without secret-tool, unavailable keyring, no search key,
`/direct` discovery, and settings reload. No new persistence format. Build on A17/A18.

### A31 · P2/M — Retry only the failed assessment

Retain answer/evidence and offer “Retry claim check” separately from “Research again.”
Snapshot settings/model provenance and label stale evidence. Track retry lineage so
an old failed row does not keep offering duplicate retries forever (earlier B6).
Distinguish consumed retry from an intentional new research request. Add GTK retry
controls through the runner, not new networking in the view. Add local ⌘R for the
eligible failed turn (earlier F13), coordinated with #33's Ask Again action.

**Accept:** assessment retry makes no search/answer calls, never overwrites a newer
answer, and preserves failure context. Old-row retry state stays correct after
append/reload. Requires clear stage state from A04/A05/A15.

### A32 · P3/M — Evidence lens

Click a claim to highlight its assessed sentence and sources. Offer uncertain-only
filtering, a compact verdict distribution, and “What would change this answer?”
follow-ups. Use structured sentence anchors, not fuzzy string matching. Reuse verdict
distributions in History rows and the collapsed trail (earlier D3/V2): dots or a
compact stacked bar must include accessible counts/labels and incomplete status.
Add the reverse direction (D5): selecting a source reveals the sentences citing it,
using a pure reverse index over existing numeric citations, not another model call.

**Accept:** contradictions stay visible; associations are auditable; no invented
numerical confidence. Start from A25's accessible source inspector.

### A33 · P3/M — Preview plans and choose research depth

Offer Quick/Standard/Deep with explicit search caps and stage-model choices. Allow
query inspection/editing for an opted-in deep run. Show measured timings and
provider-reported usage; do not invent prices. Evaluate
`stream_options: {include_usage: true}` behind explicit provider capabilities (earlier
G2). Verify z.ai support; do not assume every compatible gateway ignores unknown
parameters. Usage-only frames must not alter answer completion.

**Accept:** default asking remains one step, caps are enforced, and extra calls require
explicit depth selection. Test unsupported/absent usage and malformed usage frames;
never estimate missing counts as measured. Use actual outcome tracking from A09.

### A34 · P3/M — Local presets and per-stage models

Test Ollama/llama.cpp endpoints, supported model discovery, context/output limits,
and temperature capabilities. Allow separate planner and assessor models.

**Accept:** local-only/direct versus remote research is unmistakable. Local inference
must not imply remote web-search privacy. Reuse A10/A30 capability/settings work.

### A35 · P3/L — Bounded full-page evidence

Fetch a few decisive pages only after designing isolated credential-free transport,
SSRF/redirect controls, byte/time/MIME limits, extraction, provenance, and untrusted
content boundaries. Distinguish retrieved quotes from search summaries.

**Accept:** hostile/private-network URLs cannot trigger unsafe fetches; no arbitrary
model-directed browsing or HTML execution. Security tests precede quality tuning.

### A36 · P3/S–M — Small delights without another model call

Independent candidates, each with a narrow acceptance target:

- **Copy feedback:** “Copied,” plus answer-only/evidence-inclusive choices. Explain
  empty answer-only copies (B7); #26 already preserves useful failed-turn exports.
- **Pocket finding:** pin one compact claim/source card while working elsewhere.
- **Evidence receipt:** export question, model, date, verdicts, limits, and sources.
- **Reading bookmark:** return to the last inspected source within the session.
  The earlier queue deferred persisted scroll offsets because reopened threads often
  target the newest answer; revisit archival position memory only with user evidence.
- **Challenge this:** visibly seed a disconfirming follow-up; never auto-send it.
- **Quiet completion:** #36 already records macOS status/sound. Verify opt-in,
  panel-closed behavior, and accessibility; do not implement a second Mac signal.
  Add an optional Linux desktop completion notification when its window is hidden
  (G8), without leaking answer text on the lock screen or stealing focus.
- **Planning cue:** an optional indeterminate shimmer while the plan is pending
  (earlier F10), with a static Reduce Motion alternative; never a fabricated ETA.

Use existing turn data, accessible restrained motion, and honest verdict styling.
Coordinate draft preservation (A23), reader intent (A19), and export completeness
(#26/A46). Pending #33/#34 already cover elapsed time, Ask Again, and example seeds.

### A37 · P3/L — Compare research across time

Start with manual “Research again and compare.” Preserve old evidence and distinguish
source additions/removals, changed verdicts, source churn, and changed conclusions.
Only then consider scheduled watches with explicit budgets, retention, provider
disclosure, and notification controls.

**Accept:** old threads are never silently re-sent; comparison remains auditable;
a refreshed source list is not falsely described as a changed answer.

## Additional tasks retained from the earlier analysis

### A43 · P2/M — Bounded transient retries (G1)

**Where:** `Core/Research/ResearchRunner.swift`, `ChatCompletionsClient.swift`.

Offer at most one bounded backoff retry for transient planning/assessment failures,
including rate limits and dropped connections. Keep answer streaming fail-fast:
blind replay duplicates prose and charges. Respect cancellation and stage deadlines;
classify only sanitized status/transport outcomes, never provider error text.

**Accept:** injected-clock tests for retryable versus permanent failures, attempt
limits, cancellation during backoff, and no automatic streamed-answer replay. Keep
retry progress and any additional provider calls visible.

### A44 · P2/M — Machine-readable CLI output (G3/F9)

**Where:** `LinuxApp.runHeadless`, a portable transcript encoder in Core.

Add `vervellum --json` with a versioned output contract for question, answer, findings,
sources, notices, completion/failure state, and partial output. Keep progress on
stderr and JSON alone on stdout; `StandardErrorLog` already anticipates this split.

**Accept:** success, direct, partial failure, cancellation, Unicode, and empty-result
fixtures parse as one document with meaningful exit status. Never serialize keys or
foreign errors. Reuse #26's evidence/completion rules.

### A45 · P2/S — Escape the revoked-selection-grant loop (G7)

**Where:** macOS selection alert and `AppDelegate`/`PanelController` orchestration.

Offer “Open without selection” after grant loss, with an explicit remembered fallback
until the user chooses selection again. Do not re-prompt on every summon or silently
request Accessibility. Explain that ad-hoc updates reset the grant; A38 is the signing
fix, not an excuse to trap the user in alerts.

**Accept:** revoked/denied/restored grants, subsequent summons, and preference resets
are predictable. The core summon path remains permission-free; no captured text is
sent or retained by the fallback.

### A46 · P2/M — Export complete threads (F6)

**Where:** `TranscriptFormatter`, macOS command/save-panel orchestration, Linux UI/CLI.

Add whole-thread Markdown export, exposed through ⌘S and `NSSavePanel` on macOS.
Activate the agent before showing the save panel; restore focus afterward. Export
questions, evidence, findings, limitations, and per-turn completion state. Numbered
sources must remain unambiguous across turns. Reuse #26 rather than copying its logic.

**Accept:** multi-turn source-number collisions, failures with partial prose,
non-ASCII paths, cancellation, denied writes, and history disabled. Export only on
explicit request; preserve existing archive and secret-store boundaries.

### A47 · P3/M — Summarize unsettled claims with `/digest` (D4)

**Where:** shared command/parser, `ResearchContext`, runner, both front ends.

Produce a brief from the current thread's unsettled claims without new searches.
Use existing context assembly and clearly label “No fresh search”; this is a thread
summary, not a new evidence check. Preserve uncertainty and per-turn provenance;
never let old citation numbers bind to a different turn's sources.

**Accept:** no-search execution, empty/no-unsettled threads, context trimming,
source-number collisions, and cancellation. Disclose the summarizing model call;
do not silently re-send other threads or bypass A06's budgets.

### A48 · P2/M — Show reasoning-stage progress (B5/D1)

**Where:** `ChatCompletionsClient.streamText`, research progress models, both trails.

`delta.reasoning_content` can precede `delta.content` for tens of seconds; earlier
examples included GLM-5, DeepSeek-R1, and o-series through gateways. Count it as
progress instead of showing dead air. Start with a phase/activity indicator;
optionally offer collapsed provider-supplied reasoning intended for display. Do not
confuse reasoning with the final answer or treat it as retrieved evidence.

**Accept:** reasoning-only prefixes, mixed deltas, normal models, cancellation, and
non-streaming replies with both reasoning and content. Decode any new persisted
progress/reasoning fields tolerantly so older archives still load. Preserve content parsing and
empty-answer detection. Use fixtures first, then a live compatible model before
shipping the optional display; the earlier review deferred it for that reason.

### A49 · P2/S — Pin the Linux CI image as documented

**Where:** `.github/workflows/linux.yml`, `CICD.md`.

The comment claims a digest pin, but the job uses mutable `swift:6.1-noble`. Pin an
explicit tested digest and document its refresh cadence. Preserve Swift language
mode parity across platforms; do not silently inherit toolchain changes.

**Accept:** workflow metadata agrees with the actual image reference. Deliberate
image refreshes run build/tests/package/install checks before adoption; pins receive
regular security updates rather than becoming permanent stale snapshots.

### A50 · P2/M — Rename threads and delete individual turns (F12)

**Where:** `ResearchThread`/`ThreadLibrary` operations, existing stores, both UIs.

Give threads stable user titles rather than truncated first questions. Remove a wrong
turn without deleting the whole thread. Add undo/confirmation and coordinate active
turn cancellation, queued snapshots, read-only archives, and history-off behavior.

**Accept:** rename/reload, empty or Unicode titles, deleting first/middle/active turns,
undo, and denied writes. Retained turns keep their own citation/source associations.
Use tolerant decoding for optional titles and A13/A15's persistence coordination.

### A51 · P2/M — Safe external ask entry point (F14)

**Where:** macOS URL registration and app/panel orchestration.

Support `vervellum://ask?q=…` from Shortcuts, Alfred, or bookmarklets. Treat incoming
URLs as untrusted input: bound/validate decoding, redact captured content, and seed
an inspectable composer rather than silently sending to a provider. Do not accept
arbitrary commands, provider reconfiguration, credentials, or raw shell execution.

**Accept:** encoded Unicode, malformed/oversized URLs, repeated activation, and drafts
in progress. Never log the incoming query; preserve summon/focus behavior. Any future
auto-submit automation needs a separate explicit consent design.

### A52 · P2/M — Redacted clipboard capture with `/clip` (F15)

**Where:** command dispatch, platform clipboard abstraction, shared capture/redaction.

Read the clipboard only on the explicit command and seed the composer through the
same redaction/metadata path as selection. Build on A07: redact before truncation and
before display. Preserve the existing draft or make replacement reversible without
putting unredacted captured text into undo history.

**Accept:** secrets/PEMs, oversized or non-text clipboard contents, active runs, undo,
and visible truncation/redaction notices. Never auto-send, poll the clipboard, log
captured text, or replace the user's clipboard contents.

### A53 · P3/S — Recent threads in the status menu (D6)

**Where:** macOS status-menu orchestration over the existing thread store.

Expose a bounded list of recent titles (five was the earlier proposal) with actions
to reopen them. Coordinate with #36's activity indicator, renamed titles, and active
research. This makes history reachable from the app's persistent surface.

**Accept:** empty/disabled history, deleted/renamed threads, keyboard menu navigation,
and a run in progress. Reopening must not discard a draft or interrupt research
silently; keep archive access behind the store.

## Execution rules

- Preserve numeric-only citations, uncited-verdict rejection, explicit uncertainty,
  sequential answer/assessment, and visible context trimming.
- Keep Core portable: Foundation/Dispatch only, no UI imports or main-actor hops.
- Decode new `ResearchTurn` fields with tolerant defaults (`decodeIfPresent`), not
  synthesized required keys. Test old archives and lossless `CodingKeys` round trips;
  breaking both the primary and same-shaped backup can silently reset the library.
- Keep credentials in existing secret stores, foreign errors sanitized, and research
  redirects refused. Updater fetching is a separate credential-free policy.
- Fix bugs test-first. Put independent changes in separate branches/PRs; record
  platform limitations and remaining validation rather than claiming parity.
- Earlier Linux UI work was deferred for missing GTK headers. A local sysroot/Xvfb
  is now available, but neither it nor hosted Mac CI replaces desktop QA. Exports,
  History keys, full-screen placement, and accessibility still need real sessions.
- Do not widen scope into a redesign until reader stability, persistence, and trust
  failures are covered. Start with A01, A07, A12–A15/A17; then A19/A20/A25–A28.
- Preserve this queue when merging later analyses: consolidate duplicates, retain
  distinct acceptance criteria, and move implemented items to merge/validation work.
