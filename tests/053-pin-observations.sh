#!/usr/bin/env bash
# tests/053-pin-observations.sh — the observation-pinning seam: a
# standalone --pin-file/--dump-pins pair that generalizes the existing
# --remote-node pin machinery (src/runtime/remote.ml's preseed_pins_from_file /
# parse_pin_line) used for forked workers, plus a new `(pin-probe "NAME"
# <codec-value>)` line kind that pins a register-probe's OWN value
# directly into the session's probe cache, short-circuiting its observe-fn
# entirely (Primitives.probe_value_for consults probe_values FIRST,
# unconditionally, before ever calling a registered probe's fn).
#
# demo/volatile-deploy.pp folds `(probe "replica-count")` directly into its
# returned desired-state value, so the published hash tracks
# metrics-file's CURRENT content whenever the probe is left unpinned — the
# one shape that makes "probe cells are pinned inputs" falsifiable.
#
#   unpinned control — publish twice with DIFFERENT metrics-file content:
#                       the two hashes must DIFFER (proves the probe is
#                       genuinely volatile, not a strawman).
#   canonical run — --dump-pins captures one run's file and probe
#                       observations as a pin file.
#   pinned — --pin-file that dump, across 3 placement
#                       combinations (serial/parallel:4/remote:B),
#                       metrics-file mutated to a DIFFERENT value than
#                       canonical: all 3 published hashes must equal the
#                       canonical hash, AND the observe-fn's sentinel file
#                       must be ABSENT for every one of them (proof the
#                       observe-fn never ran at all).
#
# Push/materialization combinations are not wired here:
# the program deliberately registers no domain — it is
# the minimal adversarial shape (a bare probe folded into a returned
# value, nothing to materialize onto disk) — so a --watch --stabilize
# "push" pass has no tree to converge/diff against. Push+remote combos are
# impractical to wire for a hash comparison here, so the 3 pull
# (--publish-object) combos below cover the hash-equality core instead.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
trap 'rm -rf "$TMP"' EXIT

DEMO_PP="$PWD/demo/volatile-deploy.pp"
GRANTS=(--grant "fs:$TMP:rw")
METRICS="$TMP/metrics.txt"
SHARED="$TMP/shared"; mkdir -p "$SHARED"

# =====================================================================
# Unpinned control: the probe is genuinely volatile
# =====================================================================
echo "--- unpinned control ---"
CTL_HOME="$TMP/home-control"; mkdir -p "$CTL_HOME"
publish_unpinned() {  # METRICS-VALUE SENTINEL-BASENAME -> sets $HASH/$UNPINNED_OUT
  printf '%s\n' "$1" > "$METRICS"
  rm -rf "$CTL_HOME/.pp/store"
  UNPINNED_OUT=$(HOME="$CTL_HOME" "$PP" "${GRANTS[@]}" --publish-object "$SHARED" "$DEMO_PP" -- "$METRICS" "$TMP/$2" 2>&1)
  HASH=$(printf '%s' "$UNPINNED_OUT" | grep -oE '[0-9a-f]{64}' | head -1)
}
publish_unpinned 5 sentinel-u1.txt
H1="$HASH"
if [ -n "$H1" ]; then ok "control-run1-publishes ($H1)"; else bad "control-run1-publishes" "$UNPINNED_OUT"; fi
[ -f "$TMP/sentinel-u1.txt" ] && ok "control-run1-observe-fn-ran (sentinel present)" \
  || bad "control-run1-observe-fn-ran" "sentinel missing"

publish_unpinned 42 sentinel-u2.txt
H2="$HASH"
if [ -n "$H2" ]; then ok "control-run2-publishes ($H2)"; else bad "control-run2-publishes" "$UNPINNED_OUT"; fi

if [ -n "$H1" ] && [ -n "$H2" ] && [ "$H1" != "$H2" ]; then
  ok "control-hashes-differ (probe genuinely volatile: $H1 vs $H2)"
else
  bad "control-hashes-differ" "H1=$H1 H2=$H2"
fi

# =====================================================================
# Canonical run: --dump-pins captures the pin file
# =====================================================================
echo "--- canonical run + dump-pins ---"
CANON_VALUE=7
printf '%s\n' "$CANON_VALUE" > "$METRICS"
PIN_HOME="$TMP/home-canonical"; mkdir -p "$PIN_HOME"
PINS_FILE="$TMP/pins.txt"
HOME="$PIN_HOME" "$PP" "${GRANTS[@]}" --dump-pins "$PINS_FILE" "$DEMO_PP" -- "$METRICS" "$TMP/sentinel-canon.txt" \
  > "$TMP/canon-dump.out" 2>&1
