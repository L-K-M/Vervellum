# Deep Research Review

A review of `/deep-research` against OpenAI Deep Research, Gemini Deep Research,
Anthropic's Research system, GPT-Researcher, and Stanford STORM, and the changes
made as a result. Written 2026-09-10; the "Implemented changes" section is kept in
step with the code.

## What the pipeline does today

A deep turn is: read pages linked in the question (≤3, charged against the page
budget) → plan (≤4 searches, primary-source and disconfirming-search instructions)
→ round 1 searches put to *every* configured engine → up to two follow-up rounds
planned against a digest of what was found → read pages behind top results (≤3 per
turn, prefix order) → evidence assembly (≤24 sources, ≤70 KB, prefix kept) →
streamed answer citing by number only → assessment grading the answer's claims
(`supported` / `contradicted` / `mixed` / `insufficient` / `opinion`, evidential
verdicts must cite) → revision when a claim is contradicted or mixed, validated
before acceptance.

## Where it already leads

- **Structural citation integrity.** The model cannot write a URL; it cites numbers
  from a list Vervellum owns. Every other tool reviewed string-matches or trusts the
  model.
- **Claim-level verification with `insufficient` as a first-class outcome**, plus a
  validated, gated revision pass. The comparison tools ship citations without visible
  claim grading; Anthropic's CitationAgent checks attribution, not truth.
- **Snippet vs. `page_text` distinction**, notices for every degradation, evidence
  kept whole between rounds.
- **Multi-engine fan-out with dedupe.** Most tools are single-index.
- **Fail-soft stages and provider fallback.**

The verification half of the product is ahead of the field. The gathering half is
where the gaps were.

## What the other tools do differently

| Tool | Gathering | Verification | Steering |
|---|---|---|---|
| OpenAI Deep Research | Agentic loop, tens of minutes, many pages, code execution | Citation links only | Clarifying questions, editable plan, mid-run steering |
| Gemini Deep Research | Agentic loop, 5–10+ min | Citation links only | Editable plan before start |
| Anthropic Research | Orchestrator + parallel subagents, parallel tool calls | CitationAgent (attribution) | Effort scaled to query complexity |
| GPT-Researcher | Sub-question decomposition, >20 sources scraped, relevance filtering; tree-exploration deep mode | Frequency-of-agreement heuristic | Depth/breadth config |
| STORM | Perspective-guided questioning, simulated expert dialogue | Per-section grounding | Outline then article |

Two measured findings from Anthropic's engineering post carry the most weight:

- Token usage alone explained ~80% of the performance variance on BrowseComp; tool
  calls and model choice explained most of the rest. Deep-research quality is, to a
  first approximation, a function of how much evidence the system actually processes.
- Parallel tool calling cut research time by up to 90%, which is what makes spending
  those tokens affordable.

Also noted: Anthropic's human testers caught agents preferring SEO content farms
over authoritative sources, fixed with source-quality prompting. OpenAI and Gemini
both expose plan review before spending.

## The gaps found

Ranked by expected impact on answer quality.

### G1 — Deep mode read no more than quick mode, and read the wrong pages
`PageReaderFactory.maxPages = 3` was a per-turn constant, shared with linked pages.
Reading is the main thing "deep" means everywhere else. Worse, both selection
mechanisms favored round 1: `readPages` took the list prefix (linked first, then
search rank), and `ResearchContext.evidence` kept a prefix when over budget, so
round 2–3 sources — the gap-closers the extra rounds exist to find — were dropped
first.

### G2 — Page selection was rank order, never judgment
No relevance pass existed between "found" and "read". The follow-up planner is the
natural judge, but the digest deliberately carried no URLs and renumbered entries
locally, so the planner could not say "read source 7 in full". The commonest gap
after round 1 is not "search more" but "read the page behind that snippet", and the
pipeline had no channel for it.

### G3 — Assessment `followups` were computed, displayed, and discarded
The assessor names up to three questions that would materially reduce the remaining
uncertainty, and in deep mode nothing acted on them. A load-bearing claim judged
`insufficient` is exactly the signal a deep turn should use for one more targeted
round.

### G4 — No sub-question decomposition
The plan was a flat list of ≤4 queries. Every comparison tool decomposes explicitly
and scales effort to complexity. Vervellum ran the same three-round shape for a
one-fact question and for a literature review, and the answer's structure had no
spine to hang on.

### G5 — The follow-up planner was half-blind
It saw what was found, never what was tried and failed; a query that returned
nothing was indistinguishable from one never run. And the digest renumbered sources
1…40 locally, so nothing downstream could reference the turn's real numbering. The
answer payload's `searches_run` listed round 1's searches only, over evidence that
included later rounds' results.

### G6 — Sequential searches, with a justification covering one backend
"Sequential on purpose" holds for the stateful MCP session; SearXNG, the Kagi CLI,
and *across engines* have no such constraint. Deep mode multiplies the count:
4 queries × N engines × rounds, serialized.

### G7 — One answer shape for all modes
A deep answer used the same "headings only when genuinely needed" prompt as a quick
lookup. The field's norm for deep output is structured (outline → sections).

### G8 — No source-quality or diversity signal in evidence assembly
"Prefer primary sources" was asked at query-planning time only. Nothing in assembly
countered one domain filling the list, and rank order was trusted as quality order.
Anthropic's content-farm failure mode lives here.

### G9 — No human checkpoint *(deliberately not implemented)*
OpenAI and Gemini review the plan before spending. The decision here is that the
system should be smart without user intervention: disambiguation, effort scaling,
and correction are the pipeline's job, not the user's.

### G10 — No way to measure any of this
The test suite proves the plumbing obeys its rules; nothing measured answer quality.
Anthropic started with ~20 queries and an LLM judge.

## The architectural fork

The field has converged on **bounded agentic loops** — the model calls search/read
tools until satisfied, under effort caps — over fixed stage pipelines, because
reacting to actual results beats planning against a digest. Vervellum's staged
design buys predictable cost, a fully auditable process trail, and a known stage for
every degradation. Both positions are now implemented and documented:

- The staged pipeline (`/deep-research`) keeps its contract and absorbs the
  gathering improvements above.
- `/agent-research` runs a bounded tool loop — see [`AGENT-RESEARCH.md`](AGENT-RESEARCH.md).

## Implemented changes

_Tracking section. Each entry names the gap it closes and the PR that landed it._

(pending)
