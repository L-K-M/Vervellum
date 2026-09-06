# Open-PR consolidation

[PR #69](https://github.com/L-K-M/Vervellum/pull/69) consolidates the 42 PRs open at
review start. Code was compared against `ab49b2f`, reconciled, then independently
reviewed for core and UI risks. Original PRs are resolved through this integration,
not merged independently over one another.

## Dispositions

| PRs | Decision |
|---|---|
| #2 | Keep the CI repair; supersede #21, #38, #46. |
| #22, #25 | Keep heading parsing and return-to-thread fixes. |
| #26, #61 | Combine complete transcripts with exact structured source URLs. |
| #27, #53 | Combine linear SSE scanning and interruption handling; require explicit completion. |
| #28, #59 | Combine GTK lifecycle tests and interaction fixes; one close handler. |
| #29 | Keep allow-listed diagnostic fields. |
| #30 | Keep strict citation arrays; supersede #23. Reject #57's scalar/digit coercion. |
| #31 | Keep reader-controlled following; supersede #49. Move observation outside lazy rows. |
| #32 | Keep pipe-table parsing and macOS grids; Linux uses lossless labeled rows with citations. |
| #33, #34 | Keep retry/clock controls and composer examples. |
| #36 | Keep the status glyph, with accessible state; remove unsolicited sound. |
| #40 | Close as redundant: its review is preserved by immutable link in `ANALYSIS.md`. |
| #47 | Keep allocation-free history matching; supersede #35's duplicate index. |
| #48, #50 | Keep search progress and composer measurement; preserve redaction notices across dismissal. |
| #51 | Keep coalescing; supersede #24. Inject scheduling and compare every non-prose field. |
| #52 | Discard. Stop can launch queued billable work; lifecycle coverage is absent. |
| #54 | Keep one optional-field retry; preserve reasoning tags inside JSON strings. |
| #55 | Keep recognized tool names only; never infer operations from descriptions or log their names. |
| #56, #58 | Keep code-aware citations and historical-marker removal; fix CRLF, escaping, and stale invalid numbers. |
| #57 | Keep qualified assessment failure and unambiguous verdict aliases; never equate dispute with contradiction. |
| #60 | Keep recovery/erasure fixes and Stripe redaction; restore conservative alphabetic bearer-token redaction. |
| #62 | Keep emphasis across citations; share citation masking with macOS. |
| #63, #68 | Keep Debian version ordering, desktop metadata, and token permissions. |
| #64 | Keep longer non-streaming idle timeout; do not claim an absolute deadline. |
| #65 | Keep language/date prompts and budgeted assessment context. |
| #66 | Keep Linux scaling; make process-trail visibility honor the preference. |
| #67 | Keep Settings handoff and inert model links; enforce deletion below the UI. |

## Integration corrections

Regression tests exposed and now cover:

- Future backup protection, startup-disabled erasure, failed-erasure write blocking,
  history reenablement, deletion resurrection, and checkpoint starvation.
- Stop versus queued callbacks, pending prose, and late completion, using controlled
  runner/scheduler fixtures rather than sleeps.
- Missing/unknown finish reasons, malformed/error frames and delta shapes, whole-response completion,
  optional-field retries, and preserved partial transcripts.
- Fixed-context rejection, exact JSON budget accounting, and assessment warnings in
  follow-up history. Recovering partial prose also reruns citation validation.
- Placeholder injection and markdown consuming citation markers. Only retrieved
  citations carry link attributes; fallback rendering preserves their positions.
- Long Linux table cells and their actionable citations, without truncation.

History writes now stamp schema 2. Older released readers can overwrite unfamiliar
notice values even with a version stamp; downgrades sharing that file are unsupported.
Deletion markers exist only in memory, not in the history document.

## Validation

- Linux shared tests: `swift test --parallel`.
- macOS build and shared/platform tests: `xcodebuild ... clean test` in CI.
- Eleven loopback provider scenarios: `python3 Tests/Integration/provider_fixtures.py .build/release/vervellum`.
- GTK native-close/reopen under Xvfb; desktop validation; Debian build, install, and
  dependency checks in Linux CI.
- Defect regressions were observed failing before their fixes. Logs and CI
  history are linked from #69. The optional GLM integration repeatedly skipped actual
  review because `ZAI_API_KEY` is absent; green workflow status is not review approval.

## Remaining limits

- Real GNOME Wayland behavior, macOS full-screen placement/activation, scrolling,
  multi-display movement, Liquid Glass, Accessibility, and IME need desktop QA.
  Xvfb and unit tests do not establish these behaviors.
- No end-to-end UI performance benchmark or live third-party-provider compatibility
  claim. Linux tables preserve content but do not yet provide native comparison grids.
- Absolute network deadlines, bounded credential subprocesses, signed releases,
  authenticated updates, digest-pinned Linux images, and broader Markdown/accessibility
  work remain backlog items. This consolidation does not implement them.

`ANALYSIS.md` preserves earlier findings and acceptance criteria as a historical
review snapshot. This file supersedes its pending-PR tables and integration statuses.
