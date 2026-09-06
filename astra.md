# Astra review

Baseline: `5be8eab` on `main`. Review recorded before implementation.

Scope: shared pipeline, transport, evidence and citation handling, persistence,
macOS panel/composer/settings, GTK/CLI, packaging, tests, and product documentation.
This is a code review, not a desktop usability test. No Mac or display is available
here. Visual concerns below require GUI verification; no measured frame-rate claims
are made. Other agents' PRs were not consulted.

## Assessment

Keep the shared core, numeric citation contract, separate assessment pass, plain
callbacks, native composer, and explicit unsourced mode. Improve the enforcement and
presentation around them. The largest risks are trustworthy-looking output with
missing evidence, silent data loss, and UI updates that interrupt reading.

Priority: **P1** trust/data-loss/blocking; **P2** usability/performance; **P3** expansion.
Effort: **S** local change; **M** several components; **L** design/security work.
“Confirmed” means the implementation contains the stated path, not that every
platform symptom was reproduced interactively.

## Trust and correctness

### A01 — Only application citations may create links · P1/M · confirmed

`Vervellum/Views/MarkdownText.swift` passes model Markdown through
`AttributedString(markdown:)` without removing its link attributes. A response such
as `[read this](https://invented.example)` can therefore create an actionable link
outside the numbered source list. Non-HTTP schemes also need a regression test.
`CitationValidator` warns only after successful streaming; warning is not prevention.

Remove all model-origin link attributes before inserting application-owned citation
links. Handle literal object-replacement characters without shifting citation
placeholders. Keep model links inert, including during streaming; never substitute
URL allow-list matching for numeric citations. Test Markdown/autolinks, custom
schemes, emphasis, literal U+FFFC, and multi-source markers. Update the security
claims to distinguish enforced rendering from prompt instructions.

### A02 — Reject fractional and Boolean assessment citations · P1/S · confirmed

`Core/Research/ResponseParsers.swift` rounds `Double` source values. `1.6` becomes
source 2; Foundation's JSON Boolean bridging can also turn `true` into source 1.
This manufactures the citation that permits an evidential verdict to survive.

Accept only exact integers or integer strings. Reject Boolean, fractional,
non-finite, overflow, and out-of-range values; flag malformed references. Drop
supported/contradicted/mixed findings when no valid citation remains. Preserve
insufficient/opinion findings. Test JSON-decoded values, not just Swift literals.

### A03 — Make copied/CLI transcripts self-contained · P1/S · confirmed

`Core/Text/TranscriptFormatter.swift` lists only answer citations, although the
export includes verdict citations too. A finding citing source 3 can leave `[3]`
unresolvable. Any `failure` returns early, losing a usable answer when assessment
fails. Cancellation and an assessment still running are not labelled in exports.

Export the union of answer and finding references once, in source-number order.
Preserve partial prose, evidence, caveats, and safe errors. Label incomplete states
without suggesting verification finished. Test assessment-only citations, failures
before/after prose, cancellation, direct mode, and copying during assessment.

### A04 — Never silently accept a broken stream · P1/M · confirmed

`HTTPTransport.streamJSONEvents` ignores malformed JSON frames;
`ChatCompletionsClient.streamText` ignores error envelopes and accepts EOF without a
finish reason. Valid tokens followed by a provider error or a cleanly closed but
truncated HTTP stream can be treated as a complete answer. Its `try? messageContent`
also discards errors from the non-streaming fallback.

Introduce a completion-state parser. Fail safely on malformed data/error frames;
require an explicit completion signal under a documented compatibility policy.
Preserve partial text but skip assessment of a failed answer. Test truncated streams,
`length`, filters, fallback JSON, `[DONE]`, usage-only frames, and sanitized errors.

### A05 — Validate partial answers on every terminal path · P1/S · confirmed

`ResearchRunner` calls `applyCitationValidation` only after `streamText` succeeds.
Stopped or failed answers can retain invalid citations/URLs without notices.
Validate retained prose in terminal cleanup, once; test stop and failure after an
invalid marker or URL has arrived. Do not flag half-arrived markers while streaming.

