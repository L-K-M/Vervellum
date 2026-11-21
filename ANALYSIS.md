# Vervellum research backlog

Codex pass 2026-11-21: reviewed against `origin/main` at `e90efc3`. Four small
fixes from this pass are open in PRs #233 (range citations, A62), #234
(image-retry state, S33), #236 (negative attachment size, A80) and #240 (notice
tones, R03); their implemented slices are annotated in place and are not repeated
here. New findings C01–C07 are appended at the end. Concurrent branches and other
agents' PRs were not inspected during this review.

Codex pass 2026-11-21 (second): reviewed against `origin/main` at `9c3e3d7`. Three
fixes are open in PRs #232 (declared page encodings, A81), #237 (assessment stage
timing, A82) and #248 (fence marker/length matching and the info string, A29).
PRs #235 and #245 additionally cover A80 and A62, which the pass above already
records as #236 and #233. New findings V01–V02 are appended at the end. Concurrent
branches and other agents' PRs were not inspected during this review.

Panel-UX pass 2026-11-21 (Devin): thirteen focused PRs are open — #204
(Reduce-Motion caret), #207 and #202 (submit-key hint; S07 implemented slice),
#211 (history delete confirmation; A28's confirmation slice), #215 (summon
promotes a Settings preview; the visible-panel half of S08), #216 (per-turn
askedAt timestamp), #217 (status menu names the running question), #218 (Latest
jump in finished threads), #222 (edit & re-ask), #223 (attachment preview
popover), #225 (history search-field focus on open; A28's focus slice), #226
(empty-state attachment hint), #227 (status-item elapsed time), #228 (first-frame
provider readiness). Their implemented slices are omitted below; restore the
entry if a PR closes unmerged.

Two further November 21 reviews used `d4c9c1c`. The first reconciled A09, A11a,
A12, A17, A18a, A23, A28, A64, A77e, R03, N01, N03, N06, N10 and N13.
It recorded #200 for source URL userinfo and #205 for panel-header hit targets
as open at review time. Verify the header at the 360-point minimum width and
largest text scale in a GUI session. Each review examined its own PRs.

