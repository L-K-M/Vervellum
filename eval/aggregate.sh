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

# No cd: judged-dir paths resolve against the caller, where before/after pairs
# live; nothing here reads anything relative to the repo root.

aggregate() {
    # $1 = dir. Emits "factual citation coverage source_quality calibration passes fails n".
    awk '
        function commit() {
            if (!have) return
            f += sc["factual"]; c += sc["citation"]; cov += sc["coverage"]
            sq += sc["source_quality"]; cal += sc["calibration"]; n++
            # A record accepted on its factual score may still be missing axes,
            # which read as 0.0 below — the more likely failure of a capable but
            # sloppy judge, and quieter than no record at all.
            axes = 0
            for (k in sc) axes++
            if (axes < 5) incomplete++
            # judge.md defines the verdict as exactly this predicate; deriving it
            # here makes the gate deterministic even when the judge disagrees
            # with its own arithmetic.
            if (sc["factual"] >= 0.8 && sc["citation"] >= 0.7 && sc["calibration"] >= 0.7) p++
            else f2++
            have = 0
        }
        # A new file commits the previous one: files are cases. This rule runs
        # before the fence rule on purpose: a fenced reply puts ``` on line 1,
        # and the fence rule would skip this commit and drop the previous
        # case — the common shape of a judge reply, not an edge.
        FNR == 1 { commit(); split("", sc); pending = ""; depth = 0; files++ }
        # Fence lines are decoration, not cases.
        /^[ \t]*```/ { next }
        {
            # A judge may pretty-print its JSON across lines: accumulate until
            # the braces balance, then parse the whole object at once. A
            # single-line object balances immediately, so nothing changes for
            # the one-line contract.
            depth += gsub(/\{/, "&", $0) - gsub(/\}/, "&", $0)
            pending = pending $0
            if (depth > 0) next
            line = pending; pending = ""; depth = 0
            # Parse into a candidate; only an object that actually carries a
            # factual score replaces the record. Brace-bearing prose after the
            # JSON must not wipe what was parsed. The last score-bearing object
            # wins.
            split("", cand)
            # Each axis is found by its quoted key rather than by field position:
            # a judge may prefix the JSON with prose ("real: {...}"), and values
            # may share a line with anything. index()+substr rather than match():
            # see the header comment.
            na = split("factual citation coverage source_quality calibration", names, " ")
            for (a = 1; a <= na; a++) {
                k = names[a]
                # The quoted key alone, then the value after any spaces and the
                # colon — pretty-printers put a space before the colon too, and
                # the needle has no business caring.
                pos = index(line, "\"" k "\"")
                if (pos > 0) {
                    rest = substr(line, pos + length(k) + 2)
                    sub(/^[ \t:]+/, "", rest)
                    sub(/[^0-9.].*$/, "", rest)
                    if (rest != "" && rest != ".") cand[k] = rest + 0
                }
            }
            if ("factual" in cand) {
                # The whole record, not a merge: a second object missing an axis
                # must not inherit it from the object before, or the gate would
                # read a mixture no judge ever wrote.
                split("", sc)
                for (k in cand) sc[k] = cand[k]
                have = 1
            }
        }
        END {
            commit()
            if (n == 0) { printf "no judged cases in %s\n", dir > "/dev/stderr"; exit 1 }
            # Files that produced no case shrink the comparison silently no
            # longer: the count says which replies never parsed.
            if (files > n) {
                printf "warning: %d of %d files in %s produced no readable scores\n", \
                       files - n, files, dir > "/dev/stderr"
            }
            if (incomplete > 0) {
                printf "warning: %d case(s) in %s missing one or more axes (scored as 0.0)\n", \
                       incomplete, dir > "/dev/stderr"
            }
            printf "%.3f %.3f %.3f %.3f %.3f %d %d %d\n", f/n, c/n, cov/n, sq/n, cal/n, p, f2, n
        }
    ' dir="$1" "$1"/*.json || return 1
}

DIR1="${1:?usage: eval/aggregate.sh <judged-dir> [other-judged-dir]}"
echo "                factual citation coverage sourceq calibr. pass fail n"
row1=$(aggregate "$DIR1") || exit 1
echo "$(basename "$DIR1")  $row1"
if [ $# -ge 2 ]; then
    row2=$(aggregate "$2") || exit 1
    echo "$(basename "$2")  $row2"
fi