### A06 — Enforce the budget even without history · P1/M · confirmed

`ResearchContext.assemble` drops history but returns an oversized fixed payload when
the current question or `extra` alone exceeds the budget. It omits array commas in
its estimate. Assessment bypasses this assembly entirely. Byte counts are described
as characters/tokens, and 110 KB is not a portable guarantee of a 32k-token fit.
Historic answer shortening is also silent despite the whole-turn-trimming promise.

Give every stage a measured input budget and output reserve. Reject an oversized
current question visibly; never silently crop it. Make shortening/trimming explicit,
count serialized punctuation, and document heuristic versus provider token limits.
Test giant questions/schema/answers, Unicode, exact boundaries, and zero history.
Use prefix indices rather than repeated `removeFirst` on both arrays.

### A07 — Redact selection before truncation · P1/M · confirmed

`SelectedTextReader.trim` truncates to 8,000 characters before `AppDelegate` calls
`SecretRedactor`. A long PEM block loses its closing delimiter, so the complete-block
regex no longer matches. An existing safety net can be defeated by the app's own
cropping. Partial selections already require conservative handling too.

Return capture metadata; redact bounded captured text before display truncation,
and redact unterminated private-key blocks conservatively. Show both truncation and
redaction notices. Test a valid long PEM, cut-off delimiters, and ordinary prose.
Keep selection opt-in; never silently send or log captured content.

### A08 — Keep diagnostic structure content-free · P1/S · confirmed

`EvidenceExtractor.shape` prints arbitrary dictionary keys into the research log.
A key can itself contain a question, token, or attacker-controlled multiline text.
Log known schema keys only; summarize unknown keys by count/type. Test a secret in a
key and nested JSON-string payloads; no original bytes may reach the log.

### A09 — Track actual search outcomes · P2/M · confirmed

`ResearchRunner` records all planned searches as `searches_run`, even when some fail.
Successful remaining searches hide partial failure from the user. Both progress
summaries count plans, not successful requests; there is no per-query progress.

Store pending/running/succeeded/failed outcomes, safe failure labels, elapsed time,
and source contribution. Feed only successful queries to the answer as completed
searches. Show “2/4 succeeded; evidence may be incomplete.” Test mixed failures,
cancellation, and persistence migration. Keep searches sequential unless the MCP
server's concurrency contract is established.

### A10 — Treat MCP compatibility as a capability · P2/M · confirmed

`SearchMCPClient` accepts only two z.ai tool names, reads one `tools/list` page, and
checks required/unknown keys but not value types or enums. The product description
suggests broader MCP support. Required model temperatures also exclude some
OpenAI-compatible reasoning endpoints.

First document supported providers. Add explicit tool selection, pagination bounds,
supported schema type/enum validation, and provider capability presets. Do not infer
arbitrary tool safety from a name. Test real-shaped fixtures without live keys.

### A11 — Preserve source identity and boundaries · P2/M · confirmed

`SourceHarvester.normalized` strips trailing URL punctuation even for structured URL
fields and accepts userinfo. Exact-string dedup leaves fragment/tracking variants
separate. `EvidenceExtractor.hits(inParagraph:)` overlaps context between neighboring
link lines, potentially assigning one result's summary to another.

Separate structured URL validation from prose cleanup. Reject credential-bearing
links, preserve legitimate query punctuation, define conservative dedup keys, and
partition prose hits into non-overlapping items. Test multiple results without blank
lines, URL parentheses/query punctuation, and near-duplicate but distinct pages.

## Persistence and lifecycle

### A12 — Preserve newer archives before decoding their contents · P1/M · confirmed

`ThreadArchive.load` fully decodes `ThreadLibrary` before inspecting `version`.
A newer document with an unknown enum case can fail decoding, fall back to an old
backup/empty library, and then be overwritten. The version guard never sees it.

Read a minimal version envelope first. Keep unknown versions read-only even when
threads cannot decode. Distinguish corrupt/missing/newer states in the UI. Test a
future verdict/notice/stage, missing required fields, and a valid older backup.