The second review followed the research evidence through export, history search
and the native panel. The implementation PRs cover
[transcript sources](https://github.com/L-K-M/Vervellum/pull/203),
[history scans](https://github.com/L-K-M/Vervellum/pull/213),
[Reduce Motion](https://github.com/L-K-M/Vervellum/pull/214),
[citation layout](https://github.com/L-K-M/Vervellum/pull/219) and
[deep-round evidence budgeting](https://github.com/L-K-M/Vervellum/pull/221).
If one closes unmerged, restore its acceptance criteria here. A18a is covered by
staged credential edits and cleanup-failure reporting. Keycap now owns Escape in
the recorder, which retires A75c.

The November 4 review was based on `1924f01` and covered changes through #191.
It verified Sol3 heads independently, excluded uninspected parallel work and
flagged #138's proposed code-URL exemption as incompatible with the citation
contract. Earlier context remains in [PR-REVIEW.md](PR-REVIEW.md),
[fable.md](fable.md) and the
[historical analysis](https://github.com/L-K-M/Vervellum/blob/0311b35/ANALYSIS.md).

The nine earlier Sol2 patches passed together: 903 macOS tests with Xcode 26.0.1 on
macOS 15 Intel; the 839-case Linux suite with the display-dependent GTK test
skipped; a release build; eleven loopback provider fixtures; three dependency
discovery tests. Local Xvfb could not initialize XKB. Real VoiceOver, Wayland,
macOS 26 glass/placement and frame-time QA remain unverified.

Answers must not write URLs, bare domains or Markdown links, including in code.
Keep numeric-only citations, sourced evidential verdicts, explicit uncertainty,
answer-before-assessment ordering and visible context trimming. Core stays
Foundation/Dispatch-only without main-actor hops. Keep credentials in the existing
secret stores, foreign errors sanitized, and provider redirects refused.
Decode persisted additions tolerantly and test old archives and lossless round
trips. Fix bugs test-first; profile performance claims before redesigning.

The earlier review treated literal setext headings and paced, non-per-token saves
as deliberate contracts, not defects. Do not change those without an explicit
design decision and the ambiguous table-delimiter regression tests.

Historical scores are mean · user/engineer/designer · effort, not new measurements.
S means local work, M several components, L design work. Estimates are rough.

## Important

### A09 · Describe only the searches that actually ran

Bugs — important

Completed-count ticks, `failedQueries`/`searchFailures` state and an elapsed clock
exist, but per-query outcome is not persisted or shown in detail, and `searches_run`
in the answer context still lists every planned query including failed ones; the
model is told searches ran that did not.

Suggested fix: persist per-query pending/running/succeeded/failed state with safe
(errors-sanitized) messages, per-query elapsed time and contribution; show labeled
success/failure glyphs beside planned queries in the trail; summarize partial
failure as "2/4 succeeded" with an incomplete-evidence notice; pass only successful
searches to the model as run.

Accept: cancellation and archive-migration tests; preserve the current tested
concurrent fan-out and deterministic source numbering. No failed search is described
as successful. Publish stable intermediate evidence and show a compact
Plan → Search → Answer → Assess timeline.

Historical progress options: 8.3 · 9/7/9 · M; live query counts 8.0 · 8/8/8 · S; stage timeline 5.7 · 5/5/7 · S.

Earlier effort: M.

### A11a · Keep neighboring search snippets separate

Bugs — important

EvidenceExtractor can assign overlapping context to adjacent prose result links, making one result appear to support another.

Suggested fix: Partition dense prose into non-overlapping result items; keep each snippet with its own URL.

Accept: Results without blank lines, multiple links, distinct pages and permissive extraction must not fabricate source context.

Where: Sources/VervellumKit/Core/Research/EvidenceExtractor.swift, hits(inParagraph:). Earlier effort: M.

### A12 · Protect unknown history values and explain read-only mode

Bugs — important

Future-version primary and backup guards exist. Unknown Verdict or ResearchStage values within the same version still need loss-preserving handling. History does not visibly explain that a newer archive is read-only.

Suggested fix: Preserve unknown values or refuse writes with a sanitized explanation. Show ThreadStore.isReadOnly in History; do not imply changes will persist.

Accept: Unknown same-version enums cannot silently destroy data. Keep future-version protection with an older backup or history disabled. TurnNotice.unknown is already supported and must not become a decoding failure.

Where: Sources/VervellumKit/Core/Store/ThreadArchive.swift; Vervellum/Views/HistoryView.swift. Earlier effort: M.

### A13 · Finish truthful erasure

Bugs — important

`eraseFailure` is recorded and shown, tombstones prevent resurrection, launch-time
erase runs when history is off, and deleting a thread discards its session. Two clauses
remain: a recorded deletion failure has no retry affordance; and Linux open-session behavior after `deleteAll` still needs an integration test
and an explicit stored-history-versus-active-session retention policy.

Suggested fix: add a retry action to the erase-failure notice (sanitized errors
only); make the open-thread behavior after `deleteAll` match that explicit retention
policy, including late callbacks.

Accept: denied deletion, queued writes, completion after Delete All, and relaunch
with history disabled all end with primary and backup gone or a visible error saying
they are not; a deleted thread never silently resurrects on either platform.

Earlier effort: M.

### A14 · Surface backup failures and verify concurrent archive operations

Bugs — important

Validated backup rotation exists; the private-directory fence is covered by open #125. Backup removal/copy failures are still suppressed, and concurrent erase/flush behavior needs regression proof.

Suggested fix: Report backup/permission failures in application-authored terms. Test failure during recovery, backup rotation and concurrent erase/flush before changing synchronization.

Accept: Recovery followed by a failed write must preserve a usable backup. Read-only archives remain untouched. Keep permission-before-content proof. Current writes use queued immutable snapshots; do not reintroduce the obsolete claim that writeNow reads mutable isHistoryEnabled.

Where: Sources/VervellumKit/Core/Store/ThreadArchive.swift:303–337. Earlier effort: M.

### A17 · Make credential acquisition nonblocking and erasure truthful

Performance problems, stuttering, and jank — important

Desktop subprocesses now have time bounds, but each synchronous lookup can still stall GTK. Locked-keyring UX, failed keyring deletion and actual read-backend reporting remain unresolved.

Suggested fix: Acquire credentials asynchronously through the secret service while retaining process bounds. Report deletion failures and read-only environment overrides. Record which backend answered each account; document the existing JSON file backend and which entry points write it.

Accept: Hung/missing/failing secret-tool, locked keyrings, environment overrides and deletion tests must leave GTK responsive. Keys stay off argv and out of errors/logs. Do not remove an existing file tier without a compatibility decision for its users.

Where: Sources/VervellumKit/Linux/LinuxSecretStore.swift; LinuxPanel.swift. Earlier effort: M.

### A18 · Protect editing shortcuts from global registration

General issues — important

Keycap rejects Shift-only bindings and several system-owned shortcuts. Common editing
chords such as Command-C, Command-V and Command-Z still need a policy, as do
Option-only character chords used for text composition. Make the policy change in
Keycap, release it there, then update the macOS dependency and test the recorder
and stored bindings in Vervellum.

Suggested fix: reject a documented set of protected editing chords before
registration, define the Option-only policy explicitly, and test recorder, stored
preferences, duplicate handling, and Carbon registration together.

### A22 · Absolute provider deadlines and the fixture matrix

Performance problems, stuttering, and jank — important

Non-streaming calls carry a 600 s `timeoutInterval` (deliberately generous: a
non-streaming call is silent until the model finishes, and a local model on a large
evidence block legitimately takes minutes), body reads have a wall-clock check, and
#131 gives credential-free page fetches a true short deadline across redirects. The
remainder is provider-side: streaming exchanges have no exchange-wide absolute
deadline through the response head; the ten-minute check runs only on arriving
chunks and starts after the head, so a stalled or trickling provider exchange can
hold a call far longer than intended. Cheap SearXNG JSON requests also inherit a
model-generation-sized allowance instead of the existing cheap-request budget
(S31). The deadline fixture matrix is still open.

Suggested fix: enforce an independent monotonic per-exchange deadline for provider
JSON and streaming calls that cancels the URL task, running from request start
through the response head and body, while preserving the legitimate
slow-local-model behavior the 600 s interval protects; route cheap SearXNG calls
through the existing cheap-JSON budget helper with cancellation coverage.

Accept: no headers, idle body, trickle-versus-keepalive, cancellation before
registration, early matching MCP response, refused redirects, and producer-cap
fixtures; inject clocks/transport at the service boundary or use loopback fixtures,
never live providers.

Cheap-call location: Sources/VervellumKit/Core/Research/SearXNGClient.swift:123–128. Cheap-budget effort: 2 hours (S31).

Earlier effort: M.

### A23 · Preserve edited drafts during recall and suggestions

Bugs — important

Editing a recalled question must end recall mode; otherwise arrows can replace the edited text. Clicking a follow-up replaces a nonempty draft, while programmatic NSTextView.string assignment does not provide the undo the comment promises.

Suggested fix: Make suggestion replacement reversible or explicitly confirm it. End recall after user edits and use undo-cooperative shouldChangeText/didChangeText updates.

Accept: Cover multiline drafts, edited recalled text, suggestions during runs, undo, keypad/modified Return and CJK composition. Verify hasMarkedText routing before consuming composition-confirming Return. No unintended send or draft/attachment loss.

Where: Vervellum/Views/PanelRootView.swift:1108–1129,1370–1397; ComposerView.swift:133. Earlier effort: M.

### A28 · History keyboard model beyond the Delete control

Usability: speed, convenience, clarity — important

History rows now have separate Open and Delete buttons. Verify their spoken order
and labels. Move focus to the search field on entry and back to the composer on
exit. Add arrow-key navigation, Return to open and keyboard deletion with undo or
confirmation.

Suggested fix: add an undo/confirmation step to history deletion (coordinate with
archive coordination from A13/A15-era work already shipped); manage focus on
History open/close; implement list-key handling in `HistoryView` with ↑/↓/Return
and keyboard Delete.

Accept: VoiceOver/Orca reading order, focus, source actions, errors, and no-results
states; keyboard deletion without hover and with undo; controls reachable at larger
text scale.

Historical navigation score: 8.0 · 8/8/8 · M.

Earlier effort: M.

Escape refinement: while the history query is nonempty, first clear it; only the next Escape closes History. The panel monitor currently intercepts Escape before the responder chain, and backOut cannot see the view-local query. Locations: PanelController.swift:312–324; PanelRootView.swift:1043–1075.

### A35 · Close the page-reader DNS boundary

Bugs — important

Literal private addresses are checked, but a public-looking hostname can resolve into private space. SECURITY.md already records this limitation; bounded page fetching alone does not satisfy the earlier hostile/private-destination acceptance requirement.

Suggested fix: Design a credential-free connection policy that validates resolved destinations and pins the validated address while preserving Host and TLS identity. Revalidate every redirect; a one-time lookup followed by an unpinned URLSession request does not prevent rebinding.

Accept: Preserve the explicit-user-pasted-private-URL policy, byte/time/MIME limits, no script execution and the untrusted-evidence boundary. No broader SSRF guarantee before those tests exist.

Where: Sources/VervellumKit/Core/Research/PageReader.swift; SECURITY.md:98–104. Earlier effort: L.

### A38 · Authenticate distribution and bound update downloads

General issues — important

Releases use ad-hoc signing. Updraft checks GitHub redirect hosts, the completed file's size and an API-supplied SHA-256 digest when available. Its default session has idle and resource timeouts. A transfer can still exceed its expected size before the file is checked. Developer ID signing requires maintainer-owned credentials.

Suggested fix: adopt Developer ID and notarization, verify signature/Team ID before offering an update, and enforce a byte cap during download in Updraft. Preserve its credential-free redirect checks and timeouts.

Accept: never present an unauthenticated artifact as verified. Keep unsigned-release and reset-Accessibility-grant limitations explicit. A future apt channel needs signed repository metadata. Denied-Keychain diagnosis is S23.

Where: release workflows, the pinned Updraft package and Vervellum/App/AppDelegate.swift. Earlier effort: L.

### A63 · Redact pasted text

Bugs — important

Only Accessibility-captured text is redacted; ⌘V goes straight through the composer,
and a `.env` line pasted in a hurry is exactly the case `SecretRedactor` exists
for.

Suggested fix: route paste through the same redaction and the same banner as the
selection path, building on A07 (redact before truncation, before display); keep
plain prose untouched.

Accept: a pasted key is replaced and the banner names the count; redaction is
visible before Return, never applied silently on send; no false positives beyond
`SecretRedactor`'s documented conservative bias.

Earlier effort: S.

### A77 · Return activation after alerts

Bugs — important

Update and Accessibility alerts activate the agent and do not reliably hand activation back. The update alert defaults to Download.

Suggested fix: Keep background update discovery nonmodal; use modal interaction only for explicit Check now and yield activation afterward.

Accept: An alert must never leave Vervellum frontmost without a window.

Where: Vervellum/Updates/UpdateChecker.swift; Vervellum/App/AppDelegate.swift. Earlier effort: M.

### A77b · Refresh the remembered foreground application

Bugs — important

The restore target is captured only on the first show. Clicking through another app while the panel stays open leaves it stale.

Suggested fix: Refresh the target when the panel yields key status to another application.

Accept: Escape returns focus to the app actually left, without unrelated activation changes.

Where: Vervellum/Panel/PanelController.swift:104–109,338–360. Earlier effort: S.

### A77e · Keep selection lookup off the summon path

Performance problems, stuttering, and jank — important

AX selection reads can block the main thread through multiple messaging timeouts before the panel appears.

Suggested fix: Set a short AX messaging timeout, show the panel first and deliver the selection later through the existing platform callback.

Accept: A hung foreground app delays the selection, not panel interaction. Preserve opt-in capture, redaction-before-display and no automatic submission.

Where: Vervellum/Selection/SelectedTextReader.swift; Vervellum/App/AppDelegate.swift. Earlier effort: M.

## Nice-to-have

### A06 · Reserve model output in stage budgets

Bugs — nice-to-have

Input budgeting now charges attachments and rejects an impossible combined answer
context before planning, but stage prompt assembly can still consume the model's
whole context allowance without reserving measured space for the generation itself.
A provider may therefore truncate or reject an otherwise valid planning, answering,
assessment, or revision request.

Suggested fix: define a measured output reserve for each generation stage, subtract
it from the stage's available input budget in `ResearchContext`, and cover exact
boundaries, Unicode, long history, and zero-history cases without silently cropping
current input.

### A07 · Carry capture redaction and truncation metadata

Bugs — nice-to-have

`SelectedTextReader.trim` reduces selection capture to a bare `String`, so the
composer cannot distinguish ordinary input from an Accessibility value that was
length-capped or changed by `SecretRedactor`, and redaction still sees only the
already-trimmed text. The user therefore cannot tell which safety transformation
occurred, while future redaction rules must reason about shortened input.

Suggested fix: return a capture result that carries truncation and redaction
metadata, redact the bounded captured value before display truncation, and show a
concise composer notice without changing the opt-in, never-auto-submit, never-log
behavior.

### A10 · Provider and MCP capability remainder

General issues — nice-to-have

Known-operation MCP tool resolution, schema-backed SearXNG/Kagi and the remembered
optional-parameter retry exist. Remaining: bounded `tools/list` pagination
(`nextCursor`); argument validation checks names only; type and enum checking
against the advertised schema is still missing; explicit user-selected/recognized operation support; never infer safe operations
from descriptions or a query-shaped schema. Provider presets belong to A34,
search-count settings to A33, image fallback to S33.

Suggested fix: paginate tool discovery with a bound; validate argument types/enums
against the fetched schema in `SearchBackend.validate`; require explicit operation selection before supporting an unknown MCP tool.

Accept: real-shaped fixtures for tool pages, schema, types/enums, temperature and
vision capabilities without live keys; product claims broaden only after support
exists.

Historical explicit-adapter score: 8.3 · 9/9/7 · S.

Earlier effort: M.

### A18b · Preserve unsaved provider-pane edits

Usability: speed, convenience, clarity — nice-to-have

ProvidersView.load runs on every onAppear and clears pending key entries, deletions and catalogues. Tab-switch loss remains a GUI hypothesis until reproduced.

Suggested fix: Load once per presentation, or preserve and explicitly resolve dirty edits before reloading.

Accept: Type an endpoint/key, switch panes and return; verify retention and cancellation without touching real secrets.

Where: Vervellum/Settings/ProvidersView.swift:204,536–549. Earlier effort: S.

### A18c · Reload Linux settings and expose persistence failures

General issues — nice-to-have

The settings store preserves sequential external edits, but cached reads do not live-reload. A damaged or unwritable settings file is reported only on stderr; unsaved in-session changes are not a successful disk save.

Suggested fix: Expose reload/validation and persistence-error state through the settings service, for example on window focus. Apply valid settings without requiring A30's form first; keep externally repaired JSON authoritative and preserve unreadable bytes.

Accept: Read-only files and external edits must not produce false saved-state claims. No second settings file. Environment-key overrides remain explicit.

Where: Sources/VervellumKit/Core/Platform/SettingsStore.swift; Sources/VervellumKit/Linux/LinuxEnvironment.swift:141. Earlier effort: M.

### A20 · Streaming render reuse remainder

Performance problems, stuttering, and jank — nice-to-have

Coalescing, Equatable turn views and SelectableText exist. The Linux renderer preserves
GTK widgets during answer-only growth; stage, source and notice changes still
rebuild the thread. Native MarkdownBody still parses the growing answer per
evaluation, and composer measurement repeats when its inputs have not changed.

Profile a stream containing tables, code and grouped citations with older turns visible. Record main-thread time and snapshot count. Preserve code masking when reusing completed blocks.

Suggested fix: Profile block-level parsing reuse, terminal GTK row identity and
measurement memoization. Measure queue depth before pre-enqueue coalescing, and
repeated Source.domain parsing before caching with correct URL invalidation.

Accept: 50-turn threads, variable-height AppKit rows, long pastes and bursty
streams retain responsive Stop, stable selection, exact final text and bounded
queues. Dispatch stays in front ends, never MainActor in Core.

Where: Vervellum/Views/ComposerView.swift:161–173; PanelRootView.swift:428;
Sources/VervellumKit/Linux/LinuxPanel.swift:547–561,628–630. GTK follow-up: 1 day
(S13); measurement: 2–3 hours (S14). Historical cache/tail-renderer options:
6.0 · 7/5/6 · S; 4.7 · 5/4/5 · M; GTK reuse 5.0 · 5/5/5 · M;
measurement 4.3 · 4/5/4 · S. Earlier effort: M.

### A23a · Complete commands with Tab and broaden recall

Usability: speed, convenience, clarity — nice-to-have

Arrow completions exist. Tab acceptance and shell-style recall across saved threads remain proposed.

Suggested fix: Accept a visible slash completion on Tab. Offer newest-first, deduplicated cross-thread recall with the draft restored on exit; recall seeds, never sends.

Accept: Do not conflict with IME or A65's Tab-to-actions traversal. Preserve edited text and attachments.

Historical completion score: 6.0 · 6/6/6 · S.

### A23b · Restore the draft and open thread after relaunch

Missing features — nice-to-have

A dismissal preserves the draft, but quit/crash/relaunch does not restore the draft and selected thread.

Suggested fix: Persist draft plus open-thread identity through existing preferences/archive metadata, with a clear history-off privacy policy.

Accept: Never resurrect deleted threads or silently send restored drafts. Preserve attachments only under their existing retention policy.

Historical score: 6.3 · 7/6/6 · S.

### A24 · Linux IME routing and a Stop shortcut

Usability: speed, convenience, clarity — nice-to-have

Return-never-cancels, stopped/retry feedback and preference-sensitive submit hints
exist. Clipboard, follow-up links and waiting questions are covered by #151–#153;
platform help by #143. Remaining: route IME confirmation before consuming Return
and provide a dedicated local Stop shortcut.

Suggested fix: Verify gtk_text_view_im_context_filter_keypress routing and add the
local shortcut without an in-process global grab. Keep help accurate.

Accept: Real GTK IME confirmation, Shift-Return, keypad Enter, drafts and live runs;
no unintended send, cancellation or unrelated editing-key interception. Quit is A76.

Earlier effort: M.

### A25 · Evidence card stability and grouped sources

Visual issues and layout problems — nice-to-have

The `SourcePreview` popover with its permanent summary/page-read caveat and
domain/date rows exists. Remaining: revealing a summary still changes row height,
moving later sources under the pointer and hiding the summary from keyboard users
(S19; explicit disclosure or a stable-size inspector, with keyboard activation);
a grouped citation `[2, 5]` opens or exposes only the first source; expose every
grouped source (one chip per number is the smaller change, B86); opening several
tabs must never be an implicit group action.

Suggested fix: fixed-height rows with explicit disclosure; keyboard-activatable
preview; per-number chips that each resolve to their own source. Show the browser
glyph on keyboard focus, not only hover. Put the snippet/caveat in the accessibility
value and a permanent summary/page-read tag beside the number.

Accept: keyboard and screen-reader inspection of every source's domain, date,
snippet and "Search summary; not the full page" caveat; hover never changes
transcript height; group citations expose all members; the app-owned numbered-citation
rule is preserved.

Where: Vervellum/Views/SourcesView.swift:181–197. Effort: half a day (S19). Historical score: 7.7 · 7/7/9 · S.

Earlier effort: M.

### A26 · Verify the remaining narrow-panel layouts

[Claim card wrapping](https://github.com/L-K-M/Vervellum/pull/219) covers the
verdict and citation buttons. Check the remaining label combinations on short
displays at minimum width and 140% type, including long model, domain and date
strings, RTL and CJK text. Capture the failing layout before changing it. Every
essential label and action should stay readable and reachable. Historical B87/S20
estimate for evidence wrapping was half a day.

### A27 · Measured contrast and live accessibility observation

Aesthetics and theming — nice-to-have

Themeable palettes, semantic text colors and some Reduce Motion routes exist. Remaining: current presets need fresh contrast measurements. Earlier estimates were about
2:1 for compounded tertiary text and 2.3:1 for #FF8A4C on a light ground, not fresh
measurements of every current theme. Verdict-colored sentences also need checking. Pango's fixed secondary #7a7a7a
(PangoMarkup.swift:25) may miss contrast on dark Adwaita; this is unmeasured.
Evaluate theme-derived foreground alpha, not another fixed compromise.
Verify an opaque Reduce Transparency fallback, not merely the absence of Liquid
Glass, and observe transparency changes live. [Panel Reduce Motion changes](https://github.com/L-K-M/Vervellum/pull/214)
cover the writing caret, source hover and Latest overlay. Verify the live setting
with a running answer and VoiceOver.

Suggested fix: measure presets in light/dark/high-contrast and correct failures
with semantic or scheme-aware colors; observe accessibility changes live and check each preset against rendered content.

Accept: measured contrast over bright/dark content and Adwaita themes in both
appearance schemes; live Reduce Transparency/Reduce Motion switches; meaning stays
readable without color; GUI QA before claiming any aesthetic improvement.

Where: Vervellum/Views/PanelTheme.swift:171–174; TurnView.swift:228–241,264,341; PanelRootView.swift:300,334. Effort: contrast 1 day (S24), motion half a day (S25). Historical contrast: 8.3 · 8/8/9 · S; motion: 8.0 · 7/9/8 · S; scheme tuning: 6.7 · 6/6/8 · S.

A November 21 hosted FindingsView sample at 360 points and 140% text gave a
maximum glyph-to-background contrast of 3.83:1 for the small “CLAIMS” heading,
6.88:1 for “MIXED”, 11.14:1 for the claim and 6.14:1 for its explanation.
These are sampled bitmap pixels converted to sRGB, including antialiasing, on one
opaque dark window background. Start with the heading when measuring the resolved
foreground and background colors across the actual panel presets.

Earlier palette notes: mixed about 2.1:1 and supported about 2.9:1 on light grounds; Linux used #c4630f, #217a4a and #9a6a10 as candidate light-safe hues. Also inspect dark card contrast, a light-mode scrim and an opaque reduced-transparency tint. These are historical estimates/design hypotheses, not fresh measurements.

Earlier effort: M.

### A29 · Match Markdown fences and complete code-block actions

Visual issues and layout problems — nice-to-have

Tables, ATX closing-sequence handling and literal citations in code exist. Fences
still close on a three-backtick or three-tilde prefix without matching the
opener's marker and length. Native code already scrolls horizontally; Linux
long-line handling and code-copy actions remain.

Suggested fix: Track the opening marker/length; a closer needs the same marker,
at least that length and only trailing whitespace. Keep an unterminated remainder
as code through end-of-stream. Add code-copy actions and Linux long-line handling
where absent, preserving the native scroll view.

Accept: Mismatched, shorter/longer and nested fences; incomplete streaming prefixes;
long lines. Align render/parser and citation-code masks. No dependency or HTML
renderer. Pango nested emphasis is A29a; range citations are A62.

The fence half is implemented in open PR #248 (the opener's marker and run length
are carried; a closer needs the same marker, at least that length and only trailing
whitespace; the info string follows the whole opening run). Code-copy actions and
Linux long-line handling remain. Restore the fence half if that PR closes unmerged.

Earlier effort: M.

### A29a · Parse Pango bold-italic delimiter runs correctly

Bugs — nice-to-have

The Pango parser tries `**` before `*`, so `***bold italic***` can pair the wrong run, producing bold literal stars and a trailing asterisk. Native macOS inline Markdown is unaffected.

Suggested fix: Count delimiter runs or prefer the longest delimiter at a shared position. Verify other nested Linux emphasis, not merely emphasis across citations.

Accept: Keep untrusted text escaped and incomplete streaming constructs readable.

Where: Sources/VervellumKit/Linux/PangoMarkup.swift:252–290.

### A30 · Native Linux setup

Missing features — nice-to-have

Linux still needs a settings/setup window: presets, masked keys, explicit Save,
backend warnings, validation, optional connection checks with provider disclosure,
and a user-chosen summon accelerator through setup/CLI.

Suggested fix: Build over LinuxEnvironment, SettingsStore, SecretStore and
ThreadArchive. Reuse A17/A18; do not introduce another format or store.

Accept: Clean install without secret-tool, unavailable keyring, no search key,
/direct discovery and settings reload work. Backends identify themselves through
backendDescription. Preserve manually changed desktop bindings unless explicitly
replaced. Basic history is covered by #154; search is A30a and export A46.

Historical Linux UI parity: 6.0 · 6/6/6 · M. Earlier effort: L.

### A30a · Search the Linux history list

Missing features — nice-to-have

The GTK panel can list, reopen and delete saved threads. Add a search field using the shared core matcher.

Suggested fix: Add GTK filtering over ThreadLibrary.search, preserving detached
session identity and the result completeness required by R06.

Accept: Empty, no-results, live/detached and read-only threads remain navigable.
No duplicate writers or second archive format; keep any README parity claims
scoped until this exists.

### A31 · Retry only the failed claim check

Missing features — nice-to-have

The `assessmentUnavailable` failure path and deep auto-regather exist. Remaining:
an explicit "Retry claim check" action that retains the answer and evidence and
makes no search or answer calls; snapshot settings/model provenance and label stale
evidence; retry lineage so an old failed row does not keep offering duplicate
retries; distinguish a consumed retry from an intentional new research request; ⌘R
for the eligible failed turn, coordinated with the existing Ask Again action.

Suggested fix: a runner-level assessment-only retry entry point driven from the
failure card and turn row, with provenance and lineage recorded on the turn.

Accept: assessment retry makes no search/answer calls, never overwrites a newer
answer, and preserves failure context; old-row retry state stays correct after
append/reload.

Where: Sources/VervellumKit/Core/Research/ResearchSession.swift:190–231; Vervellum/Views/TurnView.swift:205–212. Effort: 1–2 days (S15).

Earlier effort: M.

### A32 · Evidence lens

Novel, delightful, or quirky ideas worth trying — nice-to-have

Click a claim to highlight its assessed sentence and sources; offer uncertain-only
filtering. Use structured sentence anchors, not fuzzy matching. Add the reverse
direction (S26): selecting a source reveals its citing sentences through a pure
index over existing numeric citations, without a model call or confidence score.
The distribution bar is A60b; counter-evidence follow-ups are A36d.

Suggested fix: Persist auditable sentence anchors at assessment time and build
the reverse citation index from validator output.

Accept: Contradictions stay visible; associations are auditable. Start from A25's
accessible source inspector.

Where: Sources/VervellumKit/Core/Research/CitationValidator.swift;
Vervellum/Views/SourcesView.swift. Reverse index: 1 day (S26). Historical
claim/prose linking: 6.7 · 7/4/9 · M. Earlier effort: M.

### A33 · Research depth remainder

Missing features — nice-to-have

Research/direct/deep/agent levels, search caps, the picker, cost lines and
level-honoring retry exist. Remaining: query inspection/editing for an opted-in
deep run; provider-reported usage; evaluate `stream_options: {include_usage:
true}` behind explicit provider capabilities (verify z.ai support; do not assume
every compatible gateway ignores unknown parameters); surfaced measured timings
beyond the trace; expose a bounded searches-per-question setting instead of only
the ResearchRunner.maxSearches constant.

Suggested fix: an editable plan step for deep runs gated on explicit opt-in;
usage-frame parsing behind a capability flag; timings summarized in the trail.

Accept: default asking stays one step; caps are enforced; extra calls require
explicit depth selection; unsupported/absent/malformed usage frames are tested and
missing counts are never estimated as measured; usage-only frames never alter
answer completion.

Historical presets/search-count option: 5.3 · 6/5/5 · M; usage meter: 5.0 · 6/4/5 · M.

Earlier effort: M.

### A34 · Provider presets and per-stage models

Missing features — nice-to-have

Model discovery via `/models`, the picker and the image capability flag exist.
Remaining: verified Ollama/llama.cpp compatibility, per-profile context/output
limits and temperature capabilities; endpoint presets for OpenAI, z.ai, OpenRouter,
Groq, Ollama, LM Studio and llama.cpp (plus bearer-auth gateways where tested);
separate planner and assessor models.

Suggested fix: preset list in ProviderSettings feeding the endpoint/model fields;
per-stage model selection plumbed through the runner's client construction.

Accept: local-only/direct versus remote research is unmistakable; local inference
never implies remote web-search privacy; reuses A10/A30 capability work.

Historical presets: 6.3 · 6/7/6 · S; per-stage model choice: 6.3 · 6/7/6 · S.

Earlier effort: M.

### A35a · Read a chosen page and recheck its evidence

Missing features — nice-to-have

Automatic bounded reading exists, but the earlier high-ranked idea also proposed a user-selected source fetch followed by re-assessment.

Suggested fix: Offer an explicit read/recheck action over the existing reader and assessment services, without arbitrary model-written browsing.

Accept: Disclose the extra calls. Preserve source numbering, snippet/page-text provenance, budgets and cancellation. A fetched page is marked read only if its text reached the model.

Historical score: 9.3 · 10/8/10 · L.

### A36 · Confirm successful Copy and offer copy formats

Novel, delightful, or quirky ideas worth trying — nice-to-have

Copy has no success feedback. Earlier ideas also requested answer-only, evidence-inclusive and paragraph-with-resolved-sources copies.

Suggested fix: Show a brief accessible Copied receipt only after successful pasteboard write; offer formats over TranscriptFormatter and explain an empty answer-only copy.

Accept: Keep failed/stopped state and app-owned source definitions in evidence-inclusive output.

Where: Vervellum/Views/TurnView.swift:191–200. Feedback effort: 1–2 hours (S28). Historical copy options: 6.3 · 7/6/6 · M; paragraph copy 6.0 · 6/5/7 · S.

Earlier effort: S–M.

### A36a · Pin a pocket finding

Novel, delightful, or quirky ideas worth trying — nice-to-have

A compact claim/source card could stay visible while the reader works elsewhere.

Suggested fix: Prototype a user-pinned card from existing turn data without another model call.

Accept: Keep the verdict, citation and limitations together; never imply a numerical confidence score.

Earlier effort: S–M.

### A36b · Export an evidence receipt

Novel, delightful, or quirky ideas worth trying — nice-to-have

A shareable receipt should preserve question, model, date, verdicts, limits and sources.

Suggested fix: Offer a receipt format over the same complete export machinery as A46.

Accept: Use existing turn data; retain incomplete/failure labels and unambiguous per-turn sources.

Earlier effort: S–M.

### A36c · Remember the last inspected source

Novel, delightful, or quirky ideas worth trying — nice-to-have

Readers lose their place when returning from a source inspection.

Suggested fix: Keep a session reading bookmark. Persist scroll offsets only after user evidence justifies that behavior, since reopened threads often target the newest answer.

Accept: Do not let streaming or layout changes override deliberate reading position.

Earlier effort: S–M.

### A36d · Seed a counter-evidence follow-up

Novel, delightful, or quirky ideas worth trying — nice-to-have

A finding has no quick Ask about this claim, Challenge this or What would change
this answer seed.

Suggested fix: Seed a disconfirming question without auto-sending it or destroying an existing draft.

Accept: Reuse the claim and its originating turn's source context; never rebind old
citation numbers to a new evidence list. Add no model call until the user submits.

Where: Vervellum/Views/TurnView.swift:292–320; PanelRootView.swift:1108. Effort: half a day (S27).

### A36e · Notify quiet Linux completion

Novel, delightful, or quirky ideas worth trying — nice-to-have

A hidden Linux window has no optional completion signal. The macOS status glyph already exists.

Suggested fix: Offer a generic opt-in desktop completion notification, not an answer-text banner.

Accept: Never leak answer text on the lock screen or steal focus; do not duplicate the Mac signal.

Earlier effort: S–M.

### A36f · Show a restrained planning cue

Novel, delightful, or quirky ideas worth trying — nice-to-have

Planning may remain silent while a non-streaming model works.

Suggested fix: Try an optional indeterminate cue with a static Reduce Motion alternative.

Accept: Never invent an ETA or animate individual streamed blocks.

Earlier effort: S.

### A36g · Use the planner reading as a thread subtitle

Novel, delightful, or quirky ideas worth trying — nice-to-have

A completed first turn's existing reading can be more useful than a truncated question title.

Suggested fix: Reuse that text for a title/subtitle after the first turn, without another model call.

Accept: Preserve user-assigned titles and incomplete-state labels.

Historical score: 7.0 · 7/7/7 · S.

### A36h · Badge disputed findings

Novel, delightful, or quirky ideas worth trying — nice-to-have

A collapsed trail hides whether any finding is mixed or contradicted.

Suggested fix: Add a compact disagreement badge whose tooltip/accessibility label names the affected claim or count.

Accept: Use existing verdicts; do not portray all-supported findings as a truth seal.

Historical score: 6.3 · 6/6/7 · S.

### A36i · Style the summary-only caveat as an evidence cue

Novel, delightful, or quirky ideas worth trying — nice-to-have

The snippet-versus-page distinction could be easier to scan.

Suggested fix: Try a small magnifier chip while keeping the written summary/page-read caveat accessible and accurate.

Accept: Only text actually sent to the model earns page-read styling.

Earlier effort: S.

### A37 · Compare research across time

Novel, delightful, or quirky ideas worth trying — nice-to-have

The earlier backlog's comparison feature remains unimplemented. Start with manual research-again-and-compare, preserving old evidence, source additions/removals, changed verdicts, source churn and changed conclusions.

Suggested fix: Build an auditable ResearchDiff first. Consider scheduled watches only afterward, with explicit budgets, retention, provider disclosure and notification controls.

Accept: Never silently resend old threads or present a refreshed source list alone as a changed answer.

Earlier effort: L. Historical options: watch 5.3 · 5/5/6 · M; comparison strip 4.7 · 5/4/5 · M.

### A40 · Documentation and release-gate drift remainder

General issues — nice-to-have

Verified drift remains across documentation and release automation. `CICD.md` names
a nonexistent `glm-review.yml` trigger instead of the single
`zai-code-review.yml` review workflow, and describes three release assets although
releases publish four including Flatpak. The tag workflow runs shared tests but skips
the provider fixtures, GTK lifecycle check, and desktop validation used by ordinary
Linux CI; it installs `desktop-file-utils` without invoking it, while `linux.yml`
does not run for tags. README still hard-codes `0.1.0` outside the release marker
and leaves Linux scope ambiguous for search and Up/Down recall. `PRIVACY.md`
misstates the update User-Agent and omits Linux stderr logging. Remaining Markdown
emphasis claims, erase-backup fixture claims, and the ICON-CREDITS SF Symbol inventory
also need reconciliation against code.
Launch-with-history-off already covers backup creation and should not gain a
duplicate regression.

Suggested fix: update each document to the behavior that exists, share or reproduce
the complete Linux verification gate in the release workflow, validate every stated
test against a failure it can actually catch, and keep the published asset inventory
in step with release automation.

### A43 · Bounded transient retry remainder

General issues — nice-to-have

The multi-provider fallback chain with attribution and Stop respect exists.
Remaining: at most one bounded same-provider backoff retry for transient
planning/assessment failures (rate limits, dropped connections); streamed answers
stay fail-fast; blind replay duplicates prose and charges; injected-clock tests
for retryable-versus-permanent classification and attempt limits; cancellation
during backoff; an offline gate before spending a call; a 429 `Retry-After`
countdown instead of a bare "try again"; classify only sanitized status/transport
outcomes, never provider error text.

Suggested fix: a retry policy beside the fallback chain with an injected clock and
visible retry progress.

Accept: retry progress and any additional provider calls stay visible; no
automatic streamed-answer replay.

Historical network-state score: 5.7 · 6/5/6 · M.

Earlier effort: M.

### A44 · Machine-readable CLI output

Missing features — nice-to-have

Add `vervellum --json` with a versioned output contract: question, answer,
findings, sources, notices, completion/failure state, and partial output. Keep
progress on stderr and JSON alone on stdout (`StandardErrorLog` already anticipates
the split). Mirror the transcript's completion rules: a failed turn keeps its
partial text beside a failure state; a stopped one is marked stopped.

Suggested fix: a portable transcript encoder in Core shared by the CLI and the
transcript formatter.

Accept: success, direct, partial failure, cancellation, Unicode, and empty-result
fixtures parse as one document with a meaningful exit status; keys and foreign
errors are never serialized.

Historical score: 6.0 · 6/6/6 · S.

Earlier effort: M.

### A45 · Escape the revoked-selection-grant loop

Usability: speed, convenience, clarity — nice-to-have

The prompt explains the ad-hoc re-signing revoke. Remaining: a remembered "Open
without selection" fallback after grant loss or denial, until the user chooses
selection again; never re-prompt on every summon and never silently request
Accessibility. A38 is the signing fix, not an excuse to trap the user in alerts.

Suggested fix: a preference-backed fallback mode offered from the existing alert,
keeping the summon path itself permission-free.

Accept: revoked/denied/restored grants, subsequent summons, and preference resets
are predictable; no captured text is sent or retained by the fallback.

Earlier effort: S.

### A46 · Export a whole research thread

Missing features — nice-to-have

Whole-thread Markdown export through ⌘S and `NSSavePanel` (activate the agent
before showing the save panel; restore focus afterward), plus Linux UI/CLI exposure
(S17; multi-turn researchers can copy turns but cannot save a coherent thread).
Export questions, evidence, findings, limitations and per-turn completion state;
numbered sources must stay unambiguous across turns, with `[n]: url` reference
definitions written by Vervellum from the list it owns. Copy-one-citation,
copy-a-code-block and ⌘⇧C for the last answer ride the same formatter.

Suggested fix: a thread-level pass over `TranscriptFormatter` with per-turn source
numbering, exposed through a save panel and the Linux CLI.

Accept: multi-turn source-number collisions, failures with partial prose,
non-ASCII paths, cancellation, denied writes, and history disabled; export only on
explicit request; existing archive and secret-store boundaries untouched.

Where: Sources/VervellumKit/Core/Text/TranscriptFormatter.swift; Vervellum/Views/TurnView.swift:189–200. Effort: 1 day (S17). Historical export: 7.7 · 7/7/9 · S; last-answer copy: 4.7 · 5/4/5 · S.

Earlier effort: M.

### A47 · `/digest` brief from unsettled claims

Missing features — nice-to-have

Produce a brief from the current thread's unsettled claims without new searches.
Label it "No fresh search"; a thread summary, not a new evidence check. Preserve
uncertainty and per-turn provenance; old citation numbers must never bind to a
different turn's sources.

Suggested fix: a shared command dispatching to the existing context assembly and a
summarizing model call over the current thread only.

Accept: no-search execution; empty and no-unsettled-claim threads; context
trimming; source-number collisions; cancellation; the summarizing call is
disclosed; other threads are never re-sent and A06's budgets are not bypassed.

Earlier effort: M.

### A48 · Reasoning-stage progress

Missing features — nice-to-have

`delta.reasoning_content` can precede `delta.content` for tens of seconds (GLM-5,
DeepSeek-R1, o-series through gateways) and is currently unhandled; the trail
shows dead air. Count it as progress with a phase/activity indicator; optionally
offer collapsed provider-supplied reasoning intended for display. Never confuse
reasoning with the final answer or treat it as retrieved evidence.

Suggested fix: parse reasoning deltas in `ChatCompletionsClient.streamText` behind
the existing progress plumbing, without altering content parsing or empty-answer
detection.

Accept: reasoning-only prefixes, mixed deltas, normal models, cancellation, and
non-streaming replies with both reasoning and content; new persisted progress or
reasoning fields decode tolerantly so older archives load; fixtures first, then a
live compatible model before shipping optional display.

Earlier effort: M.

### A49 · Pin the Linux CI image as documented

General issues — nice-to-have

`linux.yml`'s comment claims a digest pin, but the job uses the mutable
`swift:6.1-noble` (S11). Pin an explicit tested digest and document the refresh
cadence, or remove the claim.

Suggested fix: pin the image by digest; record the refresh policy beside it.

Accept: workflow metadata agrees with the actual image reference; deliberate
refreshes run build/tests/package/install checks before adoption; pins receive
security updates rather than becoming stale snapshots; Swift language-mode parity
across platforms is preserved.

Where: .github/workflows/linux.yml:28–32. Effort: 1–2 hours (S11).

Earlier effort: S.

### A50 · Rename threads and delete individual turns

Missing features — nice-to-have

Stable user titles instead of truncated first questions; remove a wrong turn
without deleting the whole thread; undo/confirmation; coordinate active-turn
cancellation, queued snapshots, read-only archives and history-off behavior.

Suggested fix: `ResearchThread`/`ThreadLibrary` operations with tolerant optional
title decoding, exposed in both UIs.

Accept: rename/reload, empty or Unicode titles, deleting first/middle/active
turns, undo, and denied writes; retained turns keep their own citation/source
associations.

Historical pin/rename option: 5.0 · 5/5/5 · M.

Earlier effort: M.

### A51 · Safe external ask entry point

Missing features — nice-to-have

Support `vervellum://ask?q=…` from Shortcuts, Alfred or bookmarklets. Incoming URLs
are untrusted input: bound and validate decoding, redact captured content, and seed
an inspectable composer rather than silently sending to a provider. Do not accept
arbitrary commands, provider reconfiguration, credentials, or raw shell execution.

Suggested fix: URL registration routing into the existing seed-the-composer path
behind the same redaction/metadata rules as selection.

Accept: encoded Unicode, malformed/oversized URLs, repeated activation, and drafts
in progress; the incoming query is never logged; summon/focus behavior preserved;
any auto-submit automation needs a separate explicit consent design.

Historical Services/URL entry option: 5.7 · 6/5/6 · M. A Linux ask GApplication action was also proposed.

Earlier effort: M.

### A52 · `/clip` redacted clipboard capture

Missing features — nice-to-have

Read the clipboard only on the explicit command; seed the composer through the same
redaction/metadata path as selection (builds on A07: redact before truncation and
before display); preserve the existing draft or make replacement reversible without
putting unredacted captured text into undo history.

Suggested fix: a platform clipboard abstraction behind the command dispatch,
feeding the shared capture/redaction path.

Accept: secrets/PEMs, oversized or non-text clipboard contents, active runs, undo,
and visible truncation/redaction notices; never auto-send, poll the clipboard, log
captured text, or replace the user's clipboard contents.

Historical score: 7.7 · 8/9/6 · S.

Earlier effort: M.

### A53 · Recent threads in the status menu

Usability: speed, convenience, clarity — nice-to-have

Expose a bounded list of recent titles (five was the earlier proposal) with reopen actions, coordinated with the
status glyph, renamed titles and active research. Makes history reachable from the
app's persistent surface.

Suggested fix: a status-menu section over the existing thread store.

Accept: empty/disabled history, deleted/renamed threads, keyboard menu navigation,
and a run in progress; reopening never discards a draft or silently interrupts
research; archive access stays behind the store.

Earlier effort: S.

### A54 · Failure card with the right next action

Usability: speed, convenience, clarity — nice-to-have

The failure card still offers only "Try again", which re-runs the identical
pipeline. Put "Answer without search" and "Open Settings…" on the card, driven by a
small `failureKind` enum on the turn (`search`, `model`, `configuration`, `other`)
rather than by parsing the message; give the Linux card the same actions where the
platform has the feature.

Suggested fix: classify failures at the runner boundary and drive card actions from
the enum.

Accept: each failure class shows the matching action; Try again still re-asks in
the original mode.

Historical score: 7.0 · 7/7/7 · S.

Earlier effort: S.

### A55 · Full test-connection check

Missing features — nice-to-have

"List this provider's models" gives one cheap sanitized call (S16 is the broader
ask). Remaining: pair it with the MCP handshake check so quota-versus-bad-key
errors are distinguishable; cancellable semantics with the button disabled while a
test runs; point the empty state at the check; disclose exactly what leaves the
machine.

Suggested fix: a Settings-side orchestrator running the same two cheap calls the
runner starts with, reporting Vervellum-authored sentences.

Accept: wrong path, wrong model, bad key, quota error and success each produce a
distinct sanitized sentence; no provider text is shown.

Where: Vervellum/Settings/ProvidersView.swift:594–650. Effort: 1 day (S16). Historical score: 8.7 · 9/9/8 · M.

Earlier effort: S.

### A56 · "Verify this claim"

Novel, delightful, or quirky ideas worth trying — nice-to-have

A per-finding action that plans two searches aimed at that claim (one to confirm,
one to disconfirm), appends new sources with continuing numbers, and re-grades only
that claim; turning an `insufficient` verdict from a dead end into a next step.
Sequential with the rest of the pipeline; budgets from A06.

Suggested fix: a per-finding stage in the runner over the existing plan/search/grade
machinery.

Accept: the re-graded finding shows its new verdict and sources without touching
the others; cancellation mid-verify leaves the original finding; numbering never
collides with the turn's existing sources.

Historical score: 8.3 · 9/7/9 · M.

Earlier effort: M.

### A57 · One-line evidential summary per turn

Usability: speed, convenience, clarity — nice-to-have

`✓ 4 searches · 17 sources · 6 claims: 4 supported, 1 mixed, 1 not established ·
0:41`; one Core formatter shared by the macOS trail, the Linux trail, the CLI and
the transcript, instead of the two half-implementations that exist separately.

Suggested fix: a single formatter in Core shared by all four consumers.

Accept: identical text on both platforms for the same turn; cancelled and failed
turns say so in the same line; pluralisation is tested.

Historical score: 7.3 · 7/7/8 · S.

Earlier effort: S.

### A58 · `/sources` evidence-only mode

Missing features — nice-to-have

Plan and search, show the numbered source list, skip answer generation and assessment, not the planning call.
Persisted as a turn with an empty answer and a notice, so history and the
transcript stay honest.

Suggested fix: a `Mode.sourcesOnly` path in the runner behind the existing command
dispatch.

Accept: no answer or assessment call is made; the turn renders its sources and "no
answer was requested"; a follow-up in the thread does not treat it as an answer.

Historical score: 4.3 · 4/4/5 · S.

Earlier effort: S.

### A59 · Thread tags

Missing features — nice-to-have

Optional `tags` on `ResearchThread` with tolerant decoding, a `/tag` command, and a
`tag:` prefix in the history filter that combines with text search.

Suggested fix: as above; the Linux CLI can list by tag once A30 lands.

Accept: old archives load; a tag survives rename and reopen; the filter combines
with text search.

Historical score: 3.0 · 3/3/3 · S.

Earlier effort: S.

### A60 · Consolidate the typography scale

Aesthetics and theming — nice-to-have

Text now scales, but the earlier six-step type proposal remains separate from the existing many-size metric funnel.

Suggested fix: Evaluate 10/11/13/15/17 plus 11.5 mono, with every step accepting the reading scale.

Accept: Verify 140% text, both appearances and screenshots before claiming improvement. Keep code/citations monospaced.

Where: Vervellum/Views/PanelTheme.swift. Historical score: 7.3 · 8/6/8 · M.

Earlier effort: M.

### A60a · Simplify verdict card hierarchy

Aesthetics and theming — nice-to-have

Verdict rows repeat meaning through an icon column, tracked uppercase text and a spine.

Suggested fix: Try one icon-and-label pill while keeping the 2 pt spine and reclaiming the 24 pt column.

Accept: Retain readable verdict words/symbols, source actions and contrast at enlarged text sizes.

Historical score: 6.3 · 6/5/8 · S.

### A60b · Show an accessible verdict distribution

Aesthetics and theming — nice-to-have

A small distribution could summarize the finding table and collapsed trail.

Suggested fix: Prototype a 4 pt segmented Claims bar, 3 pt collapsed-trail variant and History-row distribution with accessible counts, verdict labels and incomplete status.

Accept: Never substitute the bar for written uncertainty or present it as a confidence score.

Historical score: 6.7 · 6/5/9 · S.

### A60c · Clarify section and turn boundaries

Aesthetics and theming — nice-to-have

Sections can read like consecutive paragraphs.

Suggested fix: Try larger between-section spacing, section hairlines and a turn separator.

Accept: Verify narrow/large-text layouts and both schemes before adopting.

Historical score: 6.0 · 6/5/7 · S.

### A60d · Refine citation styling

Aesthetics and theming — nice-to-have

The earlier visual proposal used superscript chips.

Suggested fix: Try superscript citations while keeping brackets in copied text and independently accessible source actions.

Accept: Keep the app-owned numbered-citation rule and measured contrast.

Historical score: 7.0 · 8/5/8 · M.

### A60e · Generate source monograms locally

Aesthetics and theming — nice-to-have

Small deterministic source tiles could aid scanning without favicon requests.

Suggested fix: Prototype a 16 pt letter tile with stable FNV-1a hue and the registrable label's first letter.

Accept: No network fetch; labels and contrast must remain usable without color.

Historical score: 3.7 · 4/3/4 · S.

### A60f · Make panel chrome and resizing explicit

Aesthetics and theming — nice-to-have

Width is set through Settings, panelHeight has no UI, and header-dragged placement is not remembered.

Suggested fix: Evaluate leading Close, grouped New/History, demoted Settings and a resizable style with min/max dimensions persisted through preferences.

Accept: Coordinate placement with A77c/A77d; verify short displays, full-screen use and enlarged text.

Historical score: 5.3 · 6/4/6 · M.

### A60g · Illustrate the empty research state

Aesthetics and theming — nice-to-have

The earlier proposal used a small search/evidence/verdict composition to explain the pipeline.

Suggested fix: Try a 44 pt SF Symbol composition and pending-stage illustration, not decorative per-token motion.

Accept: Keep readable onboarding and configuration actions; verify real screenshots.

Historical score: 3.3 · 3/3/4 · S.

### A60h · Bring evidence styling to GTK

Aesthetics and theming — nice-to-have

Linux still lacks the proposed per-finding cards and shared evidence-health cues.

Suggested fix: Evaluate colored card spines, theme-following secondary-text alpha, superscript citations and a block-character distribution bar.

Accept: Retain words/symbols, adaptive contrast and accessible counts. No platform parity claim before GUI QA.

Historical score: 6.0 · 5/6/7 · M.

### A61 · Summon-again semantics and the restore target

Usability: speed, convenience, clarity — nice-to-have

A product decision, not a defect: the summon hotkey *hides* a panel that is open
but no longer key, where Spotlight and Raycast re-focus. PLAN §5.1, the §5.3 key
table and the Shortcuts footnote all document "press again to dismiss"; decide,
and if re-focus wins, update the three documents with the code. The restore-target defect is tracked under A77b. Cheap delight from the same file: a hotkey double-tap
reopens the last thread.

Suggested fix: record the chosen semantics in PLAN, the footnote, and the code
comment.

Accept: whichever semantics is chosen is stated consistently; Escape returns focus
to the app the user actually left.

Earlier effort: S.

### A62 · Range citations

Bugs — nice-to-have

`[1-3]`, `[1–3]` and `[2—4]` match nothing in the digits-and-commas citation
regex, so they stay literal text, contribute no cited sources and are not flagged —
the turn reads as clean when it is not.

Suggested fix: accept `\d+\s*[-–—]\s*\d+` inside the brackets and expand it bounded
by `sourceCount`, or flag an unparseable digit group as `invalidCitation`.

Accept: `[1-3]` renders chips for 1, 2, 3 and marks them cited; `[9-2]` and
`[1-300]` are flagged; code spans stay ignored.

Implemented in open PR #233 (three dash spellings, bounded expansion, reversed and
oversized ranges flagged, renderer and transcript unchanged). Restore this entry if
that PR closes unmerged.

Earlier effort: S.

### A64 · A citation click reveals the source in the panel

Usability: speed, convenience, clarity — nice-to-have

Every click on `[3]` currently leaves the panel for the browser. Make a click
scroll to and flash source 3's row; ⌘-click opens the page; keyboard activation
does the same as click. Pairs with A25's inspector and keeps the
"evidence is the product" reading loop inside the panel.

Suggested fix: a scroll proxy from `MarkdownText` chips to `SourcesView` rows,
with Command-click taking the existing open path. Option-click can copy an
app-resolved Markdown footnote ([1]: url title), with an accessible Copy source
alternative and A36's success receipt. Add an explicit Open all cited action,
showing the count and confirming large groups; never open multiple tabs implicitly.

Accept: click flashes the row without leaving the panel; ⌘-click opens;
keyboard-activated chips behave identically.

Historical score: 6.3 · 7/5/7 · S.

Earlier effort: S.

### A65 · Keyboard-complete thread and ⌘F

Usability: speed, convenience, clarity — nice-to-have

There is no designed keyboard traversal from the composer to Copy, Try again,
follow-ups, source disclosure and trail actions: Tab inserts a tab. Tab/Shift-Tab should leave the composer and walk the last turn's actionable
items with a visible focus ring; ⌥1–3 ask the follow-ups; ⌘E toggles the trail;
⌘R retries; ⌘⇧A toggles uncited sources; ⌘F opens a find bar highlighting matches
in answers, findings and sources with ⌘G/⌘⇧G stepping. The composer stays an
`NSTextView` (AGENTS.md); this adds `doCommandBy` handling, not a replacement
view. Coordinate the history half with A28.

Suggested fix: `performKeyEquivalent` routing plus `insertTab:`/`insertBacktab:`
in the composer coordinator, a `PanelCommand` enum, and a find bar over a match
index on the rendered blocks.

Accept: every visible action is reachable without a pointer; the focus ring is
visible in both schemes; Escape returns focus to the composer before its usual
back-out order; find highlights update as the answer streams without restarting
the search.

Historical traversal: 6.3 · 8/4/7 · M; find: 5.3 · 6/5/5 · M.

Earlier effort: M.

### A66 · Complete heading navigation and verify streamed reading

Usability: speed, convenience, clarity — nice-to-have

Stage announcements and some heading traits exist; native composer labeling is covered. Generic SectionLabel still needs heading semantics for Claims, Limitations and Next, plus the question. Real VoiceOver behavior during per-chunk updates remains unverified. Finding-source action exposure is covered by open #145.

Suggested fix: Add missing heading traits. Verify whether streamed answer updates restart reading; if they do, expose block-boundary accessibility updates rather than per-token value changes.

Accept: Rotor navigation reaches Claims, Sources and Next; each stage is announced once; streaming does not repeatedly interrupt reading. Verify deletion with the separate History work.

Where: Vervellum/Views/FindingsView.swift:119–139; TurnView.swift; AnswerTextView.swift. Earlier effort: M.

Historical score: 7.3 · 7/7/8 · M.

### A67 · App Intents and a Services-menu entry

Missing features — nice-to-have

"Research with Vervellum" (Services menu, with the selected text) and "Ask
Vervellum" (Shortcuts, Spotlight) through the same redaction path as the selection
shortcut, never auto-submitting. Neither needs the Accessibility grant, and both
survive the ad-hoc re-signing that revokes it (A45). Extends A51's URL scheme.

Suggested fix: a macOS `AppIntent` target and `NSServices` in Info.plist feeding
the existing seed-the-composer path.

Accept: same input rules as A51; the Services entry appears only for text
selections; no capture is logged or sent without the user pressing Return.

Historical score: 5.7 · 6/5/6 · M.

Earlier effort: S.

### A68 · Print, Save as PDF, share sheet

Missing features — nice-to-have

⌘P prints the current turn (or thread) with its sources; the share sheet takes the
same rendering. Reuse the transcript completeness rules so a printed answer never
lacks its sources.

Suggested fix: command dispatch over `TranscriptFormatter`/an attributed renderer
into the standard print/share infrastructure.

Accept: page breaks never split a finding from its citation; failed and stopped
turns print their state line.

Historical score: 4.3 · 4/4/5 · S.

Earlier effort: S.

### A69 · Diagnostics report

General issues — nice-to-have

"Copy diagnostic report": app version, OS, provider endpoints and model names
(never keys), search backend, secret backend in use, hotkey registration state,
history state, last failure class and stage timings; everything a bug report
needs and nothing PRIVACY forbids.

Suggested fix: an About/Settings action on macOS and `vervellum --doctor` on Linux
over a shared Core assembler.

Accept: the report contains no key, no question text and no provider error text;
`--doctor` exits non-zero when a required piece is missing.

Historical score: 5.3 · 5/6/5 · S.

Earlier effort: S.

### A70 · Library backup and restore

Missing features — nice-to-have

Export and import the whole `threads.json` from Settings ▸ General through the
version guard: a newer document is refused with the reason; an older one is loaded
and re-saved at the current version.

Suggested fix: save/open panels over the archive's existing encode/decode with the
version gate applied to imports.

Accept: the round trip preserves every turn; importing a newer version is refused
visibly; a corrupt file is refused without touching the current library.

Historical score: 5.0 · 5/5/5 · S.

Earlier effort: S.

### A75 · Keep minimal progress when process detail is off

Usability: speed, convenience, clarity — nice-to-have

With Show what each search did off, plan/search phases can render only the question.

Suggested fix: Show a minimal spinner/stage row for nonterminal turns; let the preference govern detailed and finished trails.

Accept: Verify all stages with detail on/off and at enlarged text sizes.

Where: Vervellum/Views/TurnView.swift:64–66. Earlier effort: S.

### A75a · Show stopped planning as stopped

Usability: speed, convenience, clarity — nice-to-have

A turn cancelled during planning can remain a bare question without status or retry.

Suggested fix: Show a cancelled-stage trail or a Stopped/Try again row, preserving the question and original mode.

Accept: Stop during every stage; do not silently relaunch queued billable work.

Where: Vervellum/Views/TurnView.swift. Earlier effort: S.

### A75b · Size ordered-list markers for multiple digits

Visual issues and layout problems — nice-to-have

The fixed 16 pt marker column cannot reliably fit 10. and longer markers.

Suggested fix: Size the marker column from its font/content instead of a fixed narrow frame.

Accept: Verify double/triple digits, 140% text and long wrapped items.

Where: Vervellum/Views/MarkdownText.swift:387. Earlier effort: S.

### A75d · Avoid repeated login-item status probes

Performance problems, stuttering, and jank — nice-to-have

General-pane renders query SMAppService.mainApp.status. The cost needs measurement, not an assumed latency claim.

Suggested fix: Sample on presentation or cache with correct invalidation if profiling shows repeated service work.

Accept: Verify enabling/disabling login launch and external status changes.

Where: Vervellum/Model/Preferences.swift; Vervellum/Settings/GeneralView.swift. Earlier effort: S.

### A76 · Linux and documentation smalls remainder

General issues — nice-to-have

The quit GAction exists internally but is undiscoverable: add `vervellum --quit`
and a `[Desktop Action quit]` whose identifier matches the GApplication action name
(the desktop file currently has only toggle/install-shortcut), plus a README line
(S18/B59); scope README's Up/Down recall and "Threads are searchable" claims per
platform until Linux has them (B56, with A40). The double synchronous `secret-tool`
spawn on empty renders is resolved by #132's cached probe; B108's backend recording
is carried by A17.

Suggested fix: CLI flag plus desktop action wired to the existing GAction; README
platform scoping.

Accept: a user can quit the resident service without knowing D-Bus; README claims
match each platform's actual features.

Where: Sources/VervellumKit/Linux/LinuxApp.swift:272–276; packaging/debian/ch.lkmc.Vervellum.desktop:13. Quit effort: 2 hours (S18).

Earlier effort: S.

### A77c · Preserve a dragged panel position

Visual issues and layout problems — nice-to-have

Showing an already-open panel re-places it, losing header-dragged positioning.

Suggested fix: Skip placement while already open unless the target display changes; define session versus persisted placement explicitly.

Accept: Verify repeated summon, pointer-screen changes and short/multiple displays.

Where: Vervellum/Panel/PanelController.swift:113. Earlier effort: S.

### A77d · Re-place the panel after display changes

Visual issues and layout problems — nice-to-have

No didChangeScreenParametersNotification observer repairs an edge layout after a display disappears.

Suggested fix: Revalidate an open panel's geometry on screen-parameter changes.

Accept: Unplugging a display leaves the panel visible and usable, without claiming Wayland positioning parity.

Where: Vervellum/Panel/PanelController.swift. Earlier effort: S.

### A78 · Stamp the Linux binary's version at build time

General issues — nice-to-have

`AppIdentity.version` falls back to the hard-coded `0.1.0` whenever `Bundle.main`
lacks `CFBundleShortVersionString`, which is always the case for the Linux
executable. The tag's version reaches the package name and `DEBIAN/control` but
never the binary, so a released `.deb` reports `0.1.0` forever from `--version`,
the User-Agent and the update comparison (S10; the updater UI is macOS-only, so
this is a diagnosis problem, not a demonstrated Linux update loop).

Suggested fix: generate a small Swift source (or resource) from `VERSION` in
`build-deb.sh` before `swift build`, have `AppIdentity` read it on Linux, and fail
a release build when the stamp is missing.

Accept: `vervellum --version` in the installed package prints the tag; the update
check compares the real version; a local `swift build` without a stamp still runs
and says so.

Where: Sources/VervellumKit/Core/Platform/AppIdentity.swift:23–29; packaging/build-deb.sh:11,33. Effort: half a day (S10).

Earlier effort: S.

### A80 · Validate persisted attachment sizes

Bugs — nice-to-have

`Attachment` accepts a negative decoded `byteCount`, so a damaged archive can display
nonsensical sizes and corrupt accounting even though the rest of the turn is
recoverable.

Suggested fix: clamp legacy negative values to zero or discard only the invalid
attachment while preserving the containing turn, with tolerant-decoding tests.

Implemented in open PR #236 (clamped on decode, record kept). Restore this entry if
that PR closes unmerged.

### A81 · Decode declared legacy page encodings accurately

Bugs — nice-to-have

At `Sources/VervellumKit/Core/Research/PageReader.swift:450–470`, `DirectPageReader`
tries UTF-8 before the declared charset, maps Windows-1252 to ISO-8859-1, and maps
explicit UTF-16LE/UTF-16BE declarations to the BOM-sensitive native UTF-16 decoder.
Older pages can therefore arrive with garbled punctuation and euro characters, while
BOM-less UTF-16 containing ASCII can be accepted as NUL-filled UTF-8 and yield no useful
page text. This weakens the evidence available to every research mode that reads them.

Suggested fix: honor recognized declared charsets before the generic UTF-8 fallback;
use `.windowsCP1252`, `.utf16LittleEndian`, and `.utf16BigEndian`, with byte fixtures
that distinguish each encoding. Rough effort: about one hour.

Implemented in open PR #232 (an explicit UTF-16 endianness is acted on before the
generic fallback, a declared Windows-1252 page uses the Windows codec, and a strict
UTF-8 decode still wins for the single-byte charsets so a mislabelled UTF-8 page
reads correctly). Restore this entry if that PR closes unmerged.

### A82 · Measure the assessment stage rather than the whole turn

General issues — nice-to-have

At `Sources/VervellumKit/Core/Research/ResearchRunner.swift:1788–1800`, the assessment
trace records elapsed time from the beginning of the research turn, so its duration
includes planning, search, page reading, and answer generation. Maintainers diagnosing
a slow assessment provider are shown a plausible but incorrect stage time; end users
are unaffected.

Suggested fix: capture a monotonic stage start immediately before assessment, as the
revision path already does, and report only the assessment interval. Rough effort:
under one hour.

Implemented in open PR #237. Restore this entry if that PR closes unmerged.

### A83 · Evict idle research sessions

Performance problems, stuttering, and jank — nice-to-have

At `Vervellum/Research/ResearchEngine.swift:50–54,108–126,181–201`, `ResearchEngine`
retains a full `ResearchSession` for every thread opened during the process lifetime.
Repeated `/new` commands alone create an unbounded map of blank idle sessions, while
long-running menu-bar users accumulate duplicate in-memory thread state.

Suggested fix: evict inactive sessions after they become idle, have no returned queued
questions, and their latest thread snapshot is durable; always retain running, queued,
and currently active sessions. Rough effort: about half a day.

### S07 · Match key hints to the submit preference

Usability: speed, convenience, clarity — nice-to-have

Empty-state Return/Shift-Return advice is hard-coded and contradicts the disabled Return-to-send preference. Platform-specific help alone does not resolve preference-sensitive wording.

Suggested fix: Derive empty-state and relevant help hints from the submit preference.

Accept: Check both preference settings and each platform's actual submit chord.

Where: Vervellum/Views/EmptyStateView.swift:39. Effort: 1 hour.

### S08 · Clear stale preview state

Bugs — nice-to-have

Dismissing the Settings preview through another panel-hide path can leave the preview toggle on. Runtime reproduction remains open.

Suggested fix: Clear preview state on panel-hide notification as well as Settings close.

Accept: Toggle preview, dismiss with the summon shortcut, and verify the control matches the visible panel.

Where: Vervellum/Settings/GeneralView.swift:192–202. Effort: 1 hour.

### S23 · Distinguish denied Keychain access from missing keys

Usability: speed, convenience, clarity — nice-to-have

A denied ad-hoc build's Keychain prompt is cached as unreadable, so stored credentials look absent until relaunch.

Suggested fix: Expose access-denied versus absent states and an explicit retry. Do not introduce repeated unsolicited authorization prompts.

Accept: Verify denied, restored and absent-key states. Keep the ad-hoc signing limitation documented until authenticated distribution exists.

Where: Vervellum/Security/KeychainStore.swift:113,176–186. Effort: half a day.

### S32 · Scope warnings to the answer or draft they describe

Bugs — nice-to-have

A clean revision can retain generic invalid-citation or URL warnings from the replaced draft. The same notice can also originate in assessment references, so clearing it merely because the displayed answer is clean would lose information.

Suggested fix: Track draft, assessment and displayed-answer validation separately. Revalidate replacement prose and label retained draft warnings by scope; never clear the whole notice list.

Accept: Cover clean revisions of invalid drafts, assessment-only invalid references, invalid displayed prose, and failed/discarded revisions that must preserve the original answer.

Where: Sources/VervellumKit/Core/Research/ResearchRunner.swift:1664,1680–1687,2036–2058; ResearchModels.swift:633–637. Effort: half a day.

Verify attribution after successive rewrites. A regather adopts findings for the new
answer. A subsequent revision can keep that answer as the draft. Both native panels
currently tell assistive technology that findings grade the draft in all cases.
Use one rule for the disclosure hint, notices and transcript heading. Exercise
regather alone, revise alone, both in sequence, interrupted adoption and legacy
records. Preserve uncertainty when an older archive lacks enough information.

### S33 · Confirm image fallback before disabling vision

Bugs — nice-to-have

Any image-bearing HTTP 400 can be attributed to missing vision, even when a wrong model name caused the failure. This costs a retry and can suppress later images for that provider.

Suggested fix: Record image rejection only after the no-image retry succeeds; retain sanitized errors and per-provider state.

Accept: Test both successful image fallback and a 400 that also fails without images.

Where: Sources/VervellumKit/Core/Research/ChatCompletionsClient.swift:302–317. Effort: 2 hours.

Implemented in open PR #234 (both flags set only after the retry answers, with the
double-failure case pinned). Restore this entry if that PR closes unmerged.

### R01 · Retain a first-use selection seed

Bugs — nice-to-have

showWithSelection posts the composer-seed notification synchronously after show. On first construction, SwiftUI may not yet have installed its onReceive observer; later presses use the retained hosting view. Confidence is medium; verify on a Mac.

Suggested fix: Carry the seed as state or a pending slot consumed on appearance, rather than a fire-and-forget notification.

Accept: First use after launch and later use both seed the composer, without sending automatically or replacing an existing draft.

Where: Vervellum/Panel/PanelController.swift:88–93; Vervellum/Views/PanelRootView.swift:160.

### R02 · Make checkpoint-starvation tests load-independent

General issues — nice-to-have

The checkpoint test assumes a 0.05-second debounce has fired within 0.5 seconds. The concurrent review observed three parallel-run failures that passed on retry/serially; this review also hit that timing assertion once.

Suggested fix: Use a bounded expectation while updates continue, then flush and verify the final contents. Do not stop the producer before checking the checkpoint: that would let a debounce-reset regression pass.

Accept: The test must still fail if continuous snapshots postpone every checkpoint.

Where: Tests/VervellumKitTests/ThreadArchiveTests.swift:263–276, assertion :273.

### R03 · Give notices meaningful visual tones

Aesthetics and theming — nice-to-have

NoticesView uses the same mixed-color warning triangle for every TurnNotice, including answerRegathered and other informational events.

Suggested fix: Map notices to a tone and symbol, reused by native and optionally Pango rendering.

Accept: Retain written labels, uncertainty and accessible distinctions; informational styling must not become a truth seal.

Where: Vervellum/Views/TurnView.swift:248; PangoMarkup.notices.

Implemented in open PR #240 (a shared `NoticeTone` in Core, used by both renderers;
informational notices use the secondary text colour). Restore this entry if that PR
closes unmerged.

### R04 · Normalize common publication-date spellings

Visual issues and layout problems — nice-to-have

Source rows and previews display provider timestamps verbatim, so a full ISO timestamp competes with compact metadata.

Suggested fix: Normalize recognized ISO-8601 shapes once in Core to a short date; preserve unparseable values as written.

Accept: Keep formatting portable and Linux formatter usage thread-safe. Do not invent dates.

Where: Vervellum/Views/SourcesView.swift:163–165; SourcePreview.swift.

### R05 · Complete model command arguments

Missing features — nice-to-have

Command completion stops at the first space, so /model cannot suggest the provider names it accepts.

Suggested fix: Add argument-aware completion for commands that take arguments, driven by ProviderSettings.modelProfiles.

Accept: Complete configured names without provider calls or exposing credentials; keep command-word, keyboard and IME behavior.

Where: Sources/VervellumKit/Core/Text/ComposerCommand.swift:136.

### R06 · Profile large-library search before hiding results

Performance problems, stuttering, and jank — nice-to-have

ThreadLibrary scans questions and full answers on each query edit, up to 2,000 threads. The matcher also checks findings, limitations, follow-ups and sources. A missing phrase across 200 one-turn threads with 8,200-character answers took 0.56–1.07 seconds per scan in a local debug build on arm64. [The single-scan change](https://github.com/L-K-M/Vervellum/pull/213) shares the result for the rows and empty state. Measure release-build input latency at the default and maximum library sizes before selecting a search strategy.

Suggested fix: Profile a roughly 150 ms debounce or an index with correct invalidation. The concurrent review suggested questions-first with an answer fallback only for a small question set; that changes result completeness and needs an explicit scope decision, not a silent optimization.

Accept: Preserve answer matches, ordering and live library changes unless the reader chooses a narrower search scope.

Where: Sources/VervellumKit/Core/Store/ThreadLibrary.swift:118–126; Vervellum/Views/HistoryView.swift:25.

### G01 · Let Linux level controls wrap

Visual issues and layout problems — nice-to-have

Four level buttons and separators occupy one non-wrapping row in the 560 px
window. Clipping at large text or narrower widths is a source-derived risk,
not a reproduced GUI result.

Suggested fix: Verify the layout, then try a GtkFlowBox or grouped wrapping layout
that preserves the selector's semantic groups and separators.

Accept: 140% text and narrow windows retain readable labels and reachable controls.

Where: Sources/VervellumKit/Linux/LinuxPanel.swift:181–209.

### G02 · Refresh relative history dates while visible

Usability: speed, convenience, clarity — nice-to-have

History's relative dates are recomputed only on render, so an open list can keep
an old age label.

Suggested fix: If touching A28's rows, use a shared periodic minute tick while
History is visible rather than a timer per row.

Accept: Labels advance without interfering with selection, reading or focus.

Where: Vervellum/Views/HistoryView.swift:154.

### G03 · Apply shared palette presets on Linux

Aesthetics and theming — nice-to-have

The macOS palette presets live in Core, but Linux's hand-written stylesheet does
not consume them.

Suggested fix: Map the selected shared palette into GTK color variables, keeping
the existing stylesheet as fallback and respecting the actual appearance scheme.

Accept: Both schemes, contrast and live preference changes need GUI verification.
Use the existing preference, not another Linux-only theme store.

Where: Sources/VervellumKit/Core/Platform/ThemePresets.swift; LinuxPanel.stylesheet.

### G04 · Make Linux level selection theme-independent

Aesthetics and theming — nice-to-have

The selected level uses a bullet, bold text and a CSS class. A theme that ignores
the class leaves a subtle signal.

Suggested fix: Add a checkmark or a real checked-state style and accessible state,
without relying on color or a particular GTK theme.

Accept: Selection stays clear under Adwaita variants and enlarged text.

Where: Sources/VervellumKit/Linux/LinuxPanel.swift:213–225.

### G05 · Compare the passages a revision changed

Novel, delightful, or quirky ideas worth trying — nice-to-have

The reader can expand the complete saved draft. Prototype a changed-paragraph view
that keeps source buttons usable in both versions and retains access to both full texts
when paragraph alignment is ambiguous.

Suggested fix: Diff draftAnswer against the displayed answer locally, using the
existing Markdown views. A line-based diff is a starting point, not a claim of
sentence-level alignment.

Accept: No model call; bound work on long answers, retain both complete versions,
and say which prose the findings assessed.

### N01 · Flag a single-domain evidence set

Novel, delightful, or quirky ideas worth trying — nice-to-have

All cited sources can come from one domain without a visible cue.

Suggested fix: Show an accessible monoculture flag from existing source metadata; do not equate domain diversity with truth.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 7.3 · 7/7/8 · S.

### N02 · Show whether a plan sought counter-evidence

Novel, delightful, or quirky ideas worth trying — nice-to-have

The prompt asks for disconfirming research, but the plan has no corresponding visible badge.

Suggested fix: Try a purpose-based cue/tag without claiming the model actually disproved anything.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 7.7 · 7/7/9 · M.

### N03 · Publish running-turn state independently

Novel, delightful, or quirky ideas worth trying — nice-to-have

Whole-thread publication can trigger avoidable view work during streaming.

Suggested fix: Profile a per-turn ObservableObject in the macOS shell; republish the thread only at boundaries if that wins. No Combine in Core.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 7.3 · 8/7/7 · M.

### N04 · Flush dismissals without blocking the interface

Novel, delightful, or quirky ideas worth trying — nice-to-have

Synchronous archive flush can delay hiding the panel.

Suggested fix: Evaluate async dismissal flush while keeping a synchronous termination checkpoint and durable final snapshot ordering.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 6.3 · 6/7/6 · S.

### N05 · Keep an unread-result indicator

Novel, delightful, or quirky ideas worth trying — nice-to-have

A completion glyph need not say whether the result was read.

Suggested fix: Try a small unread dot until the reader opens the result; expose its state accessibly.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 6.3 · 6/6/7 · S.

### N06 · Open a dedicated reading window

Novel, delightful, or quirky ideas worth trying — nice-to-have

Long answers may be easier to read in an ordinary resizable window.

Suggested fix: Offer an explicit reading window, such as Command-Shift-O, over the same thread data without another run.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 4.7 · 6/4/4 · M.

### N07 · Prepare localization before translating

Novel, delightful, or quirky ideas worth trying — nice-to-have

Strings, plural rules and date presentation are not organized for localization.

Suggested fix: Plan a String Catalog, locale-aware dates and a portable Core localization seam before the first translation.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 2.7 · 3/2/3 · L.

### N08 · Open cited sources by number key

Novel, delightful, or quirky ideas worth trying — nice-to-have

The last answer's sources lack direct number-key access.

Suggested fix: Evaluate Command-1 through Command-9 over app-owned source numbers; coordinate existing panel shortcuts and grouping behavior.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 6.0 · 6/6/6 · S; alternate 5.0 · 5/5/5 · S.

### N09 · Avoid redundant citation validation scans

Novel, delightful, or quirky ideas worth trying — nice-to-have

Some consumers need spans but still pay for URL scanning.

Suggested fix: Profile a spans-only validator entry point and one scan per answer change; preserve complete validation on every trust boundary.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 5.3 · 5/6/5 · S.

### N10 · Deliver streaming deltas instead of whole turns

Novel, delightful, or quirky ideas worth trying — nice-to-have

Every streamed callback can copy a growing turn.

Suggested fix: Profile append-in-place front-end delivery against coalesced snapshots before changing ownership or cancellation behavior.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 4.0 · 4/4/4 · M.

### N11 · Match completion styling to evidence state

Novel, delightful, or quirky ideas worth trying — nice-to-have

A stage-aware caret/tick could make completion easier to scan.

Suggested fix: Use existing stages/verdicts with a static reduced-motion alternative. Never imply verified truth from completion alone.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 4.3 · 4/4/5 · S.

### N12 · Group and filter history through the composer

Novel, delightful, or quirky ideas worth trying — nice-to-have

The earlier type-to-filter proposal included day grouping beyond in-list navigation.

Suggested fix: Offer composer-driven filtering and day groups, reusing A28's arrows/Return without destroying a draft.

Accept: Use existing data and explicit user actions; no silent model call or privacy expansion.

Historical score: 8.0 · 8/8/8 · M.

### N13 · Step between answer citations by keyboard

Novel, delightful, or quirky ideas worth trying — nice-to-have

Readers have no direct next/previous citation traversal while comparing a long answer to its sources.

Suggested fix: Evaluate Control-bracket keys, or Command-arrow only outside the composer, to select the next/previous app-owned citation in MarkdownText/AnswerTextView.

Accept: Do not intercept composer editing; use existing citation data without another model call.

### N14 · Show waiting-question counts in the status menu

Novel, delightful, or quirky ideas worth trying — nice-to-have

Waiting follow-ups are invisible while the panel is hidden, unlike the busy-run glyph.

Suggested fix: Read queue state when building the menu and observe queue changes, not only busy-state transitions. Label whether the count is active-thread or all-session.

Accept: Use existing AppDelegate/engine data; no question text or extra provider calls are needed.

Where: Vervellum/App/AppDelegate.swift:387.

### M01 · Do not let notice markdown eat literal filename characters

Bugs — nice-to-have

Attachment refusals and progress notices embed user filenames and are rendered
through `MarkdownBody` (`NoticesView`). A file named `*draft*.md` or `**bold**.png`
loses its asterisks to emphasis in the message that explains why it was refused.

Suggested fix: render refusal/progress lines as plain text (the `/help` and `/model`
notices deliberately use markdown and should keep it), or escape filenames when the
message is built.

Accept: a filename with `*`, `**`, `_`, `` ` ``, `[` or `#` survives verbatim in
its refusal notice; the markdown-capable notices still render.

Where: Vervellum/Views/TurnView.swift (`NoticesView`), the refusal message builders
in `Vervellum/Views/PanelRootView.swift`. Effort: 1 hour.

### M02 · Name the answering model when only one provider is configured

Usability: speed, convenience, clarity — nice-to-have

The composer model chip only appears with `profiles.count > 1`, so a single-provider
setup cannot see which model answers without opening Settings. The turn footer does
print it — but only after the fact.

Suggested fix: show a read-only model label on the empty state or beside the level
chip when exactly one profile exists; keep the picker interactive when there are
two or more.

Accept: a one-provider user can identify the model before asking; no new picker or
extra settings surface.

Where: Vervellum/Views/PanelRootView.swift (`modelPicker`). Effort: 1 hour.

### M03 · Show a drop affordance while dragging onto the composer

Usability: speed, convenience, clarity — nice-to-have

`ComposerTextView` accepts file and image drops, but nothing highlights the
composer as a target — users discover drop support only by trying it. The empty
state now names the feature; a visual target would complete the affordance.

Suggested fix: have `draggingEntered`/`draggingExited`/`performDragOperation` flip
a flag that draws an accent ring or tint over the composer (bridge the state into
SwiftUI via the coordinator, or overlay a border in `ComposerView`).

Accept: the highlight appears only while a valid payload is over the composer and
clears on exit/completion; no per-frame work added to the streaming path.

Where: Vervellum/Views/ComposerView.swift:341+; Vervellum/Views/PanelRootView.swift
(composer section). Effort: 2 hours.

### M04 · Tint the panel glass and separate the composer visually

Aesthetics and theming — nice-to-have

The panel uses the untinted `.regular` material/glass and a hairline between
scrolling content and composer. Against macOS 26 glass this is honest but spare:
the theme's surface colour never reaches the backdrop, and the composer does not
read as a distinct surface over a long answer.

Suggested fix: tint the glass subtly with `PanelPalette.surface` (glass APIs accept
a tint on both NSGlassEffectView and `.glassEffect`), and evaluate a soft top
shadow on the composer divider. Keep `.floating` level, material fallback, and all
contrast/adaptation behaviour intact; measure both appearances.

Accept: Increase Contrast and Reduce Transparency still readable; no window-level
change; screenshots in light and dark.

Where: Vervellum/Views/PanelBackground.swift; Vervellum/Panel/ResearchPanel.swift;
the composer divider in PanelRootView. Effort: half a day.

### M05 · Show the global hotkey chords in the status menu

Usability: speed, convenience, clarity — nice-to-have

"Ask Vervellum…" and "Research the Selection…" in the status menu carry no hint of
their registered shortcuts — the single most important interaction in the app is
undiscoverable from its own menu.

Suggested fix: display the recorded `HotkeyBinding.displayString` beside the items
(right-aligned text or the key-equivalent column, taking care that assigning
`keyEquivalent` also makes the chord fire while the menu tracks — same action, but
verify).

Accept: the menu shows the live configured chords and updates when a shortcut is
re-recorded; no double invocation.

Where: Vervellum/App/AppDelegate.swift (`makeMenu`). Effort: 1 hour.

### M06 · Cycle threads with ⌘[ / ⌘]

Usability: speed, convenience, clarity — nice-to-have

Keyboard users can open History (⌘Y) but cannot move between threads without the
pointer; ⌘[ / ⌘] back/forward through history order matches both Safari and the
panel's existing shortcut vocabulary.

Suggested fix: handle the pair in `ResearchPanel.performKeyEquivalent` like the
other panel chords, mapping to `openThread` on the previous/next entry in
`library.threads` order. Coordinate with A28's list-key model and N13's citation
stepping so the chords do not collide.

Accept: cycles across the visible ordering only while a thread view is shown; no
interception while the history search field or composer has marked text.

Where: Vervellum/Panel/ResearchPanel.swift (`performKeyEquivalent`);
Vervellum/Views/PanelRootView.swift (`openThread`). Effort: 2 hours.

### M07 · Panel-UX smalls

General issues — nice-to-have

Two marginal items from the same pass, held here so they are not lost:

- The level picker only dismisses via Escape, its chip, or a selection — clicking
  the thread area leaves it open. Harmless (the fixed composer never overlaps),
  but a click-away dismiss would match macOS convention.
- `PanelRootView` reads `preferences.textScale` at the root, so a settings-slider
  drag republishes the whole tree per tick. Profile before changing observation. The root injects the scale for
  its children, so an environment lookup at the root reads its parent’s value.
  Isolate scale-dependent chrome in a descendant if profiling warrants it.

Where: `showsLevelPicker` in Vervellum/Views/PanelRootView.swift; `textScale` at
PanelRootView root. Effort: 1–2 hours.

### H01 · Reveal why a history result matched

HistoryRow shows a title, turn count and age even when the only matching text is
buried in a finding several turns back. Prototype a single excerpt labeled by
field and open the thread at the matching turn. Have ThreadLibrary's existing
search return the match location as part of its walk. Generate the excerpt only
where it is displayed. Preserve result ordering, normal unfiltered reopening and
the session identity of detached live threads. Exercise a claim-only hit in an
older turn, mixed-script input and a cleared query. Measure together with R06.

### H02 · Distinguish retrieved and cited domains in follow-up context

ResearchContext.historyEntry removes old citation numbers, then populates
`source_domains` from every retrieved source. Its documentation describes these
as the domains backing the previous answer. Compare payloads for a two-turn
fixture with an answer citation, an assessment-only source and an unused result.
Decide whether the following planner needs search coverage separately from
citation provenance. Name the fields for their actual meaning, retain the budget
and trimming notices, and keep earlier citation numbers out of subsequent prose.

## Codex pass 2026-11-21

Reviewed against `origin/main` at `e90efc3`. Full read of the macOS front end, the
shared Core pipeline, persistence, the text layer and the Linux/GTK front end; the
macOS suite passes (1043 tests) and a Debug build runs without runtime warnings.
Four small fixes from this pass are open in PRs #233 (range citations), #234
(image-retry state), #236 (negative attachment size) and #240 (notice tones); their
slices are annotated in place above and are not repeated here. Concurrent branches
and other agents' PRs were not inspected.

### C01 · `/clear` leaves the redaction banner on an empty composer

Bugs — nice-to-have

`PanelRootView.newThread()` resets `notice`, `queueFullNote`, `attachments`,
`draft` and `recallIndex`, but not `redactionNote`
(`Vervellum/Views/PanelRootView.swift:1170`, state at `:58`, banner at `:354`).
After `/clear`, `/new` or the header's new-thread button, "N credential-shaped
values removed from the captured text." keeps showing above an empty composer.

Suggested fix: clear `redactionNote` in `newThread()`. `showsLevelPicker` is reset
by `submit` but not by the header's new-thread button; both entry points should go
through the same reset.

Accept: `/clear` by command and by the header button both leave no banner; a
selection-seeded draft still shows its count.

### C02 · Attaching a file clears whatever notice is showing

Bugs — nice-to-have

`PanelRootView.receive(_:restoring:)` does `notice = nil` whenever an attachment
is accepted (`Vervellum/Views/PanelRootView.swift:1002`). A "Finish the command
name" notice, or a refusal from an earlier drop, is discarded by an unrelated
attachment. The chips are visible on their own; the notice is the only record of
the other event.

Suggested fix: do not clear `notice` here. If a clear is wanted, clear only the
attachment-related notices this view itself posts.

Accept: a refusal or command notice survives a later attach; an attach-specific
notice is still replaced by a newer attach result.

### C03 · `/history` and `/settings` clear the words but leave the bytes armed

General issues — nice-to-have

`submit` handles `.openHistory` and `.openSettings` by setting `draft = ""` and
nothing else (`Vervellum/Views/PanelRootView.swift:925`). `attachments` survives.
`openThread` deliberately documents that the composer is global and keeps its
words and attachments while earlier work is consulted, so persisting across
History may be intended — but the two commands clear the words and keep the bytes,
so a screenshot attached for one question silently rides the next one asked from
History.

Suggested fix: decide it explicitly. If the bytes travel with the draft, clear
both; if they persist, stop clearing the draft in these two branches. Record the
decision in the comment beside `openThread`.

Accept: a question asked straight after `/history` either carries the attachment
deliberately and says so, or does not carry it; the choice is documented.

### C04 · Attachment bytes are written synchronously on the main thread

Performance — nice-to-have

`ResearchSession.start` writes every pending attachment with
`attachmentStore.write` before appending the turn
(`Sources/VervellumKit/Core/Research/ResearchSession.swift`, in `start`). `start`
is reached from `ResearchEngine.ask`, which the panel calls on the main thread, so
up to 4 × 4 MB of file writes block the UI before the turn exists. The comment
justifies the synchronous order, and the order is real — the bytes must exist
before a save names them — but it does not require the write to be on the calling
thread.

Suggested fix: perform the writes off the main thread and append/publish the turn
when they finish, keeping the pre-append ordering. `AttachmentStore.sweep`'s grace
window already covers the gap between a write and the save that names it.

Accept: a 4 × 4 MB attach does not stall the composer; a crash between the write
and the save still leaves bytes the sweep collects; a failed write still raises
`attachmentNotStored`.

### C05 · `sendJSON` has no wall-clock deadline on the response head

General issues — nice-to-have (extends A22)

`HTTPTransport.fetch` races a deadline task against the open+collect pair, but
`sendJSON` awaits `open` with no timer
(`Sources/VervellumKit/Core/Research/HTTPTransport.swift`). The request's
`timeoutInterval` is an idle timeout, so a server that accepts the connection and
never sends headers holds the call for the full 120 s idle allowance rather than
the exchange deadline the caller passed. MCP and cheap JSON calls use this path.

Suggested fix: give `sendJSON` the same independent clock as `fetch`, covering the
head and the body, and cancel the URL task when it fires.

Accept: a head that never arrives fails at the caller's deadline; a slow body
still fails at the same deadline; cancellation still stops the task; no change to
`fetch`'s behaviour.

### C06 · Header buttons have a fixed hit area that ignores the text-size preference

Visual / accessibility — nice-to-have

`HeaderButton` draws its symbol at `PanelTheme.Font.at(10.5, textScale)` inside a
fixed `frame(width: 20, height: 18)` (`Vervellum/Views/PanelHeaderView.swift`). At
140 % text the glyph is 14.7 pt in an 18 pt frame and the touch target stays
20 × 18 pt, well below the 44 pt guideline. The five controls also crowd at the
right edge with no padding. Open PR #205 fixes the target size; this entry is the
scaling half — verify against #205 before implementing.

Suggested fix: scale the frame with `textScale`, or use a minimum 44 pt hit area
with centre alignment, and keep the glyph centred.

Accept: 140 % text shows no clipped glyph; every header control meets the target
guideline at both ends of the text-size range.

### C07 · Performance smalls

Performance — nice-to-have

- `TurnView.==` compares the whole turn, including the growing answer and the
  source/findings arrays, at the coalescer's 10 Hz. A stage/answer-prefix
  comparison would be cheaper and equally correct for the render decision.
- `MarkdownBody` re-parses the whole answer on every publish (A20's remainder);
  `ComposerView.height(for:)` builds a fresh TextKit stack per call (A20/S14).
- `ThreadLibrary.search` scans every field of every turn per keystroke with no
  debounce or index (R06).
- `ResearchEngine.sessions` is never evicted (A83).

These are collected here so a future performance pass has one list; each is
profiled before it is redesigned.

## Codex pass 2026-11-21 (second)

### V01 · Surface a failed thread write

Bugs — nice-to-have

`ThreadArchive.writeNow` catches every write and rotation error and writes one line
to stderr. It sets neither `readFailure` nor `eraseFailure`, so `scheduleSave`'s gate
keeps believing the last save succeeded and Settings keeps showing history as
healthy. A full disk, a read-only folder or a permission regression is exactly when
the user needs to know their threads are not being kept. A14 covers backup rotation
and concurrent erase/flush; this is the primary write path.

Suggested fix: record a `saveFailure` beside `eraseFailure`, surface it through
`ThreadStore.eraseFailure` and Settings, and test that a failed write is reported
without blocking the next save attempt.

Accept: a forced write failure reaches the UI in Vervellum's own words; a later
successful save clears it; no path or foreign error text is shown.

Where: `Sources/VervellumKit/Core/Store/ThreadArchive.swift:391–420`;
`Vervellum/Store/ThreadStore.swift` (`eraseFailure`). Effort: half a day.

### V02 · Time `ResearchTrace.stage` with the injected clock

General issues — nice-to-have

`ResearchTrace.init` takes `now:` and uses it for `started`/`elapsed`, but `stage`
and the completion logs call `Date()` directly. A test that injects a clock can
predict `elapsed` but not the per-stage figures, so the trace's per-stage timings
cannot be fixture-tested.

Suggested fix: store the injected clock and use it for `stage` and the completion
logs as well.

Accept: a fixture clock produces deterministic stage durations; live behaviour is
unchanged.

Where: `Sources/VervellumKit/Core/Research/ResearchTrace.swift:33–45`. Effort: under
one hour.
