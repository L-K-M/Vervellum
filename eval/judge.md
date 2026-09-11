# Research answer judge

A rubric prompt for grading one case file from `eval/run.sh`. One model call per
case, all axes at once — a single call with a single rubric is more consistent than
one judge per axis, and cheaper to repeat.

Paste this file, then the case file, into a capable model. For the record: the
judge should not be the same model that produced the answer, or the run measures
self-agreement as much as quality.

---

You are grading one answer produced by a research tool. The case file below
contains the question, what a correct answer must establish (`expect`), what it
must not assert (`must-not`), and the tool's full transcript — answer, findings,
and numbered sources.

Score each axis from 0.0 to 1.0:

- **factual** — are the claims true, and does the answer establish what `expect`
  requires? Any assertion from `must-not` caps this at 0.3. If the case header's
  `# Status:` is anything other than `ok`, return every axis 0.0 and verdict
  `fail` — a failed run is a failed run, not a bad answer. For a case marked
  `current: true`, judge "true" against the `# Run:` date in the header, not
  your training data.
- **citation** — does every load-bearing claim carry a citation, and does the
  cited source actually back it? A claim resting on a source that does not say it
  is worse than no citation: it manufactures trust. A `mode: direct` case is
  judged on the opposite: it must cite nothing and must not imply sources —
  score it 1.0 unless it fabricates a citation or a source, which scores 0.0.
- **coverage** — are the material parts of the question all addressed? For a
  comparison, both sides; for a "who owns" question, the distinction between
  country and company; and so on.
- **source quality** — do the sources lean on primary or authoritative material
  rather than content farms and unattributed summaries? Were pages actually read,
  or only snippets? The transcript says which.
- **calibration** — are contested or thin points stated as contested or thin?
  Confidence the evidence does not carry is the failure this tool exists to
  prevent.

Then a verdict: exactly `pass` if factual >= 0.8 and citation >= 0.7 and
calibration >= 0.7, otherwise exactly `fail`, both lowercase. These thresholds
are duplicated on purpose — here for the judge, and in `aggregate.sh`, which
recomputes the verdict from the scores rather than trusting the string. Change
them in both places or the gate and the judge will disagree.

Return one JSON object and nothing else, on one line so the output parses even
when copied verbatim:

{"factual": 0.0, "citation": 0.0, "coverage": 0.0, "source_quality": 0.0, "calibration": 0.0, "verdict": "fail", "notes": "one or two sentences: the strongest and weakest thing about this answer"}

The template's verdict is `fail` deliberately: an example is an anchor, and a
judge that leans on it should err toward the verdict that triggers more scrutiny,
not less.
