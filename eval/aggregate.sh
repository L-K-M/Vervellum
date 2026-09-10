#!/bin/bash
# Averages judge output for one or two judged directories and prints the
# comparison the ship/no-ship gate needs. Pure awk: the judge is told to answer
# with one line of JSON, and anything it wrapped in fences is stripped here.
#
# Usage: eval/aggregate.sh <judged-dir> [other-judged-dir]
#   A judged dir holds one <case>.json per case: the judge's reply to the
#   matching .case.txt, saved verbatim (fences are fine).
set -uo pipefail

cd "$(dirname "$0")/.."

aggregate() {
    # $1 = dir. Emits "factual citation coverage source_quality calibration passes fails n".
    awk '
        # Strip markdown fences and isolate the first {...} on the line.
        /^\s*```/ { next }
        /\{.*\}/ {
            line = $0
            for (i = 1; i <= 5; i++) {
                key = substr("factual citation coverage source_quality calibration", (i-1)*11+1, 10)
            }
            for (k in keys) delete keys[k]
            while (match(line, /"(factual|citation|coverage|source_quality|calibration)": *[0-9.]+/)) {
                part = substr(line, RSTART, RLENGTH)
                gsub(/[": ]/, "", part)
                name = part; sub(/[0-9.]+$/, "", name)
                value = part; sub(/^[a-z_]+/, "", value)
                keys[name] = value + 0
                line = substr(line, RSTART + RLENGTH)
            }
            if ("factual" in keys) {
                f += keys["factual"]; c += keys["citation"]; cov += keys["coverage"]
                sq += keys["source_quality"]; cal += keys["calibration"]; n++
            }
            if ($0 ~ /"verdict": *"pass"/) p++; else f2++
        }
        END {
            if (n == 0) { printf "no judged cases in %s\n", dir > "/dev/stderr"; exit 1 }
            printf "%.3f %.3f %.3f %.3f %.3f %d %d %d\n", f/n, c/n, cov/n, sq/n, cal/n, p, f2, n
        }
    ' dir="$1" "$1"/*.json 2>/dev/null || { echo "aggregate: no judge JSON in $1" >&2; return 1; }
}

DIR1="${1:?usage: eval/aggregate.sh <judged-dir> [other-judged-dir]}"
echo "                factual citation coverage sourceq calibr. pass fail n"
row1=$(aggregate "$DIR1") || exit 1
echo "$(basename "$DIR1")  $row1"
if [ $# -ge 2 ]; then
    row2=$(aggregate "$2") || exit 1
    echo "$(basename "$2")  $row2"
fi