### A13 — Surface failed erasure and prevent resurrection · P1/M · confirmed

`ThreadArchive.eraseEverything` throws, but history-off and `deleteAll` use `try?`.
The UI reports removal even when bytes remain. A running or still-open thread can
later be saved again after “Delete all.” Linux launching with history already off
loads for version checking but leaves existing files untouched.

Define deletion of stored history versus active research explicitly. Coordinate
archive and session state; expose sanitized persistence errors and retry. Turning
history off must remove primary and backup or report failure. Test denied deletion,
a queued write, active completion after erase, and relaunch with history disabled.

### A14 — Create private archives before writing bytes · P1/M · confirmed

`ThreadArchive.writeNow` atomically writes with default temporary permissions and
only then chmods the destination. There is a readability window under a permissive
umask. Backup copying/permission failures are swallowed. After backup recovery,
rotation can replace the good backup with the corrupt primary.

Use a restrictive temporary-file writer, atomic replacement, and validated backup
rotation. Serialize archive state instead of reading `isHistoryEnabled` on the write
queue while the UI mutates it. Test permissions before content writes, backup
recovery followed by write failure, and concurrent erase/flush.

### A15 — Save active work, recover interrupted turns · P1/M · confirmed

macOS `ResearchEngine.apply` publishes UI state but does not call its persistence
callback. The store receives the initial queued turn and terminal turn, not streaming
progress. Linux saves only on finish. Quit/crash can lose the current answer, and
loaded nonterminal turns are not normalized to an interrupted state.

Checkpoint at a bounded cadence and on dismissal/termination; never write per token.
Cancel and snapshot before shutdown. Recover stale running states as interrupted,
with partial text and an explicit retry. Test relaunch from every stage and ensure
old cancelled callbacks cannot overwrite a newer session snapshot.

### A16 — Native GTK close must hide, not destroy · P1/S · confirmed path

`LinuxPanel` stores borrowed widget pointers. Its Close button hides the window,
but native window-manager close has no hide-on-close setting or close-request
handler. `LinuxApp` holds the process and panel; a later toggle can access destroyed
widgets. Set GTK's hide-on-close behavior and test repeated native-close/toggle in a
real session, including during research. Quit must remain a separate action.

### A17 — Bound keyring and shortcut subprocesses · P1/M · confirmed

`LinuxSecretStore.run` and `ShortcutInstaller.run` block without deadlines. Keyring
reads happen during panel construction and Ask on the GTK thread. A locked or wedged
service can freeze the interface. Keyring deletion failures are discarded, and the
backend description reports writes, not the actual source of a read. Environment
values actually take precedence, contrary to the documented ladder.

Move credential acquisition behind an asynchronous, bounded service with explicit
backend/result states. Terminate stalled children; distinguish unavailable/deleted/
failed and explain environment overrides. Test hung/missing/failed secret-tool and
ensure keys never enter arguments or error output. Correct the documented precedence.

### A18 — Configuration and shortcuts need truthful outcomes · P2/M · confirmed

`JSONFileSettingsStore` never reloads external edits, although editing JSON is Linux's
only setup UI. First-run shortcut bookkeeping can overwrite concurrent edits from
its stale snapshot. `ShortcutInstaller.install` reports success even when writes
fail. macOS ignores Carbon registration's returned failure. Provider Clear similarly
ignores Keychain deletion errors and says “Key removed.”

Add explicit settings reload/validation and a visible restart/reload path before a
full editor. Preserve external keys when writing bookkeeping. Check every shortcut
write and registration result; surface conflicts and recoverable failures. Test
read-only settings, failed dconf writes, external edits, and Keychain failures.

## Performance and interaction

### A19 — Let readers stop following the stream · P2/M · confirmed

`PanelRootView` scrolls to the bottom on every last-answer change. Scrolling upward
to read loses to the next token. Changes to findings/sources do not use that trigger,
so the final verification can land below the viewport unnoticed.

