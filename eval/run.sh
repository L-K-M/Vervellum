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
    # A typo'd or missing mode must not silently run as research: a deep question
    # measured as a cheap pass corrupts the before/after comparison this exists for.
    case "$mode" in
        research) flag="--ask" ;;
        deep)     flag="--deep" ;;
        direct)   flag="--direct" ;;
        *)        echo "eval: $id: no usable 'mode:' line — skipping" >&2; continue ;;
    esac
    if [ -z "$question" ]; then
        echo "eval: $id: no 'question:' line — skipping" >&2
        continue
    fi

    echo "== $id ($mode) =="
    # A deep question is several billed round trips; a wedged one must become a
    # counted failure (timeout exits 124), not a stalled run. macOS: gtimeout from
    # coreutils.
    if timeout "${VERVELLUM_EVAL_TIMEOUT:-900}" "$BINARY" "$flag" "$question" \
            > "$OUT/$id.transcript.txt" 2> "$OUT/$id.trace.txt"; then
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
