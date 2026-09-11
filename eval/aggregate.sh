#!/bin/bash
# Averages judge output for one or two judged directories and prints the
# comparison the ship/no-ship gate needs.
#
# Usage: eval/aggregate.sh <judged-dir> [other-judged-dir]
#   A judged dir holds one <case>.json per case: the judge's reply to the
#   matching .case.txt, saved verbatim (fences are fine).
#
# Per file, the LAST score-bearing line wins — a reply that repeats the template
# before answering, or emits the JSON both bare and fenced, is one case, not
# three. The verdict is recomputed from the rubric's thresholds rather than
# trusted from the judge's string, so an arithmetic slip in the verdict field
# cannot flip the gate.
#
# The parsing is deliberately built on split() rather than match()/RSTART:
# Debian's default awk is mawk, whose match() semantics diverge enough to loop
# forever on this program, and this script must run under mawk, gawk and the
# BSD/macOS awk alike.
set -uo pipefail

cd "$(dirname "$0")/.."

aggregate() {
    # $1 = dir. Emits "factual citation coverage source_quality calibration passes fails n".
    awk '
        function commit() {
            if (!have) return
            f += sc["factual"]; c += sc["citation"]; cov += sc["coverage"]
            sq += sc["source_quality"]; cal += sc["calibration"]; n++
            # judge.md defines the verdict as exactly this predicate; deriving it
            # here makes the gate deterministic even when the judge disagrees
            # with its own arithmetic.
            if (sc["factual"] >= 0.8 && sc["citation"] >= 0.7 && sc["calibration"] >= 0.7) p++
            else f2++
            have = 0
        }
        # Fence lines are decoration, not cases.
        /^[ \t]*```/ { next }
        # A new file commits the previous one: files are cases.
        FNR == 1 { commit(); split("", sc) }
        /\{.*\}/ {
            split("", sc)
            # Each axis is found by its quoted key rather than by field position:
            # a judge may prefix the JSON with prose ("real: {...}"), and values
            # may share a line with anything. index()+substr rather than match():
            # see the header comment.
            na = split("factual citation coverage source_quality calibration", names, " ")
            for (a = 1; a <= na; a++) {
                k = names[a]
                pos = index($0, "\"" k "\":")
                if (pos > 0) {
                    rest = substr($0, pos + length(k) + 3)
                    sub(/^[^0-9.]*/, "", rest)
                    sub(/[^0-9.].*$/, "", rest)
                    if (rest != "" && rest != ".") sc[k] = rest + 0
                }
            }
            if ("factual" in sc) have = 1
        }
        END {
            commit()
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
