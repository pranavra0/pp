#!/usr/bin/env bash
# tests/074 — every user-observable read ($env, $file, $probe, ...) must
# either defeat a hostile world or have its trust assumption written down.
# pins: LAW-23 LAW-39
#
# Every user-observable head must have EITHER an adversarial fixture that
# defeats a hostile world, OR a documented DESIGN.md honest-edge entry that
# records the trust assumption and its blast radius. The rule is keyed off the
# ONE source of truth for the head set — `pp --dump-surface-tables` renders the
# `$KIND` heads straight from Surface_tables.obs_heads — so a NEW head cannot
# ship unexamined: it appears here automatically and fails the build until it
# gets a fixture or an edge entry. Coverage is derived from the table, never a
# hand-maintained list.
#
#   fixture:  tests/fixtures/adversarial/<head>.sh   (run under both backends)
#   edge:     a bullet in DESIGN.md's "Honest edges" section whose first line
#             names `$head`, verified present
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/adversarial"
DESIGN="$ROOT/docs/DESIGN.md"

# A head with no adversarial fixture must be justified by a documented trust
# assumption. The allowlist lives here, but a head on it is only ACCEPTED if
# DESIGN.md's "Honest edges" section has a bullet naming the head — a
# dangling justification is a red build.
edge_allowed() {  # head -> 0 if a documented honest edge may cover it
  case "$1" in
    env|probe|config) return 0 ;;
    *)                return 1 ;;
  esac
}
honest_edges() {  # the "Honest edges" section of DESIGN.md
  awk '/^## Honest edges/{on=1; next} on && /^## /{exit} on' "$DESIGN"
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
    if ! edge_allowed "$head"; then
      bad "$head" \
        "no adversarial fixture ($fixture) and not on the honest-edge allowlist." \
        "Add a fixture, or allowlist $head here and document the trust assumption in DESIGN.md's honest edges."
    elif honest_edges | grep -qE "^- .*\`\\\$$head\`" ; then
      echo "ok   $head (documented trust assumption: DESIGN.md honest edge)"
      covered=$((covered + 1))
    else
      bad "$head" \
        "allowlisted, but no honest-edge bullet naming \`\$$head\` found in $DESIGN." \
        "The justification is dangling — write the edge bullet, or fix the allowlist."
    fi
  fi
done

n_heads=$(printf '%s\n' $heads | grep -c .)
echo "adversarial-worlds: $covered/$n_heads user-observable heads covered (fixture or honest edge)"

if [ $fail -eq 0 ]; then echo "=== ADVERSARIAL WORLDS TEST PASSED ==="; fi
exit $fail
