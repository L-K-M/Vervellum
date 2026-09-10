#!/bin/bash
# Runs the question bank against a built vervellum binary and writes, per
# question, the transcript, the trace, and a judge-ready case file.
#
# Usage: eval/run.sh [path-to-binary] [output-dir]
#   binary   defaults to .build/release/vervellum (build it first)
#   output   defaults to eval/runs/<timestamp>
#
# Configuration comes from ~/.config/vervellum as usual; for a container,
# VERVELLUM_MODEL_KEY and VERVELLUM_SEARCH_KEY are enough. Deep-mode questions
# cost several times a quick question in billed requests — that is the point
# being measured, and the reason the bank stays small.
set -uo pipefail

cd "$(dirname "$0")/.."
BINARY="${1:-.build/release/vervellum}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${2:-eval/runs/$STAMP}"

if [ ! -x "$BINARY" ]; then
    echo "eval: $BINARY not found or not executable" >&2
    echo "build it first: swift build -c release --product vervellum" >&2
    exit 1
fi

mkdir -p "$OUT"
pass=0
fail=0

for file in eval/questions/*.txt; do
    id=$(basename "$file" .txt)
    mode=$(grep -m1 '^mode: ' "$file" | cut -d' ' -f2- | xargs)
    question=$(grep -m1 '^question: ' "$file" | cut -d' ' -f2-)
    flag="--ask"
    [ "$mode" = "deep" ] && flag="--deep"
    [ "$mode" = "direct" ] && flag="--direct"

    echo "== $id ($mode) =="
    if "$BINARY" "$flag" "$question" > "$OUT/$id.transcript.txt" 2> "$OUT/$id.trace.txt"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "   failed (see $id.trace.txt)"
    fi

    # The case file is the judge's whole input: rubric lives in judge.md.
    {
        echo "# Case $id"
        echo
        cat "$file"
        echo
        echo "# Transcript"
        echo
        cat "$OUT/$id.transcript.txt"
    } > "$OUT/$id.case.txt"
done

echo
echo "done: $pass ran, $fail failed -> $OUT"
echo "judge each case with eval/judge.md, then compare across runs as README.md describes"
[ "$fail" -eq 0 ]
