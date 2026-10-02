# Simplification audit

One behavior-preserving pass, 2026-10-02. Base: `1583e64`.
Work and validation: [PR #117](https://github.com/L-K-M/Vervellum/pull/117).

## Audit boundary

| Area | Disposition |
|---|---|
| Shared research, clients, parsers, transport, sessions and budgets | Select four local simplifications below. Preserve prompts, source numbering, fail-soft stages, retries, cancellation and callback ordering. |
| Store, text, settings, secrets, themes and updates | Independent read-only audit. Keep archive recovery/tombstones, compatibility mirrors, lenient decoding, citation masking and queue confinement. Remaining deduplication has little benefit. |
| macOS and Linux front ends, C shim | Independent read-only audit, including framework callbacks, signal ownership, shortcuts and rendering. Remove only proven unreachable surface. |
| Package/project build graphs, CI, packaging, Flatpak, scripts and eval | Independent read-only audit. No external Swift package dependencies exist. Keep packaging safeguards, legacy CLI flags and framework entry points. |

`AGENTS.md`, `CLAUDE.md`, `PLAN.md`, `AGENT-RESEARCH.md`,
`DEEP-RESEARCH-REVIEW.md`, `PR-REVIEW.md`, `README.md`, `CICD.md`,
`SECURITY.md` and `PRIVACY.md` informed the boundary. Documented workarounds
remain constraints.

## Selected set

Locations below refer to the base revision. Research files are under
`Sources/VervellumKit/Core/Research/`.

| Candidate | Complexity removed | Evidence and regression boundary |
|---|---|---|
| `ResearchRunner.swift:1698–1759,2451–2503` | Two implementations of answer context, image withholding, fallback reset and streamed publication become one existing `streamAnswer` implementation. | The bodies match apart from prompt, payload and trace label. Preserve both labels and each caller's distinct attribution/cancellation/validation tail. Existing image/retry tests plus new direct-answer characterization cover these differences. |
| `ResearchSession.swift:346–348,378–407` | Remove a one-caller wrapper and its always-true `returningQueue` mode. | `cancel()` is the only caller; `discard()` already has distinct semantics. Preserve synchronous handback, coalescer flush, cancellation, late-callback rejection and notification order. Shared session tests and macOS engine/attachment tests cover the state machine. |
| `ResponseParsers.swift:103–133,215–231` | One file-private exact source-number conversion replaces duplicate rules. | Both reject boolean NSNumber values, preserve exact integers before Double conversion, and trim only whitespace from strings. Keep planner priority/dedup/cap and assessment range/sorted references/notices separate. Do not include the agent parser, whose coercion differs. |
| `HTTPTransport.swift:118–121,352,705` | Remove unread `Exchange.response` and weak `Exchange.task` state. | Inspect every registry, delegate and cancellation path: tasks are held/cancelled by the session, closures and delegate arguments; responses return through the head continuation. The private final Swift type has no serialization, selectors or supported reflection consumers. Build and real loopback checks establish deletion safety. |
| Unused platform surface | Remove GTK mutators, shortcut uninstallation code, obsolete key/modifier aliases and an unused login default. | Exact members: `GTK.expandVertically` and `GTK.setEnabled`; `ShortcutInstaller.uninstall`; `KeyCode.space/upArrow/downArrow/leftArrow/rightArrow/tab/j/Modifier`; `Preferences.Default.launchAtLogin`. Build-graph/caller inspection found no consumers. CLI flags, GApplication actions, desktop manifests and package hooks expose no uninstall path. These are internal static Swift members, with no C/ObjC hooks or serialized fields. Both platform builds are the gate; no tests are added merely to exercise deleted code. |

## Coverage established before production edits

Nine new tests were committed separately at `05802e0` and passed against the
original implementation on both platforms:

- Direct requests retain their prompt, context, streamed progress, warnings and
  trace label; fallback replaces partial prose; incomplete streams retain prose
  and citation warnings.
- Stop returns queued questions with their levels and attachment bytes in the
  existing callback order, is idempotent, rejects late completion, and is a no-op
  while idle.
- Planner reads preserve real-JSON numeric priority, exact integer boundaries,
  and a cap counted over distinct usable pages. Assessment citations preserve
  exact large integer identity and malformed-reference notices.

The reviewer found an unpinned research trace label. Commit `6581e58` adds
`Answer started`/`Answer completed` assertions to the existing whole-turn test,
still before production changes.

## Validation record

Local Swift, GTK and Xcode tooling is unavailable. Tests and platform builds run
in the repository's CI; local `git diff --check` checks patch whitespace.

| Gate | Evidence |
|---|---|
| Original macOS baseline | [37055857256](https://github.com/L-K-M/Vervellum/actions/runs/37055857256), passed |
| Original Linux baseline, including Flatpak | [37055860622](https://github.com/L-K-M/Vervellum/actions/runs/37055860622), passed |
| Nine new tests on original macOS code | [37056940264](https://github.com/L-K-M/Vervellum/actions/runs/37056940264), 887 tests passed |
| Nine new tests on original Linux code | [37056940338](https://github.com/L-K-M/Vervellum/actions/runs/37056940338), 817 tests, loopback fixtures, GTK lifecycle, Debian and Flatpak gates passed |
| Final pre-refactor label assertions | [macOS](https://github.com/L-K-M/Vervellum/actions/runs/37058104714) and [Linux](https://github.com/L-K-M/Vervellum/actions/runs/37058104652) at `6581e58`, both platform build/test gates passed |
| Final implementation gates | Latest-commit CI and independent diff review: see PR #117 |

Linux gates run `swift build -c release --product vervellum`,
`swift test --parallel`, loopback provider fixtures, GTK lifecycle under Xvfb,
desktop validation, Debian build/install, and Flatpak build/sandbox smoke checks.
macOS runs Xcode 26 `clean test`, including shared and platform-specific tests.

## Adversarial review dispositions

- Independent proposal review found no blocker in the four core candidates.
  Its trace-label coverage gap was addressed before refactoring.
- An independent addendum reproduced the platform auditor's consumer checks and
  found no blocker in the deletion batch. Final-diff review is a separate gate;
  its result is recorded on the PR.
- Preserve direct attribution → cancellation → citation validation ordering;
  research attribution → validation → cancellation is deliberately different.
- Remove the obsolete transport-field rationale with the dead fields, and update
  attachment-test comments naming the deleted cancellation wrapper.
- A suggested read-only guard on explicit history erasure was rejected.
  `SECURITY.md` explicitly permits erasing newer schemas; blocking that action
  would change supported behavior. Startup preservation and explicit deletion
  are different contracts.
- Automated review round one found only minor/informational feedback. Combine
  cancellation's duplicate empty-queue checks; the captured queue is immutable
  and callback order stays identical. Clarify the numeric-padding test without
  changing its expectations. Its cap is eight, not three.
- Defer severity storage in the test sink and explicit labels at every research
  call site: severity code is untouched and one shared label already feeds both
  logging paths. `LogLevel` has no `.error` case. Existing transport comments
  describe `onTermination` cancellation; live hotkey recording uses Carbon
  directly. Removed helpers never provided a reachable uninstallation feature.

## Deferred candidates and separate findings

- `ModelChain` caching and runner/session state retain retry memory, attribution,
  cancellation and lifetime roles. Profile ID uniqueness is not an invariant;
  simplifying cache ownership needs additional compatibility evidence.
- The ignored `ProviderSettings.problems(hasModelKey:)` argument has callers that
  read secret stores. Removing argument evaluation needs side-effect coverage.
- Shared `/model` presentation and process-trail predicates offer some deduplication,
  but UI state/focus coverage is insufficient for a worthwhile extraction.
- Stderr helpers, tiny fence-predicate deduplication and updater constant hoists
  offer little benefit relative to their new abstractions or review cost.
- Unrelated parser inconsistency: agent read actions accept JSON booleans as
  source numbers; planner reads and assessment citations reject them. Preserve
  current agent behavior here; correct it in a separate bug-fix pass.
- Unrelated, unexecuted risk: `SearXNGClient.queryValue` can reach `Int(number)`
  for an integral Double outside Int range, such as a model-written `1e308`.
  A subprocess regression test is needed before fixing the potential trap.
- Documentation drift: `PLAN.md`'s older known-limit bullets still say one
  provider and no page fetching, despite the implemented clients and newer design
  sections. This pass does not revise product documentation.

Real GNOME Wayland behavior and macOS full-screen placement, activation,
multi-display movement, glass, Accessibility and IME remain desktop QA gaps.
Xvfb and unit tests do not establish them. No performance improvement is claimed.
