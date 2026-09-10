# Eval: measuring answer quality

The unit tests prove the pipeline obeys its rules. They cannot prove the answers
are good — a plan can be valid, a citation in range, and the answer still wrong.
This harness is the other half: a small question bank with known answers, a runner
that collects transcripts, and a judge rubric that grades them.

It exists because deep-research changes are otherwise unfalsifiable. Any change to
planning, reading, or the prompts should run the bank before and after; a change
that cannot move this score is not a quality improvement.

## Layout

- `questions/` — one file per question: `mode` (`research`, `deep`, `direct`),
  `question`, `expect` (what a correct answer must establish), `must-not` (what it
  must not assert). Questions marked `current: true` decay; refresh them when they
  go stale.
- `run.sh` — runs the bank against a built binary, one transcript per question.
- `judge.md` — the grading rubric, one model call per case file.

## Running

```bash
swift build -c release --product vervellum
eval/run.sh                      # .build/release/vervellum, fresh timestamped dir
eval/run.sh .build/release/vervellum eval/runs/before   # named dir, for a pair
```

Keys come from the normal settings, or from `VERVELLUM_MODEL_KEY` /
`VERVELLUM_SEARCH_KEY` in a container. Deep-mode questions cost several times a
quick question in billed requests; the bank is twenty questions on purpose.

## Judging

Feed `judge.md` plus one `.case.txt` to a capable model that is **not** the model
being evaluated. Collect the JSON, average the axes, count the verdicts. A change
ships if the after-run beats the before-run on factual + citation without losing
calibration; everything else is taste.

## Comparing runs

Keep runs side by side (`eval/runs/before`, `eval/runs/after`) and diff the case
files before judging — a changed answer with the same score is still a signal.
Do not judge a run against another run's transcript directly; both go through the
rubric, or the comparison measures the judge's mood, not the pipeline.

## What this does not measure

Latency, cost, and provider behaviour are visible in the traces (`*.trace.txt`),
not the score. UI behaviour is verified by hand. The bank is small by design — it
catches large regressions and validates direction, and no more.
