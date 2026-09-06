# Vervellum — review archive

**Current status:** [PR-REVIEW.md](PR-REVIEW.md) records the decisions for all 42
original PRs and supersedes every pending/in-flight table below. Consult it before
implementing an older proposal; many findings below are now fixed or superseded.

## Historical analysis, before PR #69

The remaining text preserves earlier findings, identifiers, and acceptance criteria.
Its code descriptions, test counts, and PR statuses describe those snapshots, not the
current implementation.

Combines the prior cumulative `main` analysis (`0ce3a2d`) with the
[Astra review](https://github.com/L-K-M/Vervellum/blob/4b35bba4554a7a975e8eb9f4755689b943120563/astra.md).
Checked against `main` at `0ce3a2d`: application code remains at the reviewed baseline;
later changes are release metadata, README, the screenshot, and analysis.

Implemented or in-flight work is separated below; do not reimplement it. Original
Astra findings remain in review PR #40. Earlier identifiers are mapped to consolidated
tasks so neither distinct requirements nor their provenance disappear.

Merged the [Fable review](https://github.com/L-K-M/Vervellum/blob/claude/ai-popup-tool-review-dezpkl/fable.md)
(`fable.md`, sections 1–12) at `main` `8652ea8`: seventeen of its findings ship as
[pull requests #53–#68](#fable-patches), its remaining findings and ideas are folded
into the existing tasks as **Fable status** paragraphs or added as A54–A70, and its
identifiers are mapped below. Every Fable bug claim (116) was re-derived from the code
by two independent verifiers before it was kept (105 confirmed, 11 refuted or dropped —
`fable.md` §11.3 lists them); every Fable idea (89) was scored 1–10 by three judges, and
the scores decided what became a task here. The disputes the review lost are recorded
in A61 and in `fable.md` §11.2.

**P1:** trust, data loss, blocking behavior. **P2:** usability/performance.
**P3:** expansion. **S/M/L:** local change / several components / design work.
`Core/` means `Sources/VervellumKit/Core/`; `Linux/` means
`Sources/VervellumKit/Linux/`. Visual hypotheses require desktop verification.

## Historical pending-PR inventory

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

### Fable patches

Seventeen independent branches, each based on the CI repair in #2 so its test target
compiles (those two commits become no-ops once #2 or #21 merges). Every Core and
Linux change was built and its tests run on Swift 6.1 / Ubuntu 24.04 before pushing
(198 → 204 tests, 0 failures); #67 is macOS-only and was compiled by CI. All are green
on both CI workflows. The GLM reviewer is configured without its key and skipped
every one, so no automated review arrived; steady state was green CI with no comments.

| PR | Branch | What it does | Covers |
|---|---|---|---|
| [#2](https://github.com/L-K-M/Vervellum/pull/2) | `fix/ci-test-compile` | The shared test target compiles (`.map { Int($0) }`); the desktop entry is validated under its reverse-DNS filename. | A41/A42 — same fix as #21/#38/#46; merge one. |
| [#53](https://github.com/L-K-M/Vervellum/pull/53) | `fix/streaming-robustness` | An SSE `error` frame fails the turn with Vervellum's own words; cancellation is checked after the stream loop and in `/direct`; `[DONE]` flushes the pending frame; CR/CRLF/BOM handled; a partial answer kept after Stop is citation-validated; payloads use `sortedKeys`. `SSEFrameAssembler` and `StreamingReply` are pure and tested. | A04 (most), A05, part of A21 (overlaps #27 — pick one). |
| [#54](https://github.com/L-K-M/Vervellum/pull/54) | `fix/provider-compat` | On HTTP 400 for a request that carried optional parameters (`temperature`, `response_format: json_object`), retry once without them and remember the outcome; `<think>` blocks stripped and every brace-balanced run tried before giving up; the quota-vs-key heuristic no longer matches bare "token". | Part of A10 (temperature capability), A43-adjacent. |
| [#55](https://github.com/L-K-M/Vervellum/pull/55) | `fix/search-tool-resolution` | The MCP search tool is resolved by shape (known names, else the single tool, else a "search" tool with a query-shaped string), the error lists advertised names, README wording corrected. | Part of A10, part of A40. |
| [#56](https://github.com/L-K-M/Vervellum/pull/56) | `fix/citations-in-code` | `CitationValidator` skips fenced and inline code (n-backtick pairing, unterminated fences); the answer prompt says a bracketed number in code is code. | A01-adjacent (validation side), A29 ("keep citations literal in code"). |
| [#57](https://github.com/L-K-M/Vervellum/pull/57) | `fix/assessment-failure` | An assessment failure adds an `assessmentUnavailable` notice and completes the turn; `sources` accepted as array/scalar/string; verdict synonyms mapped with an `unreadableVerdictDropped` notice; unknown `TurnNotice` values decode as `.unknown`; empty-plan turns get a fixed reading so Retry keeps research mode; deterministic source numbering. | A31 (failure path; the retry action itself remains), part of A12 (tolerant notices). Overlaps #30/#23 on citation parsing philosophy (#57 is lenient with exact-integer doubles, #30 rejects fractions) — reconcile. |
| [#58](https://github.com/L-K-M/Vervellum/pull/58) | `fix/history-citation-markers` | `[n]` markers are stripped from historic answers before they enter the payload; the prompt says the numbered evidence is this turn's alone. | A01-adjacent; new. |
| [#59](https://github.com/L-K-M/Vervellum/pull/59) | `fix/linux-window-lifecycle` | `hide-on-close` (the WM close destroyed the window under a held service — use-after-free on the next shortcut); the shortcut hides only an *active* window; Return never cancels a run, Ctrl-Return always submits; the thread scrolls to the newest turn unless the reader scrolled up; "Stopped" in the trail; "Try again" on failed and stopped turns; the hint follows `submitOnReturn`. | A16 (overlaps #28 — pick one), part of A24. |
| [#60](https://github.com/L-K-M/Vervellum/pull/60) | `fix/thread-archive-safety` | The version stamp is decoded before the document, a newer primary *or* backup makes the archive read-only and neither is adopted; non-terminal turns load as failed with their partial answer; `.bak` rotation only from a primary that decoded or was written by this process; erase failures are recorded in `eraseFailure`, shown in Settings ▸ General; `SecretRedactor` catches bare Stripe keys and stops matching "a basic misunderstanding". | A12 (most), A13 (reporting), A14 (rotation), A15 (recovery half). |
| [#61](https://github.com/L-K-M/Vervellum/pull/61) | `fix/transcript-and-source-urls` | The transcript keeps the answer when the failure came after it, marks a stopped turn, and lists sources cited only by a verdict; structured `url` fields are no longer punctuation-trimmed (`…/Mercury_(planet)`). | A11 (structured URLs), A03-adjacent (overlaps #26 — pick one), A44 groundwork. |
| [#62](https://github.com/L-K-M/Vervellum/pull/62) | `fix/pango-emphasis-citations` | Emphasis spanning a citation renders on Linux (placeholder character, one emphasis pass); first `PangoMarkupTests`. | Part of A29 (Linux nested inline formatting). |
| [#63](https://github.com/L-K-M/Vervellum/pull/63) | `fix/deb-prerelease-version` | `1.1.0-beta.1` packages as `1.1.0~beta.1` so the release outranks it; both workflow jobs export `DEB_VERSION`. | New (packaging). |
| [#64](https://github.com/L-K-M/Vervellum/pull/64) | `fix/non-streaming-timeout` | Non-streaming plan/assessment requests get the 600 s deadline as their `timeoutInterval` (they are silent until the model finishes, so the 120 s idle timeout cut off slow local models); streams keep the idle timeout; `NSURLErrorTimedOut` maps to a distinct message. | Part of A22 (the inverse of its "tighter budget" suggestion, with the reason). |
| [#65](https://github.com/L-K-M/Vervellum/pull/65) | `feat/prompt-quality` | Write in the question's language; weigh `published` against `today` in answer and assessment; the assessment addresses a fresh model and is assembled through `ResearchContext` with the reading and the budgeted thread; "up to N searches, or none". `ResearchPromptsTests` pins each property. | Part of A06 (assessment assembled), new prompt work. |
| [#66](https://github.com/L-K-M/Vervellum/pull/66) | `feat/linux-preferences` | The GTK thread honours `textScale` (one CSS rule) and `showProcessTrail` (the running stage still shows); README lists the keys. | Part of A26 (Linux), A40 (PRIVACY claim now true). |
| [#67](https://github.com/L-K-M/Vervellum/pull/67) | `fix/macos-thread-links-settings` | Model-written links are dropped after markdown parsing; a deleted thread is taken out of the engine too (history row and Delete All); Settings opens above the panel (panel dismissed without restoring activation, Settings restores the remembered app). | A01 (link stripping), A13 (resurrection), new (Settings placement). |
| [#68](https://github.com/L-K-M/Vervellum/pull/68) | `fix/packaging-hygiene` | One main category in the desktop entry; the Debian job's token is `contents: read`. | New (packaging). |

Pairs that fix the same defect twice: #53/#27 (SSE framing), #61/#26 (transcripts),
#59/#28 (GTK close), #2/#21/#38/#46 (test compile). Merge one of each and close the
other; the Fable side was written without reading the other branch.

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

Fable identifiers (`fable.md`): B1/B2 → #2; B3/B58 → #68; B4 → A49; B5–B9/B21 → #53;
B10/B11/B19/Q6 → #54; B12/B48 → #55; B13/Q4 → #56; B14/B16–B18/B20 → #57; B15/Q5 → #58;
B22 → A61 (withdrawn as a bug); B23/B70/B71 → #67; B24/F3 → #52/A23; B25/P4 → #49/#31/A19;
B26/U10 → A25/A64; B27 → A18; B28/B77 → A75; B29 → A28; B30 → A60; B31/B32 → A75;
B33/B35/B37–B39/B43/B52 → #59; B34 → A24; B36/B59 → A18/A76; B40 → A17; B41/B42 → A18;
B44/P7 → A20; B45/B66 → #60/A15; B46 → A20/#35/#47; B47/B64 → #60/A12/A14;
B49 → A49; B50 → A09/#48; B51 → A76; B53 → #63; B54 → #62; B55 → #66; B56/B57 → A76;
B60–B63 → #61; B65 → #64; B67 → A62; B68 → #32/A29; B69 → A40; B72–B76 → A75;
P1/P3 → #51/#24/#50; P2/P5 → A20; P6/P8 → A17; U1 → A09; U2 → #52; U3 → A19; U4 → A54;
U5 → A28/A23; U6 → A36/A46; U7 → A55; U8 → A23; U9 → A63; U11 → A50; U12 → A34/A10;
V1/V2 → A27; V3 → A26; V4–V12 → A60; F1 → A56; F2 → A35; F4/F5 → A10/A34; F6 → A34;
F7 → A46; F8 → A44; F9 → A51/A67; F10 → A30; F11 → A37; F12 → A57; F13 → A58; F14 → A59;
Q1–Q3/Q7 → #65; D1/D2/D7/D12 → A36; D6 → A61; D3/D5/D8/D9/D10/D11 → declined (A36).
Fable §11.6: B78/B82/B83 → A75; B79/B80 → A27; B81/B87 → A26; B84/B85 → A01; B86 → A25;
B88 → A28; B89/B93 → #67; B90/B92/B94–B97 → A77; B91 → A18; B98 → A38; B99 → A12;
B100 → A78; B101–B107 → A40; B108 → A76.

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

**Fable status:** Covered by #67 (link attribute dropped after parsing, macOS) and #58 (historic markers stripped). Still open from Fable: `[n]` inside *inline* code becomes a chip on macOS because masking runs before markdown parsing — skip placeholders whose run carries `inlinePresentationIntent.code` (B85; #56 fixed the validator side); a literal U+FFFC in the answer shifts every chip after it — strip it in `mask` or use a private-use placeholder as #62 does on Linux (B84). Also open: literal U+FFFC handling, tests for autolinks/custom schemes/partial streams (a `MarkdownTextTests` file — the parser-level test in `MarkdownParserTests` cannot fail for the reason it states, `fable.md` B69), and the SECURITY/PLAN wording that says a model link is "structurally impossible".

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

**Fable status:** Covered by #53 (error frames, cancellation after the loop, `[DONE]`, CR/BOM, sorted payloads) and #54 (400 retry). Remaining: the EOF-without-`finish_reason` policy and usage-only frames, and a written list of the completion signals accepted. #53 and #27 both touch `readLines`; merge one.

### A05 · P1/S — Validate retained prose on every terminal path

**Where:** `Core/Research/ResearchRunner.swift`.

Validation runs only after successful streaming. Validate a stopped/failed answer
once in terminal cleanup and attach notices for invalid references or literal URLs.
Do not flag half-arrived markers during normal streaming.

**Accept:** stop/failure after an invalid marker or URL preserves the prose and its
warning. Successful/direct turns still validate once. Complements A01 and A04.

**Fable status:** Covered by #53: `run`'s catch validates a non-empty partial answer. Remaining: a direct-mode terminal-path test.

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

**Fable status:** #65 assembles the assessment through `ResearchContext.assemble` (same budget, reading and thread as the answer). The budget/reserve/disclosure work above is still open.

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

**Fable status:** Covered by #60: a `VersionStamp` is decoded first; a newer primary *or* backup makes the archive read-only and neither is adopted; `currentVersion`'s comment says when to bump it. #57 decodes an unknown `TurnNotice` as `.unknown`. Remaining: unknown `Verdict`/`ResearchStage` values inside the *same* version, and the History banner for `isReadOnly` (still stderr only).

### A13 · P1/M — Make erasure truthful and durable

**Where:** `ThreadArchive`, macOS engine/store/settings, `LinuxEnvironment`/panel.

History-off and Delete All discard deletion errors. Active research can be saved
again after erasure. Linux startup with history already disabled leaves old files.
Define stored-history deletion versus active-session retention; coordinate their
state and report sanitized deletion errors with retry.

**Accept:** denied deletion, queued writes, completion after Delete All, and relaunch
with history disabled. Primary and backup disappear or a visible error says they did
not. A deleted thread must not silently resurrect.

**Fable status:** Partly covered: #60 records a failed erase in `ThreadArchive.eraseFailure` (message shown under Delete All in Settings ▸ General); #67 stops a deleted thread resurrecting through the engine on macOS. Remaining: retry affordance, Linux relaunch with history already disabled, and the Linux panel's copy of the open thread after `deleteAll`.

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

**Fable status:** Partly covered: #60 rotates `.bak` only from a primary that decoded at launch or was written by this process (tested: recovery followed by a write leaves the backup intact). Remaining: restrictive temporary-file creation, serialized `isHistoryEnabled`, concurrent erase/flush tests.

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

**Fable status:** Recovery half covered by #60: non-terminal turns load as `.failed` with "Vervellum quit before this answer finished", partial text kept, Try again offered. Checkpointing during the run is #51's; quit-during-streaming still needs the flush ordering test.

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

**Fable status:** Add to the SECURITY.md "not protected" list: after every ad-hoc-signed update the login keychain re-prompts for the stored keys, and a denied prompt makes the key look unset because `KeychainStore` deliberately collapses `errSecAuthFailed` to nil (verified against the code; a documentation and diagnosability gap, not a data bug).

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

**Fable status:** Not touched by Fable; `fable.md` P4/B25 agree with the target. Verify the sentinel approach against a run that appends verdicts after the answer.

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

**Fable status:** Not duplicated by Fable. Still open here beyond #24/#51: cache parsed blocks keyed by block text and re-parse only the streaming block (P2 — `MarkdownBody` parses the whole answer per body evaluation), and compute `TurnView.validation` once per answer change (P5). On Linux, reuse finished turns' widgets and rebuild only the running box (B44).

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

**Fable status:** #59 gives Linux Ctrl-Return and makes Return never cancel. Open here: programmatic draft replacement bypasses `NSTextView`'s undo (`ComposerView.updateNSView` sets `string`; use `shouldChangeText(in:replacementString:)` + `didChangeText()` — `fable.md` B72), Tab/↑/↓ in slash completion (U8), and persisting the draft and open thread across relaunch (sweep idea).

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

**Fable status:** Covered in part by #59 (Ctrl-Return; Return never cancels; "Stopped"; Try again; hint follows `submitOnReturn`) and #66 (trail toggle). Remaining: IME (`gtk_text_view_im_context_filter_keypress` before the key controller — B34), clickable follow-ups, clipboard, and a discoverable quit (`vervellum --quit`, a `[Desktop Action quit]`, README — B59).

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

**Fable status:** Fable adds to the inspector: a multi-source marker `[2, 5]` links only to the first source and the tooltip `MarkdownText.mask` builds is never rendered — one chip per number is the smaller change (B86); a click on `[3]` should reveal source 3 in the panel with ⌘-click opening it (A64).

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

**Fable status:** #66 scales the Linux thread with one CSS rule (composer and header stay at system size). macOS evidence scaling (V3) still open; see A60 for the six-step scale.

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

**Fable status:** Fable measurements to fold in: `tertiaryText` is `Color.secondary.opacity(0.62)`, about 2:1 for the smallest text — use `.tertiaryLabelColor`, which also honours Increase Contrast (B79); fixed verdict RGB values are used as *sentence* colour for notices and failure text, not only for glyphs, and fail light-mode contrast (B80); the accent `#FF8A4C` measures about 2.3:1 on a light ground (A60 has the numbers).

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

**Fable status:** #62 renders Linux emphasis that spans a citation; #56 keeps citations literal in code on both platforms. Open: range citations `[1-3]`/`[1–3]` are neither rendered nor flagged (A62), and tables are #32's.

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

**Fable status:** `fable.md` U1 and B50 agree: per-query state, sources published after each search, an elapsed clock, and a Plan → Search → Answer → Assess timeline while running. #48 counts completed searches; the rest is still open.

### A10 · P2/M — Explicit provider and MCP capabilities

**Where:** `SearchMCPClient`, planner schema validation, provider settings/client.

Only two z.ai tool names and one listing page are supported. Argument keys are
validated, not types/enums. Required temperatures exclude some reasoning endpoints.
Document current support; add explicit tool selection, bounded pagination, supported
schema validation, and provider capability presets. Do not infer safety from names.

**Accept:** real-shaped fixtures for tool pages/schema/types/enums and temperature
capabilities, without live keys. Broaden product claims only after support exists.

**Fable status:** Covered in part by #55 (tool resolved by shape, advertised names in the error, README wording) and #54 (retry without `temperature`/`response_format` on 400, remembered per client). Remaining: bounded pagination, schema type/enum validation, explicit provider presets (U12: OpenAI, z.ai, OpenRouter, Groq, Ollama, LM Studio, llama.cpp) and a "searches per question" setting (`maxSearches` is already plumbed end to end).

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

**Fable status:** Covered in part by #61 (`normalized(_:trimmingPunctuation:)`; structured fields validated only; tests for `…_(planet)`). Remaining: userinfo rejection, conservative dedup keys, non-overlapping prose partitioning.

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

**Fable status:** Also open here from Fable: `HotkeyRecorder` accepts Shift-only and Option-only chords, registering a global hotkey that steals every capital S system-wide (B91 — require ⌘, ⌃ or ⌥ in the recorder and in `HotkeyBinding.isValid`, and refuse a stored Shift-only binding at registration); a Carbon registration that returns `false` is silently dead (B27 — surface it in Settings ▸ Shortcuts and the status menu); `HotkeyRecorder` accepts ⌘W/⌘Q/⌘C as the global hotkey (B75 — reject bare-⌘ editing chords); `ShortcutInstaller` records success when `gsettings set` fails and the first GUI launch re-installs over a changed binding (B41/B42); the Providers pane reloads stored values on every tab selection, discarding unsaved edits (B76 — load once per presentation).

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

**Fable status:** #64 gives non-streaming calls the 600 s deadline as their per-request `timeoutInterval` and keeps the 120 s idle timeout for streams — the reverse of the "tighter budget" above, because a non-streaming call is *silent* until the model finishes and a local model on a large evidence block legitimately takes minutes; `NSURLErrorTimedOut` now maps to a message that names the model, not the connection. The independent monotonic per-exchange deadline and the fixture matrix are still open.

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

**Fable status:** #55 corrected the generic-MCP claim, #66 made the PRIVACY text-scale claim true. Verified documentation drift still open: SECURITY.md, PRIVACY.md, README and PLAN state the Linux key ladder as keyring → environment → file while `LinuxSecretStore` tries the environment first (B101); SECURITY.md says every outbound request goes through the one transport while the update check and download use a plain `URLSession` (B102 — scope the three rules to provider calls and say so); PRIVACY.md calls the update User-Agent a bundle identifier (it is name/version) and describes logging in macOS-only terms (B107); ICON-CREDITS.md lists 19 SF Symbols of the 32 in use (B106); `0.1.0` is hard-coded in README's install line and the build examples outside the release-bump marker (B105); `/help` on Linux advertises ⌘ shortcuts and Settings the GTK panel lacks — split the platform rows of `ComposerCommand.helpText` (B103); the release workflow installs `desktop-file-utils` but never validates the entry, and `linux.yml`, which does, does not run for tags (B104). Also: README promises Up/Down recall and searchable threads on Linux (B56), `CICD.md` says three workflows and lists four (B57), the digest-pin claim (A49), and the `MarkdownParserTests` emphasis test that cannot fail for its stated reason (B69) plus the erase tests that never create a `.bak` (B69).

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

**Fable status:** The failure path is #57: when only the assessment fails the turn completes with an `assessmentUnavailable` notice instead of failing a visible answer. The "Retry claim check" action itself is still open; #33's Ask Again is the other half.

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

**Fable status:** Fable candidates worth adding, judged on-thesis: **thread title from the planner's reading** (D1 — free, replaces the 60-character truncation once the first turn lands); **disagreement badge** (D2 — a small `arrow.triangle.branch` in the collapsed trail when any verdict is contradicted or mixed, tooltip naming the claim); **"why did you search that?"** (D7 — the query's `purpose` on hover of each query row; the data exists); **the "summary, not the full page" caveat as a tiny magnifier chip** on the source row (D12). Judged as drops, with agreement: `/about` ASCII art and `/coin` (D10/D11), the all-supported seal (D9), source-age tint (D3), per-block fade-in (D8), a Notification Center banner with answer text (D5).

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

**Fable status:** Sweep addition: an offline gate before spending a call, and a 429 `Retry-After` countdown instead of "try again" — both classify sanitized transport/status outcomes only.

### A44 · P2/M — Machine-readable CLI output (G3/F9)

**Where:** `LinuxApp.runHeadless`, a portable transcript encoder in Core.

Add `vervellum --json` with a versioned output contract for question, answer, findings,
sources, notices, completion/failure state, and partial output. Keep progress on
stderr and JSON alone on stdout; `StandardErrorLog` already anticipates this split.

**Accept:** success, direct, partial failure, cancellation, Unicode, and empty-result
fixtures parse as one document with meaningful exit status. Never serialize keys or
foreign errors. Reuse #26's evidence/completion rules.

**Fable status:** #61 keeps the answer in a failed transcript and marks a stopped one, which the JSON contract should mirror (`completion` state alongside partial text).

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

**Fable status:** `fable.md` F7/U6 add: Markdown export with `[n]: url` reference definitions written by Vervellum from the list it owns (not a relaxation of the citation rule), copy one citation, copy a code block, ⌘⇧C for the last answer.

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

**Fable status:** Same as `fable.md` B4/B49.

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

**Fable status:** See A67 for App Intents and a Services-menu entry, which need no Accessibility grant and survive the ad-hoc re-signing that revokes it.

### A52 · P2/M — Redacted clipboard capture with `/clip` (F15)

**Where:** command dispatch, platform clipboard abstraction, shared capture/redaction.

Read the clipboard only on the explicit command and seed the composer through the
same redaction/metadata path as selection. Build on A07: redact before truncation and
before display. Preserve the existing draft or make replacement reversible without
putting unredacted captured text into undo history.

**Accept:** secrets/PEMs, oversized or non-text clipboard contents, active runs, undo,
and visible truncation/redaction notices. Never auto-send, poll the clipboard, log
captured text, or replace the user's clipboard contents.

**Fable status:** The sweep re-proposed this independently ("research the clipboard"); no new requirement.

### A53 · P3/S — Recent threads in the status menu (D6)

**Where:** macOS status-menu orchestration over the existing thread store.

Expose a bounded list of recent titles (five was the earlier proposal) with actions
to reopen them. Coordinate with #36's activity indicator, renamed titles, and active
research. This makes history reachable from the app's persistent surface.

**Accept:** empty/disabled history, deleted/renamed threads, keyboard menu navigation,
and a run in progress. Reopening must not discard a draft or interrupt research
silently; keep archive access behind the store.

## Fable additions

Tasks the Fable review added that no existing entry carries. Same priority and size
scale; each was checked against the code and the constraints in AGENTS.md.

### A54 · P2/S — Failure card with the right next action

**Where:** `ResearchRunner` (a `failureKind` on the turn), `TurnView.FailureView`, `LinuxPanel`.

The failure card offers only "Try again", which re-runs the identical pipeline. When
search failed the message *tells* the user to type `/direct`; when the app is
unconfigured it tells them to open Settings. Put "Answer without search" and "Open
Settings…" on the card, driven by a small enum on the turn (`search`, `model`,
`configuration`, `other`) rather than by parsing the message.

**Accept:** each failure class shows the matching action; Try again still re-asks in
the original mode (#57 fixed the mode inference); the Linux card gets the same
actions where the platform has the feature.

### A55 · P2/S — Test connection in Settings

**Where:** `ProvidersView`, `SearchMCPClient`, `ChatCompletionsClient`.

Save validates URL shape only; the first real feedback on a wrong model name is a
failed research turn forty seconds later. Add a "Test connection" button that runs the
same two cheap calls the runner starts with (the MCP handshake; one tiny JSON
completion against the named model) and reports Vervellum-authored results; point the
empty state at it. Discloses exactly what leaves the machine.

**Accept:** wrong path, wrong model, bad key, quota error and success each produce a
distinct sanitized sentence; no provider text is shown; the button is disabled while a
test runs; cancellable.

### A56 · P2/M — "Verify this claim"

**Where:** runner (a per-finding stage), `FindingsView`, `EvidenceExtractor.sources(from:startingAt:)`.

A per-finding action that plans two searches aimed at that claim (one to confirm, one
to disconfirm), appends new sources with continuing numbers, and re-grades only that
claim. Turns an `insufficient` verdict from a dead end into a next step. Sequential
with the rest of the pipeline; budgets from A06.

**Accept:** the re-graded finding shows its new verdict and sources without touching
the others; cancellation mid-verify leaves the original finding; numbering never
collides with the turn's existing sources.

### A57 · P2/S — One-line evidential summary per turn

**Where:** a Core formatter shared by the macOS trail, the Linux trail, the CLI and the transcript.

`✓ 4 searches · 17 sources · 6 claims: 4 supported, 1 mixed, 1 not established · 0:41`.
One function, three call sites, so the panel, `vervellum --ask` and Copy agree. The
collapsed trail line on macOS and `PangoMarkup.trail` on Linux already compute
half of it separately.

**Accept:** identical text on both platforms for the same turn; cancelled and failed
turns say so in the same line (#59/#61 already add "Stopped"); pluralisation tested.

### A58 · P2/S — `/sources`

**Where:** `ComposerCommand`, runner (`Mode.sourcesOnly`), both front ends.

Plan and search, show the numbered source list, skip the two model calls. For the
user who wants the reading list, not the essay. Persisted as a turn with an empty
answer and a notice, so history and the transcript stay honest.

**Accept:** no answer or assessment call is made; the turn renders its sources and
"no answer was requested"; a follow-up in the thread does not treat it as an answer.

### A59 · P3/S — Tags

**Where:** `ResearchThread` (optional `tags`, tolerant decoding), `ThreadLibrary.search`, `/tag`, the history filter (`tag:` prefix).

**Accept:** old archives load; a tag survives rename and reopen; the filter combines
with text search; Linux CLI can list by tag once A30 lands.

### A60 · P2/M — Visual tokens for the macOS panel

**Where:** `PanelTheme`, `TurnView`, `FindingsView`, `SourcesView`, `PanelHeaderView`, `ResearchPanel`.

The parts of `fable.md` §5 not already in A26/A27, each a hypothesis to verify on a
desktop:

- **Light-mode contrast** (V1): the accent `#FF8A4C` measures about 2.3:1 on a light
  ground and carries 10–11 pt chips and labels; `mixed` about 2.1:1, `supported` about
  2.9:1. The Linux palette already chose light-safe hues (`#c4630f`, `#217a4a`,
  `#9a6a10`). Scheme-aware `accent(scheme)`/`verdict(_:scheme)` plus a separate
  `accentFill` for white-on-orange glyphs. (Belongs with A27's palette work.)
- **One scale** (V3): thirteen font sizes today; a six-step scale
  (10/11/13/15/17 + 11.5 mono) with every step taking `scale`. (With A26.)
- **Verdict rows say one thing three times** (V4): icon column, tracked uppercase word,
  and spine. One pill per row (icon + label in a tinted capsule), keep the 2 pt spine,
  reclaim the 24 pt column.
- **Evidence-health bar** (V5): a 4 pt segmented bar in the Claims header with the
  counts as accessibility label and tooltip; a 3 pt copy in the collapsed trail line.
  (A32 wants the same distribution in History rows.)
- **Section rhythm** (V6): larger spacing between sections than within; a hairline
  after each section label; a divider between turns.
- **Cards vanish in dark mode; the scrim darkens light mode** (V7): scheme-tuned fills,
  a white scrim in light mode, an opaque tint under Reduce Transparency. (A27.)
- **Superscript citation chips** (V8) with brackets kept so a copied sentence reads.
- **Domain monograms** (V9): a deterministic 16 pt letter tile (FNV-1a hue, first letter
  of the registrable label). No favicon fetch — PRIVACY promises nothing leaves the Mac
  except provider calls.
- **Header chrome** (V10): close at the leading edge, New/History grouped trailing,
  Settings demoted; `.resizable` on the style mask with min/max sizes written back to
  preferences (B30 — width is only reachable through a Settings slider, `panelHeight`
  has no UI, a dragged panel is re-placed on every show).
- **Empty state** (V11): a 44 pt SF Symbol composition (search · evidence · verdict)
  and the pipeline in its pending state.
- **Linux parity** (V12): per-finding cards with a coloured left border, `alpha="65%"`
  secondary text that follows the theme instead of `#7a7a7a`, superscript citations, a
  block-character health bar.

**Accept:** measured contrast in both schemes; every text size scales; nothing
collides at 140 %; screenshots in the PR. GUI QA before claiming an improvement.

### A61 · P2/S — Hotkey semantics: a product decision, and one real defect

**Where:** `PanelController.toggle`, `PanelController.show`, PLAN §5.1, the Shortcuts footnote.

`fable.md` B22 called it a bug that the summon hotkey *hides* a panel that is open
but no longer key (the user clicked into their editor, then pressed the shortcut for a
follow-up). A verifier showed PLAN §5.1, the §5.3 key table and the Shortcuts footnote
all document "press again to dismiss", so it is a decision, not a defect: Spotlight and
Raycast re-focus in this state; this app dismisses. Decide, and if re-focus wins, update
the three documents with the code. The related real defect stands: `appToRestoreOnClose`
is captured at the first `show()` and not refreshed when the user clicks through a
third app and back, so Escape yields to the originally remembered app. A cheap delight
from the same file: a hotkey double-tap reopens the last thread (D6).

**Accept:** whichever semantics is chosen is stated in PLAN, the footnote and the code
comment; Escape returns focus to the app the user actually left.

### A62 · P2/S — Range citations

**Where:** `CitationValidator.citationRegex`, `numbers(in:)`, both renderers.

`[1-3]`, `[1–3]` and `[2—4]` match nothing, so they stay literal text, contribute no
cited sources and are not flagged; the turn reads as clean. Accept
`\d+\s*[-–—]\s*\d+` inside the brackets and expand it (bounded by `sourceCount`), or
flag an unparseable digit group as `invalidCitation`.

**Accept:** `[1-3]` renders as chips for 1, 2, 3 and marks them cited; `[9-2]` and
`[1-300]` are flagged; code spans (#56) still ignored.

### A63 · P2/S — Redact pasted text

**Where:** `ComposerView` (paste), `AppDelegate.onSeedComposer`, `SecretRedactor`.

Only Accessibility-captured text is redacted; ⌘V goes straight through, and a `.env`
line pasted in a hurry is the case `SecretRedactor` exists for. Route paste through
the same redaction and the same banner. Builds on A07 (redact before truncation).

**Accept:** a pasted key is replaced and the banner names the count; plain prose
pastes are untouched; the redaction is visible before Return, never applied silently on
send.

### A64 · P2/S — A citation click reveals the source in the panel

**Where:** `MarkdownText` chips, `SourcesView`, `PanelRootView` scroll proxy.

Every click on `[3]` leaves the panel for the browser. Make a click scroll to and flash
source 3's row; ⌘-click opens the page. Pairs with A25's inspector and keeps the
"evidence is the product" reading loop inside the panel.

**Accept:** click flashes the row without leaving the panel; ⌘-click opens; keyboard
activation does the same as click.

### A65 · P2/M — Keyboard-complete thread and ⌘F

**Where:** `ResearchPanel.performKeyEquivalent`, `PanelCommand`, `ComposerView.Coordinator` (`insertTab:`/`insertBacktab:`), `PanelRootView` (`@FocusState`), `MarkdownText` (match highlighting).

Every action below the answer — Copy, Try again, follow-ups, "Show N found but not
cited", the trail disclosure, source rows — is a plain button only the pointer can
reach, and Tab inserts a tab. Tab/Shift-Tab leave the composer and walk the last
turn's actionable items with a visible focus ring; ⌥1–3 ask the follow-ups; ⌘E toggles
the trail; ⌘R retries; ⌘⇧A toggles uncited sources; ⌘F opens a find bar that highlights
matches in answers, findings and sources with ⌘G/⌘⇧G stepping. The composer stays an
`NSTextView` (AGENTS.md); this adds `doCommandBy` handling, it does not replace the
view. Coordinate the history half with A28.

**Accept:** every visible action is reachable without a pointer; the focus ring is
visible in both schemes; Escape returns focus to the composer before its usual back-out
order; find highlights update as the answer streams without restarting the search.

### A66 · P2/M — VoiceOver pass

**Where:** `ProcessTrailView`, `FindingsView.SectionLabel`, `ComposerView`, `HistoryView`, `TurnView`, `ResearchEngine.apply`.

Beyond A28: nothing announces that planning finished, that sources arrived or that
the answer is complete; section labels are plain uppercase text with no header trait;
the composer `NSTextView` has no accessibility label or placeholder; the trail's
`ProgressView` has no label; a streaming `Text` re-rendered per chunk makes VoiceOver
re-read from the top. Post stage-change announcements (`.announcementRequested` with
`ResearchStage.label`), add `.isHeader` to section labels and the question, label the
composer, and mark the streaming body as a container whose value updates at block
boundaries.

**Accept:** a VoiceOver user hears each stage change once, can rotor between Claims /
Sources / Next, can delete a thread, and is not interrupted per token.

### A67 · P3/S — App Intents and a Services-menu entry

**Where:** a macOS `AppIntent` target, `NSServices` in Info.plist, the existing seed-the-composer path.

"Research with Vervellum" (Services menu, with the selected text) and "Ask Vervellum"
(Shortcuts, Spotlight) through the same redaction path as the selection shortcut,
never auto-submitting. Neither needs the Accessibility grant, and both survive the
ad-hoc re-signing that revokes it (A45). Extends A51's URL scheme.

**Accept:** same input rules as A51; the Services entry appears only for text
selections; no capture is logged or sent without the user pressing Return.

### A68 · P3/S — Print, Save as PDF, share sheet

**Where:** macOS command dispatch over `TranscriptFormatter`/an attributed renderer.

⌘P prints the current turn (or thread) with its sources; the share sheet takes the
same rendering. Reuse #26/A46's completeness rules so a printed answer never lacks
its sources.

**Accept:** page breaks do not split a finding from its citation; failed and stopped
turns print their state line.

### A69 · P2/S — Diagnostics report

**Where:** About/Settings (macOS), `vervellum --doctor` (Linux).

"Copy diagnostic report": app version, OS, provider endpoints and model names (never
keys), search backend, secret backend in use, hotkey registration state, history
state, last failure class and stage timings. Everything a bug report needs and nothing
PRIVACY forbids.

**Accept:** the report contains no key, no question text and no provider error text;
`--doctor` exits non-zero when a required piece is missing.

### A70 · P2/S — Library backup and restore

**Where:** Settings ▸ General over `ThreadArchive`.

Export the whole `threads.json` and import one, through the version guard (#60): a
newer document is refused with the reason, an older one is loaded and re-saved at the
current version.

**Accept:** round trip preserves every turn; import of a newer version is refused
visibly; a corrupt file is refused without touching the current library.

Two further sweep ideas are recorded without a task: a **reading window** (open the
thread in a normal resizable window for a long read) and **localisation readiness** (a
String Catalog and locale-aware dates before the first translation). Both are worth
doing after A60 and A66.

### A77 · P2/M — Panel activation and geometry defects

**Where:** `PanelController`, `SettingsWindowController`, `UpdateChecker`, `AppDelegate.presentAccessibilityPrompt`, `SelectedTextReader`, `GeneralView`.

Verified by code trace, each a few lines, all in the window-management layer:

- Both `NSAlert` paths (update available, Accessibility prompt) call `NSApp.activate()`
  at an arbitrary moment and never hand activation back; the update alert's default
  button is Download (B90). Present background checks non-modally (a sheet on the open
  panel or a status-item badge), run modally only for "Check now", and yield
  activation afterwards as the panel does.
- Activation is restored with `.activateAllWindows`, which raises *every* window of the
  previous app over other apps as a side effect of dismissing the panel (B92). Use
  `activate(options: [])`.
- `appToRestoreOnClose` is captured at the first `show()` and not refreshed when the
  user clicks through a third app and back, so Escape yields to the wrong app (A61).
- Width and position changes in Settings do not reach an open panel; the composer is
  measured against the new width while the window keeps the old one (B94). Observe the
  preference and re-`place` while open.
- Re-entering an open panel snaps a header-dragged panel back to its computed position,
  and a dragged position is never remembered (B95). Skip `place` when open unless the
  pointer screen changed.
- Nothing observes `didChangeScreenParametersNotification`; an edge layout keeps the
  removed display's height (B96).
- `SelectedTextReader` blocks the main thread on a hung frontmost app for the AX
  messaging timeout, up to four times, before the panel appears (B97). Set
  `AXUIElementSetMessagingTimeout` to about a second, show the panel first and seed
  the composer when the read returns.

**Accept:** an alert never leaves Vervellum frontmost with no windows; dismissing the
panel raises nothing but the app the user left; a dragged panel stays where it was
dragged for the session; unplugging a display re-places an open panel; a hung
frontmost app delays the selection, not the panel.

### A78 · P1/S — Stamp the Linux binary's version at build time

**Where:** `Core/Platform/AppIdentity.swift`, `packaging/build-deb.sh`, `release.yml`.

`AppIdentity.version` falls back to the hard-coded `0.1.0` whenever `Bundle.main` has
no `CFBundleShortVersionString`, which is always the case for the Linux executable. The
tag's version reaches the package name and `DEBIAN/control` but never the binary, so a
released `.deb` reports `0.1.0` forever from `--version`, in the User-Agent, and to the
update comparison. Generate a small Swift source (or a resource) from `VERSION` in
`build-deb.sh` before `swift build`, and have `AppIdentity` read it on Linux; fail the
build when the stamp is missing in a release job.

**Accept:** `vervellum --version` in the installed package prints the tag; the update
check compares the real version; a local `swift build` without a stamp still runs and
says so.

## Small-defect batches from the Fable review

### A75 · P2/S — macOS small defects

Each verified against the code; each a few lines.

- With "Show what each search did" off, a running turn shows nothing for the whole
  plan-and-search phase (B77 / sweep): show a minimal running row (spinner +
  `stage.label`) whenever `!stage.isTerminal`, and let the preference govern only the
  detail and the post-run summary. (#66 does this on Linux.)
- The empty-state hint and `/help` ignore `submitOnReturn` (B28).
- Opening a thread from history while research is running cancels the run silently
  (B73): guard row activation or ask; check #25 first.
- The composer's height ignores the trailing empty line, so Shift-Return at the end
  scrolls the first line away (B74): add `extraLineFragmentUsedRect` when the text ends
  in a newline; check #50 first.
- `Preferences.launchAtLogin` calls `SMAppService.mainApp.status` (an XPC round trip)
  on every render of the General pane (B31): sample once on appear.
- `HotkeyRecorder` compares `keyCode == 53` instead of a named constant (B32).
- History delete has no confirmation and no undo (B29) — A28 carries it.
- The ordered-list marker is clamped to a 16 pt frame, so `10.` does not fit (B78):
  size the column from the font.
- Submitting while the history list is open runs the research behind the list (B82):
  clear `showsHistory` on submit.
- A turn cancelled during planning renders as a bare question with no status and no
  retry (B83): show the trail for `.cancelled` and a "Cancelled · Try again" row.
- The verdict label and its chips sit in a non-wrapping `HStack` (B87) — A26.
- The history search field never receives focus (B88) — A28/A23.
- Read-only mode is never surfaced in the UI (B99) — A12.

### A76 · P2/S — Linux and documentation small defects

- The Linux service can only be quit through an undocumented D-Bus action (B59): add
  `vervellum --quit`, a `[Desktop Action quit]` (GAction name identical, per AGENTS.md),
  and a README line. Coordinate with A18's settings reload.
- README promises Up/Down recall and searchable threads for both platforms (B56): mark
  them macOS until A30 lands, or add ↑/↓ recall to `LinuxPanel` (the questions are in
  `thread.turns`; the key handler already exists).
- `CICD.md` says three workflows and lists four (B57).
- No `CHANGELOG.md` (B51); the README screenshot has since landed.
- `render()` spawns `secret-tool` twice, synchronously, on the GTK main loop whenever
  the thread is empty (B40) — A17 carries it.
- The erase tests never create a `.bak`, so a backup left behind would pass, and the
  `MarkdownParserTests` emphasis test cannot fail for its stated reason (B69) — A40
  carries both.
- The Linux secrets docs describe a 0600 key file the app never writes and whose format
  is undocumented; nothing records which tier answered a read, so `backendDescription`
  hedges (B108): record `lastReadBackend` and document the file, or drop the tier.
- The documentation drift list in A40's Fable status (B101–B107).

## Idea scores from the Fable judges

Three judges scored every Fable idea from 1 (drop) to 10 (must build): a demanding
daily user, the engineer bound by AGENTS.md, and a designer holding the thesis "the
evidence is the product". Columns: mean · user/engineer/designer · effort. Ideas
already shipped or carried by an open PR are still listed so the ranking stays whole;
"DROP:" rows are proposals to drop another idea, scored by agreement. The judges' notes
are in the review session's records; the ranking, not the notes, decided which ideas
became tasks above.

| Mean | U/E/D | Size | Idea |
|---|---|---|---|
| 9.3 | 10/8/10 | L | "Read the page": user-initiated full-text fetch for one or two decisive sources, then re-assess |
| 8.7 | 9/9/8 | S | Let the reader scroll up during streaming; add a 'jump to latest' pill |
| 8.7 | 9/9/8 | M | 'Test connection' in Providers, and a first-run pass that walks through it |
| 8.3 | 9/7/9 | M | Per-search progress with live source arrival and an elapsed clock |
| 8.3 | 8/8/9 | S | Appearance-adaptive accent and verdict colours (light mode currently fails contrast) |
| 8.3 | 9/7/9 | M | "Verify this claim": targeted re-search and re-grade of a single finding |
| 8.3 | 9/9/7 | S | Search-backend adapter: configurable MCP tool name so Brave/Tavily/Exa/SearXNG MCP servers work |
| 8.3 | 9/9/7 | S | Coalesce streamed snapshots to one main-queue hop per display frame (latest-wins), flush structural changes immediately |
| 8.0 | 8/8/8 | M | Type-to-filter history driven by the composer, with ↑/↓/Return selection and day grouping |
| 8.0 | 7/9/8 | S | Reduce Motion is never consulted; add a Motion.isReduced gate and observe the accessibility notification |
| 8.0 | 7/9/8 | S | Live search progress in the trail: "Searching · 2 of 4 — checking whether X" |
| 8.0 | 8/8/8 | S | DROP: /about prints the pipeline as ASCII; /coin refuses to research coin flips |
| 7.7 | 9/7/7 | S | Redact pasted text the same way captured text is redacted |
| 7.7 | 7/7/9 | S | Show a source's snippet on keyboard focus and click, not hover-only, and keep row height stable |
| 7.7 | 7/9/7 | S | Export a thread as Markdown (and optional HTML) with its sources and verdicts |
| 7.7 | 7/7/9 | M | Tag the disconfirming search, and badge a plan that never looked for counter-evidence |
| 7.7 | 8/9/6 | S | Make `TurnView` (and `FindingsView`/`SourcesView`) Equatable so completed turns stop re-rendering and re-validating every frame |
| 7.7 | 8/9/6 | S | Research the clipboard: a permission-free sibling of Research the Selection |
| 7.7 | 8/7/8 | S | DROP: A seal for a fully-supported answer |
| 7.3 | 8/6/8 | M | A real type scale, scaled everywhere (claims, sources and captions ignore the Text-size preference) |
| 7.3 | 7/7/8 | S | One-line evidential summary per turn, shared with the CLI and transcript |
| 7.3 | 7/7/8 | S | Monoculture flag: "every cited source is from one domain" |
| 7.3 | 8/7/7 | M | Publish the running turn through its own ObservableObject; republish `engine.thread` only at turn boundaries |
| 7.3 | 7/7/8 | M | VoiceOver pass: announce stage changes, mark section headers, label the composer, expose hover-only controls |
| 7.3 | 7/7/8 | S | DROP: Notification Center banner with the first sentence of the answer |
| 7.0 | 7/7/7 | S | Inline recovery on failure: 'Answer without search' and 'Open Settings' next to 'Try again' |
| 7.0 | 8/5/8 | M | Superscript citation chips in prose, plus hover/click source cards |
| 7.0 | 7/7/7 | S | History rows subtitled with the planner's reading (a free one-line summary) |
| 7.0 | 7/7/7 | M | Pipe tables: parse GFM tables in MarkdownParser or forbid them in the answer prompt |
| 6.7 | 8/6/6 | M | Queue the next question while a run is in flight |
| 6.7 | 6/5/9 | S | Evidence-health bar in the Claims header |
| 6.7 | 6/6/8 | S | Scheme-tuned glass, scrim and fills (cards vanish in dark mode; scrim darkens light mode) |
| 6.7 | 7/6/7 | S | Scroll-to-bottom at most once per frame, and only while the reader is pinned to the bottom |
| 6.7 | 7/4/9 | M | Claim ↔ prose linking: hovering a finding highlights the sentences it grades, and vice versa |
| 6.3 | 7/6/6 | M | Copy as Markdown, copy one citation, open all cited, and a copy button on code blocks |
| 6.3 | 6/5/8 | S | Verdict pills (icon + label in a capsule) replacing the icon rail + tracked uppercase word |
| 6.3 | 6/7/6 | S | Model provider presets with endpoint auto-fill (OpenAI, OpenRouter, Groq, Ollama, LM Studio, llama.cpp, Anthropic-via-gateway) |
| 6.3 | 6/7/6 | S | Per-turn and per-stage model override: `/model` command and a separate assessment model |
| 6.3 | 7/5/7 | S | Citation click scrolls to and highlights the source row; ⌘-click opens the page |
| 6.3 | 6/6/7 | S | Contested-turn badge: "sources disagree on 2 claims" in the trail and in history |
| 6.3 | 6/6/7 | S | Menu-bar icon that works while a run is in flight, and keeps a dot until you read the result |
| 6.3 | 6/7/6 | S | Flush the archive asynchronously on dismiss; keep the synchronous flush for termination only |
| 6.3 | 8/4/7 | M | Keyboard-complete thread: Tab out of the composer, ⌥1–3 for follow-ups, ⌘E trail, ⌘R retry, ⌘⇧A all sources |
| 6.3 | 7/6/6 | S | Persist the draft and the open thread across quit, crash and relaunch |
| 6.3 | 6/6/7 | S | DROP: Source-age tint — colour each citation by how old the page is |
| 6.0 | 6/6/6 | S | Tab completes the slash command; ↑/↓ walk the completion list instead of recall |
| 6.0 | 6/6/6 | S | ⌘1–⌘9 open the last answer's cited sources; ⌘⇧C copies it |
| 6.0 | 6/5/7 | S | Section dividers and a turn separator so sections stop reading as paragraphs |
| 6.0 | 5/6/7 | M | Linux parity: per-finding cards, theme-adaptive secondary text via Pango alpha, superscript citations and a block-character health bar |
| 6.0 | 6/6/6 | S | `vervellum --ask --json`: machine-readable CLI output |
| 6.0 | 6/6/6 | M | Linux parity for `/history`, `/settings` and `/copy` |
| 6.0 | 6/5/7 | S | "Copy with sources" on any paragraph: citations resolved to footnotes |
| 6.0 | 7/5/6 | S | Cache each block's rendered AttributedString keyed by (text, source ids, scale, font) so only the growing block re-enters cmark |
| 6.0 | 6/7/5 | S | History search: stop lowercasing every answer in the library on every keystroke (and evaluating it twice per render) |
| 6.0 | 8/5/5 | S | DROP: Per-block fade-in as the answer arrives |
| 5.7 | 5/5/7 | S | Stage timeline in the process trail while a turn runs |
| 5.7 | 6/5/6 | M | Services menu "Research with Vervellum" and a `vervellum://ask?q=` URL scheme (plus a Linux `ask` GApplication action) |
| 5.7 | 6/5/6 | M | Network-aware error states: offline gate before spending a call, and a 429 Retry-After countdown |
| 5.7 | 6/5/6 | M | App Intents: 'Research with Vervellum' and 'Ask Vervellum' for Shortcuts, Spotlight and Siri |
| 5.3 | 6/5/5 | M | Provider presets and a 'searches per question' setting |
| 5.3 | 6/4/6 | M | Panel chrome: button hierarchy, close at the leading edge, and a drag-to-resize edge with a grip |
| 5.3 | 5/5/6 | M | "Watch this question": re-run a thread and show what changed (ResearchDiff) |
| 5.3 | 5/6/5 | S | One citation scan per turn: a spans-only validator entry point, and stop running the URL regex where `literalURLs` is never read |
| 5.3 | 6/5/5 | M | ⌘F find in the thread, with match highlighting and next/previous |
| 5.3 | 5/6/5 | S | Diagnostics: 'Copy diagnostic report' in About and `vervellum --doctor` on Linux |
| 5.0 | 5/5/5 | M | Pin and rename threads |
| 5.0 | 5/5/5 | S | ⌘1…⌘9 open the last answer's source n |
| 5.0 | 5/5/5 | M | Linux: rebuild only the running turn's box on a text-only update and coalesce idle sources per frame |
| 5.0 | 6/4/5 | M | Token usage meter per turn and per thread (stream_options.include_usage) |
| 5.0 | 5/5/5 | S | Library backup and restore: export/import the whole threads.json from Settings, with the version guard |
| 4.7 | 5/4/5 | S | ⌘⇧C copies the last answer with its sources |
| 4.7 | 5/4/5 | M | "Since last time": a comparison strip when a question is asked again |
| 4.7 | 5/4/5 | M | Streaming tail renderer: freeze the parsed prefix and re-parse only the last paragraph |
| 4.7 | 5/5/4 | S | HTTPTransport.readLines: avoid shifting the buffer once per line |
| 4.7 | 6/4/4 | M | Reading window: open the thread in a normal resizable window (⌘⇧O) for long reads |
| 4.3 | 4/4/5 | S | `/sources` — evidence-only mode that stops after search |
| 4.3 | 5/4/4 | M | Source-age tint: colour each citation by how old the page is |
| 4.3 | 4/4/5 | S | Stage-aware streaming caret and a completion tick in the trail that matches the verdict health |
| 4.3 | 4/5/4 | S | Memoise `ComposerView.height` and stop invalidating the text view on every SwiftUI update |
| 4.3 | 4/4/5 | S | ⌘P print / Save as PDF, and the macOS share sheet for a turn |
| 4.0 | 3/4/5 | S | Per-block fade-in as the answer arrives (no per-token motion) |
| 4.0 | 4/4/4 | M | Stream answer deltas to the front ends instead of whole-turn snapshots, so the engine appends in place |
| 3.7 | 4/3/4 | S | Source monograms (deterministic domain avatars, no network) |
| 3.3 | 3/3/4 | S | Empty state with a small SF Symbol composition and the pipeline in three glyphs |
| 3.3 | 4/3/3 | M | Notification Center: the first sentence of the answer when a run finishes while the panel is hidden |
| 3.0 | 3/3/3 | S | Thread tags and a `tag:` filter in history |
| 3.0 | 3/3/3 | S | A seal for a fully-supported answer — and a "look for evidence against this" follow-up to keep it honest |
| 2.7 | 3/2/3 | L | Localisation readiness: String Catalog, plural rules, locale-aware dates and a Core localisation seam |
| 2.0 | 2/2/2 | S | /about prints the pipeline as ASCII; /coin refuses to research coin flips |

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
- The Fable patches (#53–#68) are independent of each other and merge cleanly onto
  `main` at `8652ea8` (test-merged); the pairs that duplicate an Astra/k3 patch are
  listed under *Fable patches*. Merge #2 (or #21) first so the test target compiles.
- When a Fable status paragraph says "covered", the acceptance criteria above it still
  name what is left; do not delete the task until every clause is met.