Track explicit reader intent and proximity to the bottom. Follow only while pinned;
show a keyboard-accessible “Latest ↓” control while detached. Resume on explicit
activation or a new submitted turn, not incidental layout changes. Test scroll-up,
selection, trackpad momentum, new findings, history switching, and text resizing.

### A20 — Coalesce snapshots and preserve widget identity · P2/M · confirmed

`ResearchRunner` copies/reports the growing turn per delta; macOS enqueues and
publishes every snapshot. Markdown, inline styling, citation scans, and composer
height layout then repeat. Linux throttles drawing to 10 Hz but still queues every
snapshot and destroys/recreates every turn widget on redraw. That loses selection,
focus, and link state; cost grows with thread length.

Coalesce before UI enqueue, keeping every token and the final snapshot. Publish stage
changes immediately. Reuse completed turn widgets and update only the active answer.
Cache immutable parsed blocks; measure actual composer width and reuse layout work.
Benchmark large threads/token bursts: queue depth bounded, terminal frame exact,
Stop responsive, and selection in completed turns preserved. Keep GLib dispatch out
of Core and do not add MainActor isolation there.

### A21 — Parse SSE lines in linear time, including CR · P2/S · confirmed

`HTTPTransport.readLines` scans an accumulated array then removes its prefix for
every LF. Many lines in one chunk repeatedly move the remaining bytes; long lines
split across chunks repeatedly rescan old bytes. It handles LF/CRLF but not lone CR,
which SSE permits. UTF-8 BOM handling also needs coverage.

Use a byte cursor or a single pass, holding only the unfinished line. Support CR, LF,
and split CRLF; consume one leading BOM. Preserve empty lines, early stop, byte caps,
UTF-8 splits, cancellation, and existing EOF behavior. Add deterministic chunk-boundary
tests plus an adversarial-input benchmark without timing assertions in CI.

### A22 — Make request deadlines real and cancellation testable · P2/M · confirmed

The transport's ten-minute checks run only when another chunk arrives and start
reading after the response head. They are not an end-to-end deadline. Early-return
stream cancellation relies on continuation lifetime; this deserves integration tests
rather than assurances in comments.

Use a monotonic per-exchange deadline that cancels the URL task independently of
incoming bytes. Test no headers, idle body, trickle/keepalive, cancellation before
registration, early matching MCP result, refused redirects, and producer caps. Use a
transport test seam or loopback server; never call live providers in CI.

### A23 — Keep draft actions non-destructive · P2/M · confirmed

macOS disables editing while researching. `askFollowup` replaces a nonempty draft,
despite its comment promising preservation; programmatic `NSTextView.string`
assignment is not an undo guarantee. Recall stays active after editing recalled text,
so arrows can discard edits. Slash suggestions are buttons, not an arrow-key palette.

Allow drafting during a run; keep Submit distinct from Stop. Preserve or explicitly
replace drafts on suggestions; end recall on user edits. Add arrow/Tab selection and
Escape semantics to commands without interfering with IME. Test all paths with
multiline drafts and hardware keyboard navigation.

### A24 — Make Linux keyboard/help behavior truthful · P2/M · confirmed

Shared `/help` advertises macOS shortcuts/features. Linux history/settings/copy
commands only print apologies; follow-ups are inert text. Return calls `submitOrStop`,
so typing Return during a run can cancel it. The key controller is attached in bubble
phase; verify whether GtkTextView consumes Return first on supported GTK versions.

Generate help from platform capabilities. Add Ctrl-Return submission, a dedicated
Stop shortcut, clickable follow-ups, and clipboard support through GTK. Test the
actual event path with IME, Shift-Return, keypad Enter, and a live run; never let
modifier handling eat normal text editing.

## Visual design and accessibility

### A25 — Stable, inspectable evidence cards · P2/M · confirmed layout behavior

`SourcesView` expands a whole summary on hover, moving neighboring rows. Summary and
“not the full page” disclosure are hover-only; keyboard users cannot reliably inspect
them. Linux shows neither snippets nor this disclosure. Multi-source answer links
open only the first source, and the macOS tooltip string is never attached.

