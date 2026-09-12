# Agent research

**Agent loop** — `/agent-loop` (CLI: `vervellum --agent-loop "…"`; the older
`/agent-research` and `--agent` still work) — is the second gathering
architecture in Vervellum: a **bounded tool loop** where the model chooses one
action at a time — run a search, read a page, or stop — and sees what each
action produced before choosing the next. The staged pipeline (**One pass** and
**Deep rounds**) plans up front and follows up in rounds; the loop reacts
continuously.

It sits at the top of the level selector, with a rule drawn above it: it spends
Deep rounds' page and evidence allowance to the character, so it is not "more
depth" — it is the same depth, chosen a step at a time. What puts it last is that
every step is its own model call.

This document is the design record: why the loop exists, what it keeps from the
staged design, where it deliberately differs, and what bounds it.

## Why a loop

Every comparable system converged on this shape. OpenAI's and Gemini's deep
research run agentic loops over tens of minutes; Anthropic's Research system is
an orchestrator spawning parallel subagents, and their engineering post carries
the two numbers that decide the argument: token usage alone explained ~80% of
performance variance on BrowseComp, and parallel tool calling cut research time
by up to 90%. Reacting to actual results beats planning against a digest,
because the gap does not exist until something has been looked up.

The staged pipeline answers that partially — Deep rounds' rounds read what
the last round found — but a round is a coarse step: up to four queries decided
at once, between two model calls. The loop is the fine-grained version: one
decision at a time, each made with the previous action's results in view.

## What it keeps

The loop changes **who decides the next search** and nothing else. Every
guarantee the staged pipeline makes holds here, because the tail is shared
code, not a parallel implementation:

- **The model never writes a URL.** It cites numbers from a list Vervellum
  built; the answer prompt, the citation validation and the revision gate are
  the same ones every mode uses.
- **A model-written value never becomes a command.** Search arguments go
  through the same `SearchBackend.validate` schema check the staged path
  applies; page reads go through the same public-address filter.
- **The evidence budget, the page budget and the source cap** are the same
  constants (`maxDeepEvidenceCharacters`, `maxDeepPages`, `maxSources`), spent
  by the loop instead of by rounds.
- **Answer → assess → revise** runs untouched afterwards: the answer is
  streamed over the numbered sources, graded against them, and corrected only
  through the validated, fail-soft revision stage.
- **Every degradation still has its notice.** Trimmed evidence, unread pages,
  failed searches — the loop cannot silently drop anything, because it uses the
  same accounting.

## The loop

One JSON call per step:

```json
{"thought": "what the evidence establishes and what this step is for",
 "action": "search" | "read" | "answer",
 "arguments": {…},   // search only, against the advertised inputSchema
 "sources": [2, 5]}  // read only, numbers from the digest
```

Each step's payload carries: the question, the digest of sources so far (with
`[read]` marks and stable numbers — the same digest the deep rounds use), the
failed-query list, the attachments, and the **budget**: the step number, the
steps left, and the searches left. Stating the budget in the payload is what
makes the caps collaborative rather than a cliff — a model that can see three
searches left plans differently than one that will be cut off mid-thought.

Reading works like the deep rounds' `read` requests: name a source by its
digest number, the page is fetched in full and marked read for later steps. A
snippet is a search engine's summary; the loop is told to read before letting a
source carry a load-bearing claim.

## Bounds

| Bound | Value | Why |
|---|---|---|
| Steps (model calls) | 16 | A read-heavy loop is bounded by wall clock, not requests. |
| Searches | 12 | Above the staged path's 12 (4 × 3 rounds) by intent; bounded, because an unbounded loop is the one thing this architecture exists not to be. |
| Page reads | the turn's deep page allowance | Same `maxDeepPages` the deep rounds spend. |
| Evidence | the deep evidence budget | The same trimmer; the loop stops when it is full, exactly as rounds do. |

The loop ends on `"answer"`, on any budget, on a full evidence budget, or on an
unparseable step — all of which fall through to the shared tail with whatever
exists. An explicit `answer` with nothing gathered is honoured exactly like the
staged planner's empty plan: the turn is answered from the model alone and
badged `noEvidence`. A loop stopped by a budget with nothing gathered is *not*
— that is a gather that failed, and the turn says so.

## What is deliberately absent

- **No post-assessment regather.** The deep path goes back for one more round
  when its check finds an unsettled claim. The loop does not: its whole run
  *was* the regather mechanism, and an `insufficient` verdict after a loop that
  chose to stop is the answer, not a reason to reopen the loop.
- **No parallel subagents.** Anthropic's architecture parallelises with
  subagents that hold their own context windows. Vervellum's value here is the
  opposite trade: one auditable trace, every step visible on the turn, every
  action charged to a stated budget. Stateless search *engines* are fanned out
  concurrently within a step (the same fan-out deep rounds use); the steps
  themselves are serial because each is justified by the last.
- **No free-form tool use.** Three actions, one per step, validated. A loop
  that could invent tools would be a different product with a different
  threat model.

## Cost and latency

A step is one model call plus its action. A typical turn is a handful of steps;
a pathological one is bounded at 16 calls, 12 searches and the page/evidence
budgets — comparable to a three-round deep turn at the ceiling, cheaper than
most, because reacting to results spends fewer queries proving what is already
known.

## Where the code is

- `ResearchRunner.agentLoop` — the loop itself (`Sources/VervellumKit/Core/Research/ResearchRunner.swift`).
- `ResearchPrompts.agentLoop` — the per-step prompt (`ResearchPrompts.swift`).
- `AgentStepParser` — step validation (`ResponseParsers.swift`).
- `stagedGathering` — the other gathering path, sharing the same tail.
- `DEEP-RESEARCH-REVIEW.md` — the comparison that produced both.