if [ -s "$PINS_FILE" ] && grep -q '(pin-probe "replica-count"' "$PINS_FILE"; then
  ok "dump-pins-writes-pin-probe-line"
else
  bad "dump-pins-writes-pin-probe-line" "$(cat "$PINS_FILE" 2>&1)" "$(cat "$TMP/canon-dump.out")"
fi
[ -f "$TMP/sentinel-canon.txt" ] && ok "canonical-run-observe-fn-ran (unpinned canonical pass)" \
  || bad "canonical-run-observe-fn-ran"

CANON_OUT=$(HOME="$PIN_HOME" "$PP" "${GRANTS[@]}" --publish-object "$SHARED" "$DEMO_PP" -- "$METRICS" "$TMP/sentinel-canon2.txt" 2>&1)
CANON_HASH=$(printf '%s' "$CANON_OUT" | grep -oE '[0-9a-f]{64}' | head -1)
if [ -n "$CANON_HASH" ]; then ok "canonical-publishes ($CANON_HASH)"; else bad "canonical-publishes" "$CANON_OUT"; fi

# Pinned: 3 pull combos (placement serial/parallel:4/remote:B), --pin-file
# + a metrics-file value DIFFERENT from canonical.
# Reuses $PIN_HOME's own (already-warm) store across every combo below —
# deliberately NOT wiped between runs, since the dumped `(pin "file:..."
# ...)` line (an incidental cell the canonical run's real observe-fn call
# also recorded, harmless here because the probe short-circuit means it is
# never actually consulted) names a blob hash that must already be present
# locally for preseed_pins_from_file's re-hash-before-trust check to pass;
# $PIN_HOME's store has held that blob since the canonical run above.
# =====================================================================
echo "--- pinned: 6 pull combos ---"

# A real (if functionally unused — this program forces no `node` at all,
# so the scheduler never actually has a batch to dispatch anywhere)
# cluster member for --schedule remote:B, matching tests/047/048/052's own
# setup shape rather than relying on remote dispatch being a silent no-op
# for an empty job batch.
mkdir -p "$PIN_HOME/.pp/cluster"
REMOTE_HOME="$TMP/home-remoteB"; mkdir -p "$REMOTE_HOME/.pp/cluster"
HOME="$PIN_HOME" "$PP" cluster-init > /dev/null 2>&1
cp "$PIN_HOME/.pp/cluster/secret" "$PIN_HOME/.pp/cluster/id" "$REMOTE_HOME/.pp/cluster/"
echo "B $REMOTE_HOME/.pp/store" > "$PIN_HOME/.pp/cluster/members"

DIVERGED_VALUE=999
printf '%s\n' "$DIVERGED_VALUE" > "$METRICS"

NAMES=(serial parallel remote)
FLAGSET=("" "--schedule parallel:4" "--schedule remote:B")
ALL_MATCH=1
for i in 0 1 2; do
  name="${NAMES[$i]}"
  sentinel="$TMP/sentinel-pinned-$name.txt"
  out=$(HOME="$PIN_HOME" "$PP" ${FLAGSET[$i]} "${GRANTS[@]}" --pin-file "$PINS_FILE" \
        --publish-object "$SHARED" "$DEMO_PP" -- "$METRICS" "$sentinel" 2>&1)
  h=$(printf '%s' "$out" | grep -oE '[0-9a-f]{64}' | head -1)
  if [ "$h" = "$CANON_HASH" ] && [ -n "$h" ]; then
    ok "pinned-$name-hash-matches-canonical ($h)"
  else
    bad "pinned-$name-hash-matches-canonical" "got=$h want=$CANON_HASH" "$out"
    ALL_MATCH=0
  fi
  if [ ! -f "$sentinel" ]; then
    ok "pinned-$name-observe-fn-not-called"
  else
    bad "pinned-$name-observe-fn-not-called" "sentinel present — observe-fn ran despite --pin-file"
  fi
done
[ "$ALL_MATCH" -eq 1 ] && ok "all-3-pull-combos-match-canonical-hash (diverged metrics value=$DIVERGED_VALUE, canonical=$CANON_VALUE)" \

echo
if [ "$fail" -eq 0 ]; then
  echo "=== 053 PIN-OBSERVATIONS: ALL PASS ==="
else
  echo "=== 053 PIN-OBSERVATIONS: FAILURES ABOVE ==="
fi
exit "$fail"