Use explicit disclosure or a fixed-size source inspector. Make source number, domain,
publication date, exact retrieved summary, and “Search summary” visible. Let a grouped
citation expose every source without opening several browser tabs. Test keyboard and
screen-reader access; hovering must not change transcript geometry.

### A26 — Scale the evidence, not just the answer · P2/M · confirmed

`textScale` affects answer Markdown but not the question, findings, most sources,
composer, or controls. `FindingsView` uses an unwrapped HStack for verdict and every
source chip, which can exceed a narrow panel. The composer sizes from a preference,
not its actual clamped window width.

Apply one reading scale throughout meaningful text. Wrap citation chips, allow
summaries/dates to wrap, and derive composer size from actual geometry. Keep small
labels secondary, not essential. Verify minimum width, 140% text, long model names,
long domains, RTL/CJK, 24 cited sources, and a short display.

### A27 — Adaptive contrast and reduced motion · P2/M · GUI verification required

The accent/verdict colors are fixed; tertiary text adds opacity to secondary text,
and the scrim is always black. Linux hard-codes small colored Pango text. Reduced
Transparency skips glass but still selects a visual-effect blur; there is no explicit
opaque fallback. Panel animations and the blinking caret ignore Reduced Motion.

Define light/dark/high-contrast semantic palettes and an opaque reduced-transparency
surface. Observe accessibility changes live. Respect Reduced Motion for panel,
disclosure, and caret. Measure contrast on bright/dark desktop backgrounds and
Adwaita themes; do not assume a semantic foreground rescues a low-contrast scrim.

### A28 — Keyboard-accessible history and status · P2/M · confirmed

History delete is a hover-only nested Button inside an open-thread Button.
Several icon-only controls rely on help text; finding accessibility labels risk
hiding reasoning/chip actions when combined. There is no stable announced live status.

Separate row actions, add labelled context menus and deletion undo/confirmation,
focus history search on open, and restore composer focus on exit. Announce stage
changes, not tokens. Audit VoiceOver and Orca reading order, labels, keyboard focus,
source actions, no-results states, and errors.

### A29 — Make common research output fit · P2/M · confirmed limits

`MarkdownParser` lacks tables and treats either fence marker as closing either kind
of code fence, regardless of fence length. ATX headings ending in a literal `#` can
lose it (`## C#`). Linux inline parsing loses nested emphasis, and code wraps with the
whole label. Comparison questions commonly produce exactly these shapes.

First fix matching fence type/length and heading closer rules with parser tests.
Then add horizontally scrollable compact tables and code-copy actions, preserving
literal citations in code and graceful streaming fragments. Keep renderer feature
parity explicit rather than claiming full Markdown support.

## Product improvements

### A30 — Linux setup and history · P2/L

Add a native setup/settings window over existing stores, with endpoint presets,
explicit Save, masked keys, backend warning, validation, and optional connection test
that says what leaves the machine. Add searchable history, reopen/delete, and thread
export. Do not introduce another persistence format. Test clean install without
secret-tool and with no search key; `/direct` should remain discoverable.

### A31 — Retry the failed stage, not the whole bill · P2/M

Assessment failure currently offers a whole-turn retry. Preserve evidence and answer
and offer “Retry claim check” when safe; use a separate explicit “Research again” for
fresh sources. Snapshot model/settings provenance and state staleness. Test that an
assessment retry makes no search/answer calls and never overwrites a newer answer.

### A32 — A compact evidence lens · P3/M

Click a claim to highlight the sentence it assesses and its sources. Offer “Only
uncertain claims,” a small verdict distribution, and “What would change this answer?”
follow-ups. Use structured claim-to-sentence anchors, not fuzzy string guessing.
Keep contradictions visible; never invent a numerical confidence score.

### A33 — A question preview and research depth · P3/M

Offer explicit Quick/Standard/Deep modes with search caps and model-stage choices.
Let users inspect/edit planned queries before opting into a deep run. Show stage
timing and provider-reported usage, not a fabricated cost estimate. Preserve today's
one-step default; extra control must not make ordinary asking slower.

