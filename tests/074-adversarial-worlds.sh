#!/usr/bin/env bash
# Check every user-observable read against an adversarial fixture or a
# structured honest-edge record.
# pins: LAW-23 LAW-39
#
# `pp --dump-surface-tables` provides the head set. A new head therefore fails
# until it has a fixture or a record in honest-edges.tsv.
#
# Fixture: tests/fixtures/adversarial/<head>.sh
# Record:  tests/fixtures/adversarial/honest-edges.tsv
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/adversarial"
EDGES="$FIX/honest-edges.tsv"

if ! awk -F '\t' '
  /^[[:space:]]*#/ || NF == 0 { next }
  NF != 2 || $1 !~ /^[a-z][a-z0-9-]*$/ || $2 == "" {
    print "invalid honest-edge record: " $0 > "/dev/stderr"; bad=1
  }
  seen[$1]++
  END {
    for (head in seen) if (seen[head] > 1) {
      print "duplicate honest-edge record: " head > "/dev/stderr"; bad=1
    }
    exit bad
  }
' "$EDGES"; then
  bad "honest-edge-manifest" "invalid or duplicate record in $EDGES"
  exit 1
fi

edge_reason() {
  awk -F '\t' -v wanted="$1" '$1 == wanted { print $2; exit }' "$EDGES"
}

# The head set, straight from the surface table (single source).
heads=$("$PP" --dump-surface-tables \
        | awk '
            /Observation heads/,/with \{ \}/ {
              line = $0
              while (match(line, /\$[a-z][a-z0-9-]*/)) {
                print substr(line, RSTART + 1, RLENGTH - 1)
                line = substr(line, RSTART + RLENGTH)
              }
            }
          ' | sort -u)

if [ -z "$heads" ]; then
  bad "enumerate-heads" "no heads parsed from --dump-surface-tables"
  exit 1
fi

covered=0
for head in $heads; do
  fixture="$FIX/$head.sh"
  if [ -f "$fixture" ]; then
    if PP="$PP" bash "$fixture"; then
      echo "ok   $head (adversarial fixture defeats the hostile world)"
      covered=$((covered + 1))
    else
      bad "$head" "adversarial fixture $fixture FAILED"
    fi
  else
    reason=$(edge_reason "$head")
    if [ -z "$reason" ]; then
      bad "$head" \
        "no adversarial fixture ($fixture) and no honest-edge record." \
        "Add a fixture or add a tab-separated record to $EDGES."
    else
      echo "ok   $head (honest edge: $reason)"
      covered=$((covered + 1))
    fi
  fi
done

n_heads=$(printf '%s\n' $heads | grep -c .)
echo "adversarial-worlds: $covered/$n_heads user-observable heads covered (fixture or honest edge)"

if [ $fail -eq 0 ]; then echo "=== ADVERSARIAL WORLDS TEST PASSED ==="; fi
exit $fail
