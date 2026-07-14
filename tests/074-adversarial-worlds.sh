#!/usr/bin/env bash
# tests/074 — A″5: the adversarial world suite, keyed off the A′1 surface table.
# pins: LAW-23 LAW-39
#
# Every user-observable head must have EITHER an adversarial fixture that
# defeats a hostile world, OR a documented DESIGN §4 honest-edge entry that
# records the trust assumption and its blast radius. The rule is keyed off the
# ONE source of truth for the head set — `pp --dump-surface-tables` renders the
# `$KIND` heads straight from Surface_tables.obs_heads — so a NEW head cannot
# ship unexamined: it appears here automatically and fails the build until it
# gets a fixture or an edge entry. Coverage is derived from the table, never a
# hand-maintained list (DESIGN §1 principle 8).
#
#   fixture:  tests/fixtures/adversarial/<head>.sh   (run under both backends)
#   edge:     a DESIGN §4 "- **E<n> ...(`$head`)...**" entry, verified present
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/adversarial"
DESIGN="$ROOT/docs/DESIGN.md"

fail=0
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

# A head with no adversarial fixture must be justified by a DESIGN §4 edge. The
# mapping lives here, but is only ACCEPTED if the named edge actually exists in
# DESIGN.md — a dangling justification is a red build.
design_edge() {  # head -> edge id, or empty
  case "$1" in
    env)    echo "E10" ;;
    probe)  echo "E11" ;;
    config) echo "E12" ;;
    *)      echo "" ;;
  esac
}

# The head set, straight from the surface table (single source).
heads=$("$PP" --dump-surface-tables \
        | awk '/Observation heads/,/with \{ \}/' \
        | grep -oE '\$[a-z]+' | sed 's/\$//' | sort -u)

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
    edge=$(design_edge "$head")
    if [ -z "$edge" ]; then
      bad "$head" \
        "no adversarial fixture ($fixture) and no DESIGN §4 edge mapping." \
        "Add a fixture, or map $head to a DESIGN §4 edge in this script and document it."
    elif grep -qE "^- \*\*$edge .*\`\\\$$head\`" "$DESIGN"; then
      echo "ok   $head (documented trust assumption: DESIGN §4 $edge)"
      covered=$((covered + 1))
    else
      bad "$head" \
        "mapped to DESIGN §4 $edge, but no matching '- **$edge …(\`\$$head\`)…' entry found in $DESIGN." \
        "The justification is dangling — write the edge, or fix the mapping."
    fi
  fi
done

n_heads=$(printf '%s\n' $heads | grep -c .)
echo "adversarial-worlds: $covered/$n_heads user-observable heads covered (fixture or DESIGN §4 edge)"

if [ $fail -eq 0 ]; then echo "=== ADVERSARIAL WORLDS (A″5) TEST PASSED ==="; fi
exit $fail