### A34 — Local-only presets and per-stage models · P3/M

Provide tested Ollama/llama.cpp endpoint presets, model discovery when supported,
context/output limits, and temperature capabilities. Allow a small planning model
and separate assessor. Make direct/local-only versus remote research unmistakable;
local inference does not make remote web search private.

### A35 — Full-page evidence, deliberately bounded · P3/L

Fetch a few decisive pages only with an explicit product/security design: isolated
credential-free transport, SSRF and redirect controls, byte/time limits, MIME checks,
text extraction, untrusted-content delimiters, and provenance. Distinguish retrieved
quotes from search summaries. No arbitrary model-directed browsing or HTML execution.
Test hostile/private-network URLs before optimizing answer quality.

### A36 — Small delights with no extra model call · P3/S–M

- Copy briefly becomes “Copied”; provide Copy answer / Copy with evidence.
- A “Pocket finding” pins one compact claim/source card while working elsewhere.
- “Evidence receipt” exports question, model, date, limitations, verdicts, and sources.
- A reading bookmark returns to the last inspected source, not always the bottom.
- “Challenge this” seeds a disconfirming follow-up, visibly, without auto-sending.
- A quiet finished indicator replaces intrusive completion sounds; make sounds opt-in.

Use existing turn data. Keep animations restrained and accessible; never decorate a
weak verdict to look authoritative.

### A37 — Revisit a question and explain what changed · P3/L

Start with manual “Research again and compare,” not background surveillance. Preserve
the old evidence, label additions/removals/changed verdicts, and separate source churn
from a changed conclusion. Scheduled watches require explicit budget, retention,
provider-disclosure, and notification controls; do not silently re-send old threads.

## Engineering and release work

### A38 — Authentic distribution and bounded updates · P1/L

Developer ID/notarization and update authentication remain prerequisites for a
credible distribution story; ad-hoc updates reset selection permission. Updater
networking bypasses `HTTPTransport`, follows redirects, and size-checks only after
an unbounded download. GitHub downloads legitimately redirect and carry no provider
key, so use a separate bounded, credential-free updater policy rather than forcing
the research transport onto it. Verify signature/Team ID before offering a file.
Add signed Linux repository metadata when an apt channel exists.

### A39 — Fail closed on package dependency discovery · P2/S

`packaging/build-deb.sh` suppresses `dpkg-shlibdeps` failures and emits a minimal GTK
fallback, contrary to documentation promising generated dependencies. This can
publish a package missing dynamic dependencies. Fail packaging instead; preserve
safe diagnostics and test an intentionally unavailable shlibdeps result.

### A40 — Test behavior and keep documentation falsifiable · P2/M

Tests cover many parsers but not the full runner, transport cancellation/deadlines,
GTK lifecycle, or rendering safety. Add injectable clocks/transports at the immediate
service boundary; fixture-driven pipeline tests and a GTK/Xcode GUI smoke matrix.
Run long-thread profiling and accessibility checks in a real desktop session.

Correct concrete overclaims: README's “every claim” versus an eight-finding cap;
“impossible” model URLs versus renderer behavior; source-summary labels “on every
source”; generic MCP support; Linux key precedence; all outbound networking refusing
redirects; and “three workflows” beside a four-row table. Documentation should name
implemented guarantees and limitations, not repeat intent as proof.

## Recommended implementation order

1. A02: strict assessment source numbers; small, portable, testable trust fix.
2. A03: self-contained, honest exports; fixes Copy and Linux CLI together.
3. A21: complete, linear SSE line framing; portable correctness/performance fix.
4. A08: content-free structural diagnostics; small privacy fix.
5. A01/A07/A12–A17: remaining trust/lifecycle work, with dedicated platform tests.
6. A19/A20/A25–A28: reading stability, accessible evidence, consistent visual scale.
7. A30/A31, then the optional evidence-lens and comparison features.

Keep independent patches in independent branches. Record shipped/pending work by ID
when consolidating into `ANALYSIS.md`; remove implemented entries from the actionable
backlog only while retaining their PR pointers and remaining validation requirements.
